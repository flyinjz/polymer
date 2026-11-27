// ScrollView. Content keeps the frames it would have unscrolled; the
// offset is applied when drawing and hit-testing, so scrolling never runs
// layout. `ScrollViewReader` hands its content a `ScrollViewProxy` that can
// scroll to a view by its `.id(...)` (`scrollTo`).
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
        // A reader around this view targets the scroll view below it. Resolved
        // last, so a view inside an outer scroll view wins over the outer one.
        c.environment.scrollViewProxy?.node = n
        return n
    }
}

/// Where a scroll view is: the offset, the content's size and the visible
/// part. Observable, so a scroll bar reading it redraws as the content moves.
@MainActor
@Observable
public final class ScrollMetrics {
    public fileprivate(set) var offset = Point.zero
    public fileprivate(set) var contentSize = Size.zero
    public fileprivate(set) var viewportSize = Size.zero
    public fileprivate(set) var axes: Axis.Set = .vertical
    public init() {}
}

/// Scrolls the `ScrollView` inside its `ScrollViewReader`:
/// `proxy.scrollTo("track-12")`, or `scrollTo(_, anchor: .top)`. Also reports
/// what a scroll bar needs: `visibleFraction` and `position`.
@MainActor
public final class ScrollViewProxy {
    /// The scroll view this reader controls; nil until one is resolved.
    weak var node: ScrollNode?
    /// What an unattached proxy reads: nothing scrolled.
    private let unattached = ScrollMetrics()

    public init() {}

    /// The scroll view's live state (offset, content and viewport size).
    public var metrics: ScrollMetrics { node?.metrics ?? unattached }

    /// True once a scroll view inside the reader has been resolved.
    public var isAttached: Bool { node != nil }

    /// How much of the content fits along `axis`, from 0 to 1 (1 when it all does).
    public func visibleFraction(_ axis: Axis = .vertical) -> Double {
        let m = metrics
        let content = axis == .vertical ? m.contentSize.height : m.contentSize.width
        let viewport = axis == .vertical ? m.viewportSize.height : m.viewportSize.width
        guard content > 0, viewport > 0 else { return 1 }
        return min(1, viewport / content)
    }

    /// Where the visible part sits along `axis`, from 0 at the start to 1 at
    /// the end (0 when there is nothing to scroll).
    public func position(_ axis: Axis = .vertical) -> Double {
        let m = metrics
        let content = axis == .vertical ? m.contentSize.height : m.contentSize.width
        let viewport = axis == .vertical ? m.viewportSize.height : m.viewportSize.width
        let limit = max(0, content - viewport)
        guard limit > 0 else { return 0 }
        let offset = axis == .vertical ? m.offset.y : m.offset.x
        return min(1, max(0, offset / limit))
    }

    /// Scrolls the view with `id` into view. `anchor` says where it should sit
    /// in the viewport; nil scrolls the least distance that shows all of it.
    /// Returns false when there is no such view or it is already visible.
    @discardableResult
    public func scrollTo(_ id: AnyHashable, anchor: UnitPoint? = nil) -> Bool {
        node?.scrollTo(id, anchor: anchor) ?? false
    }

    /// Moves the content by (dx, dy) points, within its limits.
    @discardableResult
    public func scroll(dx: Double = 0, dy: Double = 0) -> Bool {
        node?.scroll(dx: dx, dy: dy) ?? false
    }
}

/// Gives its content a proxy for scrolling the `ScrollView` inside it.
///
///     ScrollViewReader { proxy in
///         ScrollView { rows.id(row.title) }
///         PScrollBar(proxy)
///     }
public struct ScrollViewReader<Content: View>: View, PrimitiveView {
    let content: (ScrollViewProxy) -> Content

    public init(@ViewBuilder content: @escaping (ScrollViewProxy) -> Content) {
        self.content = content
    }

    public var body: Never { fatalError("ScrollViewReader is a built-in view") }

    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? ScrollReaderNode) ?? ScrollReaderNode()
        var c = c
        c.environment.scrollViewProxy = n.proxy
        n.setChild(0, content(n.proxy), c)
        return n
    }
}

/// Keeps one proxy for as long as the reader is in the tree.
final class ScrollReaderNode: PassthroughNode {
    let proxy = ScrollViewProxy()
}

final class ScrollNode: Node {
    var axes: Axis.Set = .vertical
    /// How far the content has moved up and left, in points; whole pixels.
    private(set) var offset: Point = .zero
    private(set) var contentSize: Size = .zero
    /// What the proxy (and a scroll bar reading it) sees.
    let metrics = ScrollMetrics()
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
        publish()
    }

    /// Tells readers (and a scroll bar bound to the proxy) where things are.
    private func publish() {
        let offset = self.offset, content = contentSize, viewport = frame.size
        if metrics.axes != axes { metrics.axes = axes }
        if metrics.offset != offset { metrics.offset = offset }
        if metrics.contentSize != content { metrics.contentSize = content }
        if metrics.viewportSize != viewport { metrics.viewportSize = viewport }
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
        publish()
        return true
    }

    /// Scrolls the view with `id` into view; false when it is not there or
    /// already visible. `anchor` nil scrolls the least distance that shows it.
    func scrollTo(_ id: AnyHashable, anchor: UnitPoint?) -> Bool {
        guard let content = children.first, let target = node(with: id, in: content) else { return false }
        let f = laidOutFrame(of: target)
        guard f.width > 0 || f.height > 0 else { return false }
        var p = offset
        if axes.contains(.vertical) {
            let top = f.minY - frame.minY
            if let a = anchor {
                p.y = top - a.y * frame.height
            } else if top < offset.y {
                p.y = top
            } else if top + f.height > offset.y + frame.height {
                p.y = top + f.height - frame.height
            }
        }
        if axes.contains(.horizontal) {
            let left = f.minX - frame.minX
            if let a = anchor {
                p.x = left - a.x * frame.width
            } else if left < offset.x {
                p.x = left
            } else if left + f.width > offset.x + frame.width {
                p.x = left + f.width - frame.width
            }
        }
        return scroll(dx: p.x - offset.x, dy: p.y - offset.y)
    }

    /// The laid-out frame of `n`, descending through wrapper/passthrough nodes
    /// (like `IDNode`) whose own `frame` stays `.zero`.
    private func laidOutFrame(of n: Node) -> Rect {
        if n.frame.width > 0 || n.frame.height > 0 { return n.frame }
        for c in n.children {
            let f = laidOutFrame(of: c)
            if f.width > 0 || f.height > 0 { return f }
        }
        return .zero
    }

    /// The laid-out node with `id`: an `.id(...)` view, or an element of a
    /// `ForEach` whose id it is.
    private func node(with id: AnyHashable, in n: Node) -> Node? {
        if let identified = n as? IDNode, identified.id == id { return n }
        if let each = n as? ForEachNode, let i = each.ids.firstIndex(of: id), i < each.children.count {
            return each.children[i]
        }
        for c in n.children {
            if let found = node(with: id, in: c) { return found }
        }
        return nil
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

struct ScrollViewProxyKey: EnvironmentKey { static var defaultValue: ScrollViewProxy? { nil } }
extension EnvironmentValues {
    /// The proxy of the nearest `ScrollViewReader` above this view.
    public var scrollViewProxy: ScrollViewProxy? {
        get { self[ScrollViewProxyKey.self] }
        set { self[ScrollViewProxyKey.self] = newValue }
    }
}
