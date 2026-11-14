// Geometry in points (Double), y down, origin top-left.

public struct Point: Hashable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    @inlinable public init(x: Double, y: Double) { self.x = x; self.y = y }
    public static let zero = Point(x: 0, y: 0)
    @inlinable public static func + (a: Point, b: Point) -> Point { Point(x: a.x + b.x, y: a.y + b.y) }
    @inlinable public static func - (a: Point, b: Point) -> Point { Point(x: a.x - b.x, y: a.y - b.y) }
    @inlinable public static func * (a: Point, s: Double) -> Point { Point(x: a.x * s, y: a.y * s) }
    public var description: String { "(\(x), \(y))" }
}

public struct Size: Hashable, Sendable, CustomStringConvertible {
    public var width: Double
    public var height: Double
    @inlinable public init(width: Double, height: Double) { self.width = width; self.height = height }
    public static let zero = Size(width: 0, height: 0)
    public var description: String { "\(width)x\(height)" }
}

public struct EdgeInsets: Hashable, Sendable {
    public var top: Double, leading: Double, bottom: Double, trailing: Double
    @inlinable public init(top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0) {
        self.top = top; self.leading = leading; self.bottom = bottom; self.trailing = trailing
    }
    @inlinable public init(all v: Double) { self.init(top: v, leading: v, bottom: v, trailing: v) }
    public static let zero = EdgeInsets()
}

public struct Rect: Hashable, Sendable, CustomStringConvertible {
    public var origin: Point
    public var size: Size
    @inlinable public init(origin: Point, size: Size) { self.origin = origin; self.size = size }
    @inlinable public init(x: Double, y: Double, width: Double, height: Double) {
        origin = Point(x: x, y: y); size = Size(width: width, height: height)
    }
    public static let zero = Rect(x: 0, y: 0, width: 0, height: 0)

    @inlinable public var minX: Double { origin.x }
    @inlinable public var minY: Double { origin.y }
    @inlinable public var maxX: Double { origin.x + size.width }
    @inlinable public var maxY: Double { origin.y + size.height }
    @inlinable public var midX: Double { origin.x + size.width / 2 }
    @inlinable public var midY: Double { origin.y + size.height / 2 }
    @inlinable public var width: Double { size.width }
    @inlinable public var height: Double { size.height }
    @inlinable public var isEmpty: Bool { size.width <= 0 || size.height <= 0 }

    @inlinable public func contains(_ p: Point) -> Bool { p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY }

    @inlinable public func intersection(_ r: Rect) -> Rect {
        let x0 = max(minX, r.minX), y0 = max(minY, r.minY)
        let x1 = min(maxX, r.maxX), y1 = min(maxY, r.maxY)
        if x1 <= x0 || y1 <= y0 { return .zero }
        return Rect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    @inlinable public func union(_ r: Rect) -> Rect {
        if isEmpty { return r }
        if r.isEmpty { return self }
        let x0 = min(minX, r.minX), y0 = min(minY, r.minY)
        return Rect(x: x0, y: y0, width: max(maxX, r.maxX) - x0, height: max(maxY, r.maxY) - y0)
    }

    @inlinable public func inset(by e: EdgeInsets) -> Rect {
        Rect(x: minX + e.leading, y: minY + e.top,
             width: max(0, width - e.leading - e.trailing), height: max(0, height - e.top - e.bottom))
    }

    @inlinable public func offsetBy(dx: Double, dy: Double) -> Rect {
        Rect(x: minX + dx, y: minY + dy, width: width, height: height)
    }

    public var description: String { "(\(minX), \(minY), \(width), \(height))" }
}

/// Integer pixel rectangle.
public struct PixelRect: Hashable, Sendable {
    public var x: Int, y: Int, width: Int, height: Int
    @inlinable public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    @inlinable public var isEmpty: Bool { width <= 0 || height <= 0 }
}

/// 2D affine transform: x' = a x + c y + tx, y' = b x + d y + ty.
public struct AffineTransform: Hashable, Sendable {
    public var a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double
    @inlinable public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }
    public static let identity = AffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)
    @inlinable public static func translation(x: Double, y: Double) -> AffineTransform {
        AffineTransform(a: 1, b: 0, c: 0, d: 1, tx: x, ty: y)
    }
    @inlinable public static func scale(x: Double, y: Double) -> AffineTransform {
        AffineTransform(a: x, b: 0, c: 0, d: y, tx: 0, ty: 0)
    }
    /// `self` applied first, then `t`.
    @inlinable public func concatenating(_ t: AffineTransform) -> AffineTransform {
        AffineTransform(a: a * t.a + b * t.c, b: a * t.b + b * t.d,
                        c: c * t.a + d * t.c, d: c * t.b + d * t.d,
                        tx: tx * t.a + ty * t.c + t.tx, ty: tx * t.b + ty * t.d + t.ty)
    }
    @inlinable public func apply(_ p: Point) -> Point {
        Point(x: a * p.x + c * p.y + tx, y: b * p.x + d * p.y + ty)
    }
}
