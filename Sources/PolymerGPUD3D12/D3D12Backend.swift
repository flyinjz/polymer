// Direct3D 12 backend: offscreen render targets, uploads, the six programs
// of `GPUProgram` as pipelines, and readback. It never makes a window; a
// window's swap chain will present a target made here.
//
// Every `execute` records one command list, submits it and waits, so a
// batch can be reused at once and textures can be destroyed safely.
// (Several frames in flight come with the window.)
#if os(Windows)
import WinSDK
import WinSDK.DirectX.Direct3D11
import WinSDK.DirectX.Direct3D12
import WinSDK.DirectX._DXGI
import WinSDK.DirectX.D3DCompiler
import PolymerBase
import PolymerGPU

public final class D3D12Backend: GPUBackend {
    public let name: String
    /// True for the software rasteriser (WARP).
    public let isSoftware: Bool

    let device: UnsafeMutablePointer<ID3D12Device>
    let queue: UnsafeMutablePointer<ID3D12CommandQueue>
    let allocator: UnsafeMutablePointer<ID3D12CommandAllocator>
    let list: UnsafeMutablePointer<ID3D12GraphicsCommandList>
    let fence: UnsafeMutablePointer<ID3D12Fence>
    var fenceValue: UInt64 = 0
    let event: HANDLE
    let rootSignature: UnsafeMutablePointer<ID3D12RootSignature>
    var pipelines: [UnsafeMutablePointer<ID3D12PipelineState>] = []

    let srvHeap: UnsafeMutablePointer<ID3D12DescriptorHeap>
    let rtvHeap: UnsafeMutablePointer<ID3D12DescriptorHeap>
    let srvIncrement: UInt64, rtvIncrement: UInt64
    let srvCPU: UInt64, srvGPU: UInt64, rtvCPU: UInt64
    var freeSRV: [Int], freeRTV: [Int]
    static let srvCount = 4096, rtvCount = 1024

    struct Texture {
        let resource: UnsafeMutablePointer<ID3D12Resource>
        var state: D3D12_RESOURCE_STATES
        let srv: Int
        let rtv: Int?
        let format: DXGI_FORMAT
        let bytesPerPixel: Int
    }
    var textures: [Int: Texture] = [:]
    var nextID = 1

    var upload: (resource: UnsafeMutablePointer<ID3D12Resource>, memory: UnsafeMutableRawPointer, size: Int, address: UInt64)?
    var readback: (resource: UnsafeMutablePointer<ID3D12Resource>, size: Int)?

    /// Makes a backend on the GPU `adapter` asks for (`GPU.install(D3D12Backend.make)`).
    public static func make(_ adapter: GPUAdapter) throws(GPUError) -> any GPUBackend { try D3D12Backend(adapter) }

    public init(_ adapter: GPUAdapter = .automatic) throws(GPUError) {
        var factoryIID = IID_IDXGIFactory4
        var raw: UnsafeMutableRawPointer?
        try check(CreateDXGIFactory2(0, &factoryIID, &raw), "CreateDXGIFactory2")
        let factory = raw!.assumingMemoryBound(to: IDXGIFactory4.self)
        defer { release(factory) }

        var found: (UnsafeMutablePointer<ID3D12Device>, String)?
        if adapter != .software {
            var i: UInt32 = 0
            while found == nil {
                var a: UnsafeMutablePointer<IDXGIAdapter1>?
                if factory.pointee.lpVtbl.pointee.EnumAdapters1(factory, i, &a) < 0 { break }
                i += 1
                guard let a else { continue }
                defer { release(a) }
                var desc = DXGI_ADAPTER_DESC1()
                _ = a.pointee.lpVtbl.pointee.GetDesc1(a, &desc)
                if desc.Flags & UInt32(DXGI_ADAPTER_FLAG_SOFTWARE.rawValue) != 0 { continue }
                if let d = Self.createDevice(UnsafeMutableRawPointer(a)) {
                    let name = withUnsafeBytes(of: desc.Description) {
                        String(decoding: $0.bindMemory(to: UInt16.self).prefix { $0 != 0 }, as: UTF16.self)
                    }
                    found = (d, name)
                }
            }
        }
        if found == nil, adapter != .hardware {
            var adapterIID = IID_IDXGIAdapter
            var a: UnsafeMutableRawPointer?
            try check(factory.pointee.lpVtbl.pointee.EnumWarpAdapter(factory, &adapterIID, &a), "EnumWarpAdapter")
            defer { release(a!.assumingMemoryBound(to: IUnknown.self)) }
            if let d = Self.createDevice(a!) { found = (d, "WARP") }
        }
        guard let (device, adapterName) = found else {
            throw GPUError(adapter == .hardware ? "no Direct3D 12 GPU (feature level 11.0) on this machine; use .software for WARP"
                                                : "Direct3D 12 could not make a device, not even WARP")
        }
        self.device = device
        isSoftware = adapterName == "WARP"
        name = "Direct3D 12, \(adapterName)"

        var qd = D3D12_COMMAND_QUEUE_DESC()
        qd.Type = D3D12_COMMAND_LIST_TYPE_DIRECT
        queue = try comCreate("CreateCommandQueue", IID_ID3D12CommandQueue) { iid, out in
            device.pointee.lpVtbl.pointee.CreateCommandQueue(device, &qd, &iid, &out)
        }
        allocator = try comCreate("CreateCommandAllocator", IID_ID3D12CommandAllocator) { iid, out in
            device.pointee.lpVtbl.pointee.CreateCommandAllocator(device, D3D12_COMMAND_LIST_TYPE_DIRECT, &iid, &out)
        }
        let allocator = self.allocator
        list = try comCreate("CreateCommandList", IID_ID3D12GraphicsCommandList) { iid, out in
            device.pointee.lpVtbl.pointee.CreateCommandList(device, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator, nil, &iid, &out)
        }
        _ = list.pointee.lpVtbl.pointee.Close(list)
        fence = try comCreate("CreateFence", IID_ID3D12Fence) { iid, out in
            device.pointee.lpVtbl.pointee.CreateFence(device, 0, D3D12_FENCE_FLAG_NONE, &iid, &out)
        }
        guard let e = CreateEventW(nil, false, false, nil) else { throw GPUError("CreateEventW failed") }
        event = e

        // Descriptor heaps: shader-visible SRVs (slot 0 is a null texture), and RTVs.
        var hd = D3D12_DESCRIPTOR_HEAP_DESC()
        hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV
        hd.NumDescriptors = UInt32(Self.srvCount)
        hd.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE
        srvHeap = try comCreate("CreateDescriptorHeap", IID_ID3D12DescriptorHeap) { iid, out in
            device.pointee.lpVtbl.pointee.CreateDescriptorHeap(device, &hd, &iid, &out)
        }
        var rd = D3D12_DESCRIPTOR_HEAP_DESC()
        rd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV
        rd.NumDescriptors = UInt32(Self.rtvCount)
        rtvHeap = try comCreate("CreateDescriptorHeap", IID_ID3D12DescriptorHeap) { iid, out in
            device.pointee.lpVtbl.pointee.CreateDescriptorHeap(device, &rd, &iid, &out)
        }
        srvIncrement = UInt64(device.pointee.lpVtbl.pointee.GetDescriptorHandleIncrementSize(device, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV))
        rtvIncrement = UInt64(device.pointee.lpVtbl.pointee.GetDescriptorHandleIncrementSize(device, D3D12_DESCRIPTOR_HEAP_TYPE_RTV))
        var h = D3D12_CPU_DESCRIPTOR_HANDLE(), g = D3D12_GPU_DESCRIPTOR_HANDLE()
        _ = srvHeap.pointee.lpVtbl.pointee.GetCPUDescriptorHandleForHeapStart(srvHeap, &h); srvCPU = h.ptr
        _ = srvHeap.pointee.lpVtbl.pointee.GetGPUDescriptorHandleForHeapStart(srvHeap, &g); srvGPU = g.ptr
        _ = rtvHeap.pointee.lpVtbl.pointee.GetCPUDescriptorHandleForHeapStart(rtvHeap, &h); rtvCPU = h.ptr
        freeSRV = Array((1..<Self.srvCount).reversed())
        freeRTV = Array((0..<Self.rtvCount).reversed())
        var nullView = Self.srvDesc(DXGI_FORMAT_R16G16B16A16_FLOAT)
        device.pointee.lpVtbl.pointee.CreateShaderResourceView(device, nil, &nullView, D3D12_CPU_DESCRIPTOR_HANDLE(ptr: srvCPU))

        rootSignature = try Self.makeRootSignature(device)
        try makePipelines()
    }

    deinit {
        for t in textures.values { release(t.resource) }
        if let u = upload { release(u.resource) }
        if let r = readback { release(r.resource) }
        for p in pipelines { release(p) }
        release(rootSignature); release(srvHeap); release(rtvHeap)
        release(fence); release(list); release(allocator); release(queue); release(device)
        CloseHandle(event)
    }

    static func createDevice(_ adapter: UnsafeMutableRawPointer) -> UnsafeMutablePointer<ID3D12Device>? {
        var iid = IID_ID3D12Device
        var raw: UnsafeMutableRawPointer?
        guard D3D12CreateDevice(adapter.assumingMemoryBound(to: IUnknown.self), D3D_FEATURE_LEVEL_11_0, &iid, &raw) >= 0 else { return nil }
        return raw?.assumingMemoryBound(to: ID3D12Device.self)
    }

    // MARK: Root signature and pipelines

    /// b0: 8 constants; t1, t2: instances and data (root SRVs); t0: the source texture (a table).
    static func makeRootSignature(_ device: UnsafeMutablePointer<ID3D12Device>) throws(GPUError) -> UnsafeMutablePointer<ID3D12RootSignature> {
        var range = D3D12_DESCRIPTOR_RANGE()
        range.RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SRV
        range.NumDescriptors = 1
        var params = [D3D12_ROOT_PARAMETER](repeating: D3D12_ROOT_PARAMETER(), count: 4)
        params[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS
        params[0].Constants = D3D12_ROOT_CONSTANTS(ShaderRegister: 0, RegisterSpace: 0, Num32BitValues: 8)
        params[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_SRV
        params[1].Descriptor = D3D12_ROOT_DESCRIPTOR(ShaderRegister: 1, RegisterSpace: 0)
        params[2].ParameterType = D3D12_ROOT_PARAMETER_TYPE_SRV
        params[2].Descriptor = D3D12_ROOT_DESCRIPTOR(ShaderRegister: 2, RegisterSpace: 0)
        for i in 0..<4 { params[i].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL }
        params[3].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE
        params[3].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL
        var blob: UnsafeMutablePointer<ID3DBlob>?, errors: UnsafeMutablePointer<ID3DBlob>?
        let hr = withUnsafePointer(to: &range) { r in
            params[3].DescriptorTable = D3D12_ROOT_DESCRIPTOR_TABLE(NumDescriptorRanges: 1, pDescriptorRanges: r)
            return params.withUnsafeBufferPointer { p in
                var desc = D3D12_ROOT_SIGNATURE_DESC(NumParameters: 4, pParameters: p.baseAddress, NumStaticSamplers: 0,
                                                     pStaticSamplers: nil, Flags: D3D12_ROOT_SIGNATURE_FLAG_NONE)
                return D3D12SerializeRootSignature(&desc, D3D_ROOT_SIGNATURE_VERSION_1, &blob, &errors)
            }
        }
        defer { if let blob { release(blob) }; if let errors { release(errors) } }
        guard hr >= 0, let blob else { throw GPUError("D3D12SerializeRootSignature failed: \(text(errors))") }
        let bytes = blob.pointee.lpVtbl.pointee.GetBufferPointer(blob)
        let size = blob.pointee.lpVtbl.pointee.GetBufferSize(blob)
        return try comCreate("CreateRootSignature", IID_ID3D12RootSignature) { iid, out in
            device.pointee.lpVtbl.pointee.CreateRootSignature(device, 0, bytes, size, &iid, &out)
        }
    }

    static func compile(_ entry: String, _ target: String) throws(GPUError) -> UnsafeMutablePointer<ID3DBlob> {
        var code: UnsafeMutablePointer<ID3DBlob>?, errors: UnsafeMutablePointer<ID3DBlob>?
        // Optimised, with IEEE strictness so the arithmetic follows the CPU reference.
        let flags: UInt32 = (1 << 15) | (1 << 13)
        let hr = hlslSource.withCString { s in
            D3DCompile(s, SIZE_T(strlen(s)), "polymer.hlsl", nil, nil, entry, target, flags, 0, &code, &errors)
        }
        defer { if let errors { release(errors) } }
        guard hr >= 0, let code else { throw GPUError("compiling \(entry) failed: \(text(errors))") }
        return code
    }

    func makePipelines() throws(GPUError) {
        let vs = try Self.compile("vsQuad", "vs_5_0")
        defer { release(vs) }
        let entries: [GPUProgram: String] = [.rect: "psRect", .mask: "psMask", .image: "psImage", .blur: "psBlur",
                                             .backdrop: "psBackdrop", .composite: "psComposite", .present: "psPresent",
                                             .downsample: "psDownsample", .upsample: "psUpsample"]
        for program in GPUProgram.allCases {
            let ps = try Self.compile(entries[program]!, "ps_5_0")
            defer { release(ps) }
            var d = D3D12_GRAPHICS_PIPELINE_STATE_DESC()
            d.pRootSignature = rootSignature
            d.VS = D3D12_SHADER_BYTECODE(pShaderBytecode: vs.pointee.lpVtbl.pointee.GetBufferPointer(vs),
                                         BytecodeLength: vs.pointee.lpVtbl.pointee.GetBufferSize(vs))
            d.PS = D3D12_SHADER_BYTECODE(pShaderBytecode: ps.pointee.lpVtbl.pointee.GetBufferPointer(ps),
                                         BytecodeLength: ps.pointee.lpVtbl.pointee.GetBufferSize(ps))
            var blend = D3D12_RENDER_TARGET_BLEND_DESC()
            blend.RenderTargetWriteMask = UInt8(D3D12_COLOR_WRITE_ENABLE_ALL.rawValue)
            blend.BlendOp = D3D12_BLEND_OP_ADD; blend.BlendOpAlpha = D3D12_BLEND_OP_ADD
            blend.LogicOp = D3D12_LOGIC_OP_NOOP
            switch program {
            case .blur, .present, .downsample, .upsample:
                blend.BlendEnable = false
                blend.SrcBlend = D3D12_BLEND_ONE; blend.DestBlend = D3D12_BLEND_ZERO
                blend.SrcBlendAlpha = D3D12_BLEND_ONE; blend.DestBlendAlpha = D3D12_BLEND_ZERO
            case .backdrop:
                // out = colour * coverage + target * (1 - coverage), coverage from the second output.
                blend.BlendEnable = true
                blend.SrcBlend = D3D12_BLEND_ONE; blend.DestBlend = D3D12_BLEND_INV_SRC1_ALPHA
                blend.SrcBlendAlpha = D3D12_BLEND_ONE; blend.DestBlendAlpha = D3D12_BLEND_INV_SRC1_ALPHA
            default:
                // Premultiplied source-over.
                blend.BlendEnable = true
                blend.SrcBlend = D3D12_BLEND_ONE; blend.DestBlend = D3D12_BLEND_INV_SRC_ALPHA
                blend.SrcBlendAlpha = D3D12_BLEND_ONE; blend.DestBlendAlpha = D3D12_BLEND_INV_SRC_ALPHA
            }
            d.BlendState.RenderTarget.0 = blend
            d.SampleMask = UInt32.max
            d.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID
            d.RasterizerState.CullMode = D3D12_CULL_MODE_NONE
            d.RasterizerState.DepthClipEnable = true
            d.DepthStencilState.DepthEnable = false
            d.DepthStencilState.DepthWriteMask = D3D12_DEPTH_WRITE_MASK_ZERO
            d.DepthStencilState.DepthFunc = D3D12_COMPARISON_FUNC_ALWAYS
            d.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE
            d.NumRenderTargets = 1
            d.RTVFormats.0 = program == .present ? DXGI_FORMAT_B8G8R8A8_UNORM : DXGI_FORMAT_R16G16B16A16_FLOAT
            d.SampleDesc = DXGI_SAMPLE_DESC(Count: 1, Quality: 0)
            let device = self.device
            let pso: UnsafeMutablePointer<ID3D12PipelineState> = try comCreate("CreateGraphicsPipelineState (\(program))",
                                                                             IID_ID3D12PipelineState) { iid, out in
                device.pointee.lpVtbl.pointee.CreateGraphicsPipelineState(device, &d, &iid, &out)
            }
            pipelines.append(pso)
        }
    }

    // MARK: Textures

    static func srvDesc(_ format: DXGI_FORMAT) -> D3D12_SHADER_RESOURCE_VIEW_DESC {
        var v = D3D12_SHADER_RESOURCE_VIEW_DESC()
        v.Format = format
        v.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D
        v.Shader4ComponentMapping = 0x1688   // D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING
        v.Texture2D = D3D12_TEX2D_SRV(MostDetailedMip: 0, MipLevels: 1, PlaneSlice: 0, ResourceMinLODClamp: 0)
        return v
    }

    public func makeTexture(width: Int, height: Int, format: GPUFormat) throws(GPUError) -> GPUTexture {
        guard width > 0, height > 0, width <= 16384, height <= 16384 else {
            throw GPUError("a \(width)x\(height) texture is outside 1...16384 pixels a side")
        }
        guard let srv = freeSRV.popLast() else { throw GPUError("more than \(Self.srvCount - 1) textures at once; destroy unused ones") }
        let isTarget = format == .rgba16Float || format == .bgra8
        let rtv = isTarget ? freeRTV.popLast() : nil
        if isTarget && rtv == nil { freeSRV.append(srv); throw GPUError("more than \(Self.rtvCount) render targets at once") }
        let dxgi: DXGI_FORMAT = switch format {
        case .rgba16Float: DXGI_FORMAT_R16G16B16A16_FLOAT
        case .rgba8: DXGI_FORMAT_R8G8B8A8_UNORM
        case .r8: DXGI_FORMAT_R8_UNORM
        case .bgra8: DXGI_FORMAT_B8G8R8A8_UNORM
        }
        var heap = D3D12_HEAP_PROPERTIES()
        heap.Type = D3D12_HEAP_TYPE_DEFAULT
        heap.CreationNodeMask = 1; heap.VisibleNodeMask = 1
        var desc = D3D12_RESOURCE_DESC()
        desc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D
        desc.Width = UInt64(width); desc.Height = UInt32(height)
        desc.DepthOrArraySize = 1; desc.MipLevels = 1
        desc.Format = dxgi
        desc.SampleDesc = DXGI_SAMPLE_DESC(Count: 1, Quality: 0)
        desc.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN
        desc.Flags = isTarget ? D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET : D3D12_RESOURCE_FLAG_NONE
        let state = isTarget ? D3D12_RESOURCE_STATE_RENDER_TARGET : D3D12_RESOURCE_STATE_COPY_DEST
        let device = self.device
        let resource: UnsafeMutablePointer<ID3D12Resource>
        do {
            resource = try comCreate("CreateCommittedResource (\(width)x\(height) \(format))", IID_ID3D12Resource) { iid, out in
                device.pointee.lpVtbl.pointee.CreateCommittedResource(device, &heap, D3D12_HEAP_FLAG_NONE, &desc, state, nil, &iid, &out)
            }
        } catch {
            freeSRV.append(srv); if let rtv { freeRTV.append(rtv) }
            throw error
        }
        var view = Self.srvDesc(dxgi)
        device.pointee.lpVtbl.pointee.CreateShaderResourceView(device, resource, &view, D3D12_CPU_DESCRIPTOR_HANDLE(ptr: srvCPU + UInt64(srv) * srvIncrement))
        if let rtv {
            device.pointee.lpVtbl.pointee.CreateRenderTargetView(device, resource, nil, D3D12_CPU_DESCRIPTOR_HANDLE(ptr: rtvCPU + UInt64(rtv) * rtvIncrement))
        }
        let id = nextID
        nextID += 1
        textures[id] = Texture(resource: resource, state: state, srv: srv, rtv: rtv, format: dxgi, bytesPerPixel: format.bytesPerPixel)
        return GPUTexture(id: id, width: width, height: height, format: format)
    }

    public func destroy(_ texture: GPUTexture) {
        guard let t = textures.removeValue(forKey: texture.id) else { return }
        release(t.resource)
        freeSRV.append(t.srv)
        if let r = t.rtv { freeRTV.append(r) }
    }

    func transition(_ id: Int, to state: D3D12_RESOURCE_STATES) {
        guard var t = textures[id], t.state != state else { return }
        var b = D3D12_RESOURCE_BARRIER()
        b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION
        b.Flags = D3D12_RESOURCE_BARRIER_FLAG_NONE
        b.Transition = D3D12_RESOURCE_TRANSITION_BARRIER(pResource: t.resource, Subresource: 0xffff_ffff,
                                                         StateBefore: t.state, StateAfter: state)
        list.pointee.lpVtbl.pointee.ResourceBarrier(list, 1, &b)
        t.state = state
        textures[id] = t
    }

    // MARK: Buffers

    func buffer(_ size: Int, _ heapType: D3D12_HEAP_TYPE, _ state: D3D12_RESOURCE_STATES) throws(GPUError) -> UnsafeMutablePointer<ID3D12Resource> {
        var heap = D3D12_HEAP_PROPERTIES()
        heap.Type = heapType
        heap.CreationNodeMask = 1; heap.VisibleNodeMask = 1
        var desc = D3D12_RESOURCE_DESC()
        desc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER
        desc.Width = UInt64(size); desc.Height = 1; desc.DepthOrArraySize = 1; desc.MipLevels = 1
        desc.Format = DXGI_FORMAT_UNKNOWN
        desc.SampleDesc = DXGI_SAMPLE_DESC(Count: 1, Quality: 0)
        desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR
        let device = self.device
        return try comCreate("CreateCommittedResource (buffer of \(size) bytes)", IID_ID3D12Resource) { iid, out in
            device.pointee.lpVtbl.pointee.CreateCommittedResource(device, &heap, D3D12_HEAP_FLAG_NONE, &desc, state, nil, &iid, &out)
        }
    }

    /// The upload buffer, at least `size` bytes, mapped for good.
    func uploadMemory(_ size: Int) throws(GPUError) -> (UnsafeMutableRawPointer, UInt64) {
        if let u = upload, u.size >= size { return (u.memory, u.address) }
        if let u = upload { release(u.resource); upload = nil }
        var n = 1 << 20
        while n < size { n *= 2 }
        let r = try buffer(n, D3D12_HEAP_TYPE_UPLOAD, D3D12_RESOURCE_STATE_GENERIC_READ)
        var p: UnsafeMutableRawPointer?
        var none = D3D12_RANGE(Begin: 0, End: 0)
        try check(r.pointee.lpVtbl.pointee.Map(r, 0, &none, &p), "mapping the upload buffer")
        let address = r.pointee.lpVtbl.pointee.GetGPUVirtualAddress(r)
        upload = (r, p!, n, address)
        return (p!, address)
    }

    // MARK: Running commands

    func begin() throws(GPUError) {
        try check(allocator.pointee.lpVtbl.pointee.Reset(allocator), "resetting the command allocator")
        try check(list.pointee.lpVtbl.pointee.Reset(list, allocator, nil), "resetting the command list")
    }

    func submitAndWait() throws(GPUError) {
        try check(list.pointee.lpVtbl.pointee.Close(list), "closing the command list")
        var lists: [UnsafeMutablePointer<ID3D12CommandList>?] = [UnsafeMutableRawPointer(list).assumingMemoryBound(to: ID3D12CommandList.self)]
        queue.pointee.lpVtbl.pointee.ExecuteCommandLists(queue, 1, &lists)
        fenceValue += 1
        try check(queue.pointee.lpVtbl.pointee.Signal(queue, fence, fenceValue), "signalling the fence")
        if fence.pointee.lpVtbl.pointee.GetCompletedValue(fence) < fenceValue {
            try check(fence.pointee.lpVtbl.pointee.SetEventOnCompletion(fence, fenceValue, event), "waiting for the GPU")
            WaitForSingleObject(event, INFINITE)
        }
        let removed = device.pointee.lpVtbl.pointee.GetDeviceRemovedReason(device)
        if removed < 0 { throw GPUError("the GPU device was removed (HRESULT 0x\(String(UInt32(bitPattern: removed), radix: 16)))") }
    }

    public func execute(_ batch: GPUBatch) throws(GPUError) { try execute(batch, endStates: []) }

    /// Runs a batch, then leaves the given textures in the given states (a back buffer ready to present).
    func execute(_ batch: GPUBatch, endStates: [(Int, D3D12_RESOURCE_STATES)]) throws(GPUError) {
        guard !batch.isEmpty else { return }
        func align(_ n: Int, _ a: Int) -> Int { (n + a - 1) / a * a }
        // Upload buffer: instances, data, then each upload's rows (rows 256-byte aligned, placed 512-aligned).
        let instanceBytes = batch.instances.count * MemoryLayout<GPUInstance>.stride
        let dataOffset = align(instanceBytes, 256)
        let dataBytes = batch.data.count * MemoryLayout<SIMD4<Float>>.stride
        var offset = align(dataOffset + dataBytes, 512)
        var placements: [(offset: Int, pitch: Int)] = []
        placements.reserveCapacity(batch.uploads.count)
        for u in batch.uploads {
            let pitch = align(u.rect.width * u.texture.format.bytesPerPixel, 256)
            placements.append((offset, pitch))
            offset = align(offset + pitch * u.rect.height, 512)
        }
        let (memory, address) = try uploadMemory(max(offset, 256))
        batch.instances.withUnsafeBytes { memory.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        if dataBytes > 0 { batch.data.withUnsafeBytes { (memory + dataOffset).copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }
        batch.bytes.withUnsafeBytes { src in
            for (u, p) in zip(batch.uploads, placements) {
                let row = u.rect.width * u.texture.format.bytesPerPixel
                for y in 0..<u.rect.height {
                    (memory + p.offset + y * p.pitch).copyMemory(from: src.baseAddress! + u.bytes.lowerBound + y * row, byteCount: row)
                }
            }
        }

        try begin()
        let list = self.list
        var heaps: [UnsafeMutablePointer<ID3D12DescriptorHeap>?] = [srvHeap]
        list.pointee.lpVtbl.pointee.SetDescriptorHeaps(list, 1, &heaps)
        list.pointee.lpVtbl.pointee.SetGraphicsRootSignature(list, rootSignature)
        list.pointee.lpVtbl.pointee.SetGraphicsRootShaderResourceView(list, 1, address)
        list.pointee.lpVtbl.pointee.SetGraphicsRootShaderResourceView(list, 2, address + UInt64(dataOffset))
        list.pointee.lpVtbl.pointee.IASetPrimitiveTopology(list, D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP)

        let uploadResource = upload!.resource
        for (u, p) in zip(batch.uploads, placements) {
            guard let t = textures[u.texture.id] else { continue }
            transition(u.texture.id, to: D3D12_RESOURCE_STATE_COPY_DEST)
            var dst = D3D12_TEXTURE_COPY_LOCATION()
            dst.pResource = t.resource; dst.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX; dst.SubresourceIndex = 0
            var src = D3D12_TEXTURE_COPY_LOCATION()
            src.pResource = uploadResource; src.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT
            src.PlacedFootprint = D3D12_PLACED_SUBRESOURCE_FOOTPRINT(
                Offset: UInt64(p.offset),
                Footprint: D3D12_SUBRESOURCE_FOOTPRINT(Format: t.format, Width: UInt32(u.rect.width), Height: UInt32(u.rect.height),
                                                       Depth: 1, RowPitch: UInt32(p.pitch)))
            list.pointee.lpVtbl.pointee.CopyTextureRegion(list, &dst, UInt32(u.rect.x), UInt32(u.rect.y), 0, &src, nil)
        }

        var lastPipeline = -1, lastTarget = -1
        for command in batch.commands {
            switch command {
            case .clear(let s, let r, let c):
                guard let t = textures[s.texture.id], let rtv = t.rtv else { continue }
                transition(s.texture.id, to: D3D12_RESOURCE_STATE_RENDER_TARGET)
                var rect = RECT(left: Int32(r.x - s.x), top: Int32(r.y - s.y), right: Int32(r.x + r.width - s.x), bottom: Int32(r.y + r.height - s.y))
                var color = (c.x, c.y, c.z, c.w)
                withUnsafePointer(to: &color) { p in
                    p.withMemoryRebound(to: Float.self, capacity: 4) { f in
                        list.pointee.lpVtbl.pointee.ClearRenderTargetView(list, D3D12_CPU_DESCRIPTOR_HANDLE(ptr: rtvCPU + UInt64(rtv) * rtvIncrement), f, 1, &rect)
                    }
                }
            case .copy(let from, let to, let r):
                guard let a = textures[from.texture.id], let b = textures[to.texture.id] else { continue }
                transition(from.texture.id, to: D3D12_RESOURCE_STATE_COPY_SOURCE)
                transition(to.texture.id, to: D3D12_RESOURCE_STATE_COPY_DEST)
                var dst = D3D12_TEXTURE_COPY_LOCATION()
                dst.pResource = b.resource; dst.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX; dst.SubresourceIndex = 0
                var src = D3D12_TEXTURE_COPY_LOCATION()
                src.pResource = a.resource; src.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX; src.SubresourceIndex = 0
                var box = D3D12_BOX(left: UInt32(r.x - from.x), top: UInt32(r.y - from.y), front: 0,
                                    right: UInt32(r.x + r.width - from.x), bottom: UInt32(r.y + r.height - from.y), back: 1)
                list.pointee.lpVtbl.pointee.CopyTextureRegion(list, &dst, UInt32(r.x - to.x), UInt32(r.y - to.y), 0, &src, &box)
            case .draw(let d):
                guard let t = textures[d.target.texture.id], let rtv = t.rtv else { continue }
                let sc = d.scissor.clamped(to: d.target.bounds)
                if sc.isEmpty || d.instances.isEmpty { continue }
                transition(d.target.texture.id, to: D3D12_RESOURCE_STATE_RENDER_TARGET)
                var table = srvGPU
                if let s = d.source, let st = textures[s.texture.id] {
                    transition(s.texture.id, to: D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE)
                    table = srvGPU + UInt64(st.srv) * srvIncrement
                }
                if lastPipeline != d.program.rawValue {
                    list.pointee.lpVtbl.pointee.SetPipelineState(list, pipelines[d.program.rawValue])
                    lastPipeline = d.program.rawValue
                }
                if lastTarget != d.target.texture.id {
                    var h = D3D12_CPU_DESCRIPTOR_HANDLE(ptr: rtvCPU + UInt64(rtv) * rtvIncrement)
                    list.pointee.lpVtbl.pointee.OMSetRenderTargets(list, 1, &h, false, nil)
                    var vp = D3D12_VIEWPORT(TopLeftX: 0, TopLeftY: 0, Width: Float(d.target.texture.width),
                                            Height: Float(d.target.texture.height), MinDepth: 0, MaxDepth: 1)
                    list.pointee.lpVtbl.pointee.RSSetViewports(list, 1, &vp)
                    lastTarget = d.target.texture.id
                }
                var rect = RECT(left: Int32(sc.x - d.target.x), top: Int32(sc.y - d.target.y),
                                right: Int32(sc.x + sc.width - d.target.x), bottom: Int32(sc.y + sc.height - d.target.y))
                list.pointee.lpVtbl.pointee.RSSetScissorRects(list, 1, &rect)
                var constants: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) = (
                    Float(d.target.x).bitPattern, Float(d.target.y).bitPattern,
                    Float(d.target.texture.width).bitPattern, Float(d.target.texture.height).bitPattern,
                    Float(d.source?.x ?? 0).bitPattern, Float(d.source?.y ?? 0).bitPattern,
                    UInt32(d.instances.lowerBound), 0)
                list.pointee.lpVtbl.pointee.SetGraphicsRoot32BitConstants(list, 0, 8, &constants, 0)
                list.pointee.lpVtbl.pointee.SetGraphicsRootDescriptorTable(list, 3, D3D12_GPU_DESCRIPTOR_HANDLE(ptr: table))
                list.pointee.lpVtbl.pointee.DrawInstanced(list, 4, UInt32(d.instances.count), 0, 0)
            }
        }
        for (id, state) in endStates { transition(id, to: state) }
        try submitAndWait()
    }

    public func read(_ texture: GPUTexture) throws(GPUError) -> [Float] {
        guard let t = textures[texture.id], texture.format == .rgba16Float || texture.format == .bgra8 else {
            throw GPUError("only render targets (rgba16Float, bgra8) can be read back")
        }
        let bpp = texture.format.bytesPerPixel
        let pitch = (texture.width * bpp + 255) / 256 * 256
        let size = pitch * texture.height
        if readback == nil || readback!.size < size {
            if let r = readback { release(r.resource) }
            readback = (try buffer(size, D3D12_HEAP_TYPE_READBACK, D3D12_RESOURCE_STATE_COPY_DEST), size)
        }
        let rb = readback!.resource
        try begin()
        transition(texture.id, to: D3D12_RESOURCE_STATE_COPY_SOURCE)
        var dst = D3D12_TEXTURE_COPY_LOCATION()
        dst.pResource = rb; dst.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT
        dst.PlacedFootprint = D3D12_PLACED_SUBRESOURCE_FOOTPRINT(
            Offset: 0, Footprint: D3D12_SUBRESOURCE_FOOTPRINT(Format: t.format, Width: UInt32(texture.width), Height: UInt32(texture.height),
                                                              Depth: 1, RowPitch: UInt32(pitch)))
        var src = D3D12_TEXTURE_COPY_LOCATION()
        src.pResource = t.resource; src.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX; src.SubresourceIndex = 0
        list.pointee.lpVtbl.pointee.CopyTextureRegion(list, &dst, 0, 0, 0, &src, nil)
        try submitAndWait()

        var p: UnsafeMutableRawPointer?
        var range = D3D12_RANGE(Begin: 0, End: SIZE_T(size))
        try check(rb.pointee.lpVtbl.pointee.Map(rb, 0, &range, &p), "mapping the readback buffer")
        var out = [Float](repeating: 0, count: texture.width * texture.height * 4)
        out.withUnsafeMutableBufferPointer { o in
            for y in 0..<texture.height {
                if bpp == 8 {
                    let row = (p! + y * pitch).assumingMemoryBound(to: UInt16.self)
                    for i in 0..<(texture.width * 4) { o[y * texture.width * 4 + i] = halfToFloat(row[i]) }
                } else {
                    let row = (p! + y * pitch).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<texture.width {
                        let s = x * 4, d = (y * texture.width + x) * 4
                        o[d] = Float(row[s + 2]) / 255; o[d + 1] = Float(row[s + 1]) / 255
                        o[d + 2] = Float(row[s]) / 255; o[d + 3] = Float(row[s + 3]) / 255
                    }
                }
            }
        }
        var none = D3D12_RANGE(Begin: 0, End: 0)
        rb.pointee.lpVtbl.pointee.Unmap(rb, 0, &none)
        return out
    }
}

// MARK: COM helpers

func check(_ hr: HRESULT, _ what: @autoclosure () -> String) throws(GPUError) {
    if hr < 0 { throw GPUError("\(what()) failed (HRESULT 0x\(String(UInt32(bitPattern: hr), radix: 16)))") }
}

/// Calls a COM factory method and returns the object it made.
func comCreate<T>(_ what: String, _ iid: IID, _ body: (inout IID, inout UnsafeMutableRawPointer?) -> HRESULT) throws(GPUError) -> UnsafeMutablePointer<T> {
    var iid = iid
    var raw: UnsafeMutableRawPointer?
    try check(body(&iid, &raw), what)
    guard let raw else { throw GPUError("\(what) returned nothing") }
    return raw.assumingMemoryBound(to: T.self)
}

func release<T>(_ p: UnsafeMutablePointer<T>) {
    let u = UnsafeMutableRawPointer(p).assumingMemoryBound(to: IUnknown.self)
    _ = u.pointee.lpVtbl.pointee.Release(u)
}

/// The text in a D3D error blob.
func text(_ blob: UnsafeMutablePointer<ID3DBlob>?) -> String {
    guard let blob, let p = blob.pointee.lpVtbl.pointee.GetBufferPointer(blob) else { return "no details" }
    let n = Int(blob.pointee.lpVtbl.pointee.GetBufferSize(blob))
    return String(decoding: UnsafeRawBufferPointer(start: p, count: n).prefix { $0 != 0 }, as: UTF8.self)
}

@inline(__always) func halfToFloat(_ h: UInt16) -> Float {
    let sign: UInt32 = UInt32(h & 0x8000) << 16
    let e = Int((h >> 10) & 0x1f), m = UInt32(h & 0x3ff)
    if e == 0 {
        let v = Float(m) * (1 / 16_777_216)   // m * 2^-24
        return sign != 0 ? -v : v
    }
    if e == 31 { return Float(bitPattern: sign | 0x7f80_0000 | (m << 13)) }
    return Float(bitPattern: sign | (UInt32(e + 112) << 23) | (m << 13))
}
#endif
