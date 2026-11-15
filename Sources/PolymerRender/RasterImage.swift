// Images to draw: a bitmap with the copies of it scaled to the sizes it is
// drawn at, so a frame that draws an image at an unchanged size does no
// resampling.
import PolymerBase

/// A bitmap as drawn by the renderer. Compared by identity: a display item
/// that draws the same `RasterImage` in the same place draws the same pixels.
/// Used on one thread at a time (the thread that renders).
public final class RasterImage {
    public let bitmap: Bitmap
    /// Scaled copies by size in pixels, most recent last.
    private var scaled: [(width: Int, height: Int, bitmap: Bitmap)] = []
    /// Number of resamples done, for checks and measurements.
    public private(set) var resampleCount = 0

    public init(_ bitmap: Bitmap) { self.bitmap = bitmap }

    /// The image at `width` x `height` pixels: the bitmap itself at its own
    /// size, otherwise resampled (Lanczos-3, widened when shrinking so every
    /// source pixel counts) and kept for the next frame.
    public func scaled(width: Int, height: Int) -> Bitmap {
        if width == bitmap.width, height == bitmap.height { return bitmap }
        if let i = scaled.firstIndex(where: { $0.width == width && $0.height == height }) {
            let e = scaled.remove(at: i)
            scaled.append(e)
            return e.bitmap
        }
        let b = Resample.lanczos(bitmap, width: width, height: height)
        resampleCount += 1
        if scaled.count >= 2 { scaled.removeFirst() }
        scaled.append((width, height, b))
        return b
    }
}

enum Resample {
    static func lanczos3(_ x: Double) -> Double {
        let x = abs(x)
        if x < 1e-12 { return 1 }
        if x >= 3 { return 0 }
        let px = Double.pi * x
        return 3 * Math.sin(px) * Math.sin(px / 3) / (px * px)
    }

    /// Weights for one axis: for each output pixel, the first source pixel and the weights from there.
    static func weights(from n: Int, to m: Int) -> [(start: Int, w: [Float])] {
        let ratio = Double(n) / Double(m)
        let stretch = max(1, ratio)          // widen the kernel when shrinking
        let support = 3 * stretch
        var out: [(Int, [Float])] = []
        out.reserveCapacity(m)
        for i in 0..<m {
            let center = (Double(i) + 0.5) * ratio - 0.5
            let lo = Int((center - support).rounded(.up)), hi = Int((center + support).rounded(.down))
            var w: [Double] = []
            var sum = 0.0
            for j in lo...hi {
                let v = lanczos3((Double(j) - center) / stretch)
                w.append(v); sum += v
            }
            // Pixels past the edge repeat the edge pixel: fold their weights onto it.
            var start = lo, folded: [Double] = []
            if lo < 0 || hi > n - 1 {
                let a = max(lo, 0), b = min(hi, n - 1)
                folded = [Double](repeating: 0, count: b - a + 1)
                for (k, v) in w.enumerated() { folded[min(max(lo + k, 0), n - 1) - a] += v }
                start = a
            } else {
                folded = w
            }
            out.append((start, folded.map { Float($0 / sum) }))
        }
        return out
    }

    /// Separable resampling in premultiplied sRGB-encoded values (as the canvas blends).
    static func lanczos(_ src: Bitmap, width: Int, height: Int) -> Bitmap {
        let w0 = src.width, h0 = src.height
        guard width > 0, height > 0, w0 > 0, h0 > 0 else { return Bitmap(width: max(0, width), height: max(0, height)) }
        // Premultiplied floats.
        var pre = [Float](repeating: 0, count: w0 * h0 * 4)
        for i in 0..<(w0 * h0) {
            let a = Float(src.pixels[4 * i + 3]) / 255
            pre[4 * i] = Float(src.pixels[4 * i]) / 255 * a
            pre[4 * i + 1] = Float(src.pixels[4 * i + 1]) / 255 * a
            pre[4 * i + 2] = Float(src.pixels[4 * i + 2]) / 255 * a
            pre[4 * i + 3] = a
        }
        // Horizontal pass: w0 x h0 → width x h0.
        let wx = weights(from: w0, to: width)
        var mid = [Float](repeating: 0, count: width * h0 * 4)
        for y in 0..<h0 {
            for x in 0..<width {
                let (s, w) = wx[x]
                var r: Float = 0, g: Float = 0, b: Float = 0, a: Float = 0
                for k in 0..<w.count {
                    let i = (y * w0 + s + k) * 4, f = w[k]
                    r += pre[i] * f; g += pre[i + 1] * f; b += pre[i + 2] * f; a += pre[i + 3] * f
                }
                let o = (y * width + x) * 4
                mid[o] = r; mid[o + 1] = g; mid[o + 2] = b; mid[o + 3] = a
            }
        }
        // Vertical pass: width x h0 → width x height, back to straight 8-bit.
        let wy = weights(from: h0, to: height)
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let (s, w) = wy[y]
            for x in 0..<width {
                var r: Float = 0, g: Float = 0, b: Float = 0, a: Float = 0
                for k in 0..<w.count {
                    let i = ((s + k) * width + x) * 4, f = w[k]
                    r += mid[i] * f; g += mid[i + 1] * f; b += mid[i + 2] * f; a += mid[i + 3] * f
                }
                // Lanczos overshoots at edges: clamp alpha, then colour to alpha.
                a = min(max(a, 0), 1)
                let o = (y * width + x) * 4
                if a > 0 {
                    out[o] = UInt8(min(max(r, 0), a) / a * 255 + 0.5)
                    out[o + 1] = UInt8(min(max(g, 0), a) / a * 255 + 0.5)
                    out[o + 2] = UInt8(min(max(b, 0), a) / a * 255 + 0.5)
                }
                out[o + 3] = UInt8(a * 255 + 0.5)
            }
        }
        return Bitmap(width: width, height: height, pixels: out)
    }
}

extension RasterImage: Hashable {
    public static func == (a: RasterImage, b: RasterImage) -> Bool { a === b }
    public func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }
}
