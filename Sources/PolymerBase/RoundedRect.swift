// A rectangle with circular corners: the geometry of every built-in shape
// (rectangles, rounded rectangles, capsules, circles) and of every effect
// shape. It has an exact signed distance, which effects use for coverage,
// edge normals and the distance from the edge.

public struct RoundedRect: Hashable, Sendable {
    public var rect: Rect
    /// Corner radius, at most half the shorter side.
    public var cornerRadius: Double

    public init(_ rect: Rect, cornerRadius: Double) {
        self.rect = rect
        self.cornerRadius = max(0, min(cornerRadius, min(rect.width, rect.height) / 2))
    }

    /// The same shape moved inwards by `amount` on every side (outwards when negative).
    public func inset(by amount: Double) -> RoundedRect {
        let r = Rect(x: rect.minX + amount, y: rect.minY + amount,
                     width: max(0, rect.width - 2 * amount), height: max(0, rect.height - 2 * amount))
        return RoundedRect(r, cornerRadius: cornerRadius - amount)
    }

    /// The outline, clockwise on screen (y down), or anticlockwise when `reversed`.
    /// Corners are cubic Béziers (0.03% from a true circle).
    public func path(reversed: Bool = false) -> Path {
        var p = Path()
        let r = rect, k = cornerRadius, c = k * (1 - 0.5522847498307936)
        guard r.width > 0, r.height > 0 else { return p }
        if k <= 0 {
            if reversed {
                p.move(to: r.origin); p.line(to: Point(x: r.minX, y: r.maxY)); p.line(to: Point(x: r.maxX, y: r.maxY))
                p.line(to: Point(x: r.maxX, y: r.minY)); p.close()
                return p
            }
            return Path(rect: r)
        }
        if !reversed {
            p.move(to: Point(x: r.minX + k, y: r.minY))
            p.line(to: Point(x: r.maxX - k, y: r.minY))
            p.cubic(to: Point(x: r.maxX, y: r.minY + k), control1: Point(x: r.maxX - c, y: r.minY), control2: Point(x: r.maxX, y: r.minY + c))
            p.line(to: Point(x: r.maxX, y: r.maxY - k))
            p.cubic(to: Point(x: r.maxX - k, y: r.maxY), control1: Point(x: r.maxX, y: r.maxY - c), control2: Point(x: r.maxX - c, y: r.maxY))
            p.line(to: Point(x: r.minX + k, y: r.maxY))
            p.cubic(to: Point(x: r.minX, y: r.maxY - k), control1: Point(x: r.minX + c, y: r.maxY), control2: Point(x: r.minX, y: r.maxY - c))
            p.line(to: Point(x: r.minX, y: r.minY + k))
            p.cubic(to: Point(x: r.minX + k, y: r.minY), control1: Point(x: r.minX, y: r.minY + c), control2: Point(x: r.minX + c, y: r.minY))
        } else {
            p.move(to: Point(x: r.minX + k, y: r.minY))
            p.cubic(to: Point(x: r.minX, y: r.minY + k), control1: Point(x: r.minX + c, y: r.minY), control2: Point(x: r.minX, y: r.minY + c))
            p.line(to: Point(x: r.minX, y: r.maxY - k))
            p.cubic(to: Point(x: r.minX + k, y: r.maxY), control1: Point(x: r.minX, y: r.maxY - c), control2: Point(x: r.minX + c, y: r.maxY))
            p.line(to: Point(x: r.maxX - k, y: r.maxY))
            p.cubic(to: Point(x: r.maxX, y: r.maxY - k), control1: Point(x: r.maxX - c, y: r.maxY), control2: Point(x: r.maxX, y: r.maxY - c))
            p.line(to: Point(x: r.maxX, y: r.minY + k))
            p.cubic(to: Point(x: r.maxX - k, y: r.minY), control1: Point(x: r.maxX, y: r.minY + c), control2: Point(x: r.maxX - c, y: r.minY))
        }
        p.close()
        return p
    }

    /// Signed distance from `p` to the edge: negative inside, positive outside.
    @inlinable public func signedDistance(_ x: Double, _ y: Double) -> Double {
        let hw = rect.width / 2, hh = rect.height / 2
        let qx = abs(x - (rect.minX + hw)) - hw + cornerRadius
        let qy = abs(y - (rect.minY + hh)) - hh + cornerRadius
        let ox = max(qx, 0), oy = max(qy, 0)
        return (ox * ox + oy * oy).squareRoot() + min(max(qx, qy), 0) - cornerRadius
    }

    /// The outward unit normal of the nearest edge at `p`.
    @inlinable public func normal(_ x: Double, _ y: Double) -> Point {
        let cx = rect.minX + rect.width / 2, cy = rect.minY + rect.height / 2
        let sx: Double = x < cx ? -1 : 1, sy: Double = y < cy ? -1 : 1
        let qx = abs(x - cx) - rect.width / 2 + cornerRadius
        let qy = abs(y - cy) - rect.height / 2 + cornerRadius
        if qx > 0, qy > 0 {
            let l = (qx * qx + qy * qy).squareRoot()
            return Point(x: sx * qx / l, y: sy * qy / l)
        }
        return qx > qy ? Point(x: sx, y: 0) : Point(x: 0, y: sy)
    }
}
