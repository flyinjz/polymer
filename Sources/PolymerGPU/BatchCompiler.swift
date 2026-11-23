// Compiles a PolymerRender.DisplayList into order-preserving, coalesced
// instanced GPU batches, uploads glyph and image/path textures, encodes
// commands into a GPUCommandEncoder, and provides a headless coverage
// verifier against PolymerRender.Canvas.
import PolymerBase
import PolymerText
import PolymerRender

/// One instanced quad emitted to the GPU vertex/fragment shader.
public struct GPUQuadInstance: Equatable, Sendable {
    public enum Kind: UInt32, Equatable, Hashable, Sendable {
        case solidRect = 0
        case glyph = 1
        case image = 2
        case pathCoverage = 3
        case backdropBlur = 4
    }

    public var kind: Kind
    /// Screen-space bounds in pixels.
    public var x: Float
    public var y: Float
    public var width: Float
    public var height: Float
    /// Normalized texture UVs (`0...1`).
    public var u0: Float
    public var v0: Float
    public var u1: Float
    public var v1: Float
    /// Premultiplied sRGB color (or opacity tint for images).
    public var r: Float
    public var g: Float
    public var b: Float
    public var a: Float
    /// Scissor / clip rectangle in screen pixels.
    public var clipX: Float
    public var clipY: Float
    public var clipW: Float
    public var clipH: Float
    /// Optional rounded corner radius (pixels).
    public var cornerRadius: Float
    /// Optional backdrop blur sigma radius (pixels).
    public var blurRadius: Float

    public init(
        kind: Kind,
        x: Float, y: Float, width: Float, height: Float,
        u0: Float = 0, v0: Float = 0, u1: Float = 1, v1: Float = 1,
        r: Float, g: Float, b: Float, a: Float,
        clip: PixelRect,
        cornerRadius: Float = 0,
        blurRadius: Float = 0
    ) {
        self.kind = kind
        self.x = x; self.y = y; self.width = width; self.height = height
        self.u0 = u0; self.v0 = v0; self.u1 = u1; self.v1 = v1
        self.r = r; self.g = g; self.b = b; self.a = a
        self.clipX = Float(clip.x)
        self.clipY = Float(clip.y)
        self.clipW = Float(clip.width)
        self.clipH = Float(clip.height)
        self.cornerRadius = cornerRadius
        self.blurRadius = blurRadius
    }
}

/// Coalesced instanced draw batch sharing kind, scissor clip, and texture binding.
public struct GPUBatch: Equatable, Sendable {
    public var kind: GPUQuadInstance.Kind
    public var scissor: PixelRect
    public var textureID: UInt64
    public var instances: [GPUQuadInstance]

    public init(kind: GPUQuadInstance.Kind, scissor: PixelRect, textureID: UInt64, instances: [GPUQuadInstance]) {
        self.kind = kind
        self.scissor = scissor
        self.textureID = textureID
        self.instances = instances
    }
}

/// Result of compiling a `DisplayList` into GPU batches.
public struct CompiledFrame: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var scale: Double
    public var batches: [GPUBatch]
    public var totalInstances: Int

    public var drawCallCount: Int { batches.count }

    public init(width: Int, height: Int, scale: Double, batches: [GPUBatch], totalInstances: Int) {
        self.width = width
        self.height = height
        self.scale = scale
        self.batches = batches
        self.totalInstances = totalInstances
    }
}

/// Compiles `PolymerRender.DisplayList` items into minimized, painter-order-preserving
/// `GPUBatch`es and encodes them through a `GPUCommandEncoder`.
public final class DisplayListCompiler {
    public let glyphAtlas: GlyphAtlas
    public let pathAtlas: GlyphAtlasPage

    private var imageTextureIDs: [RenderImage: UInt64] = [:]
    private var imageTextures: [UInt64: any GPUTexture] = [:]
    private var pendingImages: [UInt64: RenderImage] = [:]
    private var nextSyntheticTextureID: UInt64 = 10_000
    private var pipelines: [GPUQuadInstance.Kind: any GPUPipeline] = [:]
    private var boundDeviceID: ObjectIdentifier?

    public init(
        glyphAtlas: GlyphAtlas = GlyphAtlas(),
        pathAtlasSize: Int = 1024
    ) {
        self.glyphAtlas = glyphAtlas
        self.pathAtlas = GlyphAtlasPage(pageIndex: 0, width: max(64, pathAtlasSize), height: max(64, pathAtlasSize), padding: 1)
    }

    /// Compiles `list` into coalesced `GPUBatch`es while strictly preserving painter's order.
    public func compile(_ list: DisplayList, device: (any GPUDevice)? = nil) -> CompiledFrame {
        var batches: [GPUBatch] = []
        var totalInstances = 0
        let scale = list.scale

        // Reset path coverage atlas each frame (paths are frame-ephemeral masks).
        pathAtlas.reset()
        let pathTextureID: UInt64 = (device != nil) ? pathAtlas.attachTexture(from: device!).id : 9_000

        func emit(_ instance: GPUQuadInstance, scissor: PixelRect, textureID: UInt64) {
            totalInstances += 1
            // Backdrop blurs act as a resolve barrier and are never merged into an existing batch.
            if instance.kind != .backdropBlur,
               let lastIdx = batches.indices.last,
               batches[lastIdx].kind == instance.kind,
               batches[lastIdx].scissor == scissor,
               batches[lastIdx].textureID == textureID {
                batches[lastIdx].instances.append(instance)
            } else {
                batches.append(GPUBatch(kind: instance.kind, scissor: scissor, textureID: textureID, instances: [instance]))
            }
        }

        for item in list.items {
            guard !item.bounds.isEmpty && !item.clip.isEmpty else { continue }
            switch item.operation {
            case .rect(let rect, let color):
                let a = Float(color.opacity)
                guard a > 0 else { continue }
                let x = Float((rect.minX + item.origin.x) * scale)
                let y = Float((rect.minY + item.origin.y) * scale)
                let w = Float(rect.width * scale)
                let h = Float(rect.height * scale)
                guard w > 0 && h > 0 else { continue }
                let inst = GPUQuadInstance(
                    kind: .solidRect,
                    x: x, y: y, width: w, height: h,
                    r: Float(color.red) * a, g: Float(color.green) * a, b: Float(color.blue) * a, a: a,
                    clip: item.clip
                )
                emit(inst, scissor: item.clip, textureID: 0)

            case .path(let path, let color):
                let a = Float(color.opacity)
                guard a > 0, !path.isEmpty else { continue }
                let t = AffineTransform(a: scale, b: 0, c: 0, d: scale, tx: item.origin.x * scale, ty: item.origin.y * scale)
                let contours = path.applying(t).flattened(tolerance: 0.01)
                let mask = Rasterizer.rasterize(contours)
                guard mask.width > 0 && mask.height > 0 && !mask.coverage.isEmpty else { continue }

                var u0: Float = 0, v0: Float = 0, u1: Float = 1, v1: Float = 1
                var texID = pathTextureID
                if let packed = pathAtlas.allocate(width: mask.width, height: mask.height) {
                    pathAtlas.writeCoverage(mask.coverage, into: packed)
                    let invW = 1.0 / Float(pathAtlas.width)
                    let invH = 1.0 / Float(pathAtlas.height)
                    u0 = Float(packed.x) * invW
                    v0 = Float(packed.y) * invH
                    u1 = Float(packed.x + packed.width) * invW
                    v1 = Float(packed.y + packed.height) * invH
                } else {
                    // Fallback synthetic ID for masks larger than the path atlas page.
                    texID = nextSyntheticTextureID
                    nextSyntheticTextureID += 1
                }
                let inst = GPUQuadInstance(
                    kind: .pathCoverage,
                    x: Float(mask.left), y: Float(mask.top),
                    width: Float(mask.width), height: Float(mask.height),
                    u0: u0, v0: v0, u1: u1, v1: v1,
                    r: Float(color.red) * a, g: Float(color.green) * a, b: Float(color.blue) * a, a: a,
                    clip: item.clip
                )
                emit(inst, scissor: item.clip, textureID: texID)

            case .glyphs(let run):
                let a = Float(run.color.opacity)
                guard a > 0, !run.glyphs.isEmpty else { continue }
                let px = run.size * scale
                let ox = (run.position.x + item.origin.x) * scale
                let oy = (run.position.y + item.origin.y) * scale
                let lin = run.color.linear
                let luminance = 0.2126 * Double(lin.r) + 0.7152 * Double(lin.g) + 0.0722 * Double(lin.b)
                let pr = Float(run.color.red) * a
                let pg = Float(run.color.green) * a
                let pb = Float(run.color.blue) * a

                let (iy, _, fyQ) = glyphAtlas.quantizePosition(oy)
                let deltaY = oy - (Double(iy) + fyQ)

                for g in run.glyphs {
                    let gx = ox + g.x * scale
                    let (ix, _, fxQ) = glyphAtlas.quantizePosition(gx)
                    let deltaX = gx - (Double(ix) + fxQ)
                    let region = glyphAtlas.glyph(
                        font: run.font,
                        glyphID: g.glyph,
                        pixelSize: px,
                        fractionalX: fxQ,
                        fractionalY: fyQ,
                        luminance: luminance,
                        options: run.options
                    )
                    guard !region.isEmpty else { continue }

                    let page = glyphAtlas.pages[region.pageIndex]
                    let atlasTexID: UInt64
                    if let device {
                        atlasTexID = page.attachTexture(from: device).id
                    } else if let existing = page.texture {
                        atlasTexID = existing.id
                    } else {
                        atlasTexID = 1_000 + UInt64(region.pageIndex)
                    }

                    let qx = Float(Double(ix + region.bearingX) + deltaX)
                    let qy = Float(Double(iy + region.bearingY) + deltaY)
                    let inst = GPUQuadInstance(
                        kind: .glyph,
                        x: qx, y: qy,
                        width: Float(region.pixelRect.width),
                        height: Float(region.pixelRect.height),
                        u0: region.u0, v0: region.v0, u1: region.u1, v1: region.v1,
                        r: pr, g: pg, b: pb, a: a,
                        clip: item.clip
                    )
                    emit(inst, scissor: item.clip, textureID: atlasTexID)
                }

            case .image(let img, let rect, let opacity, _):
                let op = Float(min(max(opacity, 0.0), 1.0))
                guard op > 0, img.width > 0, img.height > 0, !rect.isEmpty else { continue }
                let texID = registerImage(img, device: device)
                let x = Float((rect.minX + item.origin.x) * scale)
                let y = Float((rect.minY + item.origin.y) * scale)
                let w = Float(rect.width * scale)
                let h = Float(rect.height * scale)
                guard w > 0 && h > 0 else { continue }
                let inst = GPUQuadInstance(
                    kind: .image,
                    x: x, y: y, width: w, height: h,
                    u0: 0, v0: 0, u1: 1, v1: 1,
                    r: op, g: op, b: op, a: op,
                    clip: item.clip
                )
                emit(inst, scissor: item.clip, textureID: texID)

            case .backdropBlur(let rect, let radius):
                guard radius > 0, !rect.isEmpty else { continue }
                let x = Float((rect.minX + item.origin.x) * scale)
                let y = Float((rect.minY + item.origin.y) * scale)
                let w = Float(rect.width * scale)
                let h = Float(rect.height * scale)
                guard w > 0 && h > 0 else { continue }
                let inst = GPUQuadInstance(
                    kind: .backdropBlur,
                    x: x, y: y, width: w, height: h,
                    r: 1, g: 1, b: 1, a: 1,
                    clip: item.clip,
                    blurRadius: Float(radius * scale)
                )
                emit(inst, scissor: item.clip, textureID: 0)
            }
        }

        if let device {
            glyphAtlas.flush(to: device)
            pathAtlas.uploadDirtyRegions()
        }

        return CompiledFrame(
            width: list.width,
            height: list.height,
            scale: list.scale,
            batches: batches,
            totalInstances: totalInstances
        )
    }

    private func registerImage(_ image: RenderImage, device: (any GPUDevice)?) -> UInt64 {
        if let id = imageTextureIDs[image] {
            if let device, imageTextures[id] == nil {
                uploadImage(image, id: id, device: device)
            }
            return id
        }
        if let device {
            let tex = device.makeTexture(
                width: image.width,
                height: image.height,
                format: .rgba8Unorm,
                usage: [.sampled, .transferDst],
                label: "RenderImage(\(image.width)x\(image.height))"
            )
            image.bitmap.pixels.withUnsafeBytes { raw in
                tex.upload(
                    bytes: raw,
                    bytesPerRow: image.width * 4,
                    region: PixelRect(x: 0, y: 0, width: image.width, height: image.height)
                )
            }
            imageTextureIDs[image] = tex.id
            imageTextures[tex.id] = tex
            return tex.id
        } else {
            let id = nextSyntheticTextureID
            nextSyntheticTextureID += 1
            imageTextureIDs[image] = id
            pendingImages[id] = image
            return id
        }
    }

    private func uploadImage(_ image: RenderImage, id: UInt64, device: any GPUDevice) {
        let tex = device.makeTexture(
            width: image.width,
            height: image.height,
            format: .rgba8Unorm,
            usage: [.sampled, .transferDst],
            label: "RenderImage(\(image.width)x\(image.height))"
        )
        image.bitmap.pixels.withUnsafeBytes { raw in
            tex.upload(
                bytes: raw,
                bytesPerRow: image.width * 4,
                region: PixelRect(x: 0, y: 0, width: image.width, height: image.height)
            )
        }
        imageTextures[id] = tex
        pendingImages.removeValue(forKey: id)
    }

    private func ensurePipelines(for device: any GPUDevice) {
        let devID = ObjectIdentifier(device)
        if boundDeviceID == devID && !pipelines.isEmpty { return }
        boundDeviceID = devID
        pipelines.removeAll(keepingCapacity: true)

        let defs: [(GPUQuadInstance.Kind, String, String, String)] = [
            (.solidRect, "PolymerSolidRect", "quadVertex", "solidRectFragment"),
            (.glyph, "PolymerGlyph", "quadVertex", "glyphFragment"),
            (.image, "PolymerImage", "quadVertex", "imageFragment"),
            (.pathCoverage, "PolymerPathCoverage", "quadVertex", "pathCoverageFragment"),
            (.backdropBlur, "PolymerBackdropBlur", "quadVertex", "backdropBlurFragment"),
        ]
        for (kind, label, vs, fs) in defs {
            let desc = GPUPipelineDescriptor(
                label: label,
                vertexFunction: vs,
                fragmentFunction: fs,
                colorFormat: .bgra8Unorm,
                blendMode: .premultipliedAlpha
            )
            pipelines[kind] = device.makePipeline(desc)
        }
    }

    private func resolveTexture(id: UInt64, device: any GPUDevice) -> (any GPUTexture)? {
        if id == 0 { return nil }
        if let imgTex = imageTextures[id] { return imgTex }
        if let pending = pendingImages[id] {
            uploadImage(pending, id: id, device: device)
            return imageTextures[id]
        }
        if let pathTex = pathAtlas.texture, pathTex.id == id { return pathTex }
        for page in glyphAtlas.pages {
            if let t = page.texture, t.id == id { return t }
        }
        if id >= 1_000 && id < 1_000 + UInt64(glyphAtlas.pages.count) {
            return glyphAtlas.pages[Int(id - 1_000)].attachTexture(from: device)
        }
        return nil
    }

    /// Encodes all batches of `frame` into `encoder` using a single uploaded instance buffer.
    public func encode(frame: CompiledFrame, into encoder: any GPUCommandEncoder, device: any GPUDevice) {
        ensurePipelines(for: device)
        glyphAtlas.flush(to: device)
        _ = pathAtlas.attachTexture(from: device)
        pathAtlas.uploadDirtyRegions()

        guard frame.totalInstances > 0 else {
            encoder.endEncoding()
            return
        }

        // Pack all instances into one contiguous GPU instance buffer.
        var allInstances: [GPUQuadInstance] = []
        allInstances.reserveCapacity(frame.totalInstances)
        for batch in frame.batches {
            allInstances.append(contentsOf: batch.instances)
        }

        let byteLength = allInstances.count * MemoryLayout<GPUQuadInstance>.stride
        let instanceBuffer = device.makeBuffer(length: byteLength, usage: [.vertex, .instance], label: "FrameInstances")
        allInstances.withUnsafeBytes { raw in
            instanceBuffer.write(raw, offset: 0)
        }
        encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)

        var currentKind: GPUQuadInstance.Kind?
        var currentScissor: PixelRect?
        var currentTextureID: UInt64?
        var instanceOffset = 0

        for batch in frame.batches {
            guard !batch.instances.isEmpty else { continue }
            if currentKind != batch.kind, let pipe = pipelines[batch.kind] {
                encoder.setPipeline(pipe)
                currentKind = batch.kind
            }
            if currentScissor != batch.scissor {
                encoder.setScissor(batch.scissor)
                currentScissor = batch.scissor
            }
            if currentTextureID != batch.textureID {
                let tex = resolveTexture(id: batch.textureID, device: device)
                encoder.setTexture(tex, index: 0)
                currentTextureID = batch.textureID
            }
            encoder.drawInstanced(
                vertexCount: 6,
                instanceCount: batch.instances.count,
                firstVertex: 0,
                firstInstance: instanceOffset
            )
            instanceOffset += batch.instances.count
        }

        encoder.endEncoding()
    }
}

// MARK: - Headless Batch Coverage Verifier Against CPU Canvas

public struct CoverageVerificationResult: Equatable, Sendable {
    public var canvasNonBackgroundPixels: Int
    public var gpuCoveredPixels: Int
    public var uncoveredCanvasPixels: Int
    public var clipViolationCount: Int

    public var allCanvasPixelsCovered: Bool {
        uncoveredCanvasPixels == 0 && clipViolationCount == 0
    }
}

/// Verifies compiled GPU batches against CPU `PolymerRender.Canvas` rendering of the exact same `DisplayList`.
public enum GPUBatchVerifier {
    public static func verify(
        displayList: DisplayList,
        compiledFrame: CompiledFrame,
        background: Color = .clear
    ) -> CoverageVerificationResult {
        let w = displayList.width
        let h = displayList.height
        guard w > 0 && h > 0 else {
            return CoverageVerificationResult(
                canvasNonBackgroundPixels: 0,
                gpuCoveredPixels: 0,
                uncoveredCanvasPixels: 0,
                clipViolationCount: 0
            )
        }

        // 1. Render reference image on CPU Canvas.
        var canvas = Canvas(width: w, height: h, scale: displayList.scale, background: background)
        canvas.draw(displayList)

        let bgA = Float(background.opacity)
        let bgR = Float(background.red) * bgA
        let bgG = Float(background.green) * bgA
        let bgB = Float(background.blue) * bgA

        // 2. Rasterize GPU batch quad coverage bounded by each batch's scissor clip.
        var gpuCovered = [Bool](repeating: false, count: w * h)
        var clipViolations = 0

        for batch in compiledFrame.batches {
            let s = batch.scissor
            let sx0 = max(0, s.x)
            let sy0 = max(0, s.y)
            let sx1 = min(w, s.x + s.width)
            let sy1 = min(h, s.y + s.height)

            for inst in batch.instances {
                // Verify instance clip metadata matches its batch scissor.
                if Int(inst.clipX.rounded()) != s.x ||
                   Int(inst.clipY.rounded()) != s.y ||
                   Int(inst.clipW.rounded()) != s.width ||
                   Int(inst.clipH.rounded()) != s.height {
                    clipViolations += 1
                }
                guard sx0 < sx1 && sy0 < sy1 else { continue }
                let x0 = max(sx0, Int(Double(inst.x).rounded(.down)))
                let y0 = max(sy0, Int(Double(inst.y).rounded(.down)))
                let x1 = min(sx1, Int(Double(inst.x + inst.width).rounded(.up)))
                let y1 = min(sy1, Int(Double(inst.y + inst.height).rounded(.up)))
                guard x0 < x1 && y0 < y1 else { continue }
                for y in y0..<y1 {
                    let row = y * w
                    for x in x0..<x1 {
                        gpuCovered[row + x] = true
                    }
                }
            }
        }

        // 3. Compare every non-background pixel produced by CPU Canvas against GPU coverage.
        var canvasNonBg = 0
        var coveredCount = 0
        var uncovered = 0
        let eps: Float = 1e-5

        for y in 0..<h {
            let row = y * w
            for x in 0..<w {
                let idx = row + x
                if gpuCovered[idx] { coveredCount += 1 }
                let p = idx * 4
                let dr = abs(canvas.pixels[p] - bgR)
                let dg = abs(canvas.pixels[p + 1] - bgG)
                let db = abs(canvas.pixels[p + 2] - bgB)
                let da = abs(canvas.pixels[p + 3] - bgA)
                if dr > eps || dg > eps || db > eps || da > eps {
                    canvasNonBg += 1
                    if !gpuCovered[idx] {
                        uncovered += 1
                    }
                }
            }
        }

        return CoverageVerificationResult(
            canvasNonBackgroundPixels: canvasNonBg,
            gpuCoveredPixels: coveredCount,
            uncoveredCanvasPixels: uncovered,
            clipViolationCount: clipViolations
        )
    }
}
