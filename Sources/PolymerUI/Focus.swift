// Keyboard focus and key presses, with SwiftUI's names: `.focusable()`,
// `@FocusState` with `.focused(...)`, and `.onKeyPress(...)`. A key press
// goes to the focused view and then to each view around it until one
// handles it. Tab and Shift-Tab move focus; Space and Return press a
// focused button.
import PolymerBase

// MARK: Keys

/// A key, named by the character it types (SwiftUI's `KeyEquivalent`).
public struct KeyEquivalent: Hashable, Sendable, ExpressibleByExtendedGraphemeClusterLiteral {
    public var character: Character
    public init(_ character: Character) { self.character = character }
    public init(extendedGraphemeClusterLiteral c: Character) { character = c }

    public static let upArrow = KeyEquivalent("\u{F700}")
    public static let downArrow = KeyEquivalent("\u{F701}")
    public static let leftArrow = KeyEquivalent("\u{F702}")
    public static let rightArrow = KeyEquivalent("\u{F703}")
    public static let deleteForward = KeyEquivalent("\u{F728}")
    public static let home = KeyEquivalent("\u{F729}")
    public static let end = KeyEquivalent("\u{F72B}")
    public static let pageUp = KeyEquivalent("\u{F72C}")
    public static let pageDown = KeyEquivalent("\u{F72D}")
    public static let clear = KeyEquivalent("\u{F739}")
    public static let escape = KeyEquivalent("\u{1B}")
    public static let delete = KeyEquivalent("\u{7F}")
    public static let tab = KeyEquivalent("\t")
    public static let space = KeyEquivalent(" ")
    public static let `return` = KeyEquivalent("\r")

    static let names: [(String, KeyEquivalent)] = [
        ("up", .upArrow), ("down", .downArrow), ("left", .leftArrow), ("right", .rightArrow),
        ("deleteforward", .deleteForward), ("home", .home), ("end", .end), ("pageup", .pageUp),
        ("pagedown", .pageDown), ("clear", .clear), ("escape", .escape), ("delete", .delete),
        ("tab", .tab), ("space", .space), ("return", .return),
    ]
}

/// Modifier keys held during a key press (SwiftUI's `EventModifiers`).
public struct EventModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = EventModifiers(rawValue: 1 << 1)
    public static let control = EventModifiers(rawValue: 1 << 2)
    public static let option = EventModifiers(rawValue: 1 << 3)
    public static let command = EventModifiers(rawValue: 1 << 4)
}

/// One key going down, repeating or coming up.
public struct KeyPress: Sendable {
    public struct Phases: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let down = Phases(rawValue: 1)
        public static let `repeat` = Phases(rawValue: 2)
        public static let up = Phases(rawValue: 4)
        public static let all: Phases = [.down, .repeat, .up]
    }
    public enum Result: Sendable { case handled, ignored }

    public var key: KeyEquivalent
    public var characters: String
    public var modifiers: EventModifiers
    public var phase: Phases

    public init(key: KeyEquivalent, characters: String? = nil, modifiers: EventModifiers = [], phase: Phases = .down) {
        self.key = key; self.modifiers = modifiers; self.phase = phase
        self.characters = characters ?? String(key.character)
    }

    /// A key press from text such as "tab", "shift+tab", "cmd+a", "down" or "x".
    /// Modifiers: shift, ctrl/control, alt/option, cmd/command. Nil when the text names no key.
    public init?(_ text: String) {
        var parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "+" itself, or "shift++".
        if text.hasSuffix("++") || text == "+" { parts.removeLast(2); parts.append("+") }
        guard let last = parts.popLast(), !last.isEmpty else { return nil }
        var mods: EventModifiers = []
        for p in parts {
            switch p.lowercased() {
            case "shift": mods.insert(.shift)
            case "ctrl", "control": mods.insert(.control)
            case "alt", "option": mods.insert(.option)
            case "cmd", "command": mods.insert(.command)
            default: return nil
            }
        }
        let key: KeyEquivalent
        if let named = KeyEquivalent.names.first(where: { $0.0 == last.lowercased() }) { key = named.1 }
        else if last.count == 1 { key = KeyEquivalent(Character(last.lowercased())) }
        else { return nil }
        let typed = last.count == 1 && mods.contains(.shift) ? last.uppercased() : (last.count == 1 ? last : String(key.character))
        self.init(key: key, characters: typed, modifiers: mods)
    }
}

// MARK: Focus state

/// A value that says which view inside this one has keyboard focus:
/// `Bool` for one view, or an optional `Hashable` to tell several apart.
/// Setting it moves focus; focus moving (Tab, a click) changes it.
@propertyWrapper
public struct FocusState<Value: Hashable>: DynamicProperty, LinkedProperty {
    let state: State<Value>

    public init() where Value == Bool { state = State(wrappedValue: false) }
    public init<T: Hashable>() where Value == T? { state = State(wrappedValue: nil) }

    public var wrappedValue: Value {
        get { state.wrappedValue }
        nonmutating set { state.wrappedValue = newValue }
    }

    public var projectedValue: Binding { Binding(storage: state.box.storage) }

    func link(_ l: inout PropertyLinker) { state.link(&l) }

    /// What `.focused(...)` takes: `$focus`.
    @propertyWrapper
    public struct Binding {
        let storage: StateStorage<Value>
        public var wrappedValue: Value {
            get { storage.value }
            nonmutating set { storage.value = newValue }
        }
        public var projectedValue: Binding { self }
    }
}

extension View {
    /// Lets the view take keyboard focus (Tab reaches it; a click on it focuses it).
    public func focusable(_ isFocusable: Bool = true) -> some View { FocusableView(content: self, isFocusable: isFocusable) }

    /// Ties `binding` to whether focus is on this view (or a focusable view inside it).
    public func focused(_ binding: FocusState<Bool>.Binding) -> some View {
        let s = binding.storage
        return FocusBindingView(content: self, isMe: { s.peek }, set: { mine in if s.peek != mine { s.value = mine } })
    }

    /// Ties `binding` to `value`: it holds `value` while focus is on this view,
    /// and setting it to `value` moves focus here.
    public func focused<V: Hashable>(_ binding: FocusState<V?>.Binding, equals value: V) -> some View {
        let s = binding.storage
        return FocusBindingView(content: self, isMe: { s.peek == value }, set: { mine in
            if mine { if s.peek != value { s.value = value } } else if s.peek == value { s.value = nil }
        })
    }

    /// Runs `action` when `key` goes down (or repeats) while focus is on this view or inside it.
    public func onKeyPress(_ key: KeyEquivalent, action: @escaping @MainActor () -> KeyPress.Result) -> some View {
        KeyPressView(content: self, phases: [.down, .repeat], keys: [key], action: { _ in action() })
    }

    /// Runs `action` for any of `keys` in the given phases.
    public func onKeyPress(keys: Set<KeyEquivalent>, phases: KeyPress.Phases = [.down, .repeat],
                           action: @escaping @MainActor (KeyPress) -> KeyPress.Result) -> some View {
        KeyPressView(content: self, phases: phases, keys: keys, action: action)
    }

    /// Runs `action` for every key press in the given phases.
    public func onKeyPress(phases: KeyPress.Phases = [.down, .repeat],
                           action: @escaping @MainActor (KeyPress) -> KeyPress.Result) -> some View {
        KeyPressView(content: self, phases: phases, keys: nil, action: action)
    }
}

extension StateStorage {
    /// The value without registering a read (focus bookkeeping must not make views depend on it).
    var peek: Value { stored }
}

struct FocusableView<Content: View>: View, PrimitiveView {
    let content: Content, isFocusable: Bool
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? FocusableNode) ?? FocusableNode()
        n.isFocusable = isFocusable && c.environment.isEnabled
        n.setChild(0, content, c)
        return n
    }
}

final class FocusableNode: PassthroughNode {
    var isFocusable = true
    override var acceptsFocus: Bool { isFocusable }
    override var focusesOnClick: Bool { isFocusable }
}

struct FocusBindingView<Content: View>: View, PrimitiveView {
    let content: Content
    let isMe: @MainActor () -> Bool
    let set: @MainActor (Bool) -> Void
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? FocusBindingNode) ?? FocusBindingNode()
        n.isMe = isMe; n.set = set
        c.tree.register(n)
        n.setChild(0, content, c)
        return n
    }
}

final class FocusBindingNode: PassthroughNode {
    var isMe: @MainActor () -> Bool = { false }
    var set: @MainActor (Bool) -> Void = { _ in }

    /// A view leaving the tree gives up focus: its binding is cleared now,
    /// since the node may be gone before the tree next looks at focus.
    override func unmount() {
        if isMe() { set(false) }
        super.unmount()
    }

    /// True when `node` is this node or inside it.
    func contains(_ node: Node?) -> Bool {
        var n = node
        while let x = n { if x === self { return true }; n = x.parent }
        return false
    }
}

struct KeyPressView<Content: View>: View, PrimitiveView {
    let content: Content
    let phases: KeyPress.Phases
    let keys: Set<KeyEquivalent>?
    let action: @MainActor (KeyPress) -> KeyPress.Result
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? KeyPressNode) ?? KeyPressNode()
        n.phases = phases; n.keys = keys; n.action = action
        n.setChild(0, content, c)
        return n
    }
}

final class KeyPressNode: PassthroughNode {
    var phases: KeyPress.Phases = [.down, .repeat]
    var keys: Set<KeyEquivalent>?
    var action: (@MainActor (KeyPress) -> KeyPress.Result)?
    override func handle(_ press: KeyPress) -> KeyPress.Result {
        guard phases.contains(press.phase), keys?.contains(press.key) ?? true, let action else { return .ignored }
        return action(press)
    }
}

// MARK: The tree's focus

extension TreeState {
    func register(_ b: FocusBindingNode) {
        if !focusBindings.contains(where: { $0.node === b }) { focusBindings.append(WeakFocusBinding(node: b)) }
    }

    /// Moves focus to `node` (nil clears it) and updates every `.focused` binding to match.
    func setFocus(_ node: Node?) {
        focused = node
        pruneBindings()
        let all = focusBindings.compactMap(\.node)
        // Clear first, then set, so an optional shared by several views ends on the new one.
        for b in all where !b.contains(node) { b.set(false) }
        for b in all where b.contains(node) { b.set(true) }
    }

    /// Brings focus in line with the `.focused` bindings after views changed
    /// them, and drops focus from a view that left the tree. Returns true
    /// when focus moved or a binding was written (views need evaluating).
    func syncFocus(root: Node?) -> Bool {
        // Gone from the tree, or no longer focusable (disabled).
        if let f = focused, !f.isMounted || !f.acceptsFocus || !isInside(f, root) { setFocus(nil); return true }
        var wrote = pruneBindings()
        let all = focusBindings.compactMap(\.node)
        // A binding set to its view: focus the first focusable view there.
        for b in all where b.isMe() && !b.contains(focused) {
            if let target = b.first(where: { $0.acceptsFocus }) {
                setFocus(target)
                return true
            }
            Logger("PolymerUI").warning(".focused(...) was set on a view with nothing focusable inside, so focus stays where it is. Add .focusable() to the view, or put .focused(...) on a Button or a focusable view.")
            b.set(false)
            wrote = true
        }
        // The binding of the view holding focus was cleared: focus leaves it.
        if let f = focused, all.contains(where: { $0.contains(f) && !$0.isMe() }) {
            setFocus(nil)
            return true
        }
        return wrote
    }

    /// Forgets bindings of views that left the tree; one that still claims focus is cleared first.
    @discardableResult
    private func pruneBindings() -> Bool {
        var wrote = false
        for w in focusBindings { if let b = w.node, !b.isMounted, b.isMe() { b.set(false); wrote = true } }
        focusBindings.removeAll { $0.node.map { !$0.isMounted } ?? true }
        return wrote
    }

    private func isInside(_ node: Node, _ root: Node?) -> Bool {
        var n: Node? = node
        while let x = n { if x === root { return true }; n = x.parent }
        return false
    }
}

struct WeakFocusBinding { weak var node: FocusBindingNode? }
