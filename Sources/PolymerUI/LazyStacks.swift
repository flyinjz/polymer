// LazyVStack and LazyHStack. A ForEach inside builds, lays out and draws
// only the elements in view. An element stays built once it has been in
// view, so its state survives scrolling away and back, as in SwiftUI.
// Elements never built are given the average size of those that were.
import PolymerBase
import PolymerRender

public struct LazyVStack<Content: View>: View, PrimitiveView {
    let alignment: HorizontalAlignment, spacing: Double?, content: Content
    public init(alignment: HorizontalAlignment = .center, spacing: Double? = nil, @ViewBuilder content: () -> Content) {
        self.alignment = alignment; self.spacing = spacing; self.content = content()
    }
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        LazyStackNode.resolve(existing, axis: .vertical, alignment: Alignment(horizontal: alignment, vertical: .center),
                              spacing: spacing, content: content, c)
    }
}

public struct LazyHStack<Content: View>: View, PrimitiveView {
    let alignment: VerticalAlignment, spacing: Double?, content: Content
    public init(alignment: VerticalAlignment = .center, spacing: Double? = nil, @ViewBuilder content: () -> Content) {
        self.alignment = alignment; self.spacing = spacing; self.content = content()
    }
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        LazyStackNode.resolve(existing, axis: .horizontal, alignment: Alignment(horizontal: .center, vertical: alignment),
                              spacing: spacing, content: content, c)
    }
}

/// What a lazy stack arranges: a node that is always built, or the elements of a lazy `ForEach`.
enum LazySegment {
    case node(Node)
    case elements(LazyForEachNode)
}

/// Lazy stacks and grids: told by their scroll view when the visible area moves.
@MainActor protocol LazyViewport: AnyObject {
    func viewportMoved()
}

struct WeakLazyStack { weak var node: (any LazyViewport)? }

/// The part of a lazy container (frame `r`) in view along `axis`, from its
/// edge: the nearest scroll view's visible area, or the whole tree without one.
@MainActor func visibleSpan(_ node: Node & LazyViewport, axis: Axis, _ r: Rect) -> (Double, Double) {
    var view: Rect? = nil
    var top: Node = node
    var n = node.parent
    while let x = n {
        if let s = x as? ScrollNode { s.register(node); view = s.viewport; break }
        top = x
        n = x.parent
    }
    let v = view ?? top.frame
    let (lo, hi, edge, length) = axis == .horizontal ? (v.minX, v.maxX, r.minX, r.width) : (v.minY, v.maxY, r.minY, r.height)
    return (max(lo, edge) - edge, min(hi, edge + length) - edge)
}

/// A `ForEach` inside a lazy stack. Knows every element's id; builds an
/// element only when the stack asks for it. `children` holds the elements
/// in view, in order; every element built so far is kept in `built`.
final class LazyForEachNode: ContainerNode {
    private(set) var ids: [AnyHashable] = []
    /// Builds (or updates) the node of element `i` from the latest view values.
    private var build: ((Int, Node?) -> Node)?
    private var built: [Node?] = []
    /// The `version` each built element was last updated for.
    private var builtVersion: [Int] = []
    /// Bumped each time the `ForEach` is resolved again, so elements in view pick up new view values.
    private var version = 0
    /// Size of each element along the stack's axis, -1 when not measured.
    private(set) var sizes: [Double] = []
    private var knownSum = 0.0, knownCount = 0

    override var lazySegments: [LazySegment] { [.elements(self)] }

    func update<Content: View>(ids newIDs: [AnyHashable], _ c: ResolveContext, _ view: @escaping (Int) -> Content) {
        version += 1
        var rc = c
        rc.lazyItems = false
        let host = c.host
        build = { i, existing in
            let v = host?.track { view(i) } ?? view(i)
            return reconcile(v, existing, rc)
        }
        if newIDs == ids { return }
        var old: [AnyHashable: Int] = [:]
        old.reserveCapacity(ids.count)
        for (i, id) in ids.enumerated() { old[id] = i }
        var nextBuilt = [Node?](repeating: nil, count: newIDs.count)
        var nextVersion = [Int](repeating: 0, count: newIDs.count)
        var nextSizes = [Double](repeating: -1, count: newIDs.count)
        var seen = Set<AnyHashable>()
        seen.reserveCapacity(newIDs.count)
        for (i, id) in newIDs.enumerated() {
            if !seen.insert(id).inserted {
                Logger("PolymerUI").error("ForEach: the id \(id.base) appears more than once. Ids must be unique; give each element its own id (for example `id: \\.self` only when values never repeat).")
                continue
            }
            if let j = old.removeValue(forKey: id) {
                nextBuilt[i] = built[j]; nextVersion[i] = builtVersion[j]; nextSizes[i] = sizes[j]
            }
        }
        for (_, j) in old { built[j]?.unmount() }
        ids = newIDs; built = nextBuilt; builtVersion = nextVersion; sizes = nextSizes
        knownSum = 0; knownCount = 0
        for s in sizes where s >= 0 { knownSum += s; knownCount += 1 }
        children = []
    }

    /// The node of element `i`, built or brought up to date if needed.
    func node(at i: Int) -> Node {
        if let n = built[i], builtVersion[i] == version { return n }
        let old = built[i]
        let n = build!(i, old)
        if n !== old { old?.unmount() }
        n.parent = self
        built[i] = n
        builtVersion[i] = version
        return n
    }

    /// The average size of the elements measured so far; nil before any.
    var estimate: Double? { knownCount > 0 ? knownSum / Double(knownCount) : nil }

    func setSize(_ i: Int, _ s: Double) {
        if sizes[i] >= 0 { knownSum -= sizes[i]; knownCount -= 1 }
        sizes[i] = s
        knownSum += s; knownCount += 1
    }

    /// Forgets every measured size (the width offered to elements changed).
    func forgetSizes() {
        for i in sizes.indices { sizes[i] = -1 }
        knownSum = 0; knownCount = 0
    }

    func setInView(_ nodes: [Node]) { children = nodes }

    override func unmount() {
        markUnmounted()
        for n in built { n?.unmount() }
        built = []; children = []; build = nil
    }
}

/// LazyVStack and LazyHStack. Items are the stack's content flattened as
/// in a stack, with each element of a lazy `ForEach` one item. Items get
/// their ideal size along the axis; across it the stack fills what it is
/// offered (as SwiftUI's lazy stacks do), so off-screen rows never need measuring.
final class LazyStackNode: Node, LazyViewport {
    var axis: Axis = .vertical
    var alignment: Alignment = .center
    var spacing = defaultSpacing
    private weak var tree: TreeState?
    private var segmentCache: [LazySegment]?
    /// Where each item starts along the axis, from the stack's edge, then the total length.
    private var starts: [Double] = []
    private var startsValid = false
    /// The size offered to items across the axis; the measured sizes are for it.
    private var itemCross: Double?
    private var itemCrossSet = false
    private var widestItem = 0.0
    private var reportedLength = 0.0
    /// Items in view at the last placement.
    private(set) var inView: Range<Int> = 0..<0

    static func resolve<Content: View>(_ existing: Node?, axis: Axis, alignment: Alignment, spacing: Double?,
                                       content: Content, _ c: ResolveContext) -> Node {
        let reuse = (existing as? LazyStackNode).flatMap { $0.axis == axis ? $0 : nil }
        let n = reuse ?? LazyStackNode()
        n.axis = axis; n.alignment = alignment; n.spacing = spacing ?? defaultSpacing
        n.tree = c.tree
        var c = c
        c.stackAxis = axis
        n.setChild(0, content, c)
        return n
    }

    override var role: String { axis == .horizontal ? "LazyHStack" : "LazyVStack" }
    override var detail: String { "in view \(inView.lowerBound)..<\(inView.upperBound) of \(max(0, starts.count - 1))" }
    override func childrenAreLazy(_ inherited: Bool) -> Bool { true }

    var segments: [LazySegment] {
        if let s = segmentCache { return s }
        let s = children.first?.lazySegments ?? []
        segmentCache = s
        return s
    }

    override func invalidateLayout() {
        segmentCache = nil
        startsValid = false
        super.invalidateLayout()
    }

    func main(_ s: Size) -> Double { axis == .horizontal ? s.width : s.height }
    func cross(_ s: Size) -> Double { axis == .horizontal ? s.height : s.width }
    var itemProposal: ProposedViewSize {
        axis == .horizontal ? ProposedViewSize(width: nil, height: itemCross) : ProposedViewSize(width: itemCross, height: nil)
    }

    private func offerItems(_ c: Double?) {
        if itemCrossSet, c == itemCross { return }
        itemCross = c; itemCrossSet = true
        for case .elements(let f) in segments { f.forgetSizes() }
        widestItem = 0
        startsValid = false
    }

    /// Measures element `i` of `f` (building it if needed) and records its
    /// size. Returns true when item positions change: the size differs from
    /// the one they were worked out with (its own, or the estimate).
    @discardableResult
    private func measure(_ f: LazyForEachNode, _ i: Int) -> Bool {
        let nodes = f.node(at: i).flattened
        var m = 0.0
        for (k, n) in nodes.enumerated() {
            let s = n.measure(itemProposal)
            m += main(s) + (k > 0 ? spacing : 0)
            widestItem = max(widestItem, cross(s))
        }
        let used = f.sizes[i] >= 0 ? f.sizes[i] : f.estimate
        if f.sizes[i] != m { f.setSize(i, m) }
        return m != used
    }

    private func ensureStarts() {
        if startsValid { return }
        let segs = segments
        // Elements never measured take the average of those that were; measure one if none was.
        for case .elements(let f) in segs where !f.ids.isEmpty && f.estimate == nil { measure(f, 0) }
        starts.removeAll(keepingCapacity: true)
        var pos = 0.0
        for seg in segs {
            switch seg {
            case .node(let n):
                if !starts.isEmpty { pos += spacing }
                starts.append(pos)
                let s = n.measure(itemProposal)
                pos += main(s)
                widestItem = max(widestItem, cross(s))
            case .elements(let f):
                let e = f.estimate ?? 0
                for s in f.sizes {
                    if !starts.isEmpty { pos += spacing }
                    starts.append(pos)
                    pos += s >= 0 ? s : e
                }
            }
        }
        starts.append(pos)
        startsValid = true
    }

    override func sizeThatFits(_ p: ProposedViewSize) -> Size {
        let crossP = axis == .horizontal ? p.height : p.width
        let finite = crossP.flatMap { $0.isFinite ? $0 : nil }
        if !itemCrossSet { offerItems(finite) }
        ensureStarts()
        reportedLength = starts.last ?? 0
        let c = finite ?? widestItem
        return axis == .horizontal ? Size(width: reportedLength, height: c) : Size(width: c, height: reportedLength)
    }

    /// Items that overlap the span [lo, hi).
    private func items(in span: (Double, Double)) -> Range<Int> {
        let n = starts.count - 1
        guard n > 0, span.0 < span.1 else { return 0..<0 }
        // First item whose next start (its end plus spacing) is past lo.
        var a = 0, b = n
        while a < b { let m = (a + b) / 2; if starts[m + 1] > span.0 { b = m } else { a = m + 1 } }
        let first = a
        // First item that starts at or after hi.
        a = first; b = n
        while a < b { let m = (a + b) / 2; if starts[m] >= span.1 { b = m } else { a = m + 1 } }
        return first..<a
    }

    override func placeChildren(in r: Rect) {
        offerItems(cross(r.size))
        ensureStarts()
        let segs = segments
        let span = visibleSpan(self, axis: axis, r)
        // Real sizes replace estimates and move later items; a few rounds settle which items are in view.
        var range = items(in: span)
        for _ in 0..<4 {
            var resized = false
            var k = 0
            for seg in segs {
                switch seg {
                case .node: k += 1
                case .elements(let f):
                    let lo = max(range.lowerBound, k), hi = min(range.upperBound, k + f.ids.count)
                    if lo < hi { for g in lo..<hi where measure(f, g - k) { resized = true } }
                    k += f.ids.count
                }
            }
            if !resized { break }
            startsValid = false
            ensureStarts()
            range = items(in: span)
        }
        inView = range

        let edge = axis == .horizontal ? r.minX : r.minY
        func put(_ n: Node, at pos: Double) -> Double {
            let s = n.measure(itemProposal)
            let slot: Rect = axis == .horizontal
                ? Rect(x: edge + pos, y: r.minY, width: s.width, height: r.height)
                : Rect(x: r.minX, y: edge + pos, width: r.width, height: s.height)
            n.place(Rect(origin: alignment.origin(of: s, in: slot), size: s))
            return main(s)
        }
        var k = 0
        for seg in segs {
            switch seg {
            case .node(let n):
                _ = put(n, at: starts[k])
                k += 1
            case .elements(let f):
                var shown: [Node] = []
                let lo = max(range.lowerBound, k), hi = min(range.upperBound, k + f.ids.count)
                if lo < hi {
                    shown.reserveCapacity(hi - lo)
                    for g in lo..<hi {
                        let e = f.node(at: g - k)
                        shown.append(e)
                        var pos = starts[g]
                        for x in e.flattened { pos += put(x, at: pos) + spacing }
                    }
                }
                f.setInView(shown)
                k += f.ids.count
            }
        }
        // The length given to the parent was based on estimates; let it lay out again with the real one.
        if (starts.last ?? 0) != reportedLength {
            invalidateLayoutUpward()
            tree?.layoutRequested = true
        }
    }

    /// Called by the enclosing scroll view after it moved. Asks for placement
    /// again only when other items come into view.
    func viewportMoved() {
        guard startsValid, items(in: visibleSpan(self, axis: axis, frame)) == inView else {
            setNeedsPlacementUpward()
            tree?.layoutRequested = true
            return
        }
    }

    override func draw(_ list: inout DisplayList) {
        for seg in segments {
            switch seg {
            case .node(let n): if list.isVisible(n.frame) { n.draw(&list) }
            case .elements(let f):
                for e in f.children { for x in e.flattened where list.isVisible(x.frame) { x.draw(&list) } }
            }
        }
    }
}
