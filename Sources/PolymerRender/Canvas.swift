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

    /// Source-over of a premultiplied sRGB colour onto pixel `i`.
    @inline(__always) mutating func blendPremultiplied(_ i: Int, _ r: Float, _ g: Float, _ b: Float, _ a: Float) {
        guard a > 0 else { return }
        let k = 1 - a
        pixels[i] = r + pixels[i] * k
        pixels[i + 1] = g + pixels[i + 1] * k
        pixels[i + 2] = b + pixels[i + 2] * k
        pixels[i + 3] = a + pixels[i + 3] * k
    }

    /// Draws an image into `rect` (points), resampled with `filter` and blended
    /// with `opacity` (0...1). Partial edge pixels get partial coverage.
    public mutating func drawImage(_ image: RenderImage, in rect: Rect, opacity: Double = 1, filter: ImageFilter = .bilinear) {
        let sw = image.width, sh = image.height
        guard sw > 0, sh > 0, opacity > 0, !rect.isEmpty else { return }
        let rect = rect.offsetBy(dx: origin.x, dy: origin.y)
        let x0 = rect.minX * scale, y0 = rect.minY * scale, x1 = rect.maxX * scale, y1 = rect.maxY * scale
        let dw = x1 - x0, dh = y1 - y0
        guard dw > 0, dh > 0 else { return }
        let ix0 = max(clip.x, Int(x0.rounded(.down))), iy0 = max(clip.y, Int(y0.rounded(.down)))
        let ix1 = min(clip.x + clip.width, Int(x1.rounded(.up))), iy1 = min(clip.y + clip.height, Int(y1.rounded(.up)))
        guard ix0 < ix1, iy0 < iy1 else { return }
        let src = image.bitmap.pixels
        let inv255: Float = 1 / 255
        let op = Float(min(max(opacity, 0), 1))

        @inline(__always) func premulSample(_ sx: Int, _ sy: Int) -> (Float, Float, Float, Float) {
            let o = (sy * sw + sx) * 4
            let a = Float(src[o + 3]) * inv255
            return (Float(src[o]) * inv255 * a, Float(src[o + 1]) * inv255 * a, Float(src[o + 2]) * inv255 * a, a)
        }

        for y in iy0..<iy1 {
            let cy = min(Double(y + 1), y1) - max(Double(y), y0)
            let v = (Double(y) + 0.5 - y0) / dh * Double(sh)
            for x in ix0..<ix1 {
                let cx = min(Double(x + 1), x1) - max(Double(x), x0)
                let cov = Float(cx * cy) * op
                guard cov > 0 else { continue }
                let u = (Double(x) + 0.5 - x0) / dw * Double(sw)
                let r, g, b, a: Float
                switch filter {
                case .nearest:
                    let sx = min(max(Int(u.rounded(.down)), 0), sw - 1)
                    let sy = min(max(Int(v.rounded(.down)), 0), sh - 1)
                    (r, g, b, a) = premulSample(sx, sy)
                case .bilinear:
                    let fx = u - 0.5, fy = v - 0.5
                    let xA = Int(fx.rounded(.down)), yA = Int(fy.rounded(.down))
                    let tx = Float(fx - Double(xA)), ty = Float(fy - Double(yA))
                    let sx0 = min(max(xA, 0), sw - 1), sx1 = min(max(xA + 1, 0), sw - 1)
                    let sy0 = min(max(yA, 0), sh - 1), sy1 = min(max(yA + 1, 0), sh - 1)
                    let p00 = premulSample(sx0, sy0), p10 = premulSample(sx1, sy0)
                    let p01 = premulSample(sx0, sy1), p11 = premulSample(sx1, sy1)
                    let w00 = (1 - tx) * (1 - ty), w10 = tx * (1 - ty), w01 = (1 - tx) * ty, w11 = tx * ty
                    r = p00.0 * w00 + p10.0 * w10 + p01.0 * w01 + p11.0 * w11
                    g = p00.1 * w00 + p10.1 * w10 + p01.1 * w01 + p11.1 * w11
                    b = p00.2 * w00 + p10.2 * w10 + p01.2 * w01 + p11.2 * w11
                    a = p00.3 * w00 + p10.3 * w10 + p01.3 * w01 + p11.3 * w11
                }
                blendPremultiplied((y * width + x) * 4, r * cov, g * cov, b * cov, a * cov)
            }
        }
    }

    /// Blurs the canvas pixels already drawn inside `rect` (points, clamped to
    /// the current clip) using a 3-pass separable box approximation to a
    /// Gaussian of standard deviation `radius` points (dark glass backdrop).
    public mutating func backdropBlur(_ rect: Rect, radius: Double) {
        guard radius > 0, !rect.isEmpty else { return }
        let box = PixelRect.covering(rect, origin: origin, scale: scale).clamped(to: clip)
        guard !box.isEmpty else { return }
        let radii = Self.gaussBoxRadii(sigma: radius * scale)
        guard radii.0 > 0 || radii.1 > 0 || radii.2 > 0 else { return }
        let bw = box.width, bh = box.height
        var bufA = [Float](repeating: 0, count: bw * bh * 4)
        var bufB = [Float](repeating: 0, count: bw * bh * 4)
        for y in 0..<bh {
            let srcRow = ((box.y + y) * width + box.x) * 4
            let dstRow = y * bw * 4
            for i in 0..<(bw * 4) { bufA[dstRow + i] = pixels[srcRow + i] }
        }
        for r in [radii.0, radii.1, radii.2] where r > 0 {
            Self.boxBlurH(src: bufA, dst: &bufB, w: bw, h: bh, r: r)
            Self.boxBlurV(src: bufB, dst: &bufA, w: bw, h: bh, r: r)
        }
        for y in 0..<bh {
            let dstRow = ((box.y + y) * width + box.x) * 4
            let srcRow = y * bw * 4
            for i in 0..<(bw * 4) { pixels[dstRow + i] = bufA[srcRow + i] }
        }
    }

    /// Three box radii approximating a Gaussian of standard deviation `sigma` pixels.
    static func gaussBoxRadii(sigma: Double) -> (Int, Int, Int) {
        guard sigma > 0 else { return (0, 0, 0) }
        let wIdeal = ((12 * sigma * sigma / 3) + 1).squareRoot()
        var wl = Int(wIdeal.rounded(.down))
        if wl % 2 == 0 { wl = max(1, wl - 1) }
        let wu = wl + 2
        let mIdeal = (12 * sigma * sigma - 3 * Double(wl * wl) - 12 * Double(wl) - 9) / (-4 * Double(wl) - 4)
        let m = Int(mIdeal.rounded())
        let rl = max(0, (wl - 1) / 2), ru = max(0, (wu - 1) / 2)
        return (0 < m ? rl : ru, 1 < m ? rl : ru, 2 < m ? rl : ru)
    }

    private static func boxBlurH(src: [Float], dst: inout [Float], w: Int, h: Int, r: Int) {
        let inv = Float(1) / Float(2 * r + 1)
        for y in 0..<h {
            let row = y * w * 4
            let f0 = src[row], f1 = src[row + 1], f2 = src[row + 2], f3 = src[row + 3]
            let lOff = row + (w - 1) * 4
            let l0 = src[lOff], l1 = src[lOff + 1], l2 = src[lOff + 2], l3 = src[lOff + 3]
            var a0 = Float(r + 1) * f0, a1 = Float(r + 1) * f1, a2 = Float(r + 1) * f2, a3 = Float(r + 1) * f3
            for j in 0..<r {
                let o = row + min(j, w - 1) * 4
                a0 += src[o]; a1 += src[o + 1]; a2 += src[o + 2]; a3 += src[o + 3]
            }
            for x in 0..<w {
                let addIdx = x + r
                let remIdx = x - r - 1
                if addIdx < w {
                    let o = row + addIdx * 4
                    a0 += src[o]; a1 += src[o + 1]; a2 += src[o + 2]; a3 += src[o + 3]
                } else {
                    a0 += l0; a1 += l1; a2 += l2; a3 += l3
                }
                if remIdx >= 0 {
                    let o = row + remIdx * 4
                    a0 -= src[o]; a1 -= src[o + 1]; a2 -= src[o + 2]; a3 -= src[o + 3]
                } else {
                    a0 -= f0; a1 -= f1; a2 -= f2; a3 -= f3
                }
                let o = row + x * 4
                dst[o] = a0 * inv; dst[o + 1] = a1 * inv; dst[o + 2] = a2 * inv; dst[o + 3] = a3 * inv
            }
        }
    }

    private static func boxBlurV(src: [Float], dst: inout [Float], w: Int, h: Int, r: Int) {
        let inv = Float(1) / Float(2 * r + 1)
        let stride = w * 4
        for x in 0..<w {
            let col = x * 4
            let f0 = src[col], f1 = src[col + 1], f2 = src[col + 2], f3 = src[col + 3]
            let lOff = (h - 1) * stride + col
            let l0 = src[lOff], l1 = src[lOff + 1], l2 = src[lOff + 2], l3 = src[lOff + 3]
            var a0 = Float(r + 1) * f0, a1 = Float(r + 1) * f1, a2 = Float(r + 1) * f2, a3 = Float(r + 1) * f3
            for j in 0..<r {
                let o = min(j, h - 1) * stride + col
                a0 += src[o]; a1 += src[o + 1]; a2 += src[o + 2]; a3 += src[o + 3]
            }
            for y in 0..<h {
                let addIdx = y + r
                let remIdx = y - r - 1
                if addIdx < h {
                    let o = addIdx * stride + col
                    a0 += src[o]; a1 += src[o + 1]; a2 += src[o + 2]; a3 += src[o + 3]
                } else {
                    a0 += l0; a1 += l1; a2 += l2; a3 += l3
                }
                if remIdx >= 0 {
                    let o = remIdx * stride + col
                    a0 -= src[o]; a1 -= src[o + 1]; a2 -= src[o + 2]; a3 -= src[o + 3]
                } else {
                    a0 -= f0; a1 -= f1; a2 -= f2; a3 -= f3
                }
                let o = y * stride + col
                dst[o] = a0 * inv; dst[o + 1] = a1 * inv; dst[o + 2] = a2 * inv; dst[o + 3] = a3 * inv
            }
        }
    }

    /// Shifts pixels inside `rect` in-place by `(dx, dy)` pixels (zero
    /// allocation). Pixels moved into the newly exposed strip are untouched
    /// and meant to be redrawn as damage.
    public mutating func scroll(_ rect: PixelRect, dx: Int, dy: Int) {
        let r = rect.clamped(to: PixelRect(x: 0, y: 0, width: width, height: height))
        guard !r.isEmpty, dx != 0 || dy != 0, abs(dx) < r.width, abs(dy) < r.height else { return }
        let copyW = r.width - abs(dx), copyH = r.height - abs(dy)
        let dstX0 = dx >= 0 ? r.x + dx : r.x
        let dstY0 = dy >= 0 ? r.y + dy : r.y
        let srcX0 = dx >= 0 ? r.x : r.x - dx
        let srcY0 = dy >= 0 ? r.y : r.y - dy
        let yOrder: StrideThrough<Int> = dy > 0 ? stride(from: copyH - 1, through: 0, by: -1) : stride(from: 0, through: copyH - 1, by: 1)
        for row in yOrder {
            let sy = srcY0 + row, dyRow = dstY0 + row
            if dx > 0 {
                for col in stride(from: copyW - 1, through: 0, by: -1) {
                    let s = (sy * width + srcX0 + col) * 4, d = (dyRow * width + dstX0 + col) * 4
                    pixels[d] = pixels[s]; pixels[d + 1] = pixels[s + 1]; pixels[d + 2] = pixels[s + 2]; pixels[d + 3] = pixels[s + 3]
                }
            } else {
                for col in 0..<copyW {
                    let s = (sy * width + srcX0 + col) * 4, d = (dyRow * width + dstX0 + col) * 4
                    pixels[d] = pixels[s]; pixels[d + 1] = pixels[s + 1]; pixels[d + 2] = pixels[s + 2]; pixels[d + 3] = pixels[s + 3]
                }
            }
        }
    }

    /// Draws the items of `list` that touch `region` (pixels; nil for the
    /// whole canvas), changing no pixel outside it. Pixels inside come out
    /// exactly as if the whole list were drawn.
    public mutating func draw(_ list: DisplayList, in region: PixelRect? = nil) {
        let region = region ?? PixelRect(x: 0, y: 0, width: width, height: height)
        let savedClip = clip, savedOrigin = origin
        for item in list.items where item.bounds.intersects(region) {
            clip = item.clip.clamped(to: region)
            origin = item.origin
            switch item.operation {
            case .rect(let r, let c): fill(r, c)
            case .path(let p, let c): fill(p, c)
            case .glyphs(let g): drawGlyphs(g.glyphs, font: g.font, size: g.size, at: g.position, color: g.color, options: g.options)
            case .image(let img, let r, let op, let f): drawImage(img, in: r, opacity: op, filter: f)
            case .backdropBlur(let r, let radius): backdropBlur(r, radius: radius)
            }
        }
        clip = savedClip; origin = savedOrigin
    }

    /// Sets every pixel of `region` to `color`, as a new canvas with that background.
    public mutating func clear(_ region: PixelRect, to color: Color) {
        let r = region.clamped(to: PixelRect(x: 0, y: 0, width: width, height: height))
        guard !r.isEmpty else { return }
        let a = Float(color.opacity)
        let px: (Float, Float, Float, Float) = a > 0 ? (Float(color.red) * a, Float(color.green) * a, Float(color.blue) * a, a) : (0, 0, 0, 0)
        for y in r.y..<(r.y + r.height) {
            for x in r.x..<(r.x + r.width) {
                let i = (y * width + x) * 4
                pixels[i] = px.0; pixels[i + 1] = px.1; pixels[i + 2] = px.2; pixels[i + 3] = px.3
            }
        }
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
