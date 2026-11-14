// The retained tree: nodes that measure, place and draw themselves, and
// stay in place between updates. Layout follows SwiftUI: a parent proposes
// a size, the child chooses its own, the parent places it.
import PolymerBase
import PolymerRender

/// A size proposal; nil in a dimension means "your ideal size".
public struct ProposedViewSize: Hashable, Sendable {
    public var width: Double?
    public var height: Double?
    public init(width: Double?, height: Double?) { self.width = width; self.height = height }
    public init(_ s: Size) { width = s.width; height = s.height }
    public static let unspecified = ProposedViewSize(width: nil, height: nil)
    public static let zero = ProposedViewSize(width: 0, height: 0)
    public static let infinity = ProposedViewSize(width: .infinity, height: .infinity)

    func replacingUnspecified(_ d: Size) -> Size { Size(width: width ?? d.width, height: height ?? d.height) }
}

@MainActor
class Node {
    /// Role shown in the element tree ("Text", "VStack", ...).
    var role: String { "View" }
    final var children: [Node] = []
    final weak var parent: Node?
    final private(set) var frame: Rect = .zero
    /// Pixels per point, for snapping frames to the pixel grid.
    final var scale: Double = 1

    /// Sizes already chosen for recent proposals; emptied when the node or anything below it changes.
    private var sizeCache: [(ProposedViewSize, Size)] = []
    private var needsPlacement = true

    init() {}

    // MARK: Layout

    /// The size this node chooses for a proposal. Callers use `measure`, which remembers answers.
    func sizeThatFits(_ proposal: ProposedViewSize) -> Size { .zero }

    final func measure(_ proposal: ProposedViewSize) -> Size {
        for e in sizeCache where e.0 == proposal { return e.1 }
        let s = sizeThatFits(proposal)
        if sizeCache.count >= 6 { sizeCache.removeFirst() }
        sizeCache.append((proposal, s))
        return s
    }

    /// Sets the frame (snapped to whole pixels) and places children. Does
    /// nothing when the frame is the same and nothing below has changed.
    final func place(_ rect: Rect) {
        let s = scale
        func snap(_ v: Double) -> Double { (v * s).rounded() / s }
        let x0 = snap(rect.minX), y0 = snap(rect.minY)
        let f = Rect(x: x0, y: y0, width: snap(rect.maxX) - x0, height: snap(rect.maxY) - y0)
        if f == frame, !needsPlacement { return }
        frame = f
        needsPlacement = false
        placeChildren(in: f)
    }

    func placeChildren(in rect: Rect) {}

    /// Forgets remembered sizes; called when this node or its content changed.
    func invalidateLayout() {
        sizeCache.removeAll(keepingCapacity: true)
        needsPlacement = true
    }

    /// Invalidates this node and every ancestor (their sizes may depend on it).
    final func invalidateLayoutUpward() {
        var n: Node? = self
        while let x = n { x.invalidateLayout(); n = x.parent }
    }

    /// Asks for this node and its ancestors to be placed again at the next
    /// layout, keeping every remembered size (a lazy stack whose visible rows changed).
    final func setNeedsPlacementUpward() {
        var n: Node? = self
        while let x = n { x.needsPlacement = true; n = x.parent }
    }

    /// Children as seen by stacks: groups and views with a body are replaced by what they contain.
    var flattened: [Node] { [self] }

    /// Children as seen by lazy stacks: like `flattened`, but a lazy `ForEach`
    /// stays one segment so its elements are not built.
    var lazySegments: [LazySegment] { [.node(self)] }

    /// Whether `ForEach` views among this node's children build lazily.
    /// Only nodes a stack sees through (groups, views with a body) pass the
    /// flag on; lazy stacks set it; everything else clears it.
    func childrenAreLazy(_ inherited: Bool) -> Bool { false }

    // MARK: Children

    /// Reconciles `view` into the child slot `index` (appending when it is the next free slot).
    final func setChild<V: View>(_ index: Int, _ view: V, _ c: ResolveContext) {
        var c = c
        c.lazyItems = childrenAreLazy(c.lazyItems)
        let old = index < children.count ? children[index] : nil
        let new = reconcile(view, old, c)
        if new !== old {
            old?.unmount()
            if index < children.count { children[index] = new } else { children.append(new) }
        }
        new.parent = self
    }

    final func removeChildren(from index: Int) {
        guard index < children.count else { return }
        for c in children[index...] { c.unmount() }
        children.removeSubrange(index...)
    }

    /// Called once when the node leaves the tree for good.
    func unmount() {
        isMounted = false
        for c in children { c.unmount() }
    }

    /// False once the node has left the tree for good.
    final private(set) var isMounted = true
    final func markUnmounted() { isMounted = false }

    // MARK: Drawing

    func draw(_ canvas: inout Canvas) {
        for c in children { c.draw(&canvas) }
    }

    // MARK: Element tree

    /// False for nodes that only arrange others (padding, frames, groups); they are left out of the element tree.
    var isElement: Bool { true }
    /// Text shown after the role in the element tree.
    var detail: String { "" }
    /// The node's own area in layout coordinates.
    var elementFrame: Rect { frame }

    /// How far this node draws its content from where the content's frames say (a scroll view's offset).
    var contentShift: Point { .zero }

    /// Where the node is on screen: its area moved by every enclosing scroll offset.
    final var screenFrame: Rect {
        var shift = Point.zero
        var n = parent
        while let x = n { shift = shift + x.contentShift; n = x.parent }
        return elementFrame.offsetBy(dx: shift.x, dy: shift.y)
    }

    /// Writes the element tree. The focused node, or the first element
    /// inside it when it is not an element itself, is marked "focused".
    func dump(into out: inout String, depth: Int, focused: Node? = nil, markFocus: Bool = false) {
        var depth = depth
        var mark = markFocus || (focused != nil && focused === self)
        if isElement {
            let f = screenFrame
            func n(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
            out += String(repeating: "  ", count: depth)
            out += "\(role) (\(n(f.minX)), \(n(f.minY)), \(n(f.width))x\(n(f.height)))"
            let d = detail
            if !d.isEmpty { out += " \(d)" }
            if mark { out += " focused"; mark = false }
            out += "\n"
            depth += 1
        }
        for c in children { c.dump(into: &out, depth: depth, focused: focused, markFocus: mark); mark = false }
    }

    // MARK: Input

    /// True for nodes that can hold keyboard focus (buttons, `.focusable()`).
    var acceptsFocus: Bool { false }
    /// True when a click on the node focuses it (macOS: `.focusable()` views yes, buttons no).
    var focusesOnClick: Bool { false }
    /// Handles a key press that reached this node; `.ignored` passes it to the parent.
    func handle(_ press: KeyPress) -> KeyPress.Result { .ignored }

    /// True for nodes that draw something a pointer can land on.
    var isHitTarget: Bool { false }
    /// Run when the node, or anything inside it, is clicked.
    var tapAction: (@MainActor () -> Void)? { nil }

    /// The front-most node under `p` (points).
    func hitTest(_ p: Point) -> Node? {
        for c in children.reversed() { if let h = c.hitTest(p) { return h } }
        return isHitTarget && frame.contains(p) ? self : nil
    }

    /// Depth-first search, in drawing order.
    final func first(where match: (Node) -> Bool) -> Node? {
        if match(self) { return self }
        for c in children { if let m = c.first(where: match) { return m } }
        return nil
    }
}

/// A node with several children and no layout of its own. Stacks place its
/// children as theirs; anywhere else it overlays them like a ZStack.
class ContainerNode: Node {
    override var isElement: Bool { false }
    override var flattened: [Node] { children.flatMap { $0.flattened } }
    override var lazySegments: [LazySegment] { children.flatMap { $0.lazySegments } }
    override func childrenAreLazy(_ inherited: Bool) -> Bool { inherited }

    override func sizeThatFits(_ p: ProposedViewSize) -> Size {
        var w = 0.0, h = 0.0
        for c in flattened { let s = c.measure(p); w = max(w, s.width); h = max(h, s.height) }
        return Size(width: w, height: h)
    }
    override func placeChildren(in r: Rect) {
        for c in flattened {
            let s = c.measure(ProposedViewSize(r.size))
            c.place(Rect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height))
        }
    }
}

/// Children of a TupleView, an optional view or an empty view.
final class GroupNode: ContainerNode {}

/// A node with one child that sizes and places it as itself: views with a
/// body, `if`/`else`, `.id`, tap handlers. Inside a stack it is replaced by
/// what it contains, so it may never be placed itself.
class PassthroughNode: Node {
    override var isElement: Bool { false }
    override var flattened: [Node] { children.first?.flattened ?? [] }
    override var lazySegments: [LazySegment] { children.first?.lazySegments ?? [] }
    override func childrenAreLazy(_ inherited: Bool) -> Bool { inherited }
    override func sizeThatFits(_ p: ProposedViewSize) -> Size { children.first?.measure(p) ?? .zero }
    override func placeChildren(in r: Rect) { children.first?.place(r) }

    /// The area covered by what the node contains.
    var contentFrame: Rect { flattened.reduce(Rect.zero) { $0.union($1.frame) } }
    override var elementFrame: Rect { contentFrame }
}
