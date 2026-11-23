// Unified command system: one definition drives menus, buttons, keyboard
// shortcuts, context menus, and `polymer describe`.
import Observation
import PolymerBase
import PolymerUI

/// A keyboard shortcut pairing a key equivalent with modifier keys.
public struct KeyShortcut: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var key: KeyEquivalent
    public var modifiers: EventModifiers

    public init(_ key: KeyEquivalent, modifiers: EventModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Parses a shortcut string such as `"cmd+k"`, `"ctrl+shift+s"`, or `"space"`.
    public init?(_ text: String) {
        guard let press = KeyPress(text) else { return nil }
        self.key = press.key
        self.modifiers = press.modifiers
    }

    /// True when `press` matches this shortcut on key-down.
    public func matches(_ press: KeyPress) -> Bool {
        guard press.phase == .down else { return false }
        return press.key == key && press.modifiers == modifiers
    }

    /// Deterministic human-readable label such as `"Cmd+K"` or `"Ctrl+Shift+S"`.
    public var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.option) { parts.append("Alt") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.command) { parts.append("Cmd") }
        parts.append(Self.keyDisplayName(key))
        return parts.joined(separator: "+")
    }

    public var description: String { displayString }

    private static func keyDisplayName(_ key: KeyEquivalent) -> String {
        switch key {
        case .upArrow: return "Up"
        case .downArrow: return "Down"
        case .leftArrow: return "Left"
        case .rightArrow: return "Right"
        case .deleteForward: return "Del"
        case .home: return "Home"
        case .end: return "End"
        case .pageUp: return "PageUp"
        case .pageDown: return "PageDown"
        case .clear: return "Clear"
        case .escape: return "Esc"
        case .delete: return "Backspace"
        case .tab: return "Tab"
        case .space: return "Space"
        case .return: return "Return"
        default:
            let s = String(key.character)
            return s.uppercased()
        }
    }
}

/// Stable identifier for a registered command (for example `"file.save"` or `"playback.toggle"`).
public struct CommandID: Equatable, Hashable, Sendable, Comparable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public static func < (lhs: CommandID, rhs: CommandID) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }
}

/// A single executable user action with title, shortcut, enabled/checked state, and handler.
public struct Command: Identifiable, Sendable {
    public let id: CommandID
    public let title: String
    public let category: String
    public let shortcut: KeyShortcut?
    public let icon: String?
    public let isEnabled: @MainActor @Sendable () -> Bool
    public let isChecked: (@MainActor @Sendable () -> Bool)?
    public let perform: @MainActor @Sendable () -> Void

    public init(
        id: CommandID,
        title: String,
        category: String = "General",
        shortcut: KeyShortcut? = nil,
        icon: String? = nil,
        isEnabled: @escaping @MainActor @Sendable () -> Bool = { true },
        isChecked: (@MainActor @Sendable () -> Bool)? = nil,
        perform: @escaping @MainActor @Sendable () -> Void
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.shortcut = shortcut
        self.icon = icon
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.perform = perform
    }
}

/// An entry in a `CommandGroup` (either a command reference or a visual separator).
public enum CommandMenuItem: Equatable, Hashable, Sendable {
    case command(CommandID)
    case separator
}

/// A named menu or context-menu group of commands and separators.
public struct CommandGroup: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    public var items: [CommandMenuItem]

    public init(id: String, title: String, items: [CommandMenuItem]) {
        self.id = id
        self.title = title
        self.items = items
    }

    public init(id: String, title: String, commands: [CommandID]) {
        self.id = id
        self.title = title
        self.items = commands.map { .command($0) }
    }
}

/// Snapshot of a menu item resolved against a `CommandRegistry` for menus and context menus.
public struct ResolvedMenuItem: Equatable, Hashable, Sendable {
    public enum Kind: Equatable, Hashable, Sendable {
        case command(
            id: CommandID,
            title: String,
            shortcut: String?,
            icon: String?,
            isEnabled: Bool,
            isChecked: Bool?
        )
        case separator
    }

    public let kind: Kind

    public init(_ kind: Kind) { self.kind = kind }
}

/// Structured command descriptor exported for `polymer describe` and tooling.
public struct CommandMetadata: Equatable, Hashable, Sendable {
    public let id: CommandID
    public let title: String
    public let category: String
    public let shortcut: String?
    public let icon: String?
    public let isEnabled: Bool
    public let isChecked: Bool?

    public init(
        id: CommandID,
        title: String,
        category: String,
        shortcut: String?,
        icon: String?,
        isEnabled: Bool,
        isChecked: Bool?
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.shortcut = shortcut
        self.icon = icon
        self.isEnabled = isEnabled
        self.isChecked = isChecked
    }

    public func toJSON() -> JSON {
        var obj: [String: JSON] = [
            "id": .string(id.rawValue),
            "title": .string(title),
            "category": .string(category),
            "isEnabled": .bool(isEnabled),
        ]
        if let shortcut { obj["shortcut"] = .string(shortcut) }
        if let icon { obj["icon"] = .string(icon) }
        if let isChecked { obj["isChecked"] = .bool(isChecked) }
        return .object(obj)
    }
}

/// Central registry of commands and menu groups for an app or window.
@MainActor
@Observable
public final class CommandRegistry: Equatable {
    private var commandsByID: [CommandID: Command] = [:]
    private var commandOrder: [CommandID] = []
    private var groupsByID: [String: CommandGroup] = [:]
    private var groupOrder: [String] = []

    /// Incremented whenever commands or groups change so observing views refresh.
    public private(set) var revision: Int = 0

    public init() {}

    nonisolated public static func == (lhs: CommandRegistry, rhs: CommandRegistry) -> Bool {
        lhs === rhs
    }

    // MARK: Registration

    public func register(_ command: Command) {
        if commandsByID[command.id] == nil {
            commandOrder.append(command.id)
        }
        commandsByID[command.id] = command
        revision += 1
    }

    public func register(_ commands: [Command]) {
        guard !commands.isEmpty else { return }
        for command in commands {
            if commandsByID[command.id] == nil {
                commandOrder.append(command.id)
            }
            commandsByID[command.id] = command
        }
        revision += 1
    }

    public func unregister(_ id: CommandID) {
        guard commandsByID.removeValue(forKey: id) != nil else { return }
        commandOrder.removeAll { $0 == id }
        revision += 1
    }

    public func registerGroup(_ group: CommandGroup) {
        if groupsByID[group.id] == nil {
            groupOrder.append(group.id)
        }
        groupsByID[group.id] = group
        revision += 1
    }

    public func unregisterGroup(_ id: String) {
        guard groupsByID.removeValue(forKey: id) != nil else { return }
        groupOrder.removeAll { $0 == id }
        revision += 1
    }

    // MARK: Queries

    public func command(for id: CommandID) -> Command? {
        _ = revision
        return commandsByID[id]
    }

    /// All registered commands in registration order.
    public var allCommands: [Command] {
        _ = revision
        return commandOrder.compactMap { commandsByID[$0] }
    }

    /// All registered commands sorted deterministically by category then ID.
    public var sortedCommands: [Command] {
        allCommands.sorted {
            if $0.category != $1.category { return $0.category < $1.category }
            return $0.id < $1.id
        }
    }

    /// Registered commands belonging to `category`, in registration order.
    public func commands(inCategory category: String) -> [Command] {
        allCommands.filter { $0.category == category }
    }

    /// Sorted list of distinct command categories.
    public var categories: [String] {
        var seen = Set<String>()
        for cmd in allCommands { seen.insert(cmd.category) }
        return seen.sorted()
    }

    public func group(for id: String) -> CommandGroup? {
        _ = revision
        return groupsByID[id]
    }

    public var allGroups: [CommandGroup] {
        _ = revision
        return groupOrder.compactMap { groupsByID[$0] }
    }

    // MARK: Execution & Shortcuts

    /// Executes the command with `id` if registered and enabled. Returns true when executed.
    @discardableResult
    public func execute(_ id: CommandID) -> Bool {
        guard let cmd = commandsByID[id], cmd.isEnabled() else { return false }
        cmd.perform()
        return true
    }

    /// Finds the first registered command whose shortcut matches `press` (preferring enabled commands).
    public func command(matching press: KeyPress) -> Command? {
        _ = revision
        var fallback: Command?
        for id in commandOrder {
            guard let cmd = commandsByID[id], let shortcut = cmd.shortcut, shortcut.matches(press) else { continue }
            if cmd.isEnabled() { return cmd }
            if fallback == nil { fallback = cmd }
        }
        return fallback
    }

    /// Dispatches `press` to a matching enabled command. Returns true when handled.
    @discardableResult
    public func handleKeyPress(_ press: KeyPress) -> Bool {
        guard let cmd = command(matching: press), cmd.isEnabled() else { return false }
        cmd.perform()
        return true
    }

    // MARK: Menus & Self-Description

    /// Resolves a registered group into display-ready menu items.
    public func menuItems(forGroup groupID: String) -> [ResolvedMenuItem] {
        guard let group = group(for: groupID) else { return [] }
        return resolve(group.items)
    }

    /// Resolves an explicit list of command IDs into menu items.
    public func menuItems(forCommandIDs ids: [CommandID]) -> [ResolvedMenuItem] {
        resolve(ids.map { .command($0) })
    }

    /// Resolves a list of `CommandMenuItem` entries against the registry.
    public func resolve(_ items: [CommandMenuItem]) -> [ResolvedMenuItem] {
        var out: [ResolvedMenuItem] = []
        for item in items {
            switch item {
            case .separator:
                out.append(ResolvedMenuItem(.separator))
            case .command(let id):
                guard let cmd = commandsByID[id] else { continue }
                out.append(ResolvedMenuItem(.command(
                    id: cmd.id,
                    title: cmd.title,
                    shortcut: cmd.shortcut?.displayString,
                    icon: cmd.icon,
                    isEnabled: cmd.isEnabled(),
                    isChecked: cmd.isChecked?()
                )))
            }
        }
        return out
    }

    /// Returns the registered commands belonging to a group (omitting separators).
    public func commands(inGroup groupID: String) -> [Command] {
        guard let group = group(for: groupID) else { return [] }
        return group.items.compactMap { item in
            guard case .command(let id) = item else { return nil }
            return commandsByID[id]
        }
    }

    /// Structured metadata for all commands, sorted deterministically for `polymer describe`.
    public func describe() -> [CommandMetadata] {
        sortedCommands.map { cmd in
            CommandMetadata(
                id: cmd.id,
                title: cmd.title,
                category: cmd.category,
                shortcut: cmd.shortcut?.displayString,
                icon: cmd.icon,
                isEnabled: cmd.isEnabled(),
                isChecked: cmd.isChecked?()
            )
        }
    }

    /// Deterministic JSON export of all commands and groups for `polymer describe`.
    public func describeJSON() -> JSON {
        let cmdJSON = describe().map { $0.toJSON() }
        let grpJSON: [JSON] = allGroups.sorted { $0.id < $1.id }.map { group in
            let entries: [JSON] = group.items.map { item in
                switch item {
                case .separator: return .string("---")
                case .command(let id): return .string(id.rawValue)
                }
            }
            return .object([
                "id": .string(group.id),
                "title": .string(group.title),
                "items": .array(entries),
            ])
        }
        return .object([
            "commands": .array(cmdJSON),
            "groups": .array(grpJSON),
        ])
    }
}

// MARK: Environment Integration

private enum CommandRegistryKey: EnvironmentKey {
    static var defaultValue: CommandRegistry? { nil }
}

extension EnvironmentValues {
    public var commandRegistry: CommandRegistry? {
        get { self[CommandRegistryKey.self] }
        set { self[CommandRegistryKey.self] = newValue }
    }
}

extension View {
    public func commandRegistry(_ registry: CommandRegistry?) -> some View {
        environment(\.commandRegistry, registry)
    }
}
