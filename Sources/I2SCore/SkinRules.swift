// The resolved skin, the stored theme list rules and font face choice.
// Ported from Meimei's Core/SkinRules.swift. Differences:
//  - GrayTone and DesignTokens come from Meimei's CustomizeData.swift; they
//    live here until that file is ported, then move there unchanged.
//  - CustomizeState is not ported yet (needs CustomElement, ElementStyle,
//    PaneLayout and Workspace from CustomizeData.swift).
//  - theme ids are canonical UUID strings, so activeID returns a String.
import PolymerBase

// MARK: - Colours with alpha

/// An sRGB colour with opacity, components 0 to 1. What every surface and
/// text level resolves to, on every platform.
public struct RGBA: Hashable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

    public init(hex: UInt32, alpha: Double = 1) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
        a = alpha
    }

    public static let white = RGBA(r: 1, g: 1, b: 1)
    public static let black = RGBA(r: 0, g: 0, b: 0)
    public static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)

    /// The same colour at `opacity` times its alpha.
    public func opacity(_ opacity: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: a * opacity) }

    /// WCAG relative luminance of a 24-bit colour.
    public static func luminance(_ hex: UInt32) -> Double {
        let c = RGBA(hex: hex)
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow(base: (v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    /// As PolymerBase's colour, for drawing.
    public var color: Color { Color(red: r, green: g, blue: b, opacity: a) }

    /// JSON as Meimei's synthesized Codable: r, g, b, a.
    public var json: JSON { .object(["r": .number(r), "g": .number(g), "b": .number(b), "a": .number(a)]) }

    public init?(json j: JSON) {
        guard let r = j["r"]?.double, let g = j["g"]?.double, let b = j["b"]?.double, let a = j["a"]?.double
        else { return nil }
        self.init(r: r, g: g, b: b, a: a)
    }
}

// MARK: - Design tokens (from Meimei's CustomizeData.swift)

public enum GrayTone: String, CaseIterable, Identifiable, Sendable {
    case neutral, warm, cool
    public var id: String { rawValue }

    /// A gray at `white`, nudged toward the tone, as sRGB components 0 to 1.
    public func rgb(_ white: Double) -> (red: Double, green: Double, blue: Double) {
        switch self {
        case .neutral: return (white, white, white)
        case .warm: return (min(1, white * 1.06 + 0.006), white * 1.01, white * 0.93)
        case .cool: return (white * 0.94, white * 0.99, min(1, white * 1.07 + 0.008))
        }
    }

    /// The tone's gray at `white` as a colour.
    public func color(_ white: Double) -> RGBA { let c = rgb(white); return RGBA(r: c.red, g: c.green, b: c.blue) }
}

/// App-wide design values every surface and text reads.
public struct DesignTokens: Hashable, Sendable {
    public var accent: UInt32?
    public var tone: GrayTone = .neutral
    public var textScale: Double = 1
    public var gap: Double = 6
    public var borderWidth: Double = 1
    public var panelOpacity: Double = 0.46
    public var cornerTicks = true
    public var tickLength: Double = 7

    public static let gapRange: ClosedRange<Double> = 0...18
    public static let textScaleRange: ClosedRange<Double> = 0.8...1.4

    public init() {}

    /// Strict, as Meimei's synthesized decoder: every key is required except
    /// `accent` (missing or null is nil). Meimei stores tokens inside
    /// CustomizeState, which falls back to all defaults when unreadable.
    public init?(json j: JSON) {
        guard let o = j.object, let tone = o["tone"]?.string.flatMap(GrayTone.init(rawValue:)),
              let textScale = o["textScale"]?.double, let gap = o["gap"]?.double,
              let borderWidth = o["borderWidth"]?.double, let panelOpacity = o["panelOpacity"]?.double,
              let cornerTicks = o["cornerTicks"]?.bool, let tickLength = o["tickLength"]?.double
        else { return nil }
        if let v = o["accent"], !v.isNull {
            guard let d = v.double, d >= 0, d <= Double(UInt32.max), d.rounded(.towardZero) == d else { return nil }
            accent = UInt32(d)
        }
        self.tone = tone
        self.textScale = textScale
        self.gap = gap
        self.borderWidth = borderWidth
        self.panelOpacity = panelOpacity
        self.cornerTicks = cornerTicks
        self.tickLength = tickLength
    }

    /// `accent` is left out when nil, as Meimei's encoder does.
    public var json: JSON {
        var o: [String: JSON] = [
            "tone": .raw(tone), "textScale": .number(textScale), "gap": .number(gap),
            "borderWidth": .number(borderWidth), "panelOpacity": .number(panelOpacity),
            "cornerTicks": .bool(cornerTicks), "tickLength": .number(tickLength),
        ]
        if let accent { o["accent"] = .number(Double(accent)) }
        return .object(o)
    }
}

// MARK: - The skin every view draws with

/// The theme after the design tokens and settings are applied: a monochrome
/// tonal scale for every surface and text level, hue only from the accent,
/// and the glass and corner-tick values.
public struct StyledSkin: Hashable, Sendable {
    public var bgVoid, bgPanel, bgRow, bgRowAlt, bgRaised, hairline: RGBA
    public var textPrimary, textSecondary, textTertiary, textOnAccent: RGBA
    public var accent, accentDim, accentGlow: RGBA
    public var lcdOn, lcdOff, lcdBackground: RGBA
    public var selection, hover: RGBA
    /// Surfaces are glass panes over the backdrop rather than fills.
    public var isGlass: Bool
    /// Panels and the table stay translucent so the backdrop shows through.
    public var allowsBackdropBleed: Bool
    public var panelOpacity: Double
    public var borderWidth: Double
    public var showTicks: Bool
    public var tickLength: Double
    /// The window backdrop actually shown.
    public var backdrop: BackdropStyle
    /// Whether the accent colours came from the design tokens rather than the theme.
    public var accentOverridden: Bool
}

public enum SkinRules {
    /// The live cover theme's skin id: its surfaces are always glass and its backdrop the cover.
    public static let liveCoverID = "from-cover-live"

    /// The skin to draw with. `accent`, `accentDim`, `accentGlow` and
    /// `textOnAccent` are the theme's own (or the live cover's); `skinID`
    /// is `liveCoverID` for the live cover theme.
    public static func styled(accent: RGBA, accentDim: RGBA, accentGlow: RGBA, textOnAccent: RGBA, skinID: String,
                              tokens: DesignTokens, settings: AppSettingsData) -> StyledSkin {
        var accent = accent, accentDim = accentDim, accentGlow = accentGlow, textOnAccent = textOnAccent
        if let hex = tokens.accent {
            accent = RGBA(hex: hex)
            accentDim = RGBA(hex: hex).opacity(0.45)
            accentGlow = RGBA(hex: hex)
            textOnAccent = RGBA.luminance(hex) > 0.55 ? RGBA.black.opacity(0.85) : .white
        }
        let tone = tokens.tone
        let ink = tone.color(0.92)
        let glass = settings.surfaceStyle == .glass || skinID == liveCoverID
        return StyledSkin(
            bgVoid: tone.color(0.04),
            bgPanel: glass ? .clear : tone.color(0.07),
            bgRow: glass ? .clear : tone.color(0.055),
            bgRowAlt: RGBA.white.opacity(0.025),
            bgRaised: RGBA.white.opacity(0.05),
            hairline: RGBA.white.opacity(0.14 * settings.hairlineOpacity),
            textPrimary: ink,
            textSecondary: ink.opacity(0.62),
            textTertiary: ink.opacity(0.4),
            textOnAccent: textOnAccent,
            accent: accent, accentDim: accentDim, accentGlow: accentGlow,
            lcdOn: ink,
            lcdOff: RGBA.white.opacity(0.12),
            lcdBackground: RGBA.black.opacity(0.3),
            selection: accent.opacity(0.18),
            hover: RGBA.white.opacity(0.05),
            isGlass: glass,
            allowsBackdropBleed: glass,
            panelOpacity: tokens.panelOpacity,
            borderWidth: tokens.borderWidth,
            showTicks: tokens.cornerTicks,
            tickLength: tokens.tickLength,
            backdrop: effectiveBackdrop(skinID: skinID, settings: settings),
            accentOverridden: tokens.accent != nil
        )
    }

    /// The live cover theme always sits on the blurred cover.
    public static func effectiveBackdrop(skinID: String, settings: AppSettingsData) -> BackdropStyle {
        skinID == liveCoverID ? .artwork : settings.backdropStyle
    }
}

// MARK: - Stored themes

public enum ThemeLibrary {
    /// The stored theme list as the app uses it: the starter themes when
    /// nothing is stored; otherwise the stored themes with catalog themes the
    /// user doesn't have yet added (by stable id), and catalog grouping
    /// restored on the ones they do, colours untouched.
    public static func merged(_ stored: [CustomTheme]) -> [CustomTheme] {
        guard !stored.isEmpty else { return CustomTheme.starterThemes }
        var catalog: [String: CustomTheme] = [:]
        for t in CustomTheme.starterThemes { catalog[t.id] = t }
        var result = stored
        for i in result.indices {
            guard let canned = catalog[result[i].id] else { continue }
            if result[i].category == "Custom" { result[i].category = canned.category }
            result[i].isAlbumReactive = canned.isAlbumReactive
        }
        let have = Set(result.map(\.id))
        return result + CustomTheme.starterThemes.filter { !have.contains($0.id) }
    }

    /// The stored active theme if it's in the list, else the first theme.
    /// Ids compare as UUIDs (case-insensitively), as Meimei's do.
    public static func activeID(stored raw: String?, in themes: [CustomTheme]) -> String {
        if let raw, let id = UUIDString.canonical(raw),
           let hit = themes.first(where: { UUIDString.canonical($0.id) == id }) { return hit.id }
        return themes.first?.id ?? CustomTheme.fallback.id
    }
}

// MARK: - Font faces

/// Text weights as layout asks for them, before choosing a face.
public enum FaceWeight: String, CaseIterable, Sendable {
    case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black
}

extension AppFontFamily {
    /// Text below this size draws in the regular face, not the light one.
    public static let regularBelow = 11.0

    /// The bundled face to draw `weight` at `size`: bold for bold and
    /// heavier, regular for medium and semibold (and small text), light otherwise.
    public func face(size: Double, weight: FaceWeight) -> String {
        switch weight {
        case .bold, .heavy, .black: return faces.bold
        case .medium, .semibold: return faces.regular
        default: return size < Self.regularBelow ? faces.regular : faces.light
        }
    }
}
