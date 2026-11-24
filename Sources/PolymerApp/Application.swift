// High-level application protocol and window runtime hosting a live ViewTree.
import PolymerBase
import PolymerPlatform
import PolymerRender
import PolymerUI

/// Top-level application contract for launching a native or headless Polymer window.
@MainActor
public protocol PolymerApplication {
    associatedtype Body: View
    var windowConfig: WindowConfig { get }
    var commands: CommandRegistry { get }
    var settings: SettingsStore { get }
    var backgroundColor: Color { get }
    @ViewBuilder func makeBody() -> Body
}

extension PolymerApplication {
    public var windowConfig: WindowConfig { WindowConfig() }
    public var backgroundColor: Color { Color(hex: 0x0A0A0B) }

    /// Creates a `WindowHost` bound to this application's body, commands, and settings.
    public func makeHost(environment: EnvironmentValues = EnvironmentValues()) -> WindowHost {
        WindowHost(application: self, environment: environment)
    }

    /// Launches this application using `runner` (or `Platform.windowRunner` when nil).
    @discardableResult
    public func run(
        environment: EnvironmentValues = EnvironmentValues(),
        runner: (any WindowRunner)? = nil
    ) throws -> WindowHost {
        let host = makeHost(environment: environment)
        try host.run(using: runner)
        return host
    }

    /// Static convenience entry point for launching a `PolymerApplication` instance.
    @discardableResult
    public static func run(
        _ application: Self,
        environment: EnvironmentValues = EnvironmentValues(),
        runner: (any WindowRunner)? = nil
    ) throws -> WindowHost {
        try application.run(environment: environment, runner: runner)
    }
}

/// Hosts a live `ViewTree`, routes platform `WindowEvent`s, dispatches `CommandRegistry`
/// shortcuts, and renders RGBA `FrameBuffer`s through any `WindowRunner`.
@MainActor
public final class WindowHost {
    public let tree: ViewTree
    public var windowConfig: WindowConfig
    public let commands: CommandRegistry
    public let settings: SettingsStore
    public var backgroundColor: Color

    public private(set) var isClosed: Bool = false
    public private(set) var frameCount: Int = 0
    public private(set) var lastEvent: WindowEvent? = nil

    public var needsAnimation: Bool { tree.hasActiveAnimations }

    public var windowOptions: WindowOptions {
        let width = max(1, Int(windowConfig.initialSize.width.rounded()))
        let height = max(1, Int(windowConfig.initialSize.height.rounded()))
        let minWidth = windowConfig.minSize.map { max(1, Int($0.width.rounded())) } ?? min(320, width)
        let minHeight = windowConfig.minSize.map { max(1, Int($0.height.rounded())) } ?? min(240, height)
        let darkGlass: Bool = switch windowConfig.backdrop {
        case .darkGlass, .mica, .vibrancy: true
        case .none, .lightGlass: false
        }
        return WindowOptions(
            title: windowConfig.title,
            width: width,
            height: height,
            resizable: windowConfig.resizable,
            darkGlass: darkGlass,
            minWidth: minWidth,
            minHeight: minHeight
        )
    }

    public init<Root: View>(
        windowConfig: WindowConfig = WindowConfig(),
        commands: CommandRegistry = CommandRegistry(),
        settings: SettingsStore = SettingsStore(),
        backgroundColor: Color = Color(hex: 0x0A0A0B),
        environment: EnvironmentValues = EnvironmentValues(),
        @ViewBuilder content: () -> Root
    ) {
        var env = environment
        if env.displayScale == 1 && windowConfig.scale != 1 {
            env.displayScale = windowConfig.scale
        }
        env.commandRegistry = commands
        env.settingsStore = settings

        let tree = ViewTree(content(), environment: env)
        tree.proposedSize = ProposedViewSize(windowConfig.initialSize)

        self.tree = tree
        self.windowConfig = windowConfig
        self.commands = commands
        self.settings = settings
        self.backgroundColor = backgroundColor
    }

    public convenience init<App: PolymerApplication>(
        application: App,
        environment: EnvironmentValues = EnvironmentValues()
    ) {
        self.init(
            windowConfig: application.windowConfig,
            commands: application.commands,
            settings: application.settings,
            backgroundColor: application.backgroundColor,
            environment: environment,
            content: { application.makeBody() }
        )
    }

    public init(
        tree: ViewTree,
        windowConfig: WindowConfig = WindowConfig(),
        commands: CommandRegistry = CommandRegistry(),
        settings: SettingsStore = SettingsStore(),
        backgroundColor: Color = Color(hex: 0x0A0A0B)
    ) {
        var env = tree.environment
        if env.displayScale == 1 && windowConfig.scale != 1 {
            env.displayScale = windowConfig.scale
        }
        env.commandRegistry = commands
        env.settingsStore = settings
        tree.environment = env
        if tree.proposedSize == .unspecified {
            tree.proposedSize = ProposedViewSize(windowConfig.initialSize)
        }

        self.tree = tree
        self.windowConfig = windowConfig
        self.commands = commands
        self.settings = settings
        self.backgroundColor = backgroundColor
    }

    /// Converts a platform `WindowKeyEvent` into a `PolymerUI.KeyPress`.
    public static func keyPress(from event: WindowKeyEvent) -> KeyPress? {
        let phase: KeyPress.Phases = !event.isDown ? .up : (event.isRepeat ? .repeat : .down)
        if var press = KeyPress(event.keyPressText) {
            press.phase = phase
            if !event.characters.isEmpty {
                press.characters = event.characters
            }
            return press
        }
        guard let ch = event.characters.first else { return nil }
        var mods: EventModifiers = []
        if event.shift { mods.insert(.shift) }
        if event.control { mods.insert(.control) }
        if event.option { mods.insert(.option) }
        if event.command { mods.insert(.command) }
        return KeyPress(
            key: KeyEquivalent(Character(String(ch).lowercased())),
            characters: event.characters,
            modifiers: mods,
            phase: phase
        )
    }

    /// Routes a single platform `WindowEvent` to `CommandRegistry` and `ViewTree`.
    public func handle(_ event: WindowEvent) {
        lastEvent = event
        switch event {
        case .resized(let size, let scale):
            tree.proposedSize = ProposedViewSize(size)
            if scale > 0 && tree.environment.displayScale != scale {
                tree.environment.displayScale = scale
            }
            tree.update()

        case .pointerMoved(let point):
            tree.pointerMoved(to: point)

        case .pointerDown(let point, let button):
            switch button {
            case .left:
                _ = tree.pointerDown(at: point)
            case .right:
                _ = tree.secondaryClick(at: point)
            case .middle:
                break
            }

        case .pointerUp(let point, let button):
            switch button {
            case .left:
                _ = tree.pointerUp(at: point)
            case .right, .middle:
                break
            }

        case .pointerExited:
            tree.pointerExited()

        case .scroll(let point, let dx, let dy):
            _ = tree.scroll(at: point, dx: dx, dy: dy)

        case .key(let keyEvent):
            guard let press = Self.keyPress(from: keyEvent) else { return }
            let hasShortcutModifier = !press.modifiers.intersection([.command, .control, .option]).isEmpty
            if hasShortcutModifier && press.phase == .down {
                if commands.handleKeyPress(press) {
                    return
                }
            }
            let handledByTree = tree.key(press)
            if !handledByTree && !hasShortcutModifier && press.phase == .down {
                _ = commands.handleKeyPress(press)
            }

        case .tick(let dt):
            _ = tree.tick(dt)

        case .closed:
            isClosed = true
            tree.dismissContextMenu()
            tree.pointerExited()
        }
    }

    /// Renders the current `ViewTree` into a straight-alpha RGBA `FrameBuffer`.
    public func renderFrame() -> FrameBuffer {
        let bitmap = tree.render(background: backgroundColor)
        frameCount += 1
        return FrameBuffer(width: bitmap.width, height: bitmap.height, pixels: bitmap.pixels)
    }

    /// Runs the window event/render loop using `runner` (or `Platform.windowRunner` when nil).
    public func run(using runner: (any WindowRunner)? = nil) throws {
        guard let activeRunner = runner ?? Platform.windowRunner else {
            throw WindowError(
                "No WindowRunner is installed. Pass a runner (for example HeadlessWindowRunner) or call Platform.installDesktop(windowRunner:)."
            )
        }
        isClosed = false
        try activeRunner.runWindow(
            options: windowOptions,
            onEvent: { [weak self] event in
                self?.handle(event)
            },
            renderFrame: { [weak self] in
                self?.renderFrame() ?? .empty
            },
            needsAnimation: { [weak self] in
                self?.needsAnimation ?? false
            }
        )
    }
}
