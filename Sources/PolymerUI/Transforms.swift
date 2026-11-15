// Drawing transforms that leave layout alone: `.scaleEffect`. The view
// keeps its frame for layout and the element tree; what it draws (and
// where clicks land on it) is scaled about an anchor.
import PolymerBase
import PolymerRender

/// A point in a rectangle, in fractions of its size: (0, 0) top-leading, (1, 1) bottom-trailing.
public struct UnitPoint: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public static let zero = UnitPoint(x: 0, y: 0)
    public static let center = UnitPoint(x: 0.5, y: 0.5)
    public static let leading = UnitPoint(x: 0, y: 0.5)
    public static let trailing = UnitPoint(x: 1, y: 0.5)
    public static let top = UnitPoint(x: 0.5, y: 0)
    public static let bottom = UnitPoint(x: 0.5, y: 1)
    public static let topLeading = UnitPoint(x: 0, y: 0)
    public static let topTrailing = UnitPoint(x: 1, y: 0)
    public static let bottomLeading = UnitPoint(x: 0, y: 1)
    public static let bottomTrailing = UnitPoint(x: 1, y: 1)

    /// The point in `r`.
    func point(in r: Rect) -> Point { Point(x: r.minX + x * r.width, y: r.minY + y * r.height) }
}

extension View {
    /// Draws the view scaled by `scale` about `anchor`, without changing its layout.
    /// Text is drawn from its outlines at the new size, so it stays sharp.
    public func scaleEffect(_ scale: Double, anchor: UnitPoint = .center) -> some View {
        ScaleEffectView(content: self, scale: max(0, scale), anchor: anchor)
    }
}

struct ScaleEffectView<Content: View>: View, PrimitiveView {
    let content: Content
    let scale: Double
    let anchor: UnitPoint
    var body: Never { fatalError("ScaleEffectView is a built-in view") }

    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? ScaleEffectNode) ?? ScaleEffectNode()
        n.factor = scale
        n.anchor = anchor
        n.setChild(0, content, c)
        return n
    }
}

final class ScaleEffectNode: Node {
    private var animatedScale = Animated(1.0)
    /// The scale set by the view (the target while it animates).
    var factor: Double {
        get { animatedScale.target }
        set { change(&animatedScale, to: newValue) }
    }
    var anchor = UnitPoint.center
    override func isAnimating(at now: Double) -> Bool { super.isAnimating(at: now) || animatedScale.isRunning(at: now) }

    override var isElement: Bool { false }
    override func sizeThatFits(_ p: ProposedViewSize) -> Size { children[0].measure(p) }
    override func placeChildren(in r: Rect) { children[0].place(r) }

    private var shownScale: Double { max(0, animatedScale.value(at: tree?.now ?? 0)) }

    override func drawContent(_ list: inout DisplayList) {
        let s = shownScale
        if s == 1 { children[0].draw(&list); return }
        list.scaled(by: s, about: anchor.point(in: frame)) { children[0].draw(&$0) }
    }

    override func hitTest(_ p: Point) -> Node? {
        let s = shownScale
        guard s > 0 else { return nil }
        let a = anchor.point(in: frame)
        return children[0].hitTest(Point(x: a.x + (p.x - a.x) / s, y: a.y + (p.y - a.y) / s))
    }
}
