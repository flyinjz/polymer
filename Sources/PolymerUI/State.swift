// State and observation. A view with a body gets a host node that keeps
// its `@State` between updates and re-evaluates the body when something it
// read changes: `@State` values, or properties of `@Observable` objects
// (Swift's Observation library). Only the views that read a value are
// evaluated again.
import PolymerBase
import Synchronization

// MARK: Property wrappers

/// A property of a view that Polymer connects to the tree before `body` runs
/// (`@State`, `@Binding`, `@Environment`).
public protocol DynamicProperty {}

/// Implemented by the wrappers that need connecting.
protocol LinkedProperty {
    func link(_ linker: inout PropertyLinker)
}

/// Hands each `@State` of a view its storage, in declaration order.
struct PropertyLinker {
    var storages: [AnyObject]
    var index = 0
    let environment: EnvironmentValues
}

/// Where a `@State` value lives. Observable, so reads and writes are tracked like any other.
final class StateStorage<Value>: Observable {
    fileprivate(set) var stored: Value
    private let registrar = ObservationRegistrar()

    init(_ value: Value) { stored = value }

    var value: Value {
        get {
            registrar.access(self, keyPath: \.value)
            return stored
        }
        set {
            registrar.withMutation(of: self, keyPath: \.value) { stored = newValue }
        }
    }
}

final class StateBox<Value> {
    var storage: StateStorage<Value>
    init(_ storage: StateStorage<Value>) { self.storage = storage }
}

/// A value owned by a view, kept for as long as the view stays in the tree.
/// Changing it re-evaluates the views that read it.
@propertyWrapper
public struct State<Value>: DynamicProperty, LinkedProperty {
    let box: StateBox<Value>

    public init(wrappedValue: Value) { box = StateBox(StateStorage(wrappedValue)) }
    public init(initialValue: Value) { self.init(wrappedValue: initialValue) }

    public var wrappedValue: Value {
        get { box.storage.value }
        nonmutating set { box.storage.value = newValue }
    }

    public var projectedValue: Binding<Value> {
        let storage = box.storage
        return Binding(get: { storage.value }, set: { storage.value = $0 })
    }

    func link(_ l: inout PropertyLinker) {
        if l.index < l.storages.count, let kept = l.storages[l.index] as? StateStorage<Value> {
            box.storage = kept
        } else if l.index < l.storages.count {
            l.storages[l.index] = box.storage
        } else {
            l.storages.append(box.storage)
        }
        l.index += 1
    }
}

/// A reference to a value owned elsewhere.
@propertyWrapper @dynamicMemberLookup
public struct Binding<Value>: DynamicProperty {
    let getValue: () -> Value
    let setValue: (Value) -> Void

    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) { getValue = get; setValue = set }

    /// A binding that always reads `value` and ignores writes.
    public static func constant(_ value: Value) -> Binding<Value> { Binding(get: { value }, set: { _ in }) }

    public var wrappedValue: Value {
        get { getValue() }
        nonmutating set { setValue(newValue) }
    }

    public var projectedValue: Binding<Value> { self }

    public subscript<T>(dynamicMember keyPath: WritableKeyPath<Value, T>) -> Binding<T> {
        Binding<T>(get: { getValue()[keyPath: keyPath] },
                   set: { var v = getValue(); v[keyPath: keyPath] = $0; setValue(v) })
    }
}

/// Bindings to the properties of an `@Observable` object: `$model.title`.
@propertyWrapper @dynamicMemberLookup
public struct Bindable<Value: AnyObject & Observable> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
    public init(_ value: Value) { wrappedValue = value }
    public var projectedValue: Bindable<Value> { self }

    public subscript<T>(dynamicMember keyPath: ReferenceWritableKeyPath<Value, T>) -> Binding<T> {
        let object = wrappedValue
        return Binding<T>(get: { object[keyPath: keyPath] }, set: { object[keyPath: keyPath] = $0 })
    }
}

final class EnvironmentBox {
    var values: EnvironmentValues?
}

/// Reads a value from the environment at the view's place in the tree.
@propertyWrapper
public struct Environment<Value>: DynamicProperty, LinkedProperty {
    let keyPath: KeyPath<EnvironmentValues, Value>
    let box = EnvironmentBox()

    public init(_ keyPath: KeyPath<EnvironmentValues, Value>) { self.keyPath = keyPath }

    public var wrappedValue: Value {
        if let v = box.values { return v[keyPath: keyPath] }
        Logger("PolymerUI").warning("@Environment was read before its view was in the tree (for example in init); the default value is returned. Read it in body instead.")
        return EnvironmentValues()[keyPath: keyPath]
    }

    func link(_ l: inout PropertyLinker) { box.values = l.environment }
}

// MARK: Invalidation

/// Views waiting to be evaluated again. Changes can be reported from any thread.
final class InvalidationQueue: Sendable {
    private let pending = Mutex<[(Invalidator, Int)]>([])
    private let wake = Mutex<(@Sendable () -> Void)?>(nil)

    func push(_ invalidator: Invalidator, _ generation: Int) {
        pending.withLock { $0.append((invalidator, generation)) }
        let w = wake.withLock { $0 }
        w?()
    }

    /// Takes everything queued; entries made stale by a later evaluation are dropped.
    func drain() -> [Invalidator] {
        let taken = pending.withLock { p -> [(Invalidator, Int)] in
            let t = p
            p.removeAll(keepingCapacity: true)
            return t
        }
        return taken.compactMap { $0.1 == $0.0.generation ? $0.0 : nil }
    }

    var isEmpty: Bool { pending.withLock { $0.isEmpty } }

    func onPush(_ w: (@Sendable () -> Void)?) { wake.withLock { $0 = w } }
}

/// One per view with a body: the link from "something it read changed" back to the view.
final class Invalidator: Sendable {
    let queue: InvalidationQueue
    private let current = Atomic<Int>(0)
    @MainActor weak var host: (any ViewHost)?

    init(queue: InvalidationQueue) { self.queue = queue }

    /// Starts a new evaluation; changes reported for earlier ones are ignored.
    func begin() -> Int { current.add(1, ordering: .relaxed).newValue }

    var generation: Int { current.load(ordering: .relaxed) }

    func invalidate(_ generation: Int) {
        guard generation == current.load(ordering: .relaxed) else { return }
        queue.push(self, generation)
    }
}

/// Every tracking of a host also reads its epoch. Changing the epoch fires
/// those trackings, which removes them from every object they were watching,
/// so a view never leaves old registrations behind.
final class Epoch: Observable {
    private let registrar = ObservationRegistrar()
    var value: Int { 0 }
    func touch() { registrar.access(self, keyPath: \.value) }
    func bump() { registrar.withMutation(of: self, keyPath: \.value) {} }
}

/// State shared by every node of one tree.
@MainActor
final class TreeState {
    let queue = InvalidationQueue()
    /// Number of `body` evaluations so far, for checks and measurements.
    var bodyEvaluations = 0
    /// Set when a lazy stack needs another layout pass: its rows' real sizes
    /// replaced estimates, or scrolling brought other rows into view.
    var layoutRequested = false
    /// The node with keyboard focus.
    weak var focused: Node?
    /// Views with `.focused(...)`, in the order they first appeared.
    var focusBindings: [WeakFocusBinding] = []
    /// Views with `.onHover`.
    var hoverNodes: [WeakHoverNode] = []
}

// MARK: Hosts

@MainActor
protocol ViewHost: AnyObject {
    var depth: Int { get }
    var isDirty: Bool { get set }
    /// Runs `body`, reporting what it reads as dependencies of this view.
    func track<T>(_ body: () -> T) -> T
    /// Evaluates the body again and updates the nodes below.
    func reevaluate()
}

/// Whether views of each type have properties to link, so views without any skip the search.
/// Views that hold another value whose `@State` and `@Environment` are
/// linked too (a button style, inside the view that draws it).
@MainActor protocol LinksNestedProperties { var nestedProperties: Any { get } }

/// The properties of `view` to link: its own, then those of the value it nests.
@MainActor func linkedProperties(_ view: Any) -> [LinkedProperty] {
    var out = Mirror(reflecting: view).children.compactMap { $0.value as? LinkedProperty }
    if let n = view as? LinksNestedProperties {
        out += Mirror(reflecting: n.nestedProperties).children.compactMap { $0.value as? LinkedProperty }
    }
    return out
}

@MainActor private var linkedViewTypes: [ObjectIdentifier: Bool] = [:]

/// The node of a view with a body. Keeps the view's state and its
/// dependencies, and holds the node of its body as its only child.
final class HostNode<V: View>: PassthroughNode, ViewHost {
    private var view: V
    private var context: ResolveContext
    private var storages: [AnyObject] = []
    private let invalidator: Invalidator
    private let epoch = Epoch()
    private let name: String
    private let linked: Bool
    private var mounted = true
    var isDirty = false
    var depth: Int { context.depth }

    init(_ view: V, _ c: ResolveContext) {
        self.view = view
        context = c
        invalidator = Invalidator(queue: c.tree.queue)
        // The type's name without generic arguments.
        let full = String(describing: V.self)
        name = String(full.prefix { $0 != "<" })
        let type = ObjectIdentifier(V.self)
        if let known = linkedViewTypes[type] { linked = known } else {
            linked = !linkedProperties(view).isEmpty
            linkedViewTypes[type] = linked
        }
        super.init()
        invalidator.host = self
    }

    override var role: String { name }
    override var isElement: Bool { !(V.self is HiddenFromElementTree.Type) }

    /// Called when the parent hands down a new value of the view.
    func update(_ view: V, _ c: ResolveContext) {
        self.view = view
        context = c
        evaluate()
    }

    func reevaluate() {
        guard mounted else { return }
        evaluate()
        invalidateLayoutUpward()
    }

    private func evaluate() {
        isDirty = false
        let generation = invalidator.begin()
        epoch.bump()
        if linked {
            var linker = PropertyLinker(storages: storages, environment: context.environment)
            for p in linkedProperties(view) { p.link(&linker) }
            storages = linker.storages
        }
        var inner = context
        inner.host = self
        inner.depth += 1
        context.tree.bodyEvaluations += 1
        let body = track(generation) { view.body }
        setChild(0, body, inner)
    }

    func track<T>(_ body: () -> T) -> T { track(invalidator.generation, body) }

    private func track<T>(_ generation: Int, _ body: () -> T) -> T {
        withObservationTracking {
            epoch.touch()
            return body()
        } onChange: { [invalidator] in
            invalidator.invalidate(generation)
        }
    }

    override func unmount() {
        mounted = false
        _ = invalidator.begin()
        epoch.bump()
        invalidator.host = nil
        super.unmount()
    }
}
