// GeometryReader, as in SwiftUI: takes all the space it is offered and
// builds its content from that size (and where it is). The content is built
// while laying out, once the size is known, and again whenever the size,
// the position or what the content reads changes. It sits at the
// top-leading corner.
import PolymerBase

/// The size and place of a `GeometryReader`.
public struct GeometryProxy: Equatable, Sendable {
    public let size: Size
    /// Its rectangle in the tree's coordinates (screen points, scrolling included).
    let global: Rect
    /// Its rectangle in `space`: `.local` starts at zero, `.global` is where it is in the tree.
    public func frame(in space: CoordinateSpace) -> Rect {
        space == .global ? global : Rect(origin: .zero, size: size)
    }
}

public struct GeometryReader<Content: View>: View, PrimitiveView {
    let content: (GeometryProxy) -> Content
    public init(@ViewBuilder content: @escaping (GeometryProxy) -> Content) { self.content = content }
    public var body: Never { fatalError("GeometryReader is a built-in view") }

    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? GeometryReaderNode) ?? GeometryReaderNode()
        let content = content, host = c.host
        n.build = { node, proxy in
            let v = host?.track { content(proxy) } ?? content(proxy)
            node.setChild(0, v, c)
        }
        // Up to date with the new view value now, at the last known size; placing builds it again if that changed.
        if let p = n.proxy { n.build?(n, p) }
        return n
    }
}

final class GeometryReaderNode: Node {
    var build: ((GeometryReaderNode, GeometryProxy) -> Void)?
    /// What the content was last built with.
    private(set) var proxy: GeometryProxy?

    override var role: String { "GeometryReader" }
    override func sizeThatFits(_ p: ProposedViewSize) -> Size { p.replacingUnspecified(Size(width: 10, height: 10)) }

    override func placeChildren(in r: Rect) {
        let f = layoutFrame
        let shift = screenFrame.origin
        let next = GeometryProxy(size: f.size, global: Rect(origin: shift, size: f.size))
        if next != proxy {
            proxy = next
            build?(self, next)
        }
        guard let child = children.first else { return }
        let s = child.measure(ProposedViewSize(r.size))
        child.place(Rect(origin: r.origin, size: s))
    }
}
