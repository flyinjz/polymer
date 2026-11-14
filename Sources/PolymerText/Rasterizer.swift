// Exact analytic area coverage. Each polygon edge adds its signed area to an
// accumulation buffer; a running sum along each row gives the covered
// fraction of every pixel. No supersampling, no approximation beyond
// flattening curves to within a hundredth of a pixel.
import PolymerBase

public struct CoverageMask: Sendable {
    /// Pixel position of the mask's top-left corner.
    public var left: Int
    public var top: Int
    public var width: Int
    public var height: Int
    /// Coverage 0...1, row-major.
    public var coverage: [Float]

    public init(left: Int, top: Int, width: Int, height: Int, coverage: [Float]) {
        self.left = left; self.top = top; self.width = width; self.height = height; self.coverage = coverage
    }
    public static let empty = CoverageMask(left: 0, top: 0, width: 0, height: 0, coverage: [])
}

public enum Rasterizer {
    /// Coverage of closed polygons in pixel coordinates (y down), non-zero winding
    /// for non-overlapping contours; overlaps of the same direction clamp to full.
    ///
    /// `dx`, `dy` move the polygons before rasterising (a glyph's fractional position).
    public static func rasterize(_ contours: [[Point]], dx: Double = 0, dy: Double = 0) -> CoverageMask {
        var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
        for c in contours { for p in c { x0 = min(x0, p.x); y0 = min(y0, p.y); x1 = max(x1, p.x); y1 = max(y1, p.y) } }
        guard x0 < x1, y0 < y1 else { return .empty }
        x0 += dx; x1 += dx; y0 += dy; y1 += dy
        let left = Int(x0.rounded(.down)), top = Int(y0.rounded(.down))
        let width = Int(x1.rounded(.up)) - left, height = Int(y1.rounded(.up)) - top
        let stride = width + 2
        // Offsets are applied in Double before narrowing to Float, so shapes keep
        // full precision however far they are from the origin.
        let ox = dx - Double(left), oy = dy - Double(top)
        var acc = [Float](repeating: 0, count: stride * height)
        acc.withUnsafeMutableBufferPointer { a in
            for c in contours {
                var prev = c[c.count - 1]
                for p in c {
                    line(a, stride, width, height,
                         Float(prev.x + ox), Float(prev.y + oy), Float(p.x + ox), Float(p.y + oy))
                    prev = p
                }
            }
        }
        var cov = [Float](repeating: 0, count: width * height)
        acc.withUnsafeBufferPointer { a in
            cov.withUnsafeMutableBufferPointer { o in
                for y in 0..<height {
                    var sum: Float = 0
                    let r = y * stride, w = y * width
                    for x in 0..<width {
                        sum += a[r + x]
                        o[w + x] = min(1, abs(sum))
                    }
                }
            }
        }
        return CoverageMask(left: left, top: top, width: width, height: height, coverage: cov)
    }

    /// Adds one edge's signed area. Coordinates are relative to the mask.
    @inline(__always)
    static func line(_ a: UnsafeMutableBufferPointer<Float>, _ stride: Int, _ width: Int, _ height: Int,
                     _ ax: Float, _ ay: Float, _ bx: Float, _ by: Float) {
        if ay == by { return }
        let dir: Float
        let (p0x, p0y, p1x, p1y): (Float, Float, Float, Float)
        if ay < by { dir = 1; (p0x, p0y, p1x, p1y) = (ax, ay, bx, by) } else { dir = -1; (p0x, p0y, p1x, p1y) = (bx, by, ax, ay) }
        let dxdy = (p1x - p0x) / (p1y - p0y)
        var x = p0x
        let yStart = max(0, Int(p0y))
        if p0y < 0 { x -= p0y * dxdy }
        let yEnd = min(height, Int(p1y.rounded(.up)))
        let maxX = Float(width)
        var y = yStart
        while y < yEnd {
            let row = y * stride
            let fy = Float(y)
            let dy = min(fy + 1, p1y) - max(fy, p0y)
            let xnext = x + dxdy * dy
            let d = dy * dir
            let x0 = min(max(min(x, xnext), 0), maxX), x1 = min(max(max(x, xnext), 0), maxX)
            let x0floor = x0.rounded(.down)
            let x0i = Int(x0floor)
            let x1ceil = x1.rounded(.up)
            let x1i = Int(x1ceil)
            if x1i <= x0i + 1 {
                let xmf = 0.5 * (x0 + x1) - x0floor
                a[row + x0i] += d - d * xmf
                a[row + x0i + 1] += d * xmf
            } else {
                let s = 1 / (x1 - x0)
                let x0f = x0 - x0floor
                let a0 = 0.5 * s * (1 - x0f) * (1 - x0f)
                let x1f = x1 - x1ceil + 1
                let am = 0.5 * s * x1f * x1f
                a[row + x0i] += d * a0
                if x1i == x0i + 2 {
                    a[row + x0i + 1] += d * (1 - a0 - am)
                } else {
                    let a1 = s * (1.5 - x0f)
                    a[row + x0i + 1] += d * (a1 - a0)
                    var xi = x0i + 2
                    while xi < x1i - 1 { a[row + xi] += d * s; xi += 1 }
                    let a2 = a1 + Float(x1i - x0i - 3) * s
                    a[row + x1i - 1] += d * (1 - a2 - am)
                }
                a[row + x1i] += d * am
            }
            x = xnext
            y += 1
        }
    }
}

/// Outline emboldening: moves each polygon vertex outward along the miter of
/// its two edges, so strokes grow by `x` pixels in width and `y` in height.
public enum Embolden {
    public static func apply(_ contours: [[Point]], x: Double, y: Double) -> [[Point]] {
        guard x > 0 || y > 0 else { return contours }
        // Orientation from the total signed area (y down): positive means clockwise on screen.
        var area = 0.0
        for c in contours {
            var prev = c[c.count - 1]
            for p in c { area += prev.x * p.y - p.x * prev.y; prev = p }
        }
        let sign: Double = area >= 0 ? 1 : -1
        let hx = x / 2, hy = y / 2
        return contours.map { c in
            let n = c.count
            var out = [Point](repeating: .zero, count: n)
            for i in 0..<n {
                let p = c[i], a = c[(i + n - 1) % n], b = c[(i + 1) % n]
                var ix = p.x - a.x, iy = p.y - a.y, ox = b.x - p.x, oy = b.y - p.y
                let li = (ix * ix + iy * iy).squareRoot(), lo = (ox * ox + oy * oy).squareRoot()
                guard li > 1e-9, lo > 1e-9 else { out[i] = p; continue }
                ix /= li; iy /= li; ox /= lo; oy /= lo
                // Outward normals of the incoming and outgoing edges.
                let nix = iy * sign, niy = -ix * sign, nox = oy * sign, noy = -ox * sign
                let d = 1 + nix * nox + niy * noy
                var mx = nix + nox, my = niy + noy
                if d > 0.05 { mx /= d; my /= d } else {
                    // Very sharp corner: limit the miter.
                    let l = (mx * mx + my * my).squareRoot()
                    if l > 1e-9 { mx /= l; my /= l } else { mx = 0; my = 0 }
                }
                out[i] = Point(x: p.x + mx * hx, y: p.y + my * hy)
            }
            return out
        }
    }
}
