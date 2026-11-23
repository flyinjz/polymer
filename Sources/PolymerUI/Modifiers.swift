// Layout and decoration modifiers: padding, frame, background, overlay, border, clipping.
import PolymerBase
import PolymerRender

extension View {
    public func padding(_ insets: EdgeInsets) -> some View { PaddingView(content: self, insets: insets) }
    public func padding(_ length: Double = 8) -> some View { padding(EdgeInsets(all: length)) }
    public func padding(horizontal: Double = 0, vertical: Double = 0) -> some View {
        padding(EdgeInsets(top: vertical, leading: horizontal, bottom: vertical, trailing: horizontal))
    }

    /// Fixed size in either dimension; nil keeps the content's own.
    public func frame(width: Double? = nil, height: Double? = nil, alignment: Alignment = .center) -> some View {
        FrameView(content: self, width: width, height: height, alignment: alignment)
    }

    /// Flexible frame: `.infinity` as a maximum makes the view fill what it is offered.
    public func frame(minWidth: Double? = nil, maxWidth: Double? = nil, minHeight: Double? = nil, maxHeight: Double? = nil,
                      alignment: Alignment = .center) -> some View {
        FlexFrameView(content: self, minWidth: minWidth, maxWidth: maxWidth, minHeight: minHeight, maxHeight: maxHeight,
                      alignment: alignment)
    }

    public func background<B: View>(_ background: B) -> some View { LayerView(content: self, layer: background, behind: true) }
    public func overlay<O: View>(_ overlay: O) -> some View { LayerView(content: self, layer: overlay, behind: false) }

    /// A line of `width` points inside the view's edge.
    public func border(_ color: Color, width: Double = 1) -> some View {
        LayerView(content: self, layer: BorderShape(color: color, width: width), behind: false)
    }

    /// Hides whatever the view draws outside its frame.
    public func clipped() -> some View { ClipView(content: self) }

    /// Scales the opacity of this view (0...1). Animatable with `withAnimation` or `.animation(_:value:)`.
    public func opacity(_ value: Double) -> some View { OpacityView(content: self, opacity: value) }

    /// Shifts where this view draws and hit-tests without changing its layout frame.
    /// Animatable with `withAnimation` or `.animation(_:value:)`.
    public func offset(x: Double = 0, y: Double = 0) -> some View { OffsetView(content: self, offset: Point(x: x, y: y)) }
    public func offset(_ offset: Point) -> some View { OffsetView(content: self, offset: offset) }

    /// Constrains this view's dimensions to `aspectRatio` (width / height), fitting or filling the proposal.
    /// When `aspectRatio` is nil, preserves the child's own ideal aspect ratio.
    public func aspectRatio(_ aspectRatio: Double? = nil, contentMode: ContentMode) -> some View {
        AspectRatioView(content: self, ratio: aspectRatio, mode: contentMode)
    }

    /// Runs `action(oldValue, newValue)` whenever `value` changes (and once on first appearance when `initial` is true).
    public func onChange<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping @MainActor (V, V) -> Void) -> some View {
        OnChangeView(content: self, value: value, initial: initial, action: action)
    }

    /// Gives the view a stable name shown in the element tree (`#id`) and usable by headless input and Customize.
    public func accessibilityIdentifier(_ id: String) -> some View {
        IdentifierView(content: self, id: id)
    }
}

struct PaddingView<Content: View>: View, PrimitiveView {
    let content: Content, insets: EdgeInsets
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? PaddingNode) ?? PaddingNode()
        n.insets = insets
        n.setChild(0, content, c)
        return n
    }
}

final class PaddingNode: Node {
    var insets = EdgeInsets.zero
    override var isElement: Bool { false }
    override func sizeThatFits(_ p: ProposedViewSize) -> Size {
        let h = insets.leading + insets.trailing, v = insets.top + insets.bottom
        let inner = ProposedViewSize(width: p.width.map { max(0, $0 - h) }, height: p.height.map { max(0, $0 - v) })
        let s = children[0].measure(inner)
        return Size(width: s.width + h, height: s.height + v)
    }
    override func placeChildren(in r: Rect) { children[0].place(r.inset(by: insets)) }
}

struct FrameView<Content: View>: View, PrimitiveView {
    let content: Content, width: Double?, height: Double?, alignment: Alignment
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? FrameNode) ?? FrameNode()
        n.width = width; n.height = height; n.alignment = alignment
        n.setChild(0, content, c)
        return n
    }
}

final class FrameNode: Node {
    var width: Double?, height: Double?, alignment = Alignment.center
    override var isElement: Bool { false }
    override func sizeThatFits(_ p: ProposedViewSize) -> Size {
        let inner = children[0].measure(ProposedViewSize(width: width ?? p.width, height: height ?? p.height))
        return Size(width: width ?? inner.width, height: height ?? inner.height)
    }
    override func placeChildren(in r: Rect) {
        let s = children[0].measure(ProposedViewSize(r.size))
        children[0].place(Rect(origin: alignment.origin(of: s, in: r), size: s))
    }
}

struct FlexFrameView<Content: View>: View, PrimitiveView {
    let content: Content
    let minWidth: Double?, maxWidth: Double?, minHeight: Double?, maxHeight: Double?
    let alignment: Alignment
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? FlexFrameNode) ?? FlexFrameNode()
        n.minW = minWidth; n.maxW = maxWidth; n.minH = minHeight; n.maxH = maxHeight; n.alignment = alignment
        n.setChild(0, content, c)
        return n
    }
}

final class FlexFrameNode: Node {
    var minW: Double?, maxW: Double?, minH: Double?, maxH: Double?, alignment = Alignment.center
    override var isElement: Bool { false }

    static func clamp(_ v: Double, _ lo: Double?, _ hi: Double?) -> Double {
        var v = v
        if let hi { v = min(v, hi) }
        if let lo { v = max(v, lo) }
        return v
    }

    override func sizeThatFits(_ p: ProposedViewSize) -> Size {
        let pw = p.width.map { FlexFrameNode.clamp($0, minW, maxW) }
        let ph = p.height.map { FlexFrameNode.clamp($0, minH, maxH) }
        let inner = children[0].measure(ProposedViewSize(width: pw, height: ph))
        // With a maximum, take the proposal (up to the maximum); otherwise the content's size within the bounds.
        let w = (maxW != nil && p.width != nil) ? FlexFrameNode.clamp(max(inner.width, p.width!), minW, maxW)
                                                : FlexFrameNode.clamp(inner.width, minW, maxW)
        let h = (maxH != nil && p.height != nil) ? FlexFrameNode.clamp(max(inner.height, p.height!), minH, maxH)
                                                 : FlexFrameNode.clamp(inner.height, minH, maxH)
        return Size(width: w, height: h)
    }
    override func placeChildren(in r: Rect) {
        let s = children[0].measure(ProposedViewSize(r.size))
        children[0].place(Rect(origin: alignment.origin(of: s, in: r), size: s))
    }
}

/// Background or overlay: sized by the content, the layer is offered the content's size.
struct LayerView<Content: View, Layer: View>: View, PrimitiveView {
    let content: Content, layer: Layer, behind: Bool
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let reuse = (existing as? LayerNode).flatMap { $0.behind == behind ? $0 : nil }
        let n = reuse ?? LayerNode(behind: behind)
        n.setChild(0, content, c)
        n.setChild(1, layer, c)
        return n
    }
}

/// Children: the content, then the layer.
final class LayerNode: Node {
    let behind: Bool
    init(behind: Bool) { self.behind = behind; super.init() }
    override var isElement: Bool { false }
    override func sizeThatFits(_ p: ProposedViewSize) -> Size { children[0].measure(p) }
    override func placeChildren(in r: Rect) {
        children[0].place(r)
        let s = children[1].measure(ProposedViewSize(r.size))
        children[1].place(Rect(origin: Alignment.center.origin(of: s, in: r), size: s))
    }
    override func draw(_ list: inout DisplayList) {
        if behind { children[1].draw(&list); children[0].draw(&list) } else { children[0].draw(&list); children[1].draw(&list) }
    }
    override func hitTest(_ p: Point) -> Node? {
        let front = behind ? children[0] : children[1], back = behind ? children[1] : children[0]
        return front.hitTest(p) ?? back.hitTest(p)
    }
    /// Listed in drawing order, back to front, at the same depth: a background before its content, an overlay after.
    override func dump(into out: inout String, depth: Int, focused: Node? = nil, markFocus: Bool = false, pendingID: String? = nil) {
        children[behind ? 1 : 0].dump(into: &out, depth: depth, focused: focused, markFocus: behind ? false : markFocus, pendingID: behind ? nil : pendingID)
        children[behind ? 0 : 1].dump(into: &out, depth: depth, focused: focused, markFocus: behind ? markFocus : false, pendingID: behind ? pendingID : nil)
    }
}

struct BorderShape: View, PrimitiveView {
    let color: Color, width: Double
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? BorderNode) ?? BorderNode()
        n.color = color; n.width = width
        return n
    }
}

final class BorderNode: Node {
    var color: Color = .clear, width = 1.0
    override var role: String { "Border" }
    override var detail: String { color.description }
    override func sizeThatFits(_ p: ProposedViewSize) -> Size { p.replacingUnspecified(.zero) }
    override func draw(_ list: inout DisplayList) {
        let f = frame, w = width
        list.fill(Rect(x: f.minX, y: f.minY, width: f.width, height: w), color)
        list.fill(Rect(x: f.minX, y: f.maxY - w, width: f.width, height: w), color)
        list.fill(Rect(x: f.minX, y: f.minY + w, width: w, height: f.height - 2 * w), color)
        list.fill(Rect(x: f.maxX - w, y: f.minY + w, width: w, height: f.height - 2 * w), color)
    }
}

struct ClipView<Content: View>: View, PrimitiveView {
    let content: Content
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? ClipNode) ?? ClipNode()
        n.setChild(0, content, c)
        return n
    }
}

final class ClipNode: Node {
    override var clipsContent: Bool { true }
    override var isElement: Bool { false }
    override func sizeThatFits(_ p: ProposedViewSize) -> Size { children[0].measure(p) }
    override func placeChildren(in r: Rect) { children[0].place(r) }
    override func draw(_ list: inout DisplayList) {
        list.clipped(to: frame) { c in children[0].draw(&c) }
    }
    override func hitTest(_ p: Point) -> Node? { frame.contains(p) ? children[0].hitTest(p) : nil }
}

// MARK: Opacity, Offset, AspectRatio, OnChange, Identifier

struct OpacityView<Content: View>: View, PrimitiveView {
    let content: Content
    let opacity: Double
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let clamped = min(max(opacity, 0), 1)
        let n: OpacityNode
        if let e = existing as? OpacityNode {
            n = e
            if n.animated.set(clamped, animation: c.animation) { c.tree.registerAnimatable(n) }
        } else {
            n = OpacityNode(opacity: clamped)
        }
        n.setChild(0, content, c)
        return n
    }
}

final class OpacityNode: Node, AnimatableTicking {
    var animated: AnimatedDouble
    init(opacity: Double) { animated = AnimatedDouble(opacity); super.init() }
    override var isElement: Bool { false }
    var isAnimating: Bool { animated.isActive }
    func tick(_ dt: Double) -> Bool { animated.step(dt) }
    override func sizeThatFits(_ p: ProposedViewSize) -> Size { children[0].measure(p) }
    override func placeChildren(in r: Rect) { children[0].place(r) }
    override func draw(_ list: inout DisplayList) {
        list.withOpacity(animated.current) { c in children[0].draw(&c) }
    }
}

struct OffsetView<Content: View>: View, PrimitiveView {
    let content: Content
    let offset: Point
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n: OffsetNode
        if let e = existing as? OffsetNode {
            n = e
            if n.animated.set(offset, animation: c.animation) { c.tree.registerAnimatable(n) }
        } else {
            n = OffsetNode(offset: offset)
        }
        n.setChild(0, content, c)
        return n
    }
}

final class OffsetNode: Node, AnimatableTicking {
    var animated: AnimatedPoint
    init(offset: Point) { animated = AnimatedPoint(offset); super.init() }
    override var isElement: Bool { false }
    var isAnimating: Bool { animated.isActive }
    func tick(_ dt: Double) -> Bool { animated.step(dt) }
    override var contentShift: Point { animated.current }
    override func sizeThatFits(_ p: ProposedViewSize) -> Size { children[0].measure(p) }
    override func placeChildren(in r: Rect) { children[0].place(r) }
    override func draw(_ list: inout DisplayList) {
        let shift = animated.current
        if shift == .zero { children[0].draw(&list); return }
        list.translated(by: shift) { c in children[0].draw(&c) }
    }
    override func hitTest(_ p: Point) -> Node? {
        let shift = animated.current
        return children[0].hitTest(Point(x: p.x - shift.x, y: p.y - shift.y))
    }
}

struct AspectRatioView<Content: View>: View, PrimitiveView {
    let content: Content
    let ratio: Double?
    let mode: ContentMode
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? AspectRatioNode) ?? AspectRatioNode()
        n.ratio = ratio; n.mode = mode
        n.setChild(0, content, c)
        return n
    }
}

final class AspectRatioNode: Node {
    var ratio: Double?
    var mode: ContentMode = .fit
    override var isElement: Bool { false }

    private func targetRatio() -> Double {
        if let r = ratio, r > 0 { return r }
        let ideal = children[0].measure(.unspecified)
        return ideal.height > 0 ? ideal.width / ideal.height : 1
    }

    private func fittedSize(_ p: ProposedViewSize) -> Size {
        let r = targetRatio()
        switch (p.width, p.height) {
        case (let w?, let h?):
            let byW = Size(width: w, height: w / r)
            let byH = Size(width: h * r, height: h)
            switch mode {
            case .fit: return byW.height <= h ? byW : byH
            case .fill: return byW.height >= h ? byW : byH
            }
        case (let w?, nil):
            return Size(width: w, height: w / r)
        case (nil, let h?):
            return Size(width: h * r, height: h)
        case (nil, nil):
            return children[0].measure(.unspecified)
        }
    }

    override func sizeThatFits(_ p: ProposedViewSize) -> Size {
        let s = fittedSize(p)
        return children[0].measure(ProposedViewSize(s))
    }

    override func placeChildren(in r: Rect) {
        let s = children[0].measure(ProposedViewSize(r.size))
        children[0].place(Rect(origin: Alignment.center.origin(of: s, in: r), size: s))
    }
}

struct OnChangeView<Content: View, V: Equatable>: View, PrimitiveView {
    let content: Content
    let value: V
    let initial: Bool
    let action: @MainActor (V, V) -> Void

    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? OnChangeNode<V>) ?? OnChangeNode<V>()
        let act = action
        let newVal = value
        if let oldVal = n.lastValue {
            if oldVal != newVal {
                n.lastValue = newVal
                c.tree.pendingCallbacks.append { act(oldVal, newVal) }
            }
        } else {
            n.lastValue = newVal
            if initial {
                c.tree.pendingCallbacks.append { act(newVal, newVal) }
            }
        }
        n.setChild(0, content, c)
        return n
    }
}

final class OnChangeNode<V: Equatable>: PassthroughNode {
    var lastValue: V?
}

struct IdentifierView<Content: View>: View, PrimitiveView {
    let content: Content
    let id: String
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? IdentifierNode) ?? IdentifierNode()
        n.id = id
        n.setChild(0, content, c)
        return n
    }
}

final class IdentifierNode: PassthroughNode {
    var id: String = ""
    override var accessibilityID: String? { id.isEmpty ? nil : id }
}
