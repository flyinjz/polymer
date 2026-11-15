// ScrollView. Content keeps the frames it would have unscrolled; the
// offset is applied when drawing and hit-testing, so scrolling never runs
// layout.
import PolymerBase
import PolymerRender

extension Axis {
    /// A set of axes, as in SwiftUI.
    public struct Set: OptionSet, Hashable, Sendable {
        public let rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }
        public static let horizontal = Set(rawValue: 1)
        public static let vertical = Set(rawValue: 2)
    }
}

/// A view whose content can be larger than itself and moved under it.
/// Takes all the space it is offered; content gets its ideal size along the
/// scrolling axes.
public struct ScrollView<Content: View>: View, PrimitiveView {
    let axes: Axis.Set
    let content: Content

    public init(_ axes: Axis.Set = .vertical, @ViewBuilder content: () -> Content) {
        self.axes = axes; self.content = content()
    }

    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? ScrollNode) ?? ScrollNode()
        n.axes = axes
        var c = c
        c.stackAxis = nil
        n.setChild(0, content, c)
        return n
    }
}

final class ScrollNode: Node {
    var axes: Axis.Set = .vertical
    /// How far the content has moved up and left, in points; whole pixels.
    private(set) var offset: Point = .zero
    private(set) var contentSize: Size = .zero
    /// Lazy stacks inside, told when the visible area moves.
    private var lazyStacks: [WeakLazyStack] = []

    /// The area of the content in view, in the content's layout coordinates.
    var viewport: Rect { frame.offsetBy(dx: offset.x, dy: offset.y) }

    func register(_ s: any LazyViewport) {
        if !lazyStacks.contains(where: { $0.node === s }) { lazyStacks.append(WeakLazyStack(node: s)) }
    }

    override var role: String { "ScrollView" }
    override var clipsContent: Bool { true }
    override var detail: String {
        func n(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
        return "content \(n(contentSize.width))x\(n(contentSize.height)) offset \(n(offset.x)),\(n(offset.y))"
    }
    override var isHitTarget: Bool { true }
    override var contentShift: Point { Point(x: -offset.x, y: -offset.y) }

    func contentProposal(_ p: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: axes.contains(.horizontal) ? nil : p.width, height: axes.contains(.vertical) ? nil : p.height)
    }

    override func sizeThatFits(_ p: ProposedViewSize) -> Size {
        if let w = p.width, let h = p.height { return Size(width: w, height: h) }
        return p.replacingUnspecified(children[0].measure(contentProposal(p)))
    }

    override func placeChildren(in r: Rect) {
        contentSize = children[0].measure(contentProposal(ProposedViewSize(r.size)))
        // Content narrower than the view is centred across the scrolling axis.
        let x = axes.contains(.horizontal) ? r.minX : r.minX + (r.width - contentSize.width) / 2
        let y = axes.contains(.vertical) ? r.minY : r.minY + (r.height - contentSize.height) / 2
        // Clamp first: lazy stacks inside read the offset while they are placed.
        offset = clamped(offset)
        children[0].place(Rect(x: x, y: y, width: contentSize.width, height: contentSize.height))
    }

    func clamped(_ o: Point) -> Point {
        func snap(_ v: Double) -> Double { (v * scale).rounded() / scale }
        let maxX = axes.contains(.horizontal) ? max(0, contentSize.width - frame.width) : 0
        let maxY = axes.contains(.vertical) ? max(0, contentSize.height - frame.height) : 0
        return Point(x: snap(min(max(o.x, 0), maxX)), y: snap(min(max(o.y, 0), maxY)))
    }

    /// Moves the content by (dx, dy) points, within its limits. Returns false when it was already at the limit.
    func scroll(dx: Double, dy: Double) -> Bool {
        let next = clamped(Point(x: offset.x + dx, y: offset.y + dy))
        if next == offset { return false }
        offset = next
        lazyStacks.removeAll { $0.node == nil }
        for s in lazyStacks { s.node?.viewportMoved() }
        return true
    }

    override func drawContent(_ list: inout DisplayList) {
        let shift = contentShift
        list.clipped(to: frame) { c in
            c.translated(by: shift) { c in children[0].draw(&c) }
        }
    }

    override func hitTest(_ p: Point) -> Node? {
        guard frame.contains(p) else { return nil }
        return children[0].hitTest(Point(x: p.x + offset.x, y: p.y + offset.y)) ?? self
    }
}
