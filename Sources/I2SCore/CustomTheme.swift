// User-editable themes and the starter catalog, ported from Meimei's
// Core/CustomTheme.swift with the same JSON keys and stable ids.
// Differences: ids are canonical UUID strings; `fallback` has a fixed id
// (Meimei made a random one per launch) so it is the same on every run.
import PolymerBase

/// Every colour a theme controls, grouped for the editor, with a key path
/// into `CustomTheme` so the editor renders them generically.
public enum ThemeColorField: CaseIterable, Identifiable, Sendable {
    case bgVoid, bgPanel, bgRow, bgRowAlt, bgRaised, hairline
    case textPrimary, textSecondary, textTertiary, textOnAccent
    case accent, accentDim, accentGlow
    case selection, hover
    case lcdOn, lcdOff, lcdBackground

    public var id: Self { self }

    public var label: String {
        switch self {
        case .bgVoid: return "Void Background"
        case .bgPanel: return "Panel Background"
        case .bgRow: return "Row Background"
        case .bgRowAlt: return "Alternating Row"
        case .bgRaised: return "Raised Surface"
        case .hairline: return "Hairline / Divider"
        case .textPrimary: return "Primary Text"
        case .textSecondary: return "Secondary Text"
        case .textTertiary: return "Tertiary Text"
        case .textOnAccent: return "Text on Accent"
        case .accent: return "Accent"
        case .accentDim: return "Accent (Dim)"
        case .accentGlow: return "Accent (Glow)"
        case .selection: return "Selection"
        case .hover: return "Hover"
        case .lcdOn: return "LCD On"
        case .lcdOff: return "LCD Off"
        case .lcdBackground: return "LCD Background"
        }
    }

    public var group: String {
        switch self {
        case .bgVoid, .bgPanel, .bgRow, .bgRowAlt, .bgRaised, .hairline: return "Backgrounds"
        case .textPrimary, .textSecondary, .textTertiary, .textOnAccent: return "Text"
        case .accent, .accentDim, .accentGlow: return "Accent"
        case .selection, .hover: return "Interactive"
        case .lcdOn, .lcdOff, .lcdBackground: return "LCD Readout"
        }
    }

    /// Display order for the group headers in the theme editor.
    public static let groups: [String] = ["Backgrounds", "Text", "Accent", "Interactive", "LCD Readout"]

    /// The JSON key this colour is stored under (the property name).
    public var key: String {
        switch self {
        case .bgVoid: return "bgVoid"
        case .bgPanel: return "bgPanel"
        case .bgRow: return "bgRow"
        case .bgRowAlt: return "bgRowAlt"
        case .bgRaised: return "bgRaised"
        case .hairline: return "hairline"
        case .textPrimary: return "textPrimary"
        case .textSecondary: return "textSecondary"
        case .textTertiary: return "textTertiary"
        case .textOnAccent: return "textOnAccent"
        case .accent: return "accent"
        case .accentDim: return "accentDim"
        case .accentGlow: return "accentGlow"
        case .selection: return "selection"
        case .hover: return "hover"
        case .lcdOn: return "lcdOn"
        case .lcdOff: return "lcdOff"
        case .lcdBackground: return "lcdBackground"
        }
    }

    public var keyPath: WritableKeyPath<CustomTheme, UInt32> {
        switch self {
        case .bgVoid: return \CustomTheme.bgVoid
        case .bgPanel: return \CustomTheme.bgPanel
        case .bgRow: return \CustomTheme.bgRow
        case .bgRowAlt: return \CustomTheme.bgRowAlt
        case .bgRaised: return \CustomTheme.bgRaised
        case .hairline: return \CustomTheme.hairline
        case .textPrimary: return \CustomTheme.textPrimary
        case .textSecondary: return \CustomTheme.textSecondary
        case .textTertiary: return \CustomTheme.textTertiary
        case .textOnAccent: return \CustomTheme.textOnAccent
        case .accent: return \CustomTheme.accent
        case .accentDim: return \CustomTheme.accentDim
        case .accentGlow: return \CustomTheme.accentGlow
        case .selection: return \CustomTheme.selection
        case .hover: return \CustomTheme.hover
        case .lcdOn: return \CustomTheme.lcdOn
        case .lcdOff: return \CustomTheme.lcdOff
        case .lcdBackground: return \CustomTheme.lcdBackground
        }
    }
}

/// A user-editable theme: every skin colour as 24-bit RGB, so it
/// round-trips through storage exactly.
public struct CustomTheme: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String

    public var bgVoid: UInt32
    public var bgPanel: UInt32
    public var bgRow: UInt32
    public var bgRowAlt: UInt32
    public var bgRaised: UInt32
    public var hairline: UInt32

    public var textPrimary: UInt32
    public var textSecondary: UInt32
    public var textTertiary: UInt32
    public var textOnAccent: UInt32

    public var accent: UInt32
    public var accentDim: UInt32
    public var accentGlow: UInt32

    public var selection: UInt32
    public var hover: UInt32

    public var lcdOn: UInt32
    public var lcdOff: UInt32
    public var lcdBackground: UInt32

    /// Grouping label in the Customize Appearance list ("Y2K", "Listening Bar", ...).
    public var category: String
    /// When true, colours are sampled live from the playing track's artwork
    /// instead of these stored values, and the window backdrop becomes a
    /// blurred cover.
    public var isAlbumReactive: Bool

    /// A theme with a palette's colours.
    public init(id: String, name: String, palette p: Palette) {
        self.id = id
        self.name = name
        bgVoid = p.bgVoid; bgPanel = p.bgPanel; bgRow = p.bgRow; bgRowAlt = p.bgRowAlt
        bgRaised = p.bgRaised; hairline = p.hairline
        textPrimary = p.textPrimary; textSecondary = p.textSecondary
        textTertiary = p.textTertiary; textOnAccent = p.textOnAccent
        accent = p.accent; accentDim = p.accentDim; accentGlow = p.accentGlow
        selection = p.selection; hover = p.hover
        lcdOn = p.lcdOn; lcdOff = p.lcdOff; lcdBackground = p.lcdBackground
        category = "Custom"
        isAlbumReactive = p.bleed
    }
}

// MARK: JSON

extension CustomTheme {
    /// As Meimei's decoder: `id`, `name` and every colour are required
    /// except `selection` (defaults to `accentDim`) and `hover` (to
    /// `bgRaised`); `category` defaults to "Custom", `isAlbumReactive` to
    /// false. Missing or null take the default; a wrong type fails.
    public init?(json j: JSON) {
        guard let o = j.object, let id = o["id"]?.string.flatMap(UUIDString.canonical),
              let name = o["name"]?.string else { return nil }
        func present(_ k: String) -> JSON? {
            guard let v = o[k], !v.isNull else { return nil }
            return v
        }
        func color(_ k: String) -> UInt32? {
            guard let d = o[k]?.double, d >= 0, d <= Double(UInt32.max), d.rounded(.towardZero) == d else { return nil }
            return UInt32(d)
        }
        self.init(id: id, name: name, palette: .voidBlack)
        for field in ThemeColorField.allCases where field != .selection && field != .hover {
            guard let c = color(field.key) else { return nil }
            self[keyPath: field.keyPath] = c
        }
        if present("selection") != nil { guard let c = color("selection") else { return nil }; selection = c }
        else { selection = accentDim }
        if present("hover") != nil { guard let c = color("hover") else { return nil }; hover = c }
        else { hover = bgRaised }
        if let v = present("category") { guard let s = v.string else { return nil }; category = s }
        else { category = "Custom" }
        if let v = present("isAlbumReactive") { guard let b = v.bool else { return nil }; isAlbumReactive = b }
        else { isAlbumReactive = false }
    }

    /// Every key, as Meimei writes them.
    public var json: JSON {
        var o: [String: JSON] = [
            "id": .string(id), "name": .string(name),
            "category": .string(category), "isAlbumReactive": .bool(isAlbumReactive),
        ]
        for field in ThemeColorField.allCases { o[field.key] = .number(Double(self[keyPath: field.keyPath])) }
        return .object(o)
    }

    /// A stored theme list; one unreadable theme and the whole list is nil.
    public static func list(json: JSON) -> [CustomTheme]? {
        guard let items = json.array else { return nil }
        var out: [CustomTheme] = []
        out.reserveCapacity(items.count)
        for item in items {
            guard let t = CustomTheme(json: item) else { return nil }
            out.append(t)
        }
        return out
    }

    public static func json(_ list: [CustomTheme]) -> JSON { .array(list.map(\.json)) }
}

// MARK: Catalog

extension CustomTheme {
    public static let albumReactiveID = "9E5B1000-0000-4000-8000-00000000C0DE"

    /// First-launch seed and catalog merge source. Stable ids so palettes can
    /// be added later without overwriting a user's edits to ones they have.
    public static let starterThemes: [CustomTheme] = {
        func id(_ n: UInt32) -> String { "9E5B1000-0000-4000-8000-0000000000" + TextTools.hexPadded(n, 2) }
        let specs: [(String, String, Palette, Bool)] = [
            (id(0x01), "Y2K", .voidBlack, false),
            (id(0x02), "Y2K", .terminalAmber, false),
            (id(0x03), "Y2K", .coldSteelCyan, false),
            (id(0x04), "Y2K", .bloodChrome, false),
            (id(0x05), "Y2K", .acidStatic, false),
            (id(0x06), "Listening Bar", .lofiHarbor, false),
            (id(0x07), "Listening Bar", .matchaHour, false),
            (id(0x08), "Listening Bar", .loopStation, false),
            (id(0x09), "Studio", .pulseRed, false),
            (id(0x0A), "Studio", .pacificGlass, false),
            (id(0x0B), "Studio", .softSpotlight, false),
            (id(0x0C), "Afterimage", .nightSession, false),
            (id(0x0D), "Afterimage", .phosphor, false),
            (id(0x0E), "Afterimage", .gardenRain, false),
            (albumReactiveID, "Live", .fromCoverPlaceholder, true),
        ]
        return specs.map { id, category, palette, reactive in
            var theme = CustomTheme(id: id, name: palette.name, palette: palette)
            theme.category = category
            theme.isAlbumReactive = reactive
            return theme
        }
    }()

    /// Display order of category headers in Customize Appearance.
    public static let categoryOrder = ["Live", "Y2K", "Listening Bar", "Studio", "Afterimage", "Custom"]

    /// Only used if a theme list is ever empty, which the theme store never allows.
    public static let fallback = CustomTheme(id: "9E5B1000-0000-4000-8000-00000000FA11", name: "Fallback", palette: .voidBlack)
}

extension UInt32 {
    /// 6-digit uppercase RRGGBB, no leading `#`.
    public var hexString: String { TextTools.hexPadded(self & 0xFFFFFF, 6) }

    /// Parses a 6-digit RRGGBB hex string, with or without a leading `#`.
    public init?(hexColorString: String) {
        var cleaned = TextTools.trimming(hexColorString, TextTools.isWhitespaceOrNewline)
        cleaned.removeAll { $0 == "#" }
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        self = value
    }
}
