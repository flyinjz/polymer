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
    override func dump(into out: inout String, depth: Int, focused: Node? = nil, markFocus: Bool = false) {
        children[behind ? 1 : 0].dump(into: &out, depth: depth, focused: focused, markFocus: behind ? false : markFocus)
        children[behind ? 0 : 1].dump(into: &out, depth: depth, focused: focused, markFocus: behind ? markFocus : false)
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
