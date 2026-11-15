// Presenting render targets: a flip-model swap chain on a window, or two
// offscreen buffers (handle 0) that behave the same, for headless checks.
//
// Each frame copies into the back buffer only what it hasn't got: the damage
// of every frame since that buffer was last shown. The swap chain is told
// this frame's damage (dirty rectangles), so the compositor redraws only that.
// A waitable swap chain with a frame latency of one paces drawing to the
// display's refresh, whatever its rate.
#if os(Windows)
import WinSDK
import WinSDK.DirectX.Direct3D11
import WinSDK.DirectX.Direct3D12
import WinSDK.DirectX._DXGI
import PolymerBase
import PolymerGPU

extension D3D12Backend: GPUPresenting {
    public func makePresenter(windowHandle: UInt, width: Int, height: Int) throws(GPUError) -> any GPUPresenter {
        try D3D12Presenter(self, windowHandle: windowHandle, width: width, height: height)
    }

    /// Adds a resource made elsewhere (a swap chain's buffer) as a render target; `destroy` releases it.
    func register(_ resource: UnsafeMutablePointer<ID3D12Resource>, width: Int, height: Int,
                  state: D3D12_RESOURCE_STATES) throws(GPUError) -> GPUTexture {
        guard let srv = freeSRV.popLast(), let rtv = freeRTV.popLast() else { throw GPUError("out of descriptors") }
        device.pointee.lpVtbl.pointee.CreateRenderTargetView(device, resource, nil, D3D12_CPU_DESCRIPTOR_HANDLE(ptr: rtvCPU + UInt64(rtv) * rtvIncrement))
        let id = nextID
        nextID += 1
        textures[id] = Texture(resource: resource, state: state, srv: srv, rtv: rtv, format: DXGI_FORMAT_B8G8R8A8_UNORM, bytesPerPixel: 4)
        return GPUTexture(id: id, width: width, height: height, format: .bgra8)
    }
}

final class D3D12Presenter: GPUPresenter {
    let backend: D3D12Backend
    private(set) var width: Int
    private(set) var height: Int
    let swapChain: UnsafeMutablePointer<IDXGISwapChain3>?
    let waitable: HANDLE?
    var buffers: [GPUTexture] = []
    /// Per buffer: pixels changed since it was last shown (nil: all of them).
    var pending: [[PixelRect]?] = []
    /// The offscreen buffer to draw next, and the one shown last.
    var next = 0, shown = -1
    var batch = GPUBatch()
    var firstPresent = true
    static let flags = UInt32(DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT.rawValue)

    init(_ backend: D3D12Backend, windowHandle: UInt, width: Int, height: Int) throws(GPUError) {
        self.backend = backend
        self.width = max(1, width); self.height = max(1, height)
        guard windowHandle != 0, let hwnd = HWND(bitPattern: windowHandle) else {
            swapChain = nil; waitable = nil
            try makeBuffers()
            return
        }
        var factoryIID = IID_IDXGIFactory2
        var raw: UnsafeMutableRawPointer?
        try check(CreateDXGIFactory2(0, &factoryIID, &raw), "CreateDXGIFactory2")
        let factory = raw!.assumingMemoryBound(to: IDXGIFactory2.self)
        defer { release(factory) }
        var desc = DXGI_SWAP_CHAIN_DESC1()
        desc.Width = UInt32(self.width); desc.Height = UInt32(self.height)
        desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM
        desc.SampleDesc = DXGI_SAMPLE_DESC(Count: 1, Quality: 0)
        desc.BufferUsage = DXGI_USAGE(0x20)   // DXGI_USAGE_RENDER_TARGET_OUTPUT
        desc.BufferCount = 2
        desc.Scaling = DXGI_SCALING_NONE
        desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL
        desc.AlphaMode = DXGI_ALPHA_MODE_IGNORE
        desc.Flags = Self.flags
        var sc1: UnsafeMutablePointer<IDXGISwapChain1>?
        let queue = UnsafeMutableRawPointer(backend.queue).assumingMemoryBound(to: IUnknown.self)
        try check(factory.pointee.lpVtbl.pointee.CreateSwapChainForHwnd(factory, queue, hwnd, &desc, nil, nil, &sc1), "CreateSwapChainForHwnd")
        defer { release(sc1!) }
        _ = factory.pointee.lpVtbl.pointee.MakeWindowAssociation(factory, hwnd, UInt32(DXGI_MWA_NO_ALT_ENTER))
        var iid = IID_IDXGISwapChain3
        var sc3: UnsafeMutableRawPointer?
        try check(sc1!.pointee.lpVtbl.pointee.QueryInterface(sc1, &iid, &sc3), "IDXGISwapChain3")
        let sc = sc3!.assumingMemoryBound(to: IDXGISwapChain3.self)
        swapChain = sc
        _ = sc.pointee.lpVtbl.pointee.SetMaximumFrameLatency(sc, 1)
        waitable = sc.pointee.lpVtbl.pointee.GetFrameLatencyWaitableObject(sc)
        try makeBuffers()
    }

    deinit {
        for b in buffers { backend.destroy(b) }
        if let swapChain { release(swapChain) }
        if let waitable { CloseHandle(waitable) }
    }

    private func makeBuffers() throws(GPUError) {
        buffers = []
        if let sc = swapChain {
            for i in 0..<2 {
                var iid = IID_ID3D12Resource
                var raw: UnsafeMutableRawPointer?
                try check(sc.pointee.lpVtbl.pointee.GetBuffer(sc, UInt32(i), &iid, &raw), "getting swap chain buffer \(i)")
                buffers.append(try backend.register(raw!.assumingMemoryBound(to: ID3D12Resource.self), width: width, height: height,
                                                    state: D3D12_RESOURCE_STATE_COMMON))
            }
        } else {
            for _ in 0..<2 { buffers.append(try backend.makeTexture(width: width, height: height, format: .bgra8)) }
        }
        pending = [nil, nil]
        firstPresent = true
        next = 0; shown = -1
    }

    func resize(width: Int, height: Int) throws(GPUError) {
        let w = max(1, width), h = max(1, height)
        guard w != self.width || h != self.height else { return }
        for b in buffers { backend.destroy(b) }
        buffers = []
        self.width = w; self.height = h
        if let sc = swapChain {
            try check(sc.pointee.lpVtbl.pointee.ResizeBuffers(sc, 0, UInt32(w), UInt32(h), DXGI_FORMAT_UNKNOWN, Self.flags), "resizing the swap chain")
        }
        try makeBuffers()
    }

    func waitForFrame() {
        if let waitable { WaitForSingleObjectEx(waitable, 1000, true) }
    }

    func present(_ target: GPUTexture, damage: [PixelRect]) throws(GPUError) {
        let full = PixelRect(x: 0, y: 0, width: width, height: height)
        let rects = damage.map { $0.clamped(to: full) }.filter { !$0.isEmpty }
        // Every buffer now misses this frame's damage too.
        for i in pending.indices {
            if var p = pending[i] { p.append(contentsOf: rects); pending[i] = p.count > 64 ? nil : p }
        }
        let i = swapChain.map { Int($0.pointee.lpVtbl.pointee.GetCurrentBackBufferIndex($0)) } ?? next
        let copy = pending[i] ?? [full]
        pending[i] = []
        batch.removeAll()
        let source = GPUSurface(target, x: 0, y: 0)
        for r in copy { batch.instances.append(GPUInstance(quad: SIMD4(Float(r.x), Float(r.y), Float(r.x + r.width), Float(r.y + r.height)))) }
        if !copy.isEmpty {
            batch.commands.append(.draw(GPUDraw(target: GPUSurface(buffers[i], x: 0, y: 0), scissor: full, program: .present,
                                                source: source, instances: 0..<batch.instances.count)))
        }
        if let sc = swapChain {
            try backend.execute(batch, endStates: [(buffers[i].id, D3D12_RESOURCE_STATE_COMMON)])
            var dirty = rects.map { RECT(left: Int32($0.x), top: Int32($0.y), right: Int32($0.x + $0.width), bottom: Int32($0.y + $0.height)) }
            let hr: HRESULT = dirty.withUnsafeMutableBufferPointer { d in
                var params = DXGI_PRESENT_PARAMETERS(DirtyRectsCount: firstPresent ? 0 : UInt32(d.count),
                                                     pDirtyRects: firstPresent ? nil : d.baseAddress, pScrollRect: nil, pScrollOffset: nil)
                return sc.pointee.lpVtbl.pointee.Present1(sc, 1, 0, &params)
            }
            try check(hr, "presenting")
            firstPresent = false
        } else {
            try backend.execute(batch)
            shown = i
            next = 1 - i
        }
    }

    func readBack() throws(GPUError) -> [UInt8]? {
        guard swapChain == nil, shown >= 0 else { return nil }
        return try backend.read(buffers[shown]).map { UInt8(min(max($0 * 255 + 0.5, 0), 255)) }
    }
}
#endif
