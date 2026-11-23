// HStack, VStack and ZStack with SwiftUI's space distribution: children are
// offered space in order of flexibility, least flexible first.
import PolymerBase
import PolymerRender

public enum HorizontalAlignment: Sendable { case leading, center, trailing }
public enum VerticalAlignment: Sendable { case top, center, bottom }

public struct Alignment: Hashable, Sendable {
    public var horizontal: HorizontalAlignment
    public var vertical: VerticalAlignment
    public init(horizontal: HorizontalAlignment, vertical: VerticalAlignment) { self.horizontal = horizontal; self.vertical = vertical }
    public static let center = Alignment(horizontal: .center, vertical: .center)
    public static let leading = Alignment(horizontal: .leading, vertical: .center)
    public static let trailing = Alignment(horizontal: .trailing, vertical: .center)
    public static let top = Alignment(horizontal: .center, vertical: .top)
    public static let bottom = Alignment(horizontal: .center, vertical: .bottom)
    public static let topLeading = Alignment(horizontal: .leading, vertical: .top)
    public static let topTrailing = Alignment(horizontal: .trailing, vertical: .top)
    public static let bottomLeading = Alignment(horizontal: .leading, vertical: .bottom)
    public static let bottomTrailing = Alignment(horizontal: .trailing, vertical: .bottom)

    /// Origin of a box of size `s` aligned inside `r`.
    func origin(of s: Size, in r: Rect) -> Point {
        let x: Double = switch horizontal {
        case .leading: r.minX
        case .center: r.minX + (r.width - s.width) / 2
        case .trailing: r.maxX - s.width
        }
        let y: Double = switch vertical {
        case .top: r.minY
        case .center: r.minY + (r.height - s.height) / 2
        case .bottom: r.maxY - s.height
        }
        return Point(x: x, y: y)
    }
}

/// Default spacing between stack children, in points.
let defaultSpacing = 8.0

public struct HStack<Content: View>: View, PrimitiveView {
    let alignment: VerticalAlignment, spacing: Double?, content: Content
    public init(alignment: VerticalAlignment = .center, spacing: Double? = nil, @ViewBuilder content: () -> Content) {
        self.alignment = alignment; self.spacing = spacing; self.content = content()
    }
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        StackNode.resolve(existing, axis: .horizontal, alignment: Alignment(horizontal: .center, vertical: alignment),
                          spacing: spacing, content: content, c)
    }
}

public struct VStack<Content: View>: View, PrimitiveView {
    let alignment: HorizontalAlignment, spacing: Double?, content: Content
    public init(alignment: HorizontalAlignment = .center, spacing: Double? = nil, @ViewBuilder content: () -> Content) {
        self.alignment = alignment; self.spacing = spacing; self.content = content()
    }
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        StackNode.resolve(existing, axis: .vertical, alignment: Alignment(horizontal: alignment, vertical: .center),
                          spacing: spacing, content: content, c)
    }
}

public struct ZStack<Content: View>: View, PrimitiveView {
    let alignment: Alignment, content: Content
    public init(alignment: Alignment = .center, @ViewBuilder content: () -> Content) {
        self.alignment = alignment; self.content = content()
    }
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? ZStackNode) ?? ZStackNode()
        n.alignment = alignment
        var c = c
        c.stackAxis = nil
        n.setChild(0, content, c)
        return n
    }
}

/// HStack and VStack. Its one child is the content; layout works on the
/// content's flattened list, so groups, `ForEach` and views with a body
/// contribute their children directly.
final class StackNode: Node {
    var axis: Axis = .vertical
    var alignment: Alignment = .center
    var spacing = defaultSpacing
    private var flatCache: [Node]?

    static func resolve<Content: View>(_ existing: Node?, axis: Axis, alignment: Alignment, spacing: Double?,
                                       content: Content, _ c: ResolveContext) -> Node {
        // An HStack is never reused as a VStack: they are different views.
        let reuse = (existing as? StackNode).flatMap { $0.axis == axis ? $0 : nil }
        let n = reuse ?? StackNode()
        n.axis = axis; n.alignment = alignment; n.spacing = spacing ?? defaultSpacing
        var c = c
        c.stackAxis = axis
        n.setChild(0, content, c)
        return n
    }

    override var role: String { axis == .horizontal ? "HStack" : "VStack" }

    /// The views the stack arranges.
    var flat: [Node] {
        if let f = flatCache { return f }
        let f = children.first?.flattened ?? []
        flatCache = f
        return f
    }

    override func invalidateLayout() {
        flatCache = nil
        super.invalidateLayout()
    }

    func main(_ s: Size) -> Double { axis == .horizontal ? s.width : s.height }
    func cross(_ s: Size) -> Double { axis == .horizontal ? s.height : s.width }
    func proposal(main m: Double?, cross c: Double?) -> ProposedViewSize {
        axis == .horizontal ? ProposedViewSize(width: m, height: c) : ProposedViewSize(width: c, height: m)
    }

    /// The size of each child given the proposal.
    func distribute(_ p: ProposedViewSize) -> [Size] {
        let items = flat
        let n = items.count
        guard n > 0 else { return [] }
        let crossP = axis == .horizontal ? p.height : p.width
        let mainP = axis == .horizontal ? p.width : p.height
        let gaps = spacing * Double(n - 1)
        guard let total = mainP else {
            return items.map { $0.measure(proposal(main: nil, cross: crossP)) }
        }
        // Flexibility: how much a child can grow between its smallest and largest size.
        let loSizes = items.map { main($0.measure(proposal(main: 0, cross: crossP))) }
        let flex = items.enumerated().map { idx, c -> Double in
            let hi = main(c.measure(proposal(main: .infinity, cross: crossP)))
            return hi - loSizes[idx]
        }
        var remaining = max(0, total - gaps)
        var sizes = [Size](repeating: .zero, count: n)

        let hasPriorities = items.contains { $0.layoutPriority != 0 }
        if !hasPriorities {
            let order = (0..<n).sorted { flex[$0] < flex[$1] || (flex[$0] == flex[$1] && $0 < $1) }
            for (k, i) in order.enumerated() {
                let share = remaining / Double(n - k)
                let s = items[i].measure(proposal(main: share, cross: crossP))
                sizes[i] = s
                remaining = max(0, remaining - main(s))
            }
            return sizes
        }

        // Higher-priority groups are allocated first; lower-priority items reserve their minimum size.
        var priorities: [Double] = []
        for item in items {
            let prio = item.layoutPriority
            if !priorities.contains(prio) { priorities.append(prio) }
        }
        priorities.sort(by: >)

        for prio in priorities {
            let group = (0..<n).filter { items[$0].layoutPriority == prio }
            let lowerMinSum = (0..<n)
                .filter { items[$0].layoutPriority < prio }
                .reduce(0.0) { $0 + loSizes[$1] }
            var budget = max(0, remaining - lowerMinSum)
            let order = group.sorted { flex[$0] < flex[$1] || (flex[$0] == flex[$1] && $0 < $1) }
            for (k, i) in order.enumerated() {
                let share = budget / Double(order.count - k)
                let s = items[i].measure(proposal(main: share, cross: crossP))
                sizes[i] = s
                let used = main(s)
                budget = max(0, budget - used)
                remaining = max(0, remaining - used)
            }
        }
        return sizes
    }

    override func sizeThatFits(_ p: ProposedViewSize) -> Size {
        let sizes = distribute(p)
        guard !sizes.isEmpty else { return .zero }
        let m = sizes.reduce(0) { $0 + main($1) } + spacing * Double(sizes.count - 1)
        let c = sizes.reduce(0) { max($0, cross($1)) }
        return axis == .horizontal ? Size(width: m, height: c) : Size(width: c, height: m)
    }

    /// Draws only the children that can be seen (inside a scroll view most are not).
    override func draw(_ list: inout DisplayList) {
        let items = flat
        if items.contains(where: { $0.zIndex != 0 }) {
            let ordered = items.enumerated().sorted {
                if $0.element.zIndex != $1.element.zIndex { return $0.element.zIndex < $1.element.zIndex }
                return $0.offset < $1.offset
            }
            for entry in ordered where list.isVisible(entry.element.frame) { entry.element.draw(&list) }
            return
        }
        for c in items where list.isVisible(c.frame) { c.draw(&list) }
    }

    override func hitTest(_ p: Point) -> Node? {
        let items = flat
        guard items.contains(where: { $0.zIndex != 0 }) else { return super.hitTest(p) }
        let ordered = items.enumerated().sorted {
            if $0.element.zIndex != $1.element.zIndex { return $0.element.zIndex < $1.element.zIndex }
            return $0.offset < $1.offset
        }
        for entry in ordered.reversed() {
            if let h = entry.element.hitTest(p) { return h }
            var anc = entry.element.parent
            while let a = anc, a !== self {
                if let t = a as? TapNode, t.isButton, t.contentFrame.contains(p) { return t }
                anc = a.parent
            }
        }
        return nil
    }

    override func placeChildren(in r: Rect) {
        let sizes = distribute(ProposedViewSize(r.size))
        var pos = axis == .horizontal ? r.minX : r.minY
        for (c, s) in zip(flat, sizes) {
            let slot: Rect = axis == .horizontal
                ? Rect(x: pos, y: r.minY, width: s.width, height: r.height)
                : Rect(x: r.minX, y: pos, width: r.width, height: s.height)
            let o = alignment.origin(of: s, in: slot)
            c.place(Rect(origin: o, size: s))
            pos += main(s) + spacing
        }
    }
}

final class ZStackNode: Node {
    var alignment: Alignment = .center
    override var role: String { "ZStack" }
    var flat: [Node] { children.first?.flattened ?? [] }
    override func sizeThatFits(_ p: ProposedViewSize) -> Size {
        var w = 0.0, h = 0.0
        for c in flat { let s = c.measure(p); w = max(w, s.width); h = max(h, s.height) }
        return Size(width: w, height: h)
    }
    override func placeChildren(in r: Rect) {
        for c in flat {
            let s = c.measure(ProposedViewSize(r.size))
            c.place(Rect(origin: alignment.origin(of: s, in: r), size: s))
        }
    }
    override func draw(_ list: inout DisplayList) {
        let items = flat
        if items.contains(where: { $0.zIndex != 0 }) {
            let ordered = items.enumerated().sorted {
                if $0.element.zIndex != $1.element.zIndex { return $0.element.zIndex < $1.element.zIndex }
                return $0.offset < $1.offset
            }
            for entry in ordered { entry.element.draw(&list) }
            return
        }
        super.draw(&list)
    }
    override func hitTest(_ p: Point) -> Node? {
        let items = flat
        guard items.contains(where: { $0.zIndex != 0 }) else { return super.hitTest(p) }
        let ordered = items.enumerated().sorted {
            if $0.element.zIndex != $1.element.zIndex { return $0.element.zIndex < $1.element.zIndex }
            return $0.offset < $1.offset
        }
        for entry in ordered.reversed() {
            if let h = entry.element.hitTest(p) { return h }
            var anc = entry.element.parent
            while let a = anc, a !== self {
                if let t = a as? TapNode, t.isButton, t.contentFrame.contains(p) { return t }
                anc = a.parent
            }
        }
        return nil
    }
}
