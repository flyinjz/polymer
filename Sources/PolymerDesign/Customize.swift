// Built-in Customize engine: per-element overrides for visibility, scale, offset,
// colours, padding, and corner radius keyed by `#id` or deterministic `Node.stablePath`.
import Observation
import PolymerApp
import PolymerBase
import PolymerUI

/// Per-element user customization overrides, deterministically serializable to JSON.
public struct ElementCustomization: Equatable, Hashable, Sendable {
    public static let minScale: Double = 0.5
    public static let maxScale: Double = 2.0

    public var isHidden: Bool
    public var scale: Double
    public var offset: Point
    public var foregroundColor: Color?
    public var backgroundColor: Color?
    public var accentColor: Color?
    public var paddingOverride: EdgeInsets?
    public var cornerRadiusOverride: Double?

    public init(
        isHidden: Bool = false,
        scale: Double = 1.0,
        offset: Point = .zero,
        foregroundColor: Color? = nil,
        backgroundColor: Color? = nil,
        accentColor: Color? = nil,
        paddingOverride: EdgeInsets? = nil,
        cornerRadiusOverride: Double? = nil
    ) {
        self.isHidden = isHidden
        self.scale = Self.clampScale(scale)
        self.offset = offset
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
        self.accentColor = accentColor
        self.paddingOverride = paddingOverride
        self.cornerRadiusOverride = cornerRadiusOverride
    }

    public static let `default` = ElementCustomization()

    public var isDefault: Bool { self == .default }

    public static func clampScale(_ value: Double) -> Double {
        min(max(value, minScale), maxScale)
    }

    // MARK: Deterministic JSON Serialization

    public func toJSON() -> JSON {
        var obj: [String: JSON] = [:]
        if isHidden { obj["isHidden"] = .bool(true) }
        if scale != 1.0 { obj["scale"] = .number(scale) }
        if offset != .zero {
            obj["offset"] = .object(["x": .number(offset.x), "y": .number(offset.y)])
        }
        if let fg = foregroundColor { obj["foregroundColor"] = Self.colorToJSON(fg) }
        if let bg = backgroundColor { obj["backgroundColor"] = Self.colorToJSON(bg) }
        if let acc = accentColor { obj["accentColor"] = Self.colorToJSON(acc) }
        if let pad = paddingOverride {
            obj["paddingOverride"] = .object([
                "top": .number(pad.top),
                "leading": .number(pad.leading),
                "bottom": .number(pad.bottom),
                "trailing": .number(pad.trailing),
            ])
        }
        if let cr = cornerRadiusOverride { obj["cornerRadiusOverride"] = .number(cr) }
        return .object(obj)
    }

    public static func fromJSON(_ json: JSON) -> ElementCustomization? {
        guard let obj = json.object else { return nil }
        let isHidden = obj["isHidden"]?.bool ?? false
        let scale = clampScale(obj["scale"]?.double ?? 1.0)
        var offset = Point.zero
        if let off = obj["offset"]?.object, let x = off["x"]?.double, let y = off["y"]?.double {
            offset = Point(x: x, y: y)
        }
        let fg = obj["foregroundColor"].flatMap(colorFromJSON)
        let bg = obj["backgroundColor"].flatMap(colorFromJSON)
        let acc = obj["accentColor"].flatMap(colorFromJSON)
        var pad: EdgeInsets? = nil
        if let p = obj["paddingOverride"]?.object,
           let top = p["top"]?.double,
           let leading = p["leading"]?.double,
           let bottom = p["bottom"]?.double,
           let trailing = p["trailing"]?.double {
            pad = EdgeInsets(top: top, leading: leading, bottom: bottom, trailing: trailing)
        }
        let cr = obj["cornerRadiusOverride"]?.double
        return ElementCustomization(
            isHidden: isHidden,
            scale: scale,
            offset: offset,
            foregroundColor: fg,
            backgroundColor: bg,
            accentColor: acc,
            paddingOverride: pad,
            cornerRadiusOverride: cr
        )
    }

    private static func colorToJSON(_ c: Color) -> JSON {
        .object([
            "r": .number(c.red),
            "g": .number(c.green),
            "b": .number(c.blue),
            "a": .number(c.opacity),
        ])
    }

    private static func colorFromJSON(_ json: JSON) -> Color? {
        guard let o = json.object,
              let r = o["r"]?.double,
              let g = o["g"]?.double,
              let b = o["b"]?.double else { return nil }
        let a = o["a"]?.double ?? 1.0
        return Color(red: r, green: g, blue: b, opacity: a)
    }
}

/// Observable store of element customizations and live Customize-mode state.
@MainActor
@Observable
public final class CustomizeState: Equatable {
    /// True when the user is actively inspecting/editing layout and styles in Customize mode.
    public var isCustomizing: Bool = false
    /// Currently selected target key while Customize mode is active.
    public var selectedTarget: String? = nil
    /// Monotonic counter incremented on every override change so views refresh deterministically.
    public private(set) var revision: Int = 0

    private var overrides: [String: ElementCustomization] = [:]

    public init() {}

    nonisolated public static func == (lhs: CustomizeState, rhs: CustomizeState) -> Bool {
        lhs === rhs
    }

    /// Chooses the canonical stable key: prefers `#id` when an accessibility identifier is set,
    /// falling back to `Node.stablePath`.
    public static func targetKey(id: String?, stablePath: String) -> String {
        if let id, !id.isEmpty {
            return id.hasPrefix("#") ? id : "#\(id)"
        }
        return stablePath
    }

    /// All customized target keys, sorted deterministically.
    public var targetKeys: [String] {
        _ = revision
        return overrides.keys.sorted()
    }

    /// Snapshot of all non-default overrides.
    public var allOverrides: [String: ElementCustomization] {
        _ = revision
        return overrides
    }

    /// Returns the customization for `key` (or `.default` if none is stored).
    public func customization(for key: String) -> ElementCustomization {
        _ = revision
        if let direct = overrides[key] { return direct }
        if !key.hasPrefix("#"), let anchored = overrides["#\(key)"] { return anchored }
        if key.hasPrefix("#"), let bare = overrides[String(key.dropFirst())] { return bare }
        return .default
    }

    /// Replaces the customization for `key`. Setting `.default` removes the override.
    public func set(_ customization: ElementCustomization, for key: String) {
        var clamped = customization
        clamped.scale = ElementCustomization.clampScale(clamped.scale)
        let storageKey = resolveExistingKey(for: key)
        if clamped.isDefault {
            if overrides.removeValue(forKey: storageKey) != nil {
                revision += 1
            }
        } else if overrides[storageKey] != clamped {
            overrides[storageKey] = clamped
            revision += 1
        }
    }

    public func hide(_ key: String) {
        var c = customization(for: key)
        c.isHidden = true
        set(c, for: key)
    }

    public func unhide(_ key: String) {
        var c = customization(for: key)
        c.isHidden = false
        set(c, for: key)
    }

    public func setScale(_ scale: Double, for key: String) {
        var c = customization(for: key)
        c.scale = ElementCustomization.clampScale(scale)
        set(c, for: key)
    }

    public func setOffset(_ offset: Point, for key: String) {
        var c = customization(for: key)
        c.offset = offset
        set(c, for: key)
    }

    public func setOffset(x: Double, y: Double, for key: String) {
        setOffset(Point(x: x, y: y), for: key)
    }

    public func setStyle(
        foreground: Color? = nil,
        background: Color? = nil,
        accent: Color? = nil,
        padding: EdgeInsets? = nil,
        cornerRadius: Double? = nil,
        for key: String
    ) {
        var c = customization(for: key)
        if let foreground { c.foregroundColor = foreground }
        if let background { c.backgroundColor = background }
        if let accent { c.accentColor = accent }
        if let padding { c.paddingOverride = padding }
        if let cornerRadius { c.cornerRadiusOverride = cornerRadius }
        set(c, for: key)
    }

    public func reset(_ key: String) {
        let storageKey = resolveExistingKey(for: key)
        if overrides.removeValue(forKey: storageKey) != nil {
            revision += 1
        }
    }

    public func resetAll() {
        let hadAny = !overrides.isEmpty || selectedTarget != nil
        overrides.removeAll(keepingCapacity: true)
        selectedTarget = nil
        if hadAny {
            revision += 1
        }
    }

    // MARK: Persistence

    /// Deterministic JSON representation of all overrides.
    public func exportJSON() -> JSON {
        _ = revision
        var map: [String: JSON] = [:]
        for key in overrides.keys.sorted() {
            if let value = overrides[key], !value.isDefault {
                map[key] = value.toJSON()
            }
        }
        return .object(map)
    }

    /// Replaces overrides from a JSON object created by `exportJSON()`.
    public func importJSON(_ json: JSON) {
        guard let map = json.object else { return }
        var next: [String: ElementCustomization] = [:]
        for (key, value) in map {
            if let c = ElementCustomization.fromJSON(value), !c.isDefault {
                next[key] = c
            }
        }
        overrides = next
        revision += 1
    }

    /// Persists overrides into a `SettingsStore` under `key`.
    public func save(to settings: SettingsStore, key: String = "polymer.customize") {
        settings.set(exportJSON(), forKey: key)
    }

    /// Loads overrides from a `SettingsStore` under `key`.
    public func load(from settings: SettingsStore, key: String = "polymer.customize") {
        if let json = settings.json(forKey: key) {
            importJSON(json)
        } else {
            resetAll()
        }
    }

    private func resolveExistingKey(for key: String) -> String {
        if overrides[key] != nil { return key }
        if !key.hasPrefix("#"), overrides["#\(key)"] != nil { return "#\(key)" }
        if key.hasPrefix("#"), overrides[String(key.dropFirst())] != nil { return String(key.dropFirst()) }
        return key
    }
}

// MARK: Environment & `.customizable(_:)` Modifier

private enum CustomizeStateKey: EnvironmentKey {
    static var defaultValue: CustomizeState? { nil }
}

private enum CustomizeScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

extension EnvironmentValues {
    public var customizeState: CustomizeState? {
        get { self[CustomizeStateKey.self] }
        set { self[CustomizeStateKey.self] = newValue }
    }

    /// Scale multiplier applied by an enclosing `.customizable(_:)` modifier.
    public var customizeScale: Double {
        get { self[CustomizeScaleKey.self] }
        set { self[CustomizeScaleKey.self] = newValue }
    }
}

extension View {
    /// Installs a `CustomizeState` into the environment for this subtree.
    public func customizeState(_ state: CustomizeState?) -> some View {
        environment(\.customizeState, state)
    }

    /// Makes this view customizable (hide, scale, move, restyle) under `id` using the
    /// active `EnvironmentValues.customizeState`, and attaches `.accessibilityIdentifier(id)`.
    public func customizable(_ id: String) -> some View {
        CustomizableView(id: id, content: self)
    }
}

struct CustomizableView<Content: View>: View {
    let id: String
    let content: Content

    @Environment(\.customizeState) private var state
    @Environment(\.theme) private var theme
    @Environment(\.font) private var envFont
    @Environment(\.foregroundColor) private var envForeground

    var body: some View {
        let customization = state?.customization(for: id) ?? .default
        if customization.isHidden {
            EmptyView()
        } else {
            let scaledFont: Font? = envFont.map { f in
                customization.scale == 1.0 ? f : Font(f.face, size: f.size * customization.scale)
            }
            let effectiveTheme = customization.accentColor.map { theme.withAccent($0) } ?? theme
            let effectiveForeground = customization.foregroundColor ?? envForeground
            let isCustomizing = state?.isCustomizing ?? false
            let isSelected = state?.selectedTarget == id || state?.selectedTarget == "#\(id)"

            content
                .environment(\.font, scaledFont)
                .environment(\.foregroundColor, effectiveForeground)
                .environment(\.theme, effectiveTheme)
                .environment(\.customizeScale, customization.scale)
                .padding(customization.paddingOverride ?? .zero)
                .background(backgroundLayer(customization))
                .overlay(customizeOutline(isCustomizing: isCustomizing, isSelected: isSelected))
                .accessibilityIdentifier(id)
                .offset(customization.offset)
        }
    }

    @ViewBuilder
    private func backgroundLayer(_ c: ElementCustomization) -> some View {
        if let bg = c.backgroundColor {
            ThemedSurfaceFill(color: bg, cornerRadius: c.cornerRadiusOverride ?? 0)
        }
    }

    @ViewBuilder
    private func customizeOutline(isCustomizing: Bool, isSelected: Bool) -> some View {
        if isCustomizing {
            Color.clear.border(
                isSelected ? theme.colors.accent : theme.colors.border,
                width: isSelected ? max(2, theme.borders.borderWidth) : theme.borders.borderWidth
            )
        }
    }
}
