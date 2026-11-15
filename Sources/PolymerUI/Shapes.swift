// Shapes, as in SwiftUI: Rectangle, RoundedRectangle, Capsule and Circle,
// filled with the foreground colour or with `.fill`, outlined with
// `.stroke` or `.strokeBorder`, and custom shapes through `path(in:)`.
// The built-in ones are rounded rectangles (PolymerBase `RoundedRect`), so
// effects get their exact distance field.
import PolymerBase
import PolymerRender

/// A 2D shape. A shape is a view that fills the space offered (10 points
/// when offered none) with the foreground colour.
public protocol Shape: View {
    func path(in rect: Rect) -> Path
}

/// A shape that can be moved inwards, so it can be outlined inside its edge.
public protocol InsettableShape: Shape {
    func inset(by amount: Double) -> Self
}

/// The built-in shapes: rounded rectangles whose corner radius depends on the rectangle.
public protocol RoundedRectShape: InsettableShape {
    /// The shape's geometry in `rect`.
    func roundedRect(in rect: Rect) -> RoundedRect
}

extension RoundedRectShape {
    public func path(in rect: Rect) -> Path { roundedRect(in: rect).path() }
}

extension Shape {
    public var body: ShapeView<Self> { ShapeView(shape: self, style: .fill(nil)) }
    /// Fills the shape with `color`.
    public func fill(_ color: Color) -> ShapeView<Self> { ShapeView(shape: self, style: .fill(color)) }
}

extension InsettableShape {
    /// A line of `lineWidth` points along the edge, inside the shape.
    public func strokeBorder(_ color: Color, lineWidth: Double = 1) -> ShapeView<Self> {
        ShapeView(shape: self, style: .stroke(color, lineWidth, centered: false))
    }
    /// A line of `lineWidth` points centred on the edge.
    public func stroke(_ color: Color, lineWidth: Double = 1) -> ShapeView<Self> {
        ShapeView(shape: self, style: .stroke(color, lineWidth, centered: true))
    }
}

/// A rectangle.
public struct Rectangle: RoundedRectShape {
    var insetAmount = 0.0
    public init() {}
    public func roundedRect(in rect: Rect) -> RoundedRect { RoundedRect(rect, cornerRadius: 0).inset(by: insetAmount) }
    public func inset(by amount: Double) -> Rectangle { var s = self; s.insetAmount += amount; return s }
}

/// A rectangle with circular corners of `cornerRadius` points.
public struct RoundedRectangle: RoundedRectShape {
    public var cornerRadius: Double
    var insetAmount = 0.0
    public init(cornerRadius: Double) { self.cornerRadius = cornerRadius }
    public func roundedRect(in rect: Rect) -> RoundedRect { RoundedRect(rect, cornerRadius: cornerRadius).inset(by: insetAmount) }
    public func inset(by amount: Double) -> RoundedRectangle { var s = self; s.insetAmount += amount; return s }
}

/// A rectangle whose shorter sides are half circles.
public struct Capsule: RoundedRectShape {
    var insetAmount = 0.0
    public init() {}
    public func roundedRect(in rect: Rect) -> RoundedRect {
        RoundedRect(rect, cornerRadius: min(rect.width, rect.height) / 2).inset(by: insetAmount)
    }
    public func inset(by amount: Double) -> Capsule { var s = self; s.insetAmount += amount; return s }
}

/// The largest circle that fits, centred.
public struct Circle: RoundedRectShape {
    var insetAmount = 0.0
    public init() {}
    public func roundedRect(in rect: Rect) -> RoundedRect {
        let d = min(rect.width, rect.height)
        let square = Rect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)
        return RoundedRect(square, cornerRadius: d / 2).inset(by: insetAmount)
    }
    public func inset(by amount: Double) -> Circle { var s = self; s.insetAmount += amount; return s }
}

/// How a shape is drawn (internal; SwiftUI's `ShapeStyle` is a different thing).
enum ShapeDrawing: Sendable {
    /// Filled with a colour; nil for the environment's foreground colour.
    case fill(Color?)
    case stroke(Color, Double, centered: Bool)
}

/// A shape drawn with a style; what `.fill`, `.stroke` and `.strokeBorder` return.
public struct ShapeView<S: Shape>: View, PrimitiveView {
    let shape: S
    let style: ShapeDrawing
    public var body: Never { fatalError("ShapeView is a built-in view") }

    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? ShapeNode) ?? ShapeNode()
        let full = String(describing: S.self)
        n.name = String(full.prefix { $0 != "<" })
        let shape = self.shape
        if let r = shape as? any RoundedRectShape {
            n.geometry = .rounded { rect in r.roundedRect(in: rect) }
        } else {
            n.geometry = .path { rect in shape.path(in: rect) }
        }
        switch style {
        case .fill(let color): n.style = .fill(color ?? c.environment.foregroundColor)
        case .stroke(let color, let width, let centered): n.style = .stroke(color, width, centered: centered)
        }
        return n
    }
}

// The built-in shapes draw directly, without a view with a body in between.
extension Rectangle: PrimitiveView {
    public var body: Never { fatalError("Rectangle is a built-in view") }
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node { ShapeView(shape: self, style: .fill(nil)).resolve(existing, c) }
}
extension RoundedRectangle: PrimitiveView {
    public var body: Never { fatalError("RoundedRectangle is a built-in view") }
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node { ShapeView(shape: self, style: .fill(nil)).resolve(existing, c) }
}
extension Capsule: PrimitiveView {
    public var body: Never { fatalError("Capsule is a built-in view") }
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node { ShapeView(shape: self, style: .fill(nil)).resolve(existing, c) }
}
extension Circle: PrimitiveView {
    public var body: Never { fatalError("Circle is a built-in view") }
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node { ShapeView(shape: self, style: .fill(nil)).resolve(existing, c) }
}

final class ShapeNode: Node {
    enum Geometry {
        case rounded((Rect) -> RoundedRect)
        case path((Rect) -> Path)
    }
    enum Style { case fill(Color); case stroke(Color, Double, centered: Bool) }
    var name = "Shape"
    var geometry: Geometry = .path { _ in Path() }
    var style: Style = .fill(.clear)
    private var warned = false

    override var role: String { name }
    override var detail: String {
        switch style {
        case .fill(let c): c.description
        case .stroke(let c, let w, let centered): "\(centered ? "stroke" : "border") \(w == w.rounded() ? String(Int(w)) : String(w)) \(c.description)"
        }
    }
    override var isHitTarget: Bool {
        switch style { case .fill(let c), .stroke(let c, _, _): c.opacity > 0 }
    }
    override func sizeThatFits(_ p: ProposedViewSize) -> Size {
        // SwiftUI shapes take 10 points when given no size.
        p.replacingUnspecified(Size(width: 10, height: 10))
    }

    /// The shape's geometry in its frame, when it is a rounded rectangle.
    var roundedRect: RoundedRect? {
        if case .rounded(let g) = geometry { return g(frame) }
        return nil
    }

    override func draw(_ list: inout DisplayList) {
        guard list.isVisible(frame) else { return }
        switch (geometry, style) {
        case (.rounded(let g), .fill(let color)):
            let r = g(frame)
            // A plain rectangle fills exactly as a colour does.
            if r.cornerRadius == 0 { list.fill(r.rect, color) } else { list.fill(r.path(), color) }
        case (.rounded(let g), .stroke(let color, let w, let centered)):
            let outer = g(frame).inset(by: centered ? -w / 2 : 0)
            var ring = outer.path()
            ring.elements += outer.inset(by: w).path(reversed: true).elements
            list.fill(ring, color)
        case (.path(let g), .fill(let color)):
            list.fill(g(frame), color)
        case (.path, .stroke):
            // Only shapes made of rounded rectangles can be outlined so far; logged once per node.
            if !warned {
                warned = true
                Logger("PolymerUI").warning("(name): stroke and strokeBorder work only on Rectangle, RoundedRectangle, Capsule and Circle so far; fill a custom shape instead, or build it from those.")
            }
        }
    }
}
