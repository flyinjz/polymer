// Vector paths: moves, lines, quadratic and cubic Béziers.

public struct Path: Hashable, Sendable {
    public enum Element: Hashable, Sendable {
        case move(Point)
        case line(Point)
        case quad(Point, Point)
        case cubic(Point, Point, Point)
        case close
    }

    public var elements: [Element] = []
    public init() {}
    public init(_ elements: [Element]) { self.elements = elements }

    public mutating func move(to p: Point) { elements.append(.move(p)) }
    public mutating func line(to p: Point) { elements.append(.line(p)) }
    public mutating func quad(to p: Point, control c: Point) { elements.append(.quad(c, p)) }
    public mutating func cubic(to p: Point, control1 c1: Point, control2 c2: Point) { elements.append(.cubic(c1, c2, p)) }
    public mutating func close() { elements.append(.close) }

    public init(rect r: Rect) {
        elements = [.move(r.origin), .line(Point(x: r.maxX, y: r.minY)), .line(Point(x: r.maxX, y: r.maxY)),
                    .line(Point(x: r.minX, y: r.maxY)), .close]
    }

    public var isEmpty: Bool { elements.isEmpty }

    /// Bounds of all points, control points included (cheap and conservative).
    public var controlBounds: Rect {
        var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
        func add(_ p: Point) { x0 = min(x0, p.x); y0 = min(y0, p.y); x1 = max(x1, p.x); y1 = max(y1, p.y) }
        for e in elements {
            switch e {
            case .move(let p), .line(let p): add(p)
            case .quad(let c, let p): add(c); add(p)
            case .cubic(let c1, let c2, let p): add(c1); add(c2); add(p)
            case .close: break
            }
        }
        return x0 > x1 ? .zero : Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    public func applying(_ t: AffineTransform) -> Path {
        Path(elements.map { e in
            switch e {
            case .move(let p): .move(t.apply(p))
            case .line(let p): .line(t.apply(p))
            case .quad(let c, let p): .quad(t.apply(c), t.apply(p))
            case .cubic(let c1, let c2, let p): .cubic(t.apply(c1), t.apply(c2), t.apply(p))
            case .close: .close
            }
        })
    }

    /// Closed polygons approximating the path to within `tolerance`.
    public func flattened(tolerance: Double) -> [[Point]] {
        var contours: [[Point]] = []
        var cur: [Point] = []
        var last = Point.zero
        func finish() { if cur.count > 2 { contours.append(cur) }; cur = [] }
        for e in elements {
            switch e {
            case .move(let p):
                finish(); cur = [p]; last = p
            case .line(let p):
                cur.append(p); last = p
            case .quad(let c, let p):
                let dd = (last - c * 2 + p)
                let len = (dd.x * dd.x + dd.y * dd.y).squareRoot()
                let n = max(1, Int((len / (4 * tolerance)).squareRoot().rounded(.up)))
                for k in 1...n {
                    let t = Double(k) / Double(n), u = 1 - t
                    cur.append(Point(x: u * u * last.x + 2 * u * t * c.x + t * t * p.x,
                                     y: u * u * last.y + 2 * u * t * c.y + t * t * p.y))
                }
                last = p
            case .cubic(let c1, let c2, let p):
                let d1 = last - c1 * 2 + c2, d2 = c1 - c2 * 2 + p
                let dd = max((d1.x * d1.x + d1.y * d1.y).squareRoot(), (d2.x * d2.x + d2.y * d2.y).squareRoot())
                let n = max(1, Int((dd * 0.75 / tolerance).squareRoot().rounded(.up)))
                for k in 1...n {
                    let t = Double(k) / Double(n), u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, cc = 3 * u * t * t, d = t * t * t
                    cur.append(Point(x: a * last.x + b * c1.x + cc * c2.x + d * p.x,
                                     y: a * last.y + b * c1.y + cc * c2.y + d * p.y))
                }
                last = p
            case .close:
                finish()
            }
        }
        finish()
        // Drop a closing point equal to the start.
        return contours.map { c in
            var c = c
            if c.count > 1, c.first == c.last { c.removeLast() }
            return c
        }
    }
}
