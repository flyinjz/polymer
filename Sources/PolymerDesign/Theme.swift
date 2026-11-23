// Style-agnostic, composable Theme system. Polymer's core works with any visual
// aesthetic; `Theme.pgr` is the built-in house preset alongside `Theme.dark` and `Theme.light`.
import PolymerBase
import PolymerUI

/// Visibility policy for overlay scroll indicators.
public enum ScrollIndicatorVisibility: String, CaseIterable, Equatable, Hashable, Sendable {
    case automatic
    case visible
    case hidden
}

/// Complete semantic colour palette for a `Theme`.
public struct ThemeColors: Equatable, Hashable, Sendable {
    public var background: Color
    public var surface: Color
    public var surfaceElevated: Color
    public var surfaceGlass: Color
    public var textPrimary: Color
    public var textSecondary: Color
    public var textMuted: Color
    public var textDisabled: Color
    public var accent: Color
    public var accentText: Color
    public var border: Color
    public var hairline: Color
    public var separator: Color
    public var selection: Color
    public var hover: Color
    public var pressed: Color
    public var danger: Color
    public var warning: Color
    public var success: Color
    public var focusRing: Color

    public init(
        background: Color,
        surface: Color,
        surfaceElevated: Color,
        surfaceGlass: Color,
        textPrimary: Color,
        textSecondary: Color,
        textMuted: Color,
        textDisabled: Color,
        accent: Color,
        accentText: Color,
        border: Color,
        hairline: Color,
        separator: Color,
        selection: Color,
        hover: Color,
        pressed: Color,
        danger: Color,
        warning: Color,
        success: Color,
        focusRing: Color
    ) {
        self.background = background
        self.surface = surface
        self.surfaceElevated = surfaceElevated
        self.surfaceGlass = surfaceGlass
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.textMuted = textMuted
        self.textDisabled = textDisabled
        self.accent = accent
        self.accentText = accentText
        self.border = border
        self.hairline = hairline
        self.separator = separator
        self.selection = selection
        self.hover = hover
        self.pressed = pressed
        self.danger = danger
        self.warning = warning
        self.success = success
        self.focusRing = focusRing
    }

    /// All semantic palette colours defined in this token set.
    public var allPaletteColors: [Color] {
        [
            background, surface, surfaceElevated, surfaceGlass,
            textPrimary, textSecondary, textMuted, textDisabled,
            accent, accentText, border, hairline, separator,
            selection, hover, pressed, danger, warning, success, focusRing,
        ]
    }

    public func toJSON() -> JSON {
        .object([
            "background": .string(background.description),
            "surface": .string(surface.description),
            "surfaceElevated": .string(surfaceElevated.description),
            "surfaceGlass": .string(surfaceGlass.description),
            "textPrimary": .string(textPrimary.description),
            "textSecondary": .string(textSecondary.description),
            "textMuted": .string(textMuted.description),
            "textDisabled": .string(textDisabled.description),
            "accent": .string(accent.description),
            "accentText": .string(accentText.description),
            "border": .string(border.description),
            "hairline": .string(hairline.description),
            "separator": .string(separator.description),
            "selection": .string(selection.description),
            "hover": .string(hover.description),
            "pressed": .string(pressed.description),
            "danger": .string(danger.description),
            "warning": .string(warning.description),
            "success": .string(success.description),
            "focusRing": .string(focusRing.description),
        ])
    }
}

/// Corner radius scale in points. All zero gives sharp brutalist geometry.
public struct ThemeRadii: Equatable, Hashable, Sendable {
    public var none: Double
    public var small: Double
    public var medium: Double
    public var large: Double
    public var pill: Double

    public init(none: Double = 0, small: Double, medium: Double, large: Double, pill: Double) {
        self.none = none
        self.small = small
        self.medium = medium
        self.large = large
        self.pill = pill
    }

    public func toJSON() -> JSON {
        .object([
            "none": .number(none),
            "small": .number(small),
            "medium": .number(medium),
            "large": .number(large),
            "pill": .number(pill),
        ])
    }
}

/// Stroke widths in points. `hairlineWidth == 0` resolves to 1 physical pixel (`1 / scale`).
public struct ThemeBorders: Equatable, Hashable, Sendable {
    public var hairlineWidth: Double
    public var borderWidth: Double
    public var focusRingWidth: Double
    public var focusRingOffset: Double

    public init(
        hairlineWidth: Double = 0,
        borderWidth: Double = 1,
        focusRingWidth: Double = 2,
        focusRingOffset: Double = 0
    ) {
        self.hairlineWidth = hairlineWidth
        self.borderWidth = borderWidth
        self.focusRingWidth = focusRingWidth
        self.focusRingOffset = focusRingOffset
    }

    /// Physical 1-pixel width when `hairlineWidth <= 0`, or the explicit point width.
    public func resolvedHairlineWidth(scale: Double) -> Double {
        hairlineWidth <= 0 ? (1.0 / max(scale, 1.0)) : hairlineWidth
    }

    public func toJSON() -> JSON {
        .object([
            "hairlineWidth": .number(hairlineWidth),
            "borderWidth": .number(borderWidth),
            "focusRingWidth": .number(focusRingWidth),
            "focusRingOffset": .number(focusRingOffset),
        ])
    }
}

/// Backdrop glass parameters for translucent panels.
public struct ThemeGlass: Equatable, Hashable, Sendable {
    public var enabled: Bool
    public var blurRadius: Double
    public var tint: Color
    public var saturation: Double

    public init(enabled: Bool, blurRadius: Double, tint: Color, saturation: Double = 1.0) {
        self.enabled = enabled
        self.blurRadius = blurRadius
        self.tint = tint
        self.saturation = saturation
    }

    public func toJSON() -> JSON {
        .object([
            "enabled": .bool(enabled),
            "blurRadius": .number(blurRadius),
            "tint": .string(tint.description),
            "saturation": .number(saturation),
        ])
    }
}

/// Type scale and font family names.
public struct ThemeTypography: Equatable, Hashable, Sendable {
    public var fontFamily: String
    public var monoFamily: String
    public var captionSize: Double
    public var bodySize: Double
    public var headlineSize: Double
    public var titleSize: Double
    public var lineSpacing: Double

    public init(
        fontFamily: String,
        monoFamily: String,
        captionSize: Double = 11,
        bodySize: Double = 13,
        headlineSize: Double = 15,
        titleSize: Double = 20,
        lineSpacing: Double = 4
    ) {
        self.fontFamily = fontFamily
        self.monoFamily = monoFamily
        self.captionSize = captionSize
        self.bodySize = bodySize
        self.headlineSize = headlineSize
        self.titleSize = titleSize
        self.lineSpacing = lineSpacing
    }

    public func toJSON() -> JSON {
        .object([
            "fontFamily": .string(fontFamily),
            "monoFamily": .string(monoFamily),
            "captionSize": .number(captionSize),
            "bodySize": .number(bodySize),
            "headlineSize": .number(headlineSize),
            "titleSize": .number(titleSize),
            "lineSpacing": .number(lineSpacing),
        ])
    }
}

/// Spatial rhythm scale in points.
public struct ThemeSpacing: Equatable, Hashable, Sendable {
    public var xxs: Double
    public var xs: Double
    public var sm: Double
    public var md: Double
    public var lg: Double
    public var xl: Double

    public init(xxs: Double = 2, xs: Double = 4, sm: Double = 8, md: Double = 12, lg: Double = 16, xl: Double = 24) {
        self.xxs = xxs
        self.xs = xs
        self.sm = sm
        self.md = md
        self.lg = lg
        self.xl = xl
    }

    public func toJSON() -> JSON {
        .object([
            "xxs": .number(xxs),
            "xs": .number(xs),
            "sm": .number(sm),
            "md": .number(md),
            "lg": .number(lg),
            "xl": .number(xl),
        ])
    }
}

/// Styling tokens for keyboard and programmatic focus outlines.
public struct ThemeFocusRing: Equatable, Hashable, Sendable {
    public var color: Color
    public var lineWidth: Double
    public var cornerRadius: Double
    public var offset: Double
    public var showOnKeyboardOnly: Bool

    public init(
        color: Color,
        lineWidth: Double = 2,
        cornerRadius: Double = 0,
        offset: Double = 0,
        showOnKeyboardOnly: Bool = true
    ) {
        self.color = color
        self.lineWidth = lineWidth
        self.cornerRadius = cornerRadius
        self.offset = offset
        self.showOnKeyboardOnly = showOnKeyboardOnly
    }

    public func toJSON() -> JSON {
        .object([
            "color": .string(color.description),
            "lineWidth": .number(lineWidth),
            "cornerRadius": .number(cornerRadius),
            "offset": .number(offset),
            "showOnKeyboardOnly": .bool(showOnKeyboardOnly),
        ])
    }
}

/// Styling tokens for overlay scroll bars.
public struct ThemeScrollIndicators: Equatable, Hashable, Sendable {
    public var visibility: ScrollIndicatorVisibility
    public var thickness: Double
    public var cornerRadius: Double
    public var color: Color
    public var hoverColor: Color
    public var minLength: Double
    public var inset: Double

    public init(
        visibility: ScrollIndicatorVisibility = .automatic,
        thickness: Double = 6,
        cornerRadius: Double = 0,
        color: Color,
        hoverColor: Color,
        minLength: Double = 24,
        inset: Double = 2
    ) {
        self.visibility = visibility
        self.thickness = thickness
        self.cornerRadius = cornerRadius
        self.color = color
        self.hoverColor = hoverColor
        self.minLength = minLength
        self.inset = inset
    }

    public func toJSON() -> JSON {
        .object([
            "visibility": .string(visibility.rawValue),
            "thickness": .number(thickness),
            "cornerRadius": .number(cornerRadius),
            "color": .string(color.description),
            "hoverColor": .string(hoverColor.description),
            "minLength": .number(minLength),
            "inset": .number(inset),
        ])
    }
}

/// Composable design-system theme driving all PolymerDesign components.
public struct Theme: Equatable, Hashable, Sendable {
    public var name: String
    public var isDark: Bool
    public var colors: ThemeColors
    public var radii: ThemeRadii
    public var borders: ThemeBorders
    public var glass: ThemeGlass
    public var typography: ThemeTypography
    public var spacing: ThemeSpacing
    public var focusRing: ThemeFocusRing
    public var scrollIndicators: ThemeScrollIndicators

    public init(
        name: String,
        isDark: Bool,
        colors: ThemeColors,
        radii: ThemeRadii,
        borders: ThemeBorders,
        glass: ThemeGlass,
        typography: ThemeTypography,
        spacing: ThemeSpacing,
        focusRing: ThemeFocusRing,
        scrollIndicators: ThemeScrollIndicators
    ) {
        self.name = name
        self.isDark = isDark
        self.colors = colors
        self.radii = radii
        self.borders = borders
        self.glass = glass
        self.typography = typography
        self.spacing = spacing
        self.focusRing = focusRing
        self.scrollIndicators = scrollIndicators
    }

    // MARK: Derivation Helpers

    /// Returns a modified copy of this theme so creators can derive custom aesthetics cleanly.
    public func with(_ mutate: (inout Theme) -> Void) -> Theme {
        var copy = self
        mutate(&copy)
        return copy
    }

    /// Returns a copy with updated accent and focus-ring colours.
    public func withAccent(_ accent: Color, accentText: Color? = nil) -> Theme {
        with { t in
            t.colors.accent = accent
            if let accentText { t.colors.accentText = accentText }
            t.colors.focusRing = accent
            t.focusRing.color = accent
        }
    }

    /// Returns a copy with modified semantic colours.
    public func withColors(_ mutate: (inout ThemeColors) -> Void) -> Theme {
        with { mutate(&$0.colors) }
    }

    /// Returns a copy with new corner radii.
    public func withRadii(_ radii: ThemeRadii) -> Theme {
        with { t in
            t.radii = radii
            t.focusRing.cornerRadius = radii.small
            t.scrollIndicators.cornerRadius = radii.pill > 0 ? t.scrollIndicators.thickness / 2 : 0
        }
    }

    /// Returns a copy with new backdrop glass configuration.
    public func withGlass(_ glass: ThemeGlass) -> Theme {
        with { t in
            t.glass = glass
            t.colors.surfaceGlass = glass.tint
        }
    }

    /// Every colour token defined by this theme, used by opt-in `DesignLint.tokenColorsOnly`.
    public var paletteColors: [Color] {
        colors.allPaletteColors + [glass.tint, focusRing.color, scrollIndicators.color, scrollIndicators.hoverColor, .clear]
    }

    /// Structured JSON token catalog for `polymer describe`.
    public func describeTokens() -> JSON {
        .object([
            "name": .string(name),
            "isDark": .bool(isDark),
            "colors": colors.toJSON(),
            "radii": radii.toJSON(),
            "borders": borders.toJSON(),
            "glass": glass.toJSON(),
            "typography": typography.toJSON(),
            "spacing": spacing.toJSON(),
            "focusRing": focusRing.toJSON(),
            "scrollIndicators": scrollIndicators.toJSON(),
        ])
    }

    // MARK: Built-In Presets

    /// House pgr aesthetic: brutalist grid, 1 physical px hairlines, dark glass,
    /// sharp 0pt corners, neutral grays plus a single crisp accent, mono typography.
    public static let pgr = Theme(
        name: "pgr",
        isDark: true,
        colors: ThemeColors(
            background: Color(hex: 0x0A0A0B),
            surface: Color(hex: 0x121214),
            surfaceElevated: Color(hex: 0x1A1A1E),
            surfaceGlass: Color(hex: 0x101012, opacity: 0.72),
            textPrimary: Color(hex: 0xF4F4F5),
            textSecondary: Color(hex: 0xA1A1AA),
            textMuted: Color(hex: 0x71717A),
            textDisabled: Color(hex: 0x52525B),
            accent: Color(hex: 0x3B82F6),
            accentText: Color(hex: 0xFFFFFF),
            border: Color(white: 1, opacity: 0.14),
            hairline: Color(white: 1, opacity: 0.12),
            separator: Color(white: 1, opacity: 0.14),
            selection: Color(hex: 0x2563EB),
            hover: Color(white: 1, opacity: 0.08),
            pressed: Color(white: 1, opacity: 0.16),
            danger: Color(hex: 0xEF4444),
            warning: Color(hex: 0xF59E0B),
            success: Color(hex: 0x22C55E),
            focusRing: Color(hex: 0x3B82F6)
        ),
        radii: ThemeRadii(none: 0, small: 0, medium: 0, large: 0, pill: 0),
        borders: ThemeBorders(hairlineWidth: 0, borderWidth: 1, focusRingWidth: 2, focusRingOffset: 0),
        glass: ThemeGlass(
            enabled: true,
            blurRadius: 18,
            tint: Color(hex: 0x101012, opacity: 0.72),
            saturation: 1.1
        ),
        typography: ThemeTypography(
            fontFamily: "Geist",
            monoFamily: "GeistMono",
            captionSize: 11,
            bodySize: 13,
            headlineSize: 15,
            titleSize: 20,
            lineSpacing: 4
        ),
        spacing: ThemeSpacing(xxs: 2, xs: 4, sm: 8, md: 12, lg: 16, xl: 24),
        focusRing: ThemeFocusRing(
            color: Color(hex: 0x3B82F6),
            lineWidth: 2,
            cornerRadius: 0,
            offset: 0,
            showOnKeyboardOnly: true
        ),
        scrollIndicators: ThemeScrollIndicators(
            visibility: .automatic,
            thickness: 4,
            cornerRadius: 0,
            color: Color(white: 1, opacity: 0.24),
            hoverColor: Color(white: 1, opacity: 0.48),
            minLength: 24,
            inset: 2
        )
    )

    /// Clean modern dark theme with soft rounded corners and solid elevated surfaces.
    public static let dark = Theme(
        name: "dark",
        isDark: true,
        colors: ThemeColors(
            background: Color(hex: 0x111318),
            surface: Color(hex: 0x191C24),
            surfaceElevated: Color(hex: 0x232834),
            surfaceGlass: Color(hex: 0x191C24, opacity: 0.85),
            textPrimary: Color(hex: 0xF3F4F6),
            textSecondary: Color(hex: 0x9CA3AF),
            textMuted: Color(hex: 0x6B7280),
            textDisabled: Color(hex: 0x4B5563),
            accent: Color(hex: 0x6366F1),
            accentText: Color(hex: 0xFFFFFF),
            border: Color(hex: 0x2E3444),
            hairline: Color(hex: 0x262B38),
            separator: Color(hex: 0x2A303E),
            selection: Color(hex: 0x4F46E5),
            hover: Color(hex: 0x2A3040),
            pressed: Color(hex: 0x32394C),
            danger: Color(hex: 0xF87171),
            warning: Color(hex: 0xFBBF24),
            success: Color(hex: 0x34D399),
            focusRing: Color(hex: 0x818CF8)
        ),
        radii: ThemeRadii(none: 0, small: 4, medium: 8, large: 12, pill: 999),
        borders: ThemeBorders(hairlineWidth: 1, borderWidth: 1, focusRingWidth: 2, focusRingOffset: 1),
        glass: ThemeGlass(
            enabled: false,
            blurRadius: 12,
            tint: Color(hex: 0x191C24, opacity: 0.85),
            saturation: 1.0
        ),
        typography: ThemeTypography(
            fontFamily: "Inter",
            monoFamily: "JetBrainsMono",
            captionSize: 11,
            bodySize: 13,
            headlineSize: 16,
            titleSize: 22,
            lineSpacing: 4
        ),
        spacing: ThemeSpacing(xxs: 2, xs: 4, sm: 8, md: 12, lg: 16, xl: 24),
        focusRing: ThemeFocusRing(
            color: Color(hex: 0x818CF8),
            lineWidth: 2,
            cornerRadius: 4,
            offset: 1,
            showOnKeyboardOnly: true
        ),
        scrollIndicators: ThemeScrollIndicators(
            visibility: .automatic,
            thickness: 6,
            cornerRadius: 3,
            color: Color(white: 1, opacity: 0.22),
            hoverColor: Color(white: 1, opacity: 0.42),
            minLength: 28,
            inset: 2
        )
    )

    /// Clean modern light theme with bright surfaces, high-contrast dark ink, and rounded corners.
    public static let light = Theme(
        name: "light",
        isDark: false,
        colors: ThemeColors(
            background: Color(hex: 0xF8F9FB),
            surface: Color(hex: 0xFFFFFF),
            surfaceElevated: Color(hex: 0xF1F3F7),
            surfaceGlass: Color(hex: 0xFFFFFF, opacity: 0.82),
            textPrimary: Color(hex: 0x111827),
            textSecondary: Color(hex: 0x4B5563),
            textMuted: Color(hex: 0x6B7280),
            textDisabled: Color(hex: 0x9CA3AF),
            accent: Color(hex: 0x2563EB),
            accentText: Color(hex: 0xFFFFFF),
            border: Color(hex: 0xD1D5DB),
            hairline: Color(hex: 0xE5E7EB),
            separator: Color(hex: 0xE5E7EB),
            selection: Color(hex: 0x1D4ED8),
            hover: Color(hex: 0xE5E7EB),
            pressed: Color(hex: 0xD1D5DB),
            danger: Color(hex: 0xDC2626),
            warning: Color(hex: 0xD97706),
            success: Color(hex: 0x16A34A),
            focusRing: Color(hex: 0x2563EB)
        ),
        radii: ThemeRadii(none: 0, small: 4, medium: 8, large: 12, pill: 999),
        borders: ThemeBorders(hairlineWidth: 1, borderWidth: 1, focusRingWidth: 2, focusRingOffset: 1),
        glass: ThemeGlass(
            enabled: false,
            blurRadius: 12,
            tint: Color(hex: 0xFFFFFF, opacity: 0.82),
            saturation: 1.0
        ),
        typography: ThemeTypography(
            fontFamily: "Inter",
            monoFamily: "JetBrainsMono",
            captionSize: 11,
            bodySize: 13,
            headlineSize: 16,
            titleSize: 22,
            lineSpacing: 4
        ),
        spacing: ThemeSpacing(xxs: 2, xs: 4, sm: 8, md: 12, lg: 16, xl: 24),
        focusRing: ThemeFocusRing(
            color: Color(hex: 0x2563EB),
            lineWidth: 2,
            cornerRadius: 4,
            offset: 1,
            showOnKeyboardOnly: true
        ),
        scrollIndicators: ThemeScrollIndicators(
            visibility: .automatic,
            thickness: 6,
            cornerRadius: 3,
            color: Color(white: 0, opacity: 0.22),
            hoverColor: Color(white: 0, opacity: 0.45),
            minLength: 28,
            inset: 2
        )
    )
}

// MARK: Environment Integration

private enum ThemeKey: EnvironmentKey {
    static let defaultValue: Theme = .pgr
}

private enum ScrollIndicatorVisibilityKey: EnvironmentKey {
    static let defaultValue: ScrollIndicatorVisibility = .automatic
}

extension EnvironmentValues {
    public var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }

    public var scrollIndicatorVisibility: ScrollIndicatorVisibility {
        get { self[ScrollIndicatorVisibilityKey.self] }
        set { self[ScrollIndicatorVisibilityKey.self] = newValue }
    }
}

extension View {
    /// Applies `theme` to this view hierarchy, propagating default text and separator colours.
    public func theme(_ theme: Theme) -> some View {
        environment(\.theme, theme)
            .foregroundStyle(theme.colors.textPrimary)
            .environment(\.separatorColor, theme.colors.separator)
    }

    /// Overrides scroll indicator visibility for `PolymerScrollBar` views inside this subtree.
    public func scrollIndicators(_ visibility: ScrollIndicatorVisibility) -> some View {
        environment(\.scrollIndicatorVisibility, visibility)
    }
}
