// Backdrop effects (DESIGN section 11): materials (blur and tint) and liquid
// glass (refraction, frost, rim light, tint, optional dispersion). An effect
// reads the pixels drawn before it, within its shape and reach, and draws
// the filtered result inside the shape. Shapes are rounded rectangles; their
// exact signed distance gives coverage, edge normals and the depth inside.
import PolymerBase

/// Liquid glass, in points. The look of the defaults belongs to the design system.
public struct GlassStyle: Hashable, Sendable {
    /// How far content under the rim is pulled in from outside the shape, in points.
    public var refraction: Double
    /// Width of the curved rim, where light bends, in points.
    public var bezel: Double
    /// Blur radius of what is seen through the glass, in points.
    public var frost: Double
    /// Laid over what is seen through the glass.
    public var tint: Color
    /// Strength of the highlight along edges facing the light, 0 to 1.
    public var rim: Double
    /// Width of that highlight, in points.
    public var rimWidth: Double
    /// Direction the light comes from, in radians: 0 from the right, -pi/2 from above.
    public var lightAngle: Double
    /// How much more red bends than blue at the rim; 0 for none.
    public var dispersion: Double

    public init(refraction: Double, bezel: Double, frost: Double, tint: Color, rim: Double, rimWidth: Double = 1.5,
                lightAngle: Double = -3 * Double.pi / 4, dispersion: Double = 0) {
        self.refraction = refraction; self.bezel = bezel; self.frost = frost; self.tint = tint
        self.rim = rim; self.rimWidth = rimWidth; self.lightAngle = lightAngle; self.dispersion = dispersion
    }
}

/// What a backdrop item does to the pixels behind its shape.
public enum BackdropEffect: Hashable, Sendable {
    /// Blur (radius in points: the Gaussian's standard deviation) with a tint laid over.
    case material(blur: Double, tint: Color)
    case glass(GlassStyle)

    var blurRadius: Double {
        switch self { case .material(let b, _): b; case .glass(let g): g.frost }
    }

    /// How many pixels beyond a point the effect reads to draw it.
    func reach(scale: Double) -> Int {
        let blur = Int((3 * blurRadius * scale).rounded(.up))
        switch self {
        case .material: return blur + 1
        case .glass(let g): return blur + Int((g.refraction * scale * (1 + abs(g.dispersion))).rounded(.up)) + 2
        }
    }
}

enum Blur {
    /// Normalised Gaussian weights for a standard deviation of `sigma` pixels, out to 3 sigma.
    static func kernel(_ sigma: Double) -> [Float] {
        guard sigma > 0.01 else { return [1] }
        let n = Int((3 * sigma).rounded(.up))
        var w = [Double](repeating: 0, count: 2 * n + 1)
        var sum = 0.0
        for i in -n...n {
            let v = Math.exp(-Double(i * i) / (2 * sigma * sigma))
            w[i + n] = v; sum += v
        }
        return w.map { Float($0 / sum) }
    }

    /// Separable Gaussian blur of a premultiplied RGBA buffer, repeating the edge pixels.
    static func apply(_ src: [Float], width: Int, height: Int, sigma: Double) -> [Float] {
        let k = kernel(sigma)
        guard k.count > 1, width > 0, height > 0 else { return src }
        let n = k.count / 2
        var mid = [Float](repeating: 0, count: src.count)
        for y in 0..<height {
            for x in 0..<width {
                var r: Float = 0, g: Float = 0, b: Float = 0, a: Float = 0
                for j in 0..<k.count {
                    let sx = min(max(x + j - n, 0), width - 1)
                    let i = (y * width + sx) * 4, f = k[j]
                    r += src[i] * f; g += src[i + 1] * f; b += src[i + 2] * f; a += src[i + 3] * f
                }
                let o = (y * width + x) * 4
                mid[o] = r; mid[o + 1] = g; mid[o + 2] = b; mid[o + 3] = a
            }
        }
        var out = [Float](repeating: 0, count: src.count)
        for y in 0..<height {
            for x in 0..<width {
                var r: Float = 0, g: Float = 0, b: Float = 0, a: Float = 0
                for j in 0..<k.count {
                    let sy = min(max(y + j - n, 0), height - 1)
                    let i = (sy * width + x) * 4, f = k[j]
                    r += mid[i] * f; g += mid[i + 1] * f; b += mid[i + 2] * f; a += mid[i + 3] * f
                }
                let o = (y * width + x) * 4
                out[o] = r; out[o + 1] = g; out[o + 2] = b; out[o + 3] = a
            }
        }
        return out
    }
}

extension Canvas {
    /// Draws backdrop item `index` of `list` within `region`. The pixels
    /// behind it come from this canvas when they are all already drawn here
    /// (the region covers its reach), otherwise from the items before it
    /// drawn again offscreen, so a partial redraw matches a whole one.
    mutating func drawBackdrop(_ list: DisplayList, _ itemIndex: Int, _ shape: RoundedRect, _ effect: BackdropEffect, region: PixelRect) {
        let item = list.items[itemIndex]
        let target = item.bounds.clamped(to: clip)
        guard !target.isEmpty else { return }
        let reach = item.reach
        let source = target.outset(by: reach).clamped(to: list.fullRect)
        // The pixels behind the effect, premultiplied, over `source`.
        var behind = [Float](repeating: 0, count: source.width * source.height * 4)
        if source.clamped(to: region) == source, source.clamped(to: bounds) == source {
            for y in 0..<source.height {
                let from = index(source.x, source.y + y), to = y * source.width * 4
                for i in 0..<(source.width * 4) { behind[to + i] = pixels[from + i] }
            }
        } else {
            var off = Canvas(bounds: source, scale: scale, background: background)
            off.glyphCache = glyphCache
            off.draw(list, in: source, upTo: itemIndex)
            behind = off.pixels
        }
        let sigma = effect.blurRadius * scale
        let seen = Blur.apply(behind, width: source.width, height: source.height, sigma: sigma)

        // The shape in pixels.
        let o = origin, s = scale
        let px = RoundedRect(Rect(x: (shape.rect.minX + o.x) * s, y: (shape.rect.minY + o.y) * s,
                                  width: shape.rect.width * s, height: shape.rect.height * s), cornerRadius: shape.cornerRadius * s)

        /// Bilinear sample of `seen` at pixel-space point (x, y) (pixel centres at +0.5).
        @inline(__always) func sample(_ x: Double, _ y: Double, _ ch: Int) -> Float {
            let fx = min(max(x - 0.5 - Double(source.x), 0), Double(source.width - 1))
            let fy = min(max(y - 0.5 - Double(source.y), 0), Double(source.height - 1))
            let x0 = Int(fx), y0 = Int(fy)
            let x1 = min(x0 + 1, source.width - 1), y1 = min(y0 + 1, source.height - 1)
            let tx = Float(fx - Double(x0)), ty = Float(fy - Double(y0))
            let a = seen[(y0 * source.width + x0) * 4 + ch], b = seen[(y0 * source.width + x1) * 4 + ch]
            let c = seen[(y1 * source.width + x0) * 4 + ch], d = seen[(y1 * source.width + x1) * 4 + ch]
            return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
        }

        let shortSide = min(px.rect.width, px.rect.height)
        for y in target.y..<(target.y + target.height) {
            for x in target.x..<(target.x + target.width) {
                let cx = Double(x) + 0.5, cy = Double(y) + 0.5
                let d = px.signedDistance(cx, cy)
                let cov = Float(min(max(0.5 - d, 0), 1))
                guard cov > 0 else { continue }
                var r: Float, g: Float, b: Float, a: Float
                var tint: Color
                var highlight: Float = 0
                switch effect {
                case .material(_, let t):
                    let si = ((y - source.y) * source.width + (x - source.x)) * 4
                    r = seen[si]; g = seen[si + 1]; b = seen[si + 2]; a = seen[si + 3]
                    tint = t
                case .glass(let gs):
                    let depth = max(0, -d)
                    let bezel = max(1, min(gs.bezel * s, shortSide / 2))
                    let u = min(depth / bezel, 1)
                    // A curved rim: content is pulled in from outside, most at the edge, none past the bezel.
                    let m = gs.refraction * s * (1 - u) * (1 - u)
                    let n = px.normal(cx, cy)
                    let mr = m * (1 + gs.dispersion), mb = m * (1 - gs.dispersion)
                    r = sample(cx + n.x * mr, cy + n.y * mr, 0)
                    g = sample(cx + n.x * m, cy + n.y * m, 1)
                    b = sample(cx + n.x * mb, cy + n.y * mb, 2)
                    a = sample(cx + n.x * m, cy + n.y * m, 3)
                    tint = gs.tint
                    // Rim light on edges facing the light, fainter opposite.
                    let lx = Math.cos(gs.lightAngle), ly = Math.sin(gs.lightAngle)
                    let facing = n.x * lx + n.y * ly
                    let edge = max(0, 1 - depth / max(0.5, gs.rimWidth * s))
                    let lit = max(0, facing) * max(0, facing) + 0.35 * max(0, -facing) * max(0, -facing)
                    highlight = Float(gs.rim * lit * edge)
                }
                // Tint over what is seen, then the highlight (white) over that.
                let ta = Float(tint.opacity)
                r = Float(tint.red) * ta + r * (1 - ta); g = Float(tint.green) * ta + g * (1 - ta)
                b = Float(tint.blue) * ta + b * (1 - ta); a = ta + a * (1 - ta)
                if highlight > 0 {
                    let h = min(highlight, 1)
                    r = h + r * (1 - h); g = h + g * (1 - h); b = h + b * (1 - h); a = h + a * (1 - h)
                }
                // Inside the shape's anti-aliased edge.
                let i = index(x, y)
                pixels[i] = r * cov + pixels[i] * (1 - cov)
                pixels[i + 1] = g * cov + pixels[i + 1] * (1 - cov)
                pixels[i + 2] = b * cov + pixels[i + 2] * (1 - cov)
                pixels[i + 3] = a * cov + pixels[i + 3] * (1 - cov)
            }
        }
    }
}
