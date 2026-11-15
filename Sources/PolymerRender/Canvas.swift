// The CPU reference renderer: draws into an RGBA float buffer and produces
// identical pixels on every OS. Used for headless images and as the
// reference the GPU backends are compared against.
import PolymerBase
import PolymerText

public struct Canvas {
    /// The pixels this canvas holds, in image coordinates (an offscreen canvas may cover only part of an image).
    public let bounds: PixelRect
    /// Size in pixels.
    public let width: Int
    public let height: Int
    /// Pixels per point.
    public let scale: Double
    /// sRGB-encoded, premultiplied RGBA, row-major.
    public internal(set) var pixels: [Float]
    /// What the canvas was filled with when made.
    public let background: Color
    /// Glyph masks kept between draws; nil rasterises every glyph afresh (same pixels either way).
    public var glyphCache: GlyphCache?
    /// Drawing is limited to this pixel rectangle.
    public internal(set) var clip: PixelRect
    /// Added to every position drawn, in points (a scroll view moves its content this way).
    public internal(set) var origin: Point = .zero

    public init(width: Int, height: Int, scale: Double = 1, background: Color = .clear) {
        self.init(bounds: PixelRect(x: 0, y: 0, width: width, height: height), scale: scale, background: background)
    }

    /// A canvas holding only the pixels of `bounds` (image coordinates).
    public init(bounds: PixelRect, scale: Double = 1, background: Color = .clear) {
        self.bounds = bounds
        let width = bounds.width, height = bounds.height
        self.background = background
        self.width = width; self.height = height; self.scale = scale
        clip = bounds
        let a = Float(background.opacity)
        let px: [Float] = [Float(background.red) * a, Float(background.green) * a, Float(background.blue) * a, a]
        var p = [Float](repeating: 0, count: width * height * 4)
        if a > 0 { for i in stride(from: 0, to: p.count, by: 4) { p[i] = px[0]; p[i + 1] = px[1]; p[i + 2] = px[2]; p[i + 3] = px[3] } }
        pixels = p
    }

    /// Runs `body` with drawing limited to `rect` (points, rounded outward to
    /// whole pixels) inside the current clip.
    public mutating func clipped(to rect: Rect, _ body: (inout Canvas) -> Void) {
        let saved = clip
        let rect = rect.offsetBy(dx: origin.x, dy: origin.y)
        let x0 = max(clip.x, Int((rect.minX * scale).rounded(.down))), y0 = max(clip.y, Int((rect.minY * scale).rounded(.down)))
        let x1 = min(clip.x + clip.width, Int((rect.maxX * scale).rounded(.up)))
        let y1 = min(clip.y + clip.height, Int((rect.maxY * scale).rounded(.up)))
        clip = PixelRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
        body(&self)
        clip = saved
    }

    /// Runs `body` with everything it draws moved by `offset` (points).
    public mutating func translated(by offset: Point, _ body: (inout Canvas) -> Void) {
        let saved = origin
        origin = origin + offset
        body(&self)
        origin = saved
    }

    /// False when `rect` (points) lies entirely outside the clip, so drawing it would change nothing.
    public func isVisible(_ rect: Rect) -> Bool {
        let x0 = (rect.minX + origin.x) * scale, y0 = (rect.minY + origin.y) * scale
        let x1 = (rect.maxX + origin.x) * scale, y1 = (rect.maxY + origin.y) * scale
        return x1 > Double(clip.x) && x0 < Double(clip.x + clip.width) && y1 > Double(clip.y) && y0 < Double(clip.y + clip.height)
    }

    /// Where pixel (x, y) of the image starts in `pixels`.
    @inline(__always) func index(_ x: Int, _ y: Int) -> Int { ((y - bounds.y) * width + (x - bounds.x)) * 4 }

    /// Source-over of a colour with per-pixel coverage, in sRGB-encoded values
    /// (as CoreGraphics and browsers blend).
    @inline(__always) mutating func blend(_ i: Int, _ c: Color, _ coverage: Float) {
        let a = Float(c.opacity) * coverage
        guard a > 0 else { return }
        let k = 1 - a
        pixels[i] = Float(c.red) * a + pixels[i] * k
        pixels[i + 1] = Float(c.green) * a + pixels[i + 1] * k
        pixels[i + 2] = Float(c.blue) * a + pixels[i + 2] * k
        pixels[i + 3] = a + pixels[i + 3] * k
    }

    /// Fills a rectangle given in points; partial pixels get partial coverage.
    public mutating func fill(_ rect: Rect, _ color: Color) {
        let rect = rect.offsetBy(dx: origin.x, dy: origin.y)
        let x0 = rect.minX * scale, y0 = rect.minY * scale, x1 = rect.maxX * scale, y1 = rect.maxY * scale
        let ix0 = max(clip.x, Int(x0.rounded(.down))), iy0 = max(clip.y, Int(y0.rounded(.down)))
        let ix1 = min(clip.x + clip.width, Int(x1.rounded(.up))), iy1 = min(clip.y + clip.height, Int(y1.rounded(.up)))
        guard ix0 < ix1, iy0 < iy1 else { return }
        for y in iy0..<iy1 {
            let cy = min(Double(y + 1), y1) - max(Double(y), y0)
            for x in ix0..<ix1 {
                let cx = min(Double(x + 1), x1) - max(Double(x), x0)
                blend(index(x, y), color, Float(cx * cy))
            }
        }
    }

    /// Fills a path given in points (non-zero winding, anti-aliased).
    public mutating func fill(_ path: Path, _ color: Color) {
        let t = AffineTransform(a: scale, b: 0, c: 0, d: scale, tx: origin.x * scale, ty: origin.y * scale)
        let contours = path.applying(t).flattened(tolerance: 0.01)
        composite(Rasterizer.rasterize(contours), color)
    }

    /// Source-over of `color` through a coverage mask.
    public mutating func composite(_ m: CoverageMask, _ color: Color) {
        let y0 = max(m.top, clip.y), y1 = min(m.top + m.height, clip.y + clip.height)
        let x0 = max(m.left, clip.x), x1 = min(m.left + m.width, clip.x + clip.width)
        guard x0 < x1, y0 < y1 else { return }
        for y in y0..<y1 {
            let row = (y - m.top) * m.width - m.left
            for x in x0..<x1 {
                let c = m.coverage[row + x]
                if c > 0 { blend(index(x, y), color, c) }
            }
        }
    }

    /// Draws laid-out glyphs with the line's baseline-left at `origin` (points).
    /// Glyph positions are in points, as laid out at `size` points per em.
    public mutating func drawGlyphs(_ glyphs: [PositionedGlyph], font: FontFace, size: Double, at origin: Point,
                                    color: Color, options: TextRenderingOptions = .standard) {
        let px = size * scale
        let ox = (origin.x + self.origin.x) * scale, oy = (origin.y + self.origin.y) * scale
        // Nothing to do for a line that is entirely outside the clip.
        let top = Int((oy - px * 2).rounded(.down)), bottom = Int((oy + px).rounded(.up))
        if bottom <= clip.y || top >= clip.y + clip.height { return }
        let lin = color.linear
        let luminance = 0.2126 * Double(lin.r) + 0.7152 * Double(lin.g) + 0.0722 * Double(lin.b)
        for g in glyphs {
            composite(GlyphRenderer.mask(font: font, glyph: g.glyph, pixelSize: px, x: ox + g.x * scale, y: oy,
                                         luminance: luminance, options: options, cache: glyphCache), color)
        }
    }

    /// Draws one line of text with its baseline-left at `origin` (points).
    /// `size` is in points. Returns the advance width in points.
    @discardableResult
    public mutating func drawText(_ text: String, font: FontFace, size: Double, at origin: Point, color: Color,
                                  options: TextRenderingOptions = .standard) -> Double {
        let glyphs = TextLayout.line(text, font: font, pixelSize: size)
        drawGlyphs(glyphs, font: font, size: size, at: origin, color: color, options: options)
        return TextLayout.width(glyphs)
    }

    /// Draws the items of `list` that touch `region` (pixels; nil for the
    /// whole canvas), changing no pixel outside it. Pixels inside come out
    /// exactly as if the whole list were drawn.
    public mutating func draw(_ list: DisplayList, in region: PixelRect? = nil) { draw(list, in: region, range: 0..<list.items.count) }

    /// Draws the items of `range` that touch `region`. A layer is drawn
    /// offscreen from its own items and composited; a layer left open at
    /// the end of the range ends there.
    mutating func draw(_ list: DisplayList, in region: PixelRect?, range: Range<Int>) {
        let region = region ?? bounds
        let items = list.items
        // Where each layer in the range ends.
        var ends: [Int: Int] = [:]
        var open: [Int] = []
        for k in range {
            switch items[k].operation {
            case .beginLayer: open.append(k)
            case .endLayer: if let s = open.popLast() { ends[s] = k }
            default: break
            }
        }
        let savedClip = clip, savedOrigin = origin
        var k = range.lowerBound
        while k < range.upperBound {
            let item = items[k]
            if case .beginLayer(let effect) = item.operation {
                let end = ends[k] ?? range.upperBound
                if item.bounds.intersects(region) {
                    clip = item.clip.clamped(to: region)
                    origin = item.origin
                    drawLayer(list, k, end, effect, region: region)
                }
                k = end + 1
                continue
            }
            defer { k += 1 }
            guard item.bounds.intersects(region) else { continue }
            clip = item.clip.clamped(to: region)
            origin = item.origin
            switch item.operation {
            case .rect(let r, let c): fill(r, c)
            case .path(let p, let c): fill(p, c)
            case .glyphs(let g): drawGlyphs(g.glyphs, font: g.font, size: g.size, at: g.position, color: g.color, options: g.options)
            case .image(let img, let r): draw(img, in: r)
            case .backdrop(let shape, let effect): drawBackdrop(list, k, shape, effect, region: region, from: range.lowerBound)
            case .beginLayer, .endLayer: break
            }
        }
        clip = savedClip; origin = savedOrigin
    }

    /// Draws the layer whose items are `begin + 1 ..< end`: offscreen over the
    /// part being drawn (plus the blur's reach), then blurred, masked and
    /// composited with its opacity.
    mutating func drawLayer(_ list: DisplayList, _ begin: Int, _ end: Int, _ effect: LayerEffect, region: PixelRect) {
        let item = list.items[begin]
        let target = item.bounds.clamped(to: clip)
        guard !target.isEmpty else { return }
        let area = target.outset(by: item.reach).clamped(to: list.fullRect)
        var off = Canvas(bounds: area, scale: scale, background: .clear)
        off.glyphCache = glyphCache
        off.draw(list, in: area, range: (begin + 1)..<end)
        let content = effect.blur > 0 ? Blur.apply(off.pixels, width: area.width, height: area.height, sigma: effect.blur * scale) : off.pixels
        let o = origin, s = scale
        let mask = effect.mask.map {
            RoundedRect(Rect(x: ($0.rect.minX + o.x) * s, y: ($0.rect.minY + o.y) * s, width: $0.rect.width * s, height: $0.rect.height * s),
                        cornerRadius: $0.cornerRadius * s)
        }
        let opacity = Float(effect.opacity)
        for y in target.y..<(target.y + target.height) {
            for x in target.x..<(target.x + target.width) {
                var k = opacity
                if let mask { k *= Float(min(max(0.5 - mask.signedDistance(Double(x) + 0.5, Double(y) + 0.5), 0), 1)) }
                guard k > 0 else { continue }
                let si = ((y - area.y) * area.width + (x - area.x)) * 4
                let a = content[si + 3] * k
                guard a > 0 else { continue }
                let i = index(x, y), keep = 1 - a
                pixels[i] = content[si] * k + pixels[i] * keep
                pixels[i + 1] = content[si + 1] * k + pixels[i + 1] * keep
                pixels[i + 2] = content[si + 2] * k + pixels[i + 2] * keep
                pixels[i + 3] = a + pixels[i + 3] * keep
            }
        }
    }

    /// Draws an image stretched to `rect` (points), whose corners are rounded
    /// to whole pixels; the image is resampled to that many pixels (and the
    /// result kept by the image for the next frame).
    public mutating func draw(_ image: RasterImage, in rect: Rect) {
        let r = PixelRect.snapping(rect, origin: origin, scale: scale)
        guard !r.isEmpty, image.bitmap.width > 0, image.bitmap.height > 0 else { return }
        let x0 = max(r.x, clip.x), y0 = max(r.y, clip.y)
        let x1 = min(r.x + r.width, clip.x + clip.width), y1 = min(r.y + r.height, clip.y + clip.height)
        guard x0 < x1, y0 < y1 else { return }
        let b = image.scaled(width: r.width, height: r.height)
        for y in y0..<y1 {
            for x in x0..<x1 {
                let s = ((y - r.y) * b.width + (x - r.x)) * 4
                let a = Float(b.pixels[s + 3]) / 255
                guard a > 0 else { continue }
                let i = index(x, y), k = 1 - a
                pixels[i] = Float(b.pixels[s]) / 255 * a + pixels[i] * k
                pixels[i + 1] = Float(b.pixels[s + 1]) / 255 * a + pixels[i + 1] * k
                pixels[i + 2] = Float(b.pixels[s + 2]) / 255 * a + pixels[i + 2] * k
                pixels[i + 3] = a + pixels[i + 3] * k
            }
        }
    }

    /// Sets every pixel of `region` to `color`, as a new canvas with that background.
    public mutating func clear(_ region: PixelRect, to color: Color) {
        let r = region.clamped(to: bounds)
        guard !r.isEmpty else { return }
        let a = Float(color.opacity)
        let px: (Float, Float, Float, Float) = a > 0 ? (Float(color.red) * a, Float(color.green) * a, Float(color.blue) * a, a) : (0, 0, 0, 0)
        for y in r.y..<(r.y + r.height) {
            for x in r.x..<(r.x + r.width) {
                let i = index(x, y)
                pixels[i] = px.0; pixels[i + 1] = px.1; pixels[i + 2] = px.2; pixels[i + 3] = px.3
            }
        }
    }

    /// 8-bit sRGB, straight alpha.
    public var bitmap: Bitmap { Bitmap(premultiplied: pixels, width: width, height: height) }
}
