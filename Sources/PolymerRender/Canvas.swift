// The CPU reference renderer: draws into an RGBA float buffer and produces
// identical pixels on every OS. Used for headless images and as the
// reference the GPU backends are compared against.
import PolymerBase
import PolymerText

public struct Canvas {
    /// Size in pixels.
    public let width: Int
    public let height: Int
    /// Pixels per point.
    public let scale: Double
    /// sRGB-encoded, premultiplied RGBA, row-major.
    public private(set) var pixels: [Float]
    /// Glyph masks kept between draws; nil rasterises every glyph afresh (same pixels either way).
    public var glyphCache: GlyphCache?
    /// Drawing is limited to this pixel rectangle.
    public private(set) var clip: PixelRect
    /// Added to every position drawn, in points (a scroll view moves its content this way).
    public private(set) var origin: Point = .zero

    public init(width: Int, height: Int, scale: Double = 1, background: Color = .clear) {
        self.width = width; self.height = height; self.scale = scale
        clip = PixelRect(x: 0, y: 0, width: width, height: height)
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
                blend((y * width + x) * 4, color, Float(cx * cy))
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
                if c > 0 { blend((y * width + x) * 4, color, c) }
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

    /// 8-bit sRGB, straight alpha.
    public var bitmap: Bitmap {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = pixels[i + 3]
            let inv: Float = a > 0 ? 1 / a : 0
            for c in 0..<3 { out[i + c] = UInt8(min(max(pixels[i + c] * inv * 255 + 0.5, 0), 255)) }
            out[i + 3] = UInt8(min(max(a * 255 + 0.5, 0), 255))
        }
        return Bitmap(width: width, height: height, pixels: out)
    }
}
