// Views and the result builder, as in SwiftUI. A view describes; Polymer
// keeps a tree of nodes that lay out and draw, and updates that tree in
// place when a view is evaluated again (State.swift, Node.swift).
import PolymerBase
@_exported import Observation

@MainActor @preconcurrency
public protocol View {
    associatedtype Body: View
    @ViewBuilder var body: Body { get }
}

extension Never: View {
    public var body: Never { fatalError("Never has no body") }
}

/// Built-in views implement this instead of `body`.
@MainActor
protocol PrimitiveView {
    /// Updates `existing` when it is this view's kind of node, or makes a new one.
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node
}

extension PrimitiveView {
    public var body: Never { fatalError("\(Self.self) is a built-in view; it has no body") }
}

/// Brings the node for `view` up to date. `existing` is the node that stood
/// in this place before; it is reused when it is the same kind of view, so
/// state below it survives. The caller unmounts `existing` if another node
/// comes back.
@MainActor
func reconcile<V: View>(_ view: V, _ existing: Node?, _ c: ResolveContext) -> Node {
    let node: Node
    if let p = view as? PrimitiveView {
        node = p.resolve(existing, c)
    } else if let host = existing as? HostNode<V> {
        // An unchanged Equatable view in an unchanged environment: nothing below changed.
        if !host.update(view, c) { return host }
        node = host
    } else {
        let host = HostNode<V>(view, c)
        _ = host.update(view, c)
        node = host
    }
    node.scale = c.environment.displayScale
    node.invalidateLayout()
    return node
}

/// What a parent hands down while resolving.
struct ResolveContext {
    var environment: EnvironmentValues
    /// Main axis of the nearest enclosing stack, for views like `Divider`.
    var stackAxis: Axis?
    /// Shared by every node of one tree.
    let tree: TreeState
    /// The view whose body is being resolved; closures run later (ForEach) report their reads to it.
    var host: (any ViewHost)?
    /// Number of enclosing views with a body.
    var depth = 0
    /// True when the view is an item of a lazy stack: a `ForEach` here builds its elements only when they come into view.
    var lazyItems = false
}

public enum Axis: Sendable { case horizontal, vertical }

// MARK: Result builder

@resultBuilder @MainActor
public enum ViewBuilder {
    public static func buildBlock() -> EmptyView { EmptyView() }
    public static func buildBlock<Content: View>(_ content: Content) -> Content { content }
    public static func buildBlock<each Content: View>(_ content: repeat each Content) -> TupleView<repeat each Content> {
        TupleView(repeat each content)
    }
    public static func buildIf<Content: View>(_ content: Content?) -> Content? { content }
    public static func buildEither<T: View, F: View>(first: T) -> ConditionalContent<T, F> { .init(storage: .first(first)) }
    public static func buildEither<T: View, F: View>(second: F) -> ConditionalContent<T, F> { .init(storage: .second(second)) }
    public static func buildLimitedAvailability<Content: View>(_ content: Content) -> Content { content }
}

public struct EmptyView: View, PrimitiveView {
    public init() {}
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? GroupNode) ?? GroupNode()
        n.removeChildren(from: 0)
        return n
    }
}

public struct TupleView<each Content: View>: View, PrimitiveView {
    let content: (repeat each Content)
    public init(_ content: repeat each Content) { self.content = (repeat each content) }
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? GroupNode) ?? GroupNode()
        var i = 0
        for v in repeat each content { n.setChild(i, v, c); i += 1 }
        n.removeChildren(from: i)
        return n
    }
}

/// Several views as one, without a layout of its own (SwiftUI's `Group`).
public struct Group<Content: View>: View, PrimitiveView {
    let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node { reconcile(content, existing, c) }
}

extension Optional: View where Wrapped: View {
    public var body: Never { fatalError("Optional is a built-in view") }
}
extension Optional: PrimitiveView where Wrapped: View {
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? GroupNode) ?? GroupNode()
        switch self {
        case .some(let v): n.setChild(0, v, c); n.removeChildren(from: 1)
        case .none: n.removeChildren(from: 0)
        }
        return n
    }
}

/// The two branches of an `if`/`else`. Each branch has its own identity:
/// switching branches starts the new one with fresh state.
public struct ConditionalContent<TrueContent: View, FalseContent: View>: View, PrimitiveView {
    enum Storage { case first(TrueContent), second(FalseContent) }
    let storage: Storage
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? ConditionalNode) ?? ConditionalNode()
        switch storage {
        case .first(let v):
            if n.first != true { n.removeChildren(from: 0); n.first = true }
            n.setChild(0, v, c)
        case .second(let v):
            if n.first != false { n.removeChildren(from: 0); n.first = false }
            n.setChild(0, v, c)
        }
        return n
    }
}

final class ConditionalNode: PassthroughNode {
    var first: Bool?
}

/// One view per element of a collection. Each element's `id` is its
/// identity: state follows an element when the collection is reordered.
public struct ForEach<Data: RandomAccessCollection, ID: Hashable, Content: View>: View, PrimitiveView {
    let data: Data
    let id: (Data.Element) -> ID
    let content: (Data.Element) -> Content

    public init(_ data: Data, id: KeyPath<Data.Element, ID>, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data; self.id = { $0[keyPath: id] }; self.content = content
    }

    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        if c.lazyItems {
            let n = (existing as? LazyForEachNode) ?? LazyForEachNode()
            let data = data, content = content, id = id
            let makeIDs = { data.map { AnyHashable(id($0)) } }
            n.update(ids: c.host?.track(makeIDs) ?? makeIDs(), c) { i in
                content(data[data.index(data.startIndex, offsetBy: i)])
            }
            return n
        }
        let n = (existing as? ForEachNode) ?? ForEachNode()
        // The content closure runs now, not in the enclosing body, so its reads are reported separately.
        let build = { data.map { (AnyHashable(id($0)), content($0)) } }
        n.update(c.host?.track(build) ?? build(), c)
        return n
    }
}

extension ForEach where Data.Element: Identifiable, ID == Data.Element.ID {
    public init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data; self.id = { $0.id }; self.content = content
    }
}

extension ForEach where Data == Range<Int>, ID == Int {
    /// A fixed range of indices.
    public init(_ data: Range<Int>, @ViewBuilder content: @escaping (Int) -> Content) {
        self.data = data; self.id = { $0 }; self.content = content
    }
}

final class ForEachNode: ContainerNode {
    var ids: [AnyHashable] = []

    func update<Content: View>(_ items: [(AnyHashable, Content)], _ c: ResolveContext) {
        // Same ids in the same order: update in place.
        if ids.count == items.count, zip(ids, items).allSatisfy({ $0 == $1.0 }) {
            for (i, item) in items.enumerated() { setChild(i, item.1, c) }
            return
        }
        var old: [AnyHashable: Node] = [:]
        old.reserveCapacity(ids.count)
        for (i, id) in ids.enumerated() { old[id] = children[i] }
        var seen = Set<AnyHashable>()
        var next: [Node] = []
        next.reserveCapacity(items.count)
        for (id, view) in items {
            if !seen.insert(id).inserted {
                Logger("PolymerUI").error("ForEach: the id \(id.base) appears more than once. Ids must be unique; give each element its own id (for example `id: \\.self` only when values never repeat).")
            }
            let prev = old.removeValue(forKey: id)
            let node = reconcile(view, prev, c)
            if node !== prev { prev?.unmount() }
            node.parent = self
            next.append(node)
        }
        for (_, gone) in old { gone.unmount() }
        children = next
        ids = items.map { $0.0 }
    }
}

extension View {
    /// Gives the view an explicit identity: when `id` changes, the view is
    /// rebuilt with fresh state.
    public func id<ID: Hashable>(_ id: ID) -> some View { IDView(content: self, id: AnyHashable(id)) }
}

struct IDView<Content: View>: View, PrimitiveView {
    let content: Content
    let id: AnyHashable
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? IDNode) ?? IDNode()
        if n.id != id { n.removeChildren(from: 0); n.id = id }
        n.setChild(0, content, c)
        return n
    }
}

final class IDNode: PassthroughNode {
    var id: AnyHashable?
}
