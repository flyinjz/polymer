// Backend-agnostic GPU abstraction protocols (designed for Metal and Direct3D 12)
// plus a pure-Swift headless RecordingGPUDevice for deterministic verification.
import PolymerBase
import Synchronization

/// Pixel formats supported by Polymer GPU textures and render targets.
public enum GPUFormat: Equatable, Hashable, Sendable {
    case bgra8Unorm
    case rgba8Unorm
    case r8Unorm
    case rgba16Float

    @inlinable
    public var bytesPerPixel: Int {
        switch self {
        case .bgra8Unorm, .rgba8Unorm: return 4
        case .r8Unorm: return 1
        case .rgba16Float: return 8
        }
    }
}

/// Usage flags for GPU buffers.
public struct GPUBufferUsage: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let vertex = GPUBufferUsage(rawValue: 1 << 0)
    public static let index = GPUBufferUsage(rawValue: 1 << 1)
    public static let uniform = GPUBufferUsage(rawValue: 1 << 2)
    public static let instance = GPUBufferUsage(rawValue: 1 << 3)
    public static let storage = GPUBufferUsage(rawValue: 1 << 4)
}

/// Usage flags for GPU textures.
public struct GPUTextureUsage: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let sampled = GPUTextureUsage(rawValue: 1 << 0)
    public static let renderTarget = GPUTextureUsage(rawValue: 1 << 1)
    public static let transferDst = GPUTextureUsage(rawValue: 1 << 2)
    public static let transferSrc = GPUTextureUsage(rawValue: 1 << 3)
}

/// Render target load action at the start of a render pass.
public enum GPULoadAction: Equatable, Hashable, Sendable {
    case dontCare
    case load
    case clear(Color)
}

/// Render target store action at the end of a render pass.
public enum GPUStoreAction: Equatable, Hashable, Sendable {
    case dontCare
    case store
}

/// Blend mode for a graphics pipeline.
public enum GPUBlendMode: Equatable, Hashable, Sendable {
    case opaque
    case premultipliedAlpha
    case straightAlpha
}

/// A GPU-accessible linear memory buffer.
public protocol GPUBuffer: AnyObject {
    var id: UInt64 { get }
    var length: Int { get }
    var usage: GPUBufferUsage { get }
    var label: String { get }
    func contents() -> UnsafeMutableRawPointer?
    func write(_ bytes: UnsafeRawBufferPointer, offset: Int)
}

/// A 2D GPU texture.
public protocol GPUTexture: AnyObject {
    var id: UInt64 { get }
    var width: Int { get }
    var height: Int { get }
    var format: GPUFormat { get }
    var usage: GPUTextureUsage { get }
    var label: String { get }
    func upload(bytes: UnsafeRawBufferPointer, bytesPerRow: Int, region: PixelRect)
}

/// Immutable description of a graphics render pipeline.
public struct GPUPipelineDescriptor: Equatable, Hashable, Sendable {
    public var label: String
    public var vertexFunction: String
    public var fragmentFunction: String
    public var colorFormat: GPUFormat
    public var blendMode: GPUBlendMode

    public init(
        label: String,
        vertexFunction: String,
        fragmentFunction: String,
        colorFormat: GPUFormat = .bgra8Unorm,
        blendMode: GPUBlendMode = .premultipliedAlpha
    ) {
        self.label = label
        self.vertexFunction = vertexFunction
        self.fragmentFunction = fragmentFunction
        self.colorFormat = colorFormat
        self.blendMode = blendMode
    }
}

/// Compiled GPU render pipeline state.
public protocol GPUPipeline: AnyObject {
    var id: UInt64 { get }
    var descriptor: GPUPipelineDescriptor { get }
}

/// Configuration for a render pass.
public struct GPURenderPassDescriptor: Equatable, Sendable {
    public var viewport: PixelRect
    public var loadAction: GPULoadAction
    public var storeAction: GPUStoreAction
    public var targetTextureID: UInt64?

    public init(
        viewport: PixelRect,
        loadAction: GPULoadAction = .clear(.clear),
        storeAction: GPUStoreAction = .store,
        targetTextureID: UInt64? = nil
    ) {
        self.viewport = viewport
        self.loadAction = loadAction
        self.storeAction = storeAction
        self.targetTextureID = targetTextureID
    }
}

/// Records draw commands within a render pass.
public protocol GPUCommandEncoder: AnyObject {
    func setPipeline(_ pipeline: any GPUPipeline)
    func setScissor(_ rect: PixelRect)
    func setVertexBuffer(_ buffer: any GPUBuffer, offset: Int, index: Int)
    func setTexture(_ texture: (any GPUTexture)?, index: Int)
    func drawInstanced(vertexCount: Int, instanceCount: Int, firstVertex: Int, firstInstance: Int)
    func endEncoding()
}

/// Backend-agnostic GPU device interface (implemented by Metal, D3D12, or RecordingGPUDevice).
public protocol GPUDevice: AnyObject {
    var name: String { get }
    func makeBuffer(length: Int, usage: GPUBufferUsage, label: String) -> any GPUBuffer
    func makeTexture(width: Int, height: Int, format: GPUFormat, usage: GPUTextureUsage, label: String) -> any GPUTexture
    func makePipeline(_ descriptor: GPUPipelineDescriptor) -> any GPUPipeline
    func makeCommandEncoder(pass: GPURenderPassDescriptor) -> any GPUCommandEncoder
    func submit()
}

// MARK: - Headless Recording / Null GPU Device

/// Individual GPU command captured by `RecordingGPUDevice` for deterministic inspection.
public enum RecordedGPUCommand: Equatable, Sendable {
    case beginPass(GPURenderPassDescriptor)
    case setPipeline(pipelineID: UInt64, label: String)
    case setScissor(PixelRect)
    case setVertexBuffer(bufferID: UInt64, offset: Int, index: Int)
    case setTexture(textureID: UInt64?, index: Int)
    case drawInstanced(vertexCount: Int, instanceCount: Int, firstVertex: Int, firstInstance: Int)
    case endPass
}

/// Texture upload record captured by `RecordingGPUTexture`.
public struct RecordedTextureUpload: Equatable, Sendable {
    public var region: PixelRect
    public var bytesPerRow: Int
    public var byteCount: Int
}

public final class RecordingGPUBuffer: GPUBuffer {
    public let id: UInt64
    public let length: Int
    public let usage: GPUBufferUsage
    public let label: String
    private let rawStorage: UnsafeMutableRawPointer?
    public private(set) var writeCount: Int = 0

    init(id: UInt64, length: Int, usage: GPUBufferUsage, label: String) {
        self.id = id
        self.length = max(0, length)
        self.usage = usage
        self.label = label
        if length > 0 {
            let ptr = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: 16)
            ptr.initializeMemory(as: UInt8.self, repeating: 0, count: length)
            self.rawStorage = ptr
        } else {
            self.rawStorage = nil
        }
    }

    deinit {
        rawStorage?.deallocate()
    }

    public func contents() -> UnsafeMutableRawPointer? {
        rawStorage
    }

    public func write(_ bytes: UnsafeRawBufferPointer, offset: Int) {
        guard let dst = rawStorage, let src = bytes.baseAddress, offset >= 0, offset + bytes.count <= length else {
            return
        }
        dst.advanced(by: offset).copyMemory(from: src, byteCount: bytes.count)
        writeCount += 1
    }

    /// Reads the current buffer contents as a byte array for headless inspection.
    public func snapshotBytes() -> [UInt8] {
        guard let src = rawStorage, length > 0 else { return [] }
        let buf = UnsafeRawBufferPointer(start: src, count: length)
        return Array(buf)
    }
}

public final class RecordingGPUTexture: GPUTexture {
    public let id: UInt64
    public let width: Int
    public let height: Int
    public let format: GPUFormat
    public let usage: GPUTextureUsage
    public let label: String
    public private(set) var pixels: [UInt8]
    public private(set) var uploads: [RecordedTextureUpload] = []

    init(id: UInt64, width: Int, height: Int, format: GPUFormat, usage: GPUTextureUsage, label: String) {
        self.id = id
        self.width = max(1, width)
        self.height = max(1, height)
        self.format = format
        self.usage = usage
        self.label = label
        self.pixels = [UInt8](repeating: 0, count: self.width * self.height * format.bytesPerPixel)
    }

    public func upload(bytes: UnsafeRawBufferPointer, bytesPerRow: Int, region: PixelRect) {
        guard !region.isEmpty, let srcBase = bytes.baseAddress else { return }
        let bpp = format.bytesPerPixel
        let x0 = max(0, region.x), y0 = max(0, region.y)
        let x1 = min(width, region.x + region.width), y1 = min(height, region.y + region.height)
        guard x0 < x1, y0 < y1 else { return }

        let copyWidthBytes = (x1 - x0) * bpp
        let dstStride = width * bpp
        pixels.withUnsafeMutableBytes { dstBuf in
            guard let dstBase = dstBuf.baseAddress else { return }
            for y in y0..<y1 {
                let srcRowOffset = (y - region.y) * bytesPerRow + (x0 - region.x) * bpp
                guard srcRowOffset >= 0, srcRowOffset + copyWidthBytes <= bytes.count else { continue }
                let dstRowOffset = y * dstStride + x0 * bpp
                dstBase.advanced(by: dstRowOffset).copyMemory(from: srcBase.advanced(by: srcRowOffset), byteCount: copyWidthBytes)
            }
        }
        uploads.append(RecordedTextureUpload(region: region, bytesPerRow: bytesPerRow, byteCount: bytes.count))
    }
}

public final class RecordingGPUPipeline: GPUPipeline {
    public let id: UInt64
    public let descriptor: GPUPipelineDescriptor

    init(id: UInt64, descriptor: GPUPipelineDescriptor) {
        self.id = id
        self.descriptor = descriptor
    }
}

public final class RecordingGPUCommandEncoder: GPUCommandEncoder {
    private unowned let device: RecordingGPUDevice
    private var commands: [RecordedGPUCommand]
    private var ended: Bool = false

    init(device: RecordingGPUDevice, pass: GPURenderPassDescriptor) {
        self.device = device
        self.commands = [.beginPass(pass)]
    }

    public func setPipeline(_ pipeline: any GPUPipeline) {
        guard !ended else { return }
        commands.append(.setPipeline(pipelineID: pipeline.id, label: pipeline.descriptor.label))
    }

    public func setScissor(_ rect: PixelRect) {
        guard !ended else { return }
        commands.append(.setScissor(rect))
    }

    public func setVertexBuffer(_ buffer: any GPUBuffer, offset: Int, index: Int) {
        guard !ended else { return }
        commands.append(.setVertexBuffer(bufferID: buffer.id, offset: offset, index: index))
    }

    public func setTexture(_ texture: (any GPUTexture)?, index: Int) {
        guard !ended else { return }
        commands.append(.setTexture(textureID: texture?.id, index: index))
    }

    public func drawInstanced(vertexCount: Int, instanceCount: Int, firstVertex: Int, firstInstance: Int) {
        guard !ended else { return }
        commands.append(.drawInstanced(
            vertexCount: vertexCount,
            instanceCount: instanceCount,
            firstVertex: firstVertex,
            firstInstance: firstInstance
        ))
    }

    public func endEncoding() {
        guard !ended else { return }
        ended = true
        commands.append(.endPass)
        device.recordCompletedPass(commands)
    }
}

/// Headless pure-Swift GPU device that records all resource allocations, uploads,
/// render passes, and instanced draw calls for deterministic testing without a display.
public final class RecordingGPUDevice: GPUDevice {
    public let name: String
    private let nextID = Atomic<UInt64>(1)

    public private(set) var buffers: [UInt64: RecordingGPUBuffer] = [:]
    public private(set) var textures: [UInt64: RecordingGPUTexture] = [:]
    public private(set) var pipelines: [UInt64: RecordingGPUPipeline] = [:]

    private var pendingPasses: [[RecordedGPUCommand]] = []
    public private(set) var submittedPasses: [[RecordedGPUCommand]] = []
    public private(set) var submitCount: Int = 0

    public init(name: String = "RecordingGPUDevice") {
        self.name = name
    }

    private func allocateID() -> UInt64 {
        nextID.add(1, ordering: .relaxed).oldValue
    }

    public func makeBuffer(length: Int, usage: GPUBufferUsage, label: String) -> any GPUBuffer {
        let id = allocateID()
        let buf = RecordingGPUBuffer(id: id, length: length, usage: usage, label: label)
        buffers[id] = buf
        return buf
    }

    public func makeTexture(width: Int, height: Int, format: GPUFormat, usage: GPUTextureUsage, label: String) -> any GPUTexture {
        let id = allocateID()
        let tex = RecordingGPUTexture(id: id, width: width, height: height, format: format, usage: usage, label: label)
        textures[id] = tex
        return tex
    }

    public func makePipeline(_ descriptor: GPUPipelineDescriptor) -> any GPUPipeline {
        let id = allocateID()
        let pipe = RecordingGPUPipeline(id: id, descriptor: descriptor)
        pipelines[id] = pipe
        return pipe
    }

    public func makeCommandEncoder(pass: GPURenderPassDescriptor) -> any GPUCommandEncoder {
        RecordingGPUCommandEncoder(device: self, pass: pass)
    }

    func recordCompletedPass(_ commands: [RecordedGPUCommand]) {
        pendingPasses.append(commands)
    }

    public func submit() {
        submittedPasses.append(contentsOf: pendingPasses)
        pendingPasses.removeAll(keepingCapacity: true)
        submitCount += 1
    }

    /// Total number of `drawInstanced` calls across all submitted passes.
    public var drawCallCount: Int {
        var total = 0
        for pass in submittedPasses {
            for cmd in pass {
                if case .drawInstanced = cmd { total += 1 }
            }
        }
        return total
    }

    /// Total number of instances drawn across all submitted passes.
    public var totalInstanceCount: Int {
        var total = 0
        for pass in submittedPasses {
            for cmd in pass {
                if case .drawInstanced(_, let instanceCount, _, _) = cmd {
                    total += instanceCount
                }
            }
        }
        return total
    }

    /// Clears submitted pass logs while keeping allocated resources.
    public func resetRecording() {
        pendingPasses.removeAll(keepingCapacity: true)
        submittedPasses.removeAll(keepingCapacity: true)
        submitCount = 0
    }
}

/// Alias for headless / null GPU device usage.
public typealias NullGPUDevice = RecordingGPUDevice
