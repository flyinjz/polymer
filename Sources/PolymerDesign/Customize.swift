// Customize and element names. Every component has a stable path
// ("toolbar/play"): its parent's path and its own name. People change a
// component from its right-click menu (hide it, scale it, pick another
// style); the changes live in a `CustomizeModel` keyed by path that saves
// to and loads from JSON. A `DesignRegistry` lists every component by path,
// role, title and frame, so agents can find and drive them by name.
import PolymerBase
import PolymerUI

// MARK: Customizations

/// What a person changed on one component.
public struct ElementCustomization: Equatable, Sendable {
    public var hidden = false
    /// Multiplies the component's text, spacing and control sizes.
    public var scale = 1.0
    /// One of the component's styles; nil for the one the app chose.
    public var style: String?
    /// A width in points this component takes, whatever the app asked for.
    public var width: Double?
    /// A height in points this component takes, whatever the app asked for.
    public var height: Double?

    public init(hidden: Bool = false, scale: Double = 1, style: String? = nil,
                width: Double? = nil, height: Double? = nil) {
        self.hidden = hidden; self.scale = scale; self.style = style
        self.width = width; self.height = height
    }

    public var isDefault: Bool { !hidden && scale == 1 && style == nil && width == nil && height == nil }
}

/// Every customization in a window, by element path. Observable: components
/// redraw when theirs changes. Save with `json`, load with `init(json:)`.
@Observable
public final class CustomizeModel {
    public private(set) var elements: [String: ElementCustomization] = [:]

    /// The scales offered in the right-click menu.
    public static let scales: [Double] = [0.75, 0.9, 1, 1.1, 1.25, 1.5]

    public init() {}

    /// Loads what `json` saved. Unknown keys are ignored; values of the wrong
    /// type throw, saying where.
    public convenience init(json: JSON) throws(CustomizeError) {
        self.init()
        try load(json)
    }

    public subscript(path: String) -> ElementCustomization {
        get { elements[path] ?? ElementCustomization() }
        set { if newValue.isDefault { elements[path] = nil } else { elements[path] = newValue } }
    }

    public func setHidden(_ path: String, _ hidden: Bool) { self[path].hidden = hidden }
    public func setScale(_ path: String, _ scale: Double) { self[path].scale = scale }
    public func setStyle(_ path: String, _ style: String?) { self[path].style = style }
    /// Sets a width override in points; nil uses the app's width again.
    public func setWidth(_ path: String, _ width: Double?) { self[path].width = width }
    /// Sets a height override in points; nil uses the app's height again.
    public func setHeight(_ path: String, _ height: Double?) { self[path].height = height }
    public func reset(_ path: String) { elements[path] = nil }
    public func resetAll() { elements = [:] }

    /// Shows every hidden component again.
    public func showAll() {
        for (p, e) in elements where e.hidden { self[p].hidden = false }
    }

    public var hiddenPaths: [String] { elements.filter { $0.value.hidden }.map(\.key).sorted() }

    /// `{"version": 1, "elements": {"path": {"hidden": true, "scale": 1.25, "style": "plain"}}}`,
    /// defaults left out. Keys come out sorted, so equal models save equal text.
    public var json: JSON {
        var out: [String: JSON] = [:]
        for (path, e) in elements {
            var o: [String: JSON] = [:]
            if e.hidden { o["hidden"] = .bool(true) }
            if e.scale != 1 { o["scale"] = .number(e.scale) }
            if let s = e.style { o["style"] = .string(s) }
            if let w = e.width { o["width"] = .number(w) }
            if let h = e.height { o["height"] = .number(h) }
            out[path] = .object(o)
        }
        return .object(["version": .number(1), "elements": .object(out)])
    }

    /// Replaces every customization with what `json` holds.
    public func load(_ json: JSON) throws(CustomizeError) {
        guard let root = json.object else { throw CustomizeError("Customize data must be a JSON object with \"elements\".") }
        if let v = root["version"], v.int != 1 {
            throw CustomizeError("Customize data is version \(v.serialized); this Polymer reads version 1.")
        }
        var next: [String: ElementCustomization] = [:]
        for (path, value) in root["elements"]?.object ?? [:] {
            guard let o = value.object else { throw CustomizeError("\"\(path)\" must be an object such as {\"hidden\": true}.") }
            var e = ElementCustomization()
            if let h = o["hidden"] {
                guard let b = h.bool else { throw CustomizeError("\"\(path)\".hidden must be true or false.") }
                e.hidden = b
            }
            if let s = o["scale"] {
                guard let d = s.double, d > 0 else { throw CustomizeError("\"\(path)\".scale must be a number above 0, such as 1.25.") }
                e.scale = d
            }
            if let s = o["style"] {
                guard let t = s.string else { throw CustomizeError("\"\(path)\".style must be a style name, such as \"plain\".") }
                e.style = t
            }
            for (key, assign) in [("width", \ElementCustomization.width), ("height", \ElementCustomization.height)] {
                guard let v = o[key] else { continue }
                guard let d = v.double, d > 0 else {
                    throw CustomizeError("\"\(path)\".\(key) must be a number of points above 0.")
                }
                e[keyPath: assign] = d
            }
            if !e.isDefault { next[path] = e }
        }
        elements = next
    }
}

public struct CustomizeError: Error, Sendable, CustomStringConvertible {
    public let description: String
    init(_ d: String) { description = d }
}

// MARK: Element paths

public enum ElementPath {
    /// `parent/name`, or `name` at the root.
    public static func join(_ parent: String, _ name: String) -> String {
        parent.isEmpty ? name : parent + "/" + name
    }

    /// A name from a title: "Play Next" is "play-next". Letters and digits
    /// are kept (lowercased), runs of anything else become one "-".
    public static func slug(_ title: String) -> String {
        var out = ""
        var dash = false
        for ch in title {
            if ch.isLetter || ch.isNumber {
                if dash, !out.isEmpty { out.append("-") }
                dash = false
                out += ch.lowercased()
            } else {
                dash = true
            }
        }
        return out.isEmpty ? "element" : out
    }
}

/// Every component the tree has built, by path: role, title, styles, and
/// frame once laid out. Install one with `.designRoot(registry:)` to name
/// and drive components; without one nothing is recorded.
public final class DesignRegistry {
    public struct Entry: Equatable, Sendable {
        public let path: String
        /// What kind of component: "Button", "Toggle", "Slider".
        public let role: String
        public let title: String
        public let styles: [String]
        /// Where it is, in the tree's points; nil until laid out.
        public internal(set) var frame: Rect?
    }

    public private(set) var entries: [String: Entry] = [:]
    /// Paths built more than once since `reset()`: two components share a name.
    public private(set) var duplicates: [String] = []
    private var seen: Set<String> = []

    public init() {}

    /// Starts a new count for `duplicates` (call before building a fresh tree).
    public func reset() { entries = [:]; duplicates = []; seen = [] }

    func record(path: String, role: String, title: String, styles: [String]) {
        if !seen.insert(path).inserted, !duplicates.contains(path) { duplicates.append(path) }
        let frame = entries[path]?.frame
        entries[path] = Entry(path: path, role: role, title: title, styles: styles, frame: frame)
    }

    func place(_ path: String, _ frame: Rect) { entries[path]?.frame = frame }

    public func entry(_ path: String) -> Entry? { entries[path] }
    public func frame(of path: String) -> Rect? { entries[path]?.frame }
    public func center(of path: String) -> Point? { frame(of: path).map { Point(x: $0.midX, y: $0.midY) } }

    /// Paths, sorted.
    public var paths: [String] { entries.keys.sorted() }

    /// One line per component, sorted by path: `path Role "Title" (x, y, wxh)`.
    public var description: String {
        paths.map { p in
            let e = entries[p]!
            var line = "\(p) \(e.role) \"\(e.title)\""
            if let f = e.frame { line += " (\(f.minX), \(f.minY), \(f.width)x\(f.height))" }
            if e.styles.count > 1 { line += " styles: " + e.styles.joined(separator: ", ") }
            return line
        }.joined(separator: "\n")
    }
}

extension ViewTree {
    /// Clicks the middle of the component at `path`; false when it is not laid out.
    @discardableResult
    public func click(element path: String, in registry: DesignRegistry) -> Bool {
        _ = render()
        guard let p = registry.center(of: path) else { return false }
        return click(at: p)
    }

    /// Opens the right-click menu of the component at `path`.
    @discardableResult
    public func contextClick(element path: String, in registry: DesignRegistry) -> Bool {
        _ = render()
        guard let p = registry.center(of: path) else { return false }
        return contextClick(at: p)
    }
}

struct ElementPathKey: EnvironmentKey { static var defaultValue: String { "" } }
struct CustomizeModelKey: EnvironmentKey { static var defaultValue: CustomizeModel? { nil } }
struct DesignRegistryKey: EnvironmentKey { static var defaultValue: DesignRegistry? { nil } }

extension EnvironmentValues {
    /// The path of the component or `.element` this view is in ("" at the root).
    public var elementPath: String {
        get { self[ElementPathKey.self] }
        set { self[ElementPathKey.self] = newValue }
    }
    public var customizeModel: CustomizeModel? {
        get { self[CustomizeModelKey.self] }
        set { self[CustomizeModelKey.self] = newValue }
    }
    public var designRegistry: DesignRegistry? {
        get { self[DesignRegistryKey.self] }
        set { self[DesignRegistryKey.self] = newValue }
    }
}

extension View {
    /// Names a group: components inside get paths under `name` ("sidebar/library").
    public func element(_ name: String) -> some View { ElementScope(content: self, name: name) }

    /// Sets up the house look for a window: the theme (and the text font,
    /// colour and line colour from it), where customizations are kept, the
    /// app's commands, and a registry of components when agents need one.
    public func designRoot(theme: Theme, customize: CustomizeModel? = nil, commands: CommandRegistry? = nil,
                           registry: DesignRegistry? = nil) -> some View {
        self.environment(\.theme, theme)
            .environment(\.customizeModel, customize)
            .environment(\.commandRegistry, commands)
            .environment(\.designRegistry, registry)
            .environment(\.font, theme.font(.body))
            .environment(\.foregroundColor, theme.gray.text)
            .environment(\.separatorColor, theme.gray.line)
            // Menus, sheets, popovers and text fields take their look from the
            // same tokens, so every one matches the window's theme.
            .environment(\.panelLook, theme.panelLook)
            .environment(\.textInputLook, theme.textInputLook)
    }
}

/// Extends the element path for what is inside.
public struct ElementScope<Content: View>: View {
    let content: Content
    let name: String
    @Environment(\.elementPath) var parent
    public var body: some View { content.environment(\.elementPath, ElementPath.join(parent, name)) }
}

// MARK: Parts

/// A named piece of a component (a segment, a sidebar's detail area): it
/// gets a path and a frame in the registry, so agents can find and click it,
/// but no menu of its own; right-clicking it opens its component's menu.
public struct Part<Content: View>: View {
    let name: String
    let role: String
    let title: String
    let content: Content
    @Environment(\.elementPath) var parent
    @Environment(\.designRegistry) var registry

    public init(name: String? = nil, role: String, title: String, @ViewBuilder content: () -> Content) {
        self.name = name ?? ElementPath.slug(title); self.role = role; self.title = title; self.content = content()
    }

    public var body: some View {
        let path = ElementPath.join(parent, name)
        let _ = registry?.record(path: path, role: role, title: title, styles: [])
        located(content, path: path, registry: registry).environment(\.elementPath, path)
    }
}

@MainActor @ViewBuilder
func sized<V: View>(_ v: V, _ custom: ElementCustomization) -> some View {
    if custom.width != nil || custom.height != nil {
        v.frame(width: custom.width, height: custom.height)
    } else {
        v
    }
}

/// `v`, reporting its frame to `registry` when there is one.
@MainActor @ViewBuilder
func located<V: View>(_ v: V, path: String, registry: DesignRegistry?) -> some View {
    if let registry {
        v.background(GeometryReader { p in
            let _ = registry.place(path, p.frame(in: .global))
            Color.clear
        })
    } else {
        v
    }
}

// MARK: Component

/// What a component's content is built with.
public struct ComponentInfo {
    /// Its full path ("toolbar/play").
    public let path: String
    /// The style to draw: what Customize picked, else the app's.
    public let style: String
    /// The theme, scaled by Customize.
    public let theme: Theme
}

/// The core every component is built on (apps use it for their own): a
/// stable path, Customize (hide, scale, style) and a right-click menu of the
/// component's commands, the commands around it, and Customize.
///
///     Component(name: "play", role: "Button", title: "Play") { info in ... }
public struct Component<Content: View>: View {
    let name: String
    let role: String
    let title: String
    let styles: [String]
    let defaultStyle: String
    let own: [Command]
    let content: (ComponentInfo) -> Content

    @Environment(\.theme) var theme
    @Environment(\.elementPath) var parent
    @Environment(\.customizeModel) var model
    @Environment(\.commands) var inherited
    @Environment(\.designRegistry) var registry
    /// Customizations when the window keeps no model (not saved; hiding needs a model).
    @State var local = ElementCustomization()

    /// `name` defaults to the title's slug; `styles` are what Customize offers.
    public init(name: String? = nil, role: String, title: String, styles: [String] = [], defaultStyle: String? = nil,
                commands: [Command] = [], @ViewBuilder content: @escaping (ComponentInfo) -> Content) {
        self.name = name ?? ElementPath.slug(title)
        self.role = role
        self.title = title
        self.styles = styles
        self.defaultStyle = defaultStyle ?? styles.first ?? ""
        self.own = commands
        self.content = content
    }

    public var body: some View {
        let path = ElementPath.join(parent, name)
        let custom = model?[path] ?? local
        if !custom.hidden {
            let t = theme.scaled(by: custom.scale)
            let style = custom.style.flatMap { styles.contains($0) ? $0 : nil } ?? defaultStyle
            let _ = registry?.record(path: path, role: role, title: title, styles: styles)
            located(sized(content(ComponentInfo(path: path, style: style, theme: t)), custom), path: path, registry: registry)
                .environment(\.theme, t)
                .environment(\.elementPath, path)
                .contextMenu { menu(path: path, custom: custom, style: style) }
        }
    }

    @ViewBuilder
    func menu(path: String, custom: ElementCustomization, style: String) -> some View {
        let commands = own + inherited
        CommandItems(commands: commands)
        if !commands.isEmpty { Divider() }
        Menu("Customize") { customizeItems(path: path, custom: custom, style: style) }
    }

    @ViewBuilder
    func customizeItems(path: String, custom: ElementCustomization, style: String) -> some View {
        let store = self.model
        let fallback = self.$local
        let defaultStyle = self.defaultStyle
        if let store {
            Button("Hide") { store.setHidden(path, true) }
        }
        Menu("Size") {
            ForEach(CustomizeModel.scales, id: \.self) { s in
                Button("\(Int((s * 100).rounded()))%") {
                    if let store { store.setScale(path, s) } else { fallback.wrappedValue.scale = s }
                }
                .disabled(s == custom.scale)
            }
        }
        if styles.count > 1 {
            Menu("Style") {
                ForEach(styles, id: \.self) { s in
                    Button(Self.styleTitle(s)) {
                        let v: String? = s == defaultStyle ? nil : s
                        if let store { store.setStyle(path, v) } else { fallback.wrappedValue.style = v }
                    }
                    .disabled(s == style)
                }
            }
        }
        Divider()
        Button("Reset") {
            if let store { store.reset(path) } else { fallback.wrappedValue = ElementCustomization() }
        }
        .disabled(custom.isDefault)
        if let store, !store.hiddenPaths.isEmpty {
            Button("Show hidden items") { store.showAll() }
        }
    }

    /// "primary" is "Primary".
    static func styleTitle(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
}
