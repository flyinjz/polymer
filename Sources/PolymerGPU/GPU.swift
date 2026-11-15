// The GPU interface: what a backend (Direct3D 12 today, Metal next) must do.
// It is small on purpose. Everything that can be shared, turning a display
// list into draws, the glyph atlas, caches, is `GPURenderer`, in this module;
// a backend only makes textures, runs a batch of commands and reads pixels back.
import PolymerBase

public struct GPUError: Error, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { "gpu: \(message)" }
}

/// Texture formats Polymer uses.
public enum GPUFormat: Sendable {
    /// Render targets: premultiplied, sRGB-encoded RGBA in half floats (the CPU canvas blends in the same values).
    case rgba16Float
    /// Images: 8-bit sRGB-encoded RGBA, straight alpha (a `Bitmap`).
    case rgba8
    /// Coverage masks (the glyph and path atlas), 0...1.
    case r8
    /// What a window shows: 8-bit BGRA, opaque. Only `.present` draws into it.
    case bgra8

    public var bytesPerPixel: Int {
        switch self { case .rgba16Float: 8; case .rgba8, .bgra8: 4; case .r8: 1 }
    }
}

/// A texture made by a backend. Only render targets can be drawn into.
public struct GPUTexture: Hashable, Sendable {
    public let id: Int
    public let width: Int
    public let height: Int
    public let format: GPUFormat
    public init(id: Int, width: Int, height: Int, format: GPUFormat) {
        self.id = id; self.width = width; self.height = height; self.format = format
    }
}

/// The shader programs. Every draw is a batch of quads, one `GPUInstance`
/// each; the meaning of an instance's fields depends on the program (below).
public enum GPUProgram: Int, CaseIterable, Sendable {
    /// Analytic coverage of a rectangle. `color`: premultiplied colour; `p2`: the rectangle's exact edges (x0, y0, x1, y1).
    case rect
    /// A coverage mask from the atlas (`texture`, r8). `color`: premultiplied colour; `p2.xy`: the mask's top-left in the atlas.
    case mask
    /// An image (`texture`, rgba8, straight alpha) the size of `quad`, drawn 1:1.
    case image
    /// One pass of a separable Gaussian, replacing the target's pixels. `texture`: the input;
    /// `p2`: pixels to clamp reads to (x0, y0, x1, y1, image coordinates);
    /// `p3`: (vertical 0 or 1, half the taps, first weight's index in `data`).
    case blur
    /// A material or liquid glass inside a shape (see `GPURenderer.encodeBackdrop`). `texture`: the blurred pixels behind.
    case backdrop
    /// A layer drawn over the target. `texture`: the layer; `color.x`: opacity, `color.y`: 1 when masked;
    /// `p2`: the mask's rectangle (x, y, width, height); `p3.x`: its corner radius.
    case composite
    /// A render target copied into a `.bgra8` display image, over black. No fields.
    case present
}

/// One quad and its parameters: six float4s, as the shaders read them.
public struct GPUInstance: Sendable {
    /// Pixels covered (x0, y0, x1, y1, image coordinates, whole pixels).
    public var quad: SIMD4<Float>
    public var color: SIMD4<Float>
    public var p2: SIMD4<Float>
    public var p3: SIMD4<Float>
    public var p4: SIMD4<Float>
    public var p5: SIMD4<Float>
    public init(quad: SIMD4<Float>, color: SIMD4<Float> = .zero, p2: SIMD4<Float> = .zero, p3: SIMD4<Float> = .zero,
                p4: SIMD4<Float> = .zero, p5: SIMD4<Float> = .zero) {
        self.quad = quad; self.color = color; self.p2 = p2; self.p3 = p3; self.p4 = p4; self.p5 = p5
    }
}

/// A texture with the image pixel its top-left corner stands for, so a
/// target can cover any part of an image.
public struct GPUSurface: Hashable, Sendable {
    public let texture: GPUTexture
    public let x: Int
    public let y: Int
    public init(_ texture: GPUTexture, x: Int, y: Int) { self.texture = texture; self.x = x; self.y = y }
    /// The image pixels the texture covers.
    public var bounds: PixelRect { PixelRect(x: x, y: y, width: texture.width, height: texture.height) }
}

/// Tightly packed rows for `rect` of a texture (texture coordinates).
public struct GPUUpload: Sendable {
    public var texture: GPUTexture
    public var rect: PixelRect
    /// Where the rows are in `GPUBatch.bytes`.
    public var bytes: Range<Int>
    public init(texture: GPUTexture, rect: PixelRect, bytes: Range<Int>) { self.texture = texture; self.rect = rect; self.bytes = bytes }
}

/// What a backend runs, in order (after the batch's uploads).
public enum GPUCommand: Sendable {
    /// Sets `rect` (image coordinates) of a target to a premultiplied colour.
    case clear(GPUSurface, PixelRect, SIMD4<Float>)
    /// Copies `rect` (image coordinates) from one target to another covering it.
    case copy(from: GPUSurface, to: GPUSurface, PixelRect)
    case draw(GPUDraw)
}

public struct GPUDraw: Sendable {
    public var target: GPUSurface
    /// Pixels the draw may change (image coordinates).
    public var scissor: PixelRect
    public var program: GPUProgram
    /// The texture the program reads, with the image pixel at its top-left (0, 0 for atlas and images).
    public var source: GPUSurface?
    public var instances: Range<Int>
    public init(target: GPUSurface, scissor: PixelRect, program: GPUProgram, source: GPUSurface?, instances: Range<Int>) {
        self.target = target; self.scissor = scissor; self.program = program; self.source = source; self.instances = instances
    }
}

/// Commands with the data they refer to. Kept and reused between frames, so
/// recording allocates nothing once warm.
public struct GPUBatch: Sendable {
    /// Done first. A batch never overwrites texture pixels a command before it reads.
    public var uploads: [GPUUpload] = []
    public var commands: [GPUCommand] = []
    public var instances: [GPUInstance] = []
    /// Blur weights and shapes, read by the shaders as float4s.
    public var data: [SIMD4<Float>] = []
    /// Bytes for uploads.
    public var bytes: [UInt8] = []
    public init() {}
    public var isEmpty: Bool { commands.isEmpty && uploads.isEmpty }
    public mutating func removeAll() {
        uploads.removeAll(keepingCapacity: true); commands.removeAll(keepingCapacity: true); instances.removeAll(keepingCapacity: true)
        data.removeAll(keepingCapacity: true); bytes.removeAll(keepingCapacity: true)
    }
}

/// A GPU, as Polymer needs it.
public protocol GPUBackend: AnyObject {
    /// Which API and adapter, for reports ("Direct3D 12, NVIDIA GeForce RTX 5070").
    var name: String { get }
    func makeTexture(width: Int, height: Int, format: GPUFormat) throws(GPUError) -> GPUTexture
    func destroy(_ texture: GPUTexture)
    /// Runs the commands in order. The batch can be reused as soon as this returns.
    func execute(_ batch: GPUBatch) throws(GPUError)
    /// Premultiplied RGBA of a render target, row-major (waits for the GPU).
    func read(_ texture: GPUTexture) throws(GPUError) -> [Float]
}

/// Which adapter to use.
public enum GPUAdapter: Sendable {
    /// The system's GPU, or the software one when there is none.
    case automatic
    /// The system's GPU only.
    case hardware
    /// The software rasteriser (WARP on Windows): slow, but on every machine.
    case software
}

/// Where backends are found. The entry point installs the one for its OS,
/// as with `Platform.install`.
public enum GPU {
    public typealias Factory = @Sendable (GPUAdapter) throws(GPUError) -> any GPUBackend
    nonisolated(unsafe) private static var factory: Factory?

    public static func install(_ make: @escaping Factory) { factory = make }

    /// True when a backend is installed for this OS.
    public static var isAvailable: Bool { factory != nil }

    public static func makeBackend(_ adapter: GPUAdapter = .automatic) throws(GPUError) -> any GPUBackend {
        guard let factory else {
            throw GPUError("no GPU backend is installed for this OS; the entry point calls GPU.install (Direct3D 12 on Windows, Metal on the Mac)")
        }
        return try factory(adapter)
    }
}

/// Shows render targets in a window (or, for checks, in offscreen images).
public protocol GPUPresenter: AnyObject {
    var width: Int { get }
    var height: Int { get }
    /// The window's content changed size (pixels).
    func resize(width: Int, height: Int) throws(GPUError)
    /// Waits until the display can take another frame, so drawing follows its refresh rate.
    func waitForFrame()
    /// Shows `target` (an image the size of the window): only `damage` changed
    /// since the last frame, so only that is copied and recomposited.
    func present(_ target: GPUTexture, damage: [PixelRect]) throws(GPUError)
    /// The last image presented, for offscreen presenters (nil for windows).
    func readBack() throws(GPUError) -> [UInt8]?
}

extension GPUBackend {
    /// A presenter for a window's native handle (an HWND on Windows), or an
    /// offscreen one with the same buffers and damage tracking when the handle is 0.
    public func makePresenter(windowHandle: UInt, width: Int, height: Int) throws(GPUError) -> any GPUPresenter {
        guard let p = self as? GPUPresenting else { throw GPUError("\(name) cannot present to windows yet") }
        return try p.makePresenter(windowHandle: windowHandle, width: width, height: height)
    }
}

/// Backends that can present implement this.
public protocol GPUPresenting {
    func makePresenter(windowHandle: UInt, width: Int, height: Int) throws(GPUError) -> any GPUPresenter
}
