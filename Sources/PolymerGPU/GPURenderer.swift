// Draws display lists on a GPU backend. It follows `Canvas.draw` step for
// step (same clips, same offscreen areas for layers and backdrops, same
// blur weights, glyph and path coverage from the same rasteriser), so the
// GPU image matches the CPU reference within rounding.
import PolymerBase
import PolymerText
import PolymerRender

public final class GPURenderer {
    public let backend: any GPUBackend
    /// Glyph outlines and masks, as for the CPU canvas.
    public let glyphCache = GlyphCache()

    private var batch = GPUBatch()
    private var atlas: Atlas
    private var images: [ImageKey: ImageEntry] = [:]
    private var kernels: [Double: [Float]] = [:]
    /// Scratch render targets not in use, and the ones made just for this batch (destroyed after it).
    private var pool: [GPUTexture] = []
    private var transient: [GPUTexture] = []
    private var frame = 0

    /// Frames an image texture is kept without being drawn.
    public var imageKeepFrames = 120

    public init(backend: any GPUBackend) throws(GPUError) {
        self.backend = backend
        atlas = Atlas(texture: try backend.makeTexture(width: Atlas.size, height: Atlas.size, format: .r8))
    }

    deinit {
        backend.destroy(atlas.texture)
        for e in images.values { backend.destroy(e.texture) }
        for t in pool { backend.destroy(t) }
    }

    /// A render target for whole images of this size.
    public func makeTarget(width: Int, height: Int) throws(GPUError) -> GPUTexture {
        try backend.makeTexture(width: width, height: height, format: .rgba16Float)
    }

    /// Draws `list` into `target` (the size of the list). Only `regions` are
    /// cleared to `background` and drawn (all of it when nil); no other pixel changes.
    public func draw(_ list: DisplayList, into target: GPUTexture, regions: [PixelRect]? = nil, background: Color) throws(GPUError) {
        frame += 1
        let surface = GPUSurface(target, x: 0, y: 0)
        for region in regions ?? [list.fullRect] {
            let r = region.clamped(to: list.fullRect).clamped(to: surface.bounds)
            if r.isEmpty { continue }
            batch.commands.append(.clear(surface, r, premultiplied(background)))
            try encode(list, 0..<list.items.count, region: r, into: surface, background: background)
        }
        try flush()
        images = images.filter { key, e in
            if frame - e.lastUse <= imageKeepFrames { return true }
            backend.destroy(e.texture); return false
        }
    }

    /// The target's pixels as a bitmap (waits for the GPU).
    public func read(_ target: GPUTexture) throws(GPUError) -> Bitmap {
        Bitmap(premultiplied: try backend.read(target), width: target.width, height: target.height)
    }

    /// Runs what has been recorded.
    private func flush() throws(GPUError) {
        guard !batch.isEmpty else { return }
        try backend.execute(batch)
        batch.removeAll()
        for t in transient { backend.destroy(t) }
        transient.removeAll(keepingCapacity: true)
    }

    // MARK: Walking the list (as `Canvas.draw(_:in:range:)`)

    private func encode(_ list: DisplayList, _ range: Range<Int>, region: PixelRect, into surface: GPUSurface,
                        background: Color) throws(GPUError) {
        let items = list.items
        var ends: [Int: Int] = [:]
        var open: [Int] = []
        for k in range {
            switch items[k].operation {
            case .beginLayer: open.append(k)
            case .endLayer: if let s = open.popLast() { ends[s] = k }
            default: break
            }
        }
        var k = range.lowerBound
        while k < range.upperBound {
            let item = items[k]
            if case .beginLayer(let effect) = item.operation {
                let end = ends[k] ?? range.upperBound
                if item.bounds.intersects(region) {
                    try encodeLayer(list, k, end, effect, clip: item.clip.clamped(to: region), into: surface)
                }
                k = end + 1
                continue
            }
            defer { k += 1 }
            guard item.bounds.intersects(region) else { continue }
            let clip = item.clip.clamped(to: region)
            switch item.operation {
            case .rect(let r, let c): encodeRect(r, c, origin: item.origin, scale: list.scale, clip: clip, into: surface)
            case .path(let p, let c): try encodePath(p, c, origin: item.origin, scale: list.scale, clip: clip, into: surface)
            case .glyphs(let g): try encodeGlyphs(g, origin: item.origin, scale: list.scale, clip: clip, into: surface)
            case .image(let img, let r): try encodeImage(img, r, origin: item.origin, scale: list.scale, clip: clip, into: surface)
            case .backdrop(let shape, let effect):
                try encodeBackdrop(list, k, shape, effect, clip: clip, region: region, from: range.lowerBound,
                                   into: surface, background: background)
            case .beginLayer, .endLayer: break
            }
        }
    }

    // MARK: Items

    private func encodeRect(_ rect: Rect, _ color: Color, origin: Point, scale: Double, clip: PixelRect, into surface: GPUSurface) {
        let x0 = (rect.minX + origin.x) * scale, y0 = (rect.minY + origin.y) * scale
        let x1 = (rect.maxX + origin.x) * scale, y1 = (rect.maxY + origin.y) * scale
        let px = PixelRect(x: Int(x0.rounded(.down)), y: Int(y0.rounded(.down)),
                           width: Int(x1.rounded(.up)) - Int(x0.rounded(.down)), height: Int(y1.rounded(.up)) - Int(y0.rounded(.down)))
        guard !px.clamped(to: clip).isEmpty else { return }
        add(GPUInstance(quad: quad(px), color: premultiplied(color), p2: SIMD4(Float(x0), Float(y0), Float(x1), Float(y1))),
            .rect, clip: clip, into: surface, source: nil)
    }

    private func encodePath(_ path: Path, _ color: Color, origin: Point, scale: Double, clip: PixelRect,
                            into surface: GPUSurface) throws(GPUError) {
        let key = AtlasKey.path(path, x: origin.x, y: origin.y, scale: scale)
        let spot = try atlasSpot(key) {
            let t = AffineTransform(a: scale, b: 0, c: 0, d: scale, tx: origin.x * scale, ty: origin.y * scale)
            return Rasterizer.rasterize(path.applying(t).flattened(tolerance: 0.01))
        }
        try addMask(spot, dx: 0, dy: 0, color, clip: clip, into: surface)
    }

    private func encodeGlyphs(_ run: GlyphRun, origin: Point, scale: Double, clip: PixelRect, into surface: GPUSurface) throws(GPUError) {
        let px = run.size * scale
        let ox = (run.position.x + origin.x) * scale, oy = (run.position.y + origin.y) * scale
        let top = Int((oy - px * 2).rounded(.down)), bottom = Int((oy + px).rounded(.up))
        if bottom <= clip.y || top >= clip.y + clip.height { return }
        let lin = run.color.linear
        let luminance = 0.2126 * Double(lin.r) + 0.7152 * Double(lin.g) + 0.0722 * Double(lin.b)
        let growth = run.options.growth(ppem: px, luminance: luminance)
        let iy = oy.rounded(.down), fy = oy - iy
        for g in run.glyphs {
            let x = ox + g.x * scale
            let ix = x.rounded(.down), fx = x - ix
            let key = AtlasKey.glyph(ObjectIdentifier(run.font), g.glyph, pixelSize: px, growth: growth, fx: fx, fy: fy)
            let spot = try atlasSpot(key, keep: run.font) {
                GlyphRenderer.mask(font: run.font, glyph: g.glyph, pixelSize: px, x: fx, y: fy,
                                   luminance: luminance, options: run.options, cache: glyphCache)
            }
            try addMask(spot, dx: Int(ix), dy: Int(iy), run.color, clip: clip, into: surface)
        }
    }

    private func encodeImage(_ image: RasterImage, _ rect: Rect, origin: Point, scale: Double, clip: PixelRect,
                             into surface: GPUSurface) throws(GPUError) {
        let r = PixelRect.snapping(rect, origin: origin, scale: scale)
        guard !r.isEmpty, image.bitmap.width > 0, image.bitmap.height > 0, !r.clamped(to: clip).isEmpty else { return }
        let key = ImageKey(image: ObjectIdentifier(image), width: r.width, height: r.height)
        let texture: GPUTexture
        if var e = images[key] {
            e.lastUse = frame; images[key] = e
            texture = e.texture
        } else {
            let b = image.scaled(width: r.width, height: r.height)
            texture = try backend.makeTexture(width: r.width, height: r.height, format: .rgba8)
            let start = batch.bytes.count
            batch.bytes.append(contentsOf: b.pixels)
            batch.uploads.append(GPUUpload(texture: texture, rect: PixelRect(x: 0, y: 0, width: r.width, height: r.height),
                                           bytes: start..<batch.bytes.count))
            images[key] = ImageEntry(texture: texture, image: image, lastUse: frame)
        }
        add(GPUInstance(quad: quad(r)), .image, clip: clip, into: surface, source: GPUSurface(texture, x: r.x, y: r.y))
    }

    /// As `Canvas.drawLayer`: the layer's items offscreen over the part
    /// being drawn plus the blur's reach, blurred, then composited with the
    /// mask and opacity.
    private func encodeLayer(_ list: DisplayList, _ begin: Int, _ end: Int, _ effect: LayerEffect, clip: PixelRect,
                             into surface: GPUSurface) throws(GPUError) {
        let item = list.items[begin]
        let target = item.bounds.clamped(to: clip)
        guard !target.isEmpty else { return }
        let area = target.outset(by: item.reach).clamped(to: list.fullRect)
        let layer = try acquire(area)
        batch.commands.append(.clear(layer, area, .zero))
        try encode(list, (begin + 1)..<end, region: area, into: layer, background: .clear)
        if effect.blur > 0 { try blur(layer, area, sigma: effect.blur * list.scale) }
        let s = list.scale, o = item.origin
        var inst = GPUInstance(quad: quad(target), color: SIMD4(Float(effect.opacity), 0, 0, 0))
        if let m = effect.mask {
            inst.color.y = 1
            inst.p2 = SIMD4(Float((m.rect.minX + o.x) * s), Float((m.rect.minY + o.y) * s), Float(m.rect.width * s), Float(m.rect.height * s))
            inst.p3.x = Float(m.cornerRadius * s)
        }
        add(inst, .composite, clip: target, into: surface, source: layer)
        release(layer)
    }

    /// As `Canvas.drawBackdrop`: the pixels behind come from the target when
    /// all of them are drawn there already, otherwise from the items before
    /// the effect drawn again offscreen; then blurred and filtered inside the shape.
    private func encodeBackdrop(_ list: DisplayList, _ index: Int, _ shape: BackdropShape, _ effect: BackdropEffect,
                                clip: PixelRect, region: PixelRect, from: Int, into surface: GPUSurface,
                                background: Color) throws(GPUError) {
        let item = list.items[index]
        let target = item.bounds.clamped(to: clip)
        guard !target.isEmpty else { return }
        let source = target.outset(by: item.reach).clamped(to: list.fullRect)
        let behind = try acquire(source)
        if source.clamped(to: region) == source, source.clamped(to: surface.bounds) == source {
            batch.commands.append(.copy(from: surface, to: behind, source))
        } else {
            batch.commands.append(.clear(behind, source, premultiplied(background)))
            try encode(list, from..<index, region: source, into: behind, background: background)
        }
        let s = list.scale
        try blur(behind, source, sigma: effect.blurRadius * s)

        let px = shape.inPixels(origin: item.origin, scale: s)
        let shapeStart = batch.data.count
        let smoothing: Float
        switch px {
        case .single(let r): append(r); smoothing = -1
        case .union(let rs, let k): for r in rs { append(r) }; smoothing = Float(k)
        }
        let count = (batch.data.count - shapeStart) / 2
        var inst = GPUInstance(quad: quad(target))
        inst.p5 = SIMD4(Float(source.x), Float(source.y), Float(source.width), Float(source.height))
        switch effect {
        case .material(_, let tint):
            inst.color = premultiplied(tint)
            inst.p2 = SIMD4(0, Float(shapeStart), Float(count), smoothing)
        case .glass(let g):
            inst.color = premultiplied(g.tint)
            inst.p2 = SIMD4(1, Float(shapeStart), Float(count), smoothing)
            let bezel = max(1, min(g.bezel * s, px.halfThickness))
            inst.p3 = SIMD4(Float(g.refraction * s), Float(bezel), Float(g.rim), Float(g.rimWidth * s))
            inst.p4 = SIMD4(Float(Math.cos(g.lightAngle)), Float(Math.sin(g.lightAngle)), Float(g.dispersion), Float(max(1, bezel / 4)))
        }
        add(inst, .backdrop, clip: target, into: surface, source: behind)
        release(behind)
    }

    /// Gaussian blur of `rect` of `surface` in place, edges repeated (as `Blur.apply`).
    private func blur(_ surface: GPUSurface, _ rect: PixelRect, sigma: Double) throws(GPUError) {
        let k = kernel(sigma)
        guard k.count > 1 else { return }
        let first = batch.data.count * 4
        var i = 0
        while i < k.count {
            batch.data.append(SIMD4(k[i], i + 1 < k.count ? k[i + 1] : 0, i + 2 < k.count ? k[i + 2] : 0, i + 3 < k.count ? k[i + 3] : 0))
            i += 4
        }
        let temp = try acquire(rect)
        let clampRect = quad(rect), n = Float(k.count / 2)
        add(GPUInstance(quad: quad(rect), p2: clampRect, p3: SIMD4(0, n, Float(first), 0)), .blur, clip: rect, into: temp, source: surface)
        add(GPUInstance(quad: quad(rect), p2: clampRect, p3: SIMD4(1, n, Float(first), 0)), .blur, clip: rect, into: surface, source: temp)
        release(temp)
    }

    private func kernel(_ sigma: Double) -> [Float] {
        if let k = kernels[sigma] { return k }
        let k = Blur.kernel(sigma)
        if kernels.count > 64 { kernels.removeAll() }
        kernels[sigma] = k
        return k
    }

    private func append(_ r: RoundedRect) {
        batch.data.append(SIMD4(Float(r.rect.minX), Float(r.rect.minY), Float(r.rect.width), Float(r.rect.height)))
        batch.data.append(SIMD4(Float(r.cornerRadius), 0, 0, 0))
    }

    // MARK: Draws

    /// Adds one quad, joining it to the draw before when only the instance differs.
    private func add(_ instance: GPUInstance, _ program: GPUProgram, clip: PixelRect, into target: GPUSurface, source: GPUSurface?) {
        let i = batch.instances.count
        batch.instances.append(instance)
        if let last = batch.commands.indices.last, case .draw(var d) = batch.commands[last], d.target == target,
           d.scissor == clip, d.program == program, d.source == source, d.instances.upperBound == i {
            d.instances = d.instances.lowerBound..<(i + 1)
            batch.commands[last] = .draw(d)
            return
        }
        batch.commands.append(.draw(GPUDraw(target: target, scissor: clip, program: program, source: source, instances: i..<(i + 1))))
    }

    private func addMask(_ spot: AtlasSpot, dx: Int, dy: Int, _ color: Color, clip: PixelRect, into surface: GPUSurface) throws(GPUError) {
        guard spot.width > 0, spot.height > 0 else { return }
        let r = PixelRect(x: spot.left + dx, y: spot.top + dy, width: spot.width, height: spot.height)
        guard !r.clamped(to: clip).isEmpty else { return }
        add(GPUInstance(quad: quad(r), color: premultiplied(color), p2: SIMD4(Float(spot.x), Float(spot.y), 0, 0)),
            .mask, clip: clip, into: surface, source: GPUSurface(spot.texture, x: 0, y: 0))
    }

    // MARK: Atlas

    /// Where a mask is in the atlas, rasterising and uploading it the first time.
    private func atlasSpot(_ key: AtlasKey, keep font: FontFace? = nil, _ make: () -> CoverageMask) throws(GPUError) -> AtlasSpot {
        if let s = atlas.spots[key] { return s }
        let m = make()
        if let font { atlas.faces[ObjectIdentifier(font)] = font }
        guard m.width > 0, m.height > 0 else {
            let s = AtlasSpot(texture: atlas.texture, x: 0, y: 0, left: 0, top: 0, width: 0, height: 0)
            atlas.spots[key] = s
            return s
        }
        var texture = atlas.texture, x = 0, y = 0
        if let p = atlas.place(m.width, m.height) {
            (x, y) = p
        } else if m.width + 1 > Atlas.size || m.height + 1 > Atlas.size {
            // Larger than the atlas: a texture of its own for this batch.
            texture = try backend.makeTexture(width: m.width, height: m.height, format: .r8)
            transient.append(texture)
        } else {
            // Full: draw what uses it, then start again.
            try flush()
            atlas.reset()
            guard let p = atlas.place(m.width, m.height) else { throw GPUError("a \(m.width)x\(m.height) mask does not fit an empty atlas") }
            (x, y) = p
        }
        let start = batch.bytes.count
        batch.bytes.reserveCapacity(start + m.coverage.count)
        for c in m.coverage { batch.bytes.append(UInt8(min(max(c * 255 + 0.5, 0), 255))) }
        batch.uploads.append(GPUUpload(texture: texture, rect: PixelRect(x: x, y: y, width: m.width, height: m.height),
                                       bytes: start..<batch.bytes.count))
        let s = AtlasSpot(texture: texture, x: x, y: y, left: m.left, top: m.top, width: m.width, height: m.height)
        if texture == atlas.texture { atlas.spots[key] = s }
        return s
    }

    // MARK: Scratch targets

    /// A render target covering `rect` (image coordinates).
    private func acquire(_ rect: PixelRect) throws(GPUError) -> GPUSurface {
        var best: Int?
        for (i, t) in pool.enumerated() where t.width >= rect.width && t.height >= rect.height {
            if best == nil || t.width * t.height < pool[best!].width * pool[best!].height { best = i }
        }
        if let best { return GPUSurface(pool.remove(at: best), x: rect.x, y: rect.y) }
        // Rounded up so sizes that differ a little share textures.
        let w = (rect.width + 63) / 64 * 64, h = (rect.height + 63) / 64 * 64
        return GPUSurface(try backend.makeTexture(width: w, height: h, format: .rgba16Float), x: rect.x, y: rect.y)
    }

    /// Commands run in order, so a texture can be reused by a later command of the same batch.
    private func release(_ s: GPUSurface) {
        pool.append(s.texture)
        // Extra ones may still be used by recorded commands: destroyed after the batch runs.
        if pool.count > 16 { transient.append(pool.removeFirst()) }
    }
}

// MARK: Helpers

@inline(__always) func quad(_ r: PixelRect) -> SIMD4<Float> {
    SIMD4(Float(r.x), Float(r.y), Float(r.x + r.width), Float(r.y + r.height))
}

@inline(__always) func premultiplied(_ c: Color) -> SIMD4<Float> {
    let a = Float(c.opacity)
    return SIMD4(Float(c.red) * a, Float(c.green) * a, Float(c.blue) * a, a)
}

struct ImageKey: Hashable {
    let image: ObjectIdentifier
    let width: Int
    let height: Int
}

struct ImageEntry {
    let texture: GPUTexture
    /// Keeps the image alive so its identity stays unique.
    let image: RasterImage
    var lastUse: Int
}

enum AtlasKey: Hashable {
    case glyph(ObjectIdentifier, GlyphID, pixelSize: Double, growth: Double, fx: Double, fy: Double)
    case path(Path, x: Double, y: Double, scale: Double)
}

/// A mask in a texture: texel (x, y) holds the mask's top-left, which is
/// drawn at pixel (left, top) (plus the glyph's whole-pixel position).
struct AtlasSpot {
    let texture: GPUTexture
    let x: Int, y: Int
    let left: Int, top: Int
    let width: Int, height: Int
}

/// Coverage masks packed in rows ("shelves") of one r8 texture; emptied when full.
struct Atlas {
    static let size = 2048
    let texture: GPUTexture
    var spots: [AtlasKey: AtlasSpot] = [:]
    var faces: [ObjectIdentifier: FontFace] = [:]
    private var shelfY = 0, shelfHeight = 0, cursorX = 0

    init(texture: GPUTexture) { self.texture = texture }

    /// A free place for a w x h mask (with a pixel of space after it), or nil when full.
    mutating func place(_ w: Int, _ h: Int) -> (Int, Int)? {
        let w1 = w + 1, h1 = h + 1
        if w1 > Self.size || h1 > Self.size { return nil }
        if cursorX + w1 > Self.size { shelfY += shelfHeight; shelfHeight = 0; cursorX = 0 }
        if shelfY + h1 > Self.size { return nil }
        let p = (cursorX, shelfY)
        cursorX += w1
        shelfHeight = max(shelfHeight, h1)
        return p
    }

    mutating func reset() {
        spots.removeAll(keepingCapacity: true)
        faces.removeAll()
        shelfY = 0; shelfHeight = 0; cursorX = 0
    }
}
