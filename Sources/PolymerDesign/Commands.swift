// The command system: every action an app offers, with an id, a title, a
// shortcut and whether it can run now. Right-click menus are built from
// commands (each component's own, then those of the views around it), and
// a `CommandRegistry` runs a command by id or by its shortcut, so agents
// and keyboards reach the same actions as the pointer.
import PolymerBase
import PolymerUI

/// One action: `Command("library.play", "Play", shortcut: KeyboardShortcut("p")) { player.play() }`.
public struct Command: Identifiable {
    /// Stable and unique in the app ("library.play"); agents run commands by it.
    public let id: String
    /// What a menu shows, in sentence case ("Play next").
    public var title: String
    public var shortcut: KeyboardShortcut?
    /// False when the command can't run now: menus show it dimmed, `run` refuses it.
    public var isEnabled: Bool
    public var action: @MainActor () -> Void

    public init(_ id: String, _ title: String, shortcut: KeyboardShortcut? = nil, isEnabled: Bool = true,
                action: @escaping @MainActor () -> Void) {
        self.id = id; self.title = title; self.shortcut = shortcut; self.isEnabled = isEnabled; self.action = action
    }

    /// True when `press` is this command's shortcut.
    public func matches(_ press: KeyPress) -> Bool {
        guard let s = shortcut, press.phase == .down, press.modifiers == s.modifiers else { return false }
        return press.key == s.key || press.key.character.lowercased() == s.key.character.lowercased()
    }
}

/// Builds a list of commands: `.commands { Command(...); Command(...) }`.
@resultBuilder
public enum CommandBuilder {
    public static func buildExpression(_ c: Command) -> [Command] { [c] }
    public static func buildExpression(_ cs: [Command]) -> [Command] { cs }
    public static func buildBlock(_ parts: [Command]...) -> [Command] { parts.flatMap { $0 } }
    public static func buildOptional(_ c: [Command]?) -> [Command] { c ?? [] }
    public static func buildEither(first c: [Command]) -> [Command] { c }
    public static func buildEither(second c: [Command]) -> [Command] { c }
    public static func buildArray(_ cs: [[Command]]) -> [Command] { cs.flatMap { $0 } }
}

/// The app's commands by id. Runs them by id (`run("library.play")`) and by
/// shortcut (`handle(press)`), and lists what is wrong with them (`problems`).
public final class CommandRegistry {
    /// Who registered a command. Held weakly: when the view that added a
    /// command leaves the tree, the command goes with it.
    private final class Owner {
        weak var object: AnyObject?
        init(_ object: AnyObject) { self.object = object }
    }

    private var list: [Command] = []
    private var index: [String: Int] = [:]
    private var owners: [String: Owner] = [:]

    public init() {}
    public convenience init(@CommandBuilder _ make: () -> [Command]) {
        self.init()
        register(make())
    }

    /// The commands whose view is still in the tree, in registration order.
    public var commands: [Command] {
        prune()
        return list
    }

    /// Adds a command, or replaces the one with the same id.
    public func register(_ command: Command) {
        owners[command.id] = nil
        if let i = index[command.id] { list[i] = command } else {
            index[command.id] = list.count
            list.append(command)
        }
    }

    public func register(_ list: [Command]) { for c in list { register(c) } }

    /// Adds commands on behalf of `owner`, so they can be taken away when it
    /// leaves the tree (`.commands` does this; apps rarely need to).
    public func register(_ list: [Command], owner: AnyObject) {
        let holder = Owner(owner)
        for c in list {
            register(c)
            owners[c.id] = holder
        }
    }

    /// Removes every command `owner` registered, unless someone has replaced
    /// it since.
    public func unregister(_ owner: AnyObject) {
        prune()
        let id = ObjectIdentifier(owner)
        let gone = list.filter { owners[$0.id]?.object.map(ObjectIdentifier.init) == id }.map(\.id)
        for commandID in gone { remove(commandID) }
    }

    /// Forgets commands whose view has left the tree.
    public func prune() {
        let gone = owners.compactMap { $0.value.object == nil ? $0.key : nil }
        for commandID in gone { remove(commandID) }
    }

    private func remove(_ id: String) {
        guard let i = index[id] else { return }
        list.remove(at: i)
        owners[id] = nil
        // The commands after `i` moved down one place.
        index = [:]
        for (k, c) in list.enumerated() { index[c.id] = k }
    }

    public func command(_ id: String) -> Command? {
        prune()
        return index[id].map { list[$0] }
    }

    /// Runs the command with `id`; false when there is none or it is disabled.
    @MainActor @discardableResult
    public func run(_ id: String) -> Bool {
        guard let c = command(id), c.isEnabled else { return false }
        c.action()
        return true
    }

    /// Runs the enabled command whose shortcut is `press`; false when none is.
    @MainActor @discardableResult
    public func handle(_ press: KeyPress) -> Bool {
        guard let c = commands.first(where: { $0.isEnabled && $0.matches(press) }) else { return false }
        c.action()
        return true
    }

    /// What breaks the house rules: titles in capitals or with `//`, shortcuts used twice.
    public var problems: [String] {
        var out: [String] = []
        var seen: [KeyboardShortcut: String] = [:]
        for c in commands {
            for p in DesignRules.problems(inTitle: c.title) { out.append("\(c.id): \(p)") }
            if let s = c.shortcut {
                if let other = seen[s] { out.append("\(c.id): shortcut \(s.description) is also \(other)'s") } else { seen[s] = c.id }
            }
        }
        return out
    }

    /// One line per command: id, title, shortcut, and "disabled" when so.
    public var description: String {
        commands.map { c in
            var line = "\(c.id) \"\(c.title)\""
            if let s = c.shortcut { line += " " + s.description }
            if !c.isEnabled { line += " disabled" }
            return line
        }.joined(separator: "\n")
    }
}

extension ViewTree {
    /// A key press for the window: the focused view and button shortcuts
    /// first, then the commands' shortcuts.
    @discardableResult
    public func key(_ press: KeyPress, commands: CommandRegistry) -> Bool {
        if key(press) { return true }
        return commands.handle(press)
    }

    @discardableResult
    public func key(_ text: String, commands: CommandRegistry) -> Bool {
        guard let press = KeyPress(text) else { return false }
        return key(press, commands: commands)
    }
}

/// Checks on titles, shared by the registry and the design checks.
public enum DesignRules {
    /// What is wrong with a title shown to people: empty, all capitals, a `//` prefix.
    public static func problems(inTitle title: String) -> [String] {
        var out: [String] = []
        let trimmed = title.drop { $0 == " " }   // a Substring
        if trimmed.isEmpty { out.append("the title is empty") }
        if trimmed.hasPrefix("//") { out.append("\"\(title)\" starts with //") }
        let letters = title.filter { $0.isLetter }
        // Three letters or more, so "OK" and "TV" pass.
        if letters.count >= 3, letters.allSatisfy({ $0.isUppercase }) { out.append("\"\(title)\" is in capitals; use sentence case") }
        return out
    }
}

struct CommandsKey: EnvironmentKey { static var defaultValue: [Command] { [] } }
struct CommandRegistryKey: EnvironmentKey { static var defaultValue: CommandRegistry? { nil } }

extension EnvironmentValues {
    /// The commands of the views around this one; components list them in their right-click menus.
    public var commands: [Command] {
        get { self[CommandsKey.self] }
        set { self[CommandsKey.self] = newValue }
    }
    /// The app's registry, if it has one (`.designRoot(commands:)`).
    public var commandRegistry: CommandRegistry? {
        get { self[CommandRegistryKey.self] }
        set { self[CommandRegistryKey.self] = newValue }
    }
}

extension View {
    /// Adds commands for this view: they open from a right-click anywhere in
    /// it, appear after each component's own commands inside it, and join the
    /// app's registry (by id, replacing older ones) so their shortcuts run
    /// through `ViewTree.key(_:commands:)`. They stay registered once shown.
    public func commands(@CommandBuilder _ make: () -> [Command]) -> some View {
        CommandScope(content: self, list: make())
    }

    public func commands(_ list: [Command]) -> some View { CommandScope(content: self, list: list) }
}

/// Adds commands to the environment and offers them on a right-click.
/// They join the app's registry while the view is in the tree and leave it
/// when the view goes.
public struct CommandScope<Content: View>: View {
    let content: Content
    let list: [Command]
    @Environment(\.commands) var inherited
    @Environment(\.commandRegistry) var registry
    @State private var registration = CommandOwnership()

    public var body: some View {
        let all = list + inherited
        let _ = registration.update(list: list, registry: registry)
        content
            .environment(\.commands, all)
            .contextMenu { CommandItems(commands: all) }
            .onDisappear { registration.unregister() }
    }
}

/// Holds the commands one scope registered, for exactly as long as the
/// scope's state lives: when the view leaves the tree they go with it.
final class CommandOwnership {
    private weak var registry: CommandRegistry?
    private var ids: [String] = []

    func update(list: [Command], registry: CommandRegistry?) {
        if self.registry !== registry {
            unregister()
            self.registry = registry
        }
        let ids = list.map(\.id)
        guard ids != self.ids else { return }
        unregister()
        registry?.register(list, owner: self)
        self.ids = ids
    }

    func unregister() {
        registry?.unregister(self)
        ids = []
    }

    deinit { registry?.unregister(self) }
}

/// Menu items for commands, in order, with their shortcuts; disabled ones dimmed.
public struct CommandItems: View {
    let commands: [Command]
    public init(commands: [Command]) { self.commands = commands }
    public var body: some View {
        ForEach(commands) { c in CommandItem(command: c) }
    }
}

/// One command as a menu item (or as a plain button outside a menu).
public struct CommandItem: View {
    let command: Command
    public init(command: Command) { self.command = command }
    public var body: some View {
        if let s = command.shortcut {
            Button(command.title, action: command.action)
                .keyboardShortcut(s.key, modifiers: s.modifiers)
                .disabled(!command.isEnabled)
        } else {
            Button(command.title, action: command.action)
                .disabled(!command.isEnabled)
        }
    }
}
