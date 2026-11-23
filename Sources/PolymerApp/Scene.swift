// Scenes, window configuration, and the named screen registry used by apps and headless tools.
import PolymerBase
import PolymerRender
import PolymerUI

/// Native or composited window backdrop material.
public enum WindowBackdrop: String, CaseIterable, Equatable, Hashable, Sendable {
    case none
    case darkGlass
    case lightGlass
    case mica
    case vibrancy
}

/// Declarative configuration for an application window.
public struct WindowConfig: Equatable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var initialSize: Size
    public var minSize: Size?
    public var maxSize: Size?
    public var resizable: Bool
    public var titleBarHidden: Bool
    public var backdrop: WindowBackdrop
    public var scale: Double

    public init(
        id: String = "main",
        title: String = "Polymer",
        initialSize: Size = Size(width: 960, height: 640),
        minSize: Size? = nil,
        maxSize: Size? = nil,
        resizable: Bool = true,
        titleBarHidden: Bool = false,
        backdrop: WindowBackdrop = .darkGlass,
        scale: Double = 1
    ) {
        self.id = id
        self.title = title
        self.initialSize = initialSize
        self.minSize = minSize
        self.maxSize = maxSize
        self.resizable = resizable
        self.titleBarHidden = titleBarHidden
        self.backdrop = backdrop
        self.scale = max(1, scale)
    }

    public func toJSON() -> JSON {
        var obj: [String: JSON] = [
            "id": .string(id),
            "title": .string(title),
            "initialSize": .object(["width": .number(initialSize.width), "height": .number(initialSize.height)]),
            "resizable": .bool(resizable),
            "titleBarHidden": .bool(titleBarHidden),
            "backdrop": .string(backdrop.rawValue),
            "scale": .number(scale),
        ]
        if let minSize {
            obj["minSize"] = .object(["width": .number(minSize.width), "height": .number(minSize.height)])
        }
        if let maxSize {
            obj["maxSize"] = .object(["width": .number(maxSize.width), "height": .number(maxSize.height)])
        }
        return .object(obj)
    }
}

/// A top-level scene describing a window, its commands, and how to build its live view tree.
@MainActor
public protocol Scene {
    var windowConfig: WindowConfig { get }
    var commands: CommandRegistry { get }
    func makeTree(environment: EnvironmentValues) -> ViewTree
}

/// A standard single- or multi-instance application window scene.
@MainActor
public struct WindowGroup<Content: View>: Scene {
    public let windowConfig: WindowConfig
    public let commands: CommandRegistry
    private let rootBuilder: @MainActor () -> Content

    public init(
        id: String = "main",
        title: String,
        initialSize: Size = Size(width: 960, height: 640),
        minSize: Size? = nil,
        maxSize: Size? = nil,
        resizable: Bool = true,
        titleBarHidden: Bool = false,
        backdrop: WindowBackdrop = .darkGlass,
        scale: Double = 1,
        commands: CommandRegistry = CommandRegistry(),
        @ViewBuilder content: @escaping @MainActor () -> Content
    ) {
        self.windowConfig = WindowConfig(
            id: id,
            title: title,
            initialSize: initialSize,
            minSize: minSize,
            maxSize: maxSize,
            resizable: resizable,
            titleBarHidden: titleBarHidden,
            backdrop: backdrop,
            scale: scale
        )
        self.commands = commands
        self.rootBuilder = content
    }

    public init(
        config: WindowConfig,
        commands: CommandRegistry = CommandRegistry(),
        @ViewBuilder content: @escaping @MainActor () -> Content
    ) {
        self.windowConfig = config
        self.commands = commands
        self.rootBuilder = content
    }

    /// Builds a live `ViewTree` configured with the scene's scale, size, and `CommandRegistry`.
    public func makeTree(environment: EnvironmentValues = EnvironmentValues()) -> ViewTree {
        var env = environment
        if env.displayScale == 1 && windowConfig.scale != 1 {
            env.displayScale = windowConfig.scale
        }
        if env.commandRegistry == nil {
            env.commandRegistry = commands
        }
        let tree = ViewTree(rootBuilder(), environment: env)
        tree.proposedSize = ProposedViewSize(windowConfig.initialSize)
        return tree
    }

    /// Builds a live `ViewTree` overriding size and/or display scale.
    public func makeTree(
        size: Size?,
        scale: Double?,
        environment: EnvironmentValues = EnvironmentValues()
    ) -> ViewTree {
        var env = environment
        if let scale { env.displayScale = scale }
        else if env.displayScale == 1 && windowConfig.scale != 1 { env.displayScale = windowConfig.scale }
        if env.commandRegistry == nil { env.commandRegistry = commands }
        let tree = ViewTree(rootBuilder(), environment: env)
        tree.proposedSize = ProposedViewSize(size ?? windowConfig.initialSize)
        return tree
    }
}

/// Metadata and factory for a named screen registered for headless rendering, inspection, and tooling.
@MainActor
public struct ScreenDescriptor {
    public let name: String
    public let description: String
    public let defaultSize: Size
    public let defaultScale: Double
    public let makeTree: @MainActor (Size, Double) -> ViewTree

    public init(
        name: String,
        description: String = "",
        defaultSize: Size = Size(width: 640, height: 480),
        defaultScale: Double = 1,
        makeTree: @escaping @MainActor (Size, Double) -> ViewTree
    ) {
        self.name = name
        self.description = description
        self.defaultSize = defaultSize
        self.defaultScale = max(1, defaultScale)
        self.makeTree = makeTree
    }

    public init<V: View>(
        name: String,
        description: String = "",
        defaultSize: Size = Size(width: 640, height: 480),
        defaultScale: Double = 1,
        @ViewBuilder content: @escaping @MainActor () -> V
    ) {
        self.init(
            name: name,
            description: description,
            defaultSize: defaultSize,
            defaultScale: defaultScale
        ) { size, scale in
            var env = EnvironmentValues()
            env.displayScale = scale
            let tree = ViewTree(content(), environment: env)
            tree.proposedSize = ProposedViewSize(size)
            return tree
        }
    }

    public func metadataJSON() -> JSON {
        .object([
            "name": .string(name),
            "description": .string(description),
            "defaultSize": .object(["width": .number(defaultSize.width), "height": .number(defaultSize.height)]),
            "defaultScale": .number(defaultScale),
        ])
    }
}

/// Registry of named screens for headless rendering, inspection, and `polymer` CLI tooling.
@MainActor
public final class ScreenRegistry {
    private var screens: [String: ScreenDescriptor] = [:]

    public init() {}

    public func register(_ descriptor: ScreenDescriptor) {
        screens[descriptor.name] = descriptor
    }

    public func register<V: View>(
        name: String,
        description: String = "",
        defaultSize: Size = Size(width: 640, height: 480),
        defaultScale: Double = 1,
        @ViewBuilder content: @escaping @MainActor () -> V
    ) {
        register(ScreenDescriptor(
            name: name,
            description: description,
            defaultSize: defaultSize,
            defaultScale: defaultScale,
            content: content
        ))
    }

    public func unregister(_ name: String) {
        screens.removeValue(forKey: name)
    }

    public func screen(named name: String) -> ScreenDescriptor? {
        screens[name]
    }

    /// All registered screen names, sorted deterministically.
    public var names: [String] {
        screens.keys.sorted()
    }

    /// All registered screens, sorted deterministically by name.
    public var allScreens: [ScreenDescriptor] {
        names.compactMap { screens[$0] }
    }

    /// Builds a live `ViewTree` for the named screen using its defaults unless overridden.
    public func makeTree(named name: String, size: Size? = nil, scale: Double? = nil) -> ViewTree? {
        guard let descriptor = screens[name] else { return nil }
        return descriptor.makeTree(size ?? descriptor.defaultSize, scale ?? descriptor.defaultScale)
    }

    /// Renders a named screen headlessly to a `Bitmap`.
    public func render(
        named name: String,
        size: Size? = nil,
        scale: Double? = nil,
        background: Color = .clear
    ) -> Bitmap? {
        guard let tree = makeTree(named: name, size: size, scale: scale) else { return nil }
        return tree.render(background: background)
    }

    /// Dumps the element tree of a named screen.
    public func elementTree(named name: String, size: Size? = nil, scale: Double? = nil) -> String? {
        guard let tree = makeTree(named: name, size: size, scale: scale) else { return nil }
        return tree.elementTree
    }

    /// Deterministic JSON description of all registered screens.
    public func describeJSON() -> JSON {
        .array(allScreens.map { $0.metadataJSON() })
    }
}
