// The pgr look as values: greys plus one accent, 1-point lines, a 4-point
// spacing grid, a type scale over the bundled fonts, and the glass and
// material every component uses. Components read it from the environment
// (`@Environment(\.theme)`); apps set it once at the root (`.designRoot`)
// and change the accent with `.accent(_:)`.
import PolymerBase
import PolymerText
import PolymerUI

/// Every value the house look is made of. One per window, from the environment.
public struct Theme: Equatable {
    /// The one colour that is not grey: selection, primary actions, focus.
    public var accent: Color
    /// Text and marks drawn on the accent.
    public var onAccent: Color
    /// The greys, darkest to lightest.
    public var gray: Grays
    /// Gaps and insets, on a 4-point grid.
    public var space: Spacing
    /// Heights and widths of controls.
    public var size: Sizes
    /// The fonts and their sizes.
    public var type: TypeScale
    /// Width of every line, in points. Not scaled by Customize.
    public var line: Double
    /// Corner radius of controls and panels. The grid look is square.
    public var cornerRadius: Double
    /// The glass of floating controls (DESIGN 11).
    public var glass: Glass
    /// The material behind toolbars (sidebars are a solid surface: a blur
    /// of the plain window background would cost work and show nothing).
    public var material: Material
    /// How much `scaled(by:)` has enlarged this theme (1 at first).
    public private(set) var scale: Double

    /// Blue, a little desaturated so it sits with the greys.
    public static let defaultAccent = Color(hex: 0x4F8CF0)

    /// Fills an empty area so it takes clicks (only drawn views are hit),
    /// without changing a pixel: white at 0.1%. Stands in until PolymerUI
    /// has `.contentShape`.
    public static let hitFill = Color(white: 1, opacity: 0.001)

    /// The house theme. `sans` and `mono` are the bundled fonts; text draws
    /// nothing without a font, so apps pass them (either serves for both).
    public init(accent: Color = Theme.defaultAccent, sans: FontFace? = nil, mono: FontFace? = nil) {
        self.accent = accent
        onAccent = Color(hex: 0x0B0B0B)
        gray = Grays()
        space = Spacing()
        size = Sizes()
        type = TypeScale(sans: sans, mono: mono)
        line = 1
        cornerRadius = 0
        glass = Glass.regular.tint(Color(white: 0.06, opacity: 0.35))
        material = .thickMaterial
        scale = 1
    }

    /// The font for a role, at this theme's scale; nil when the theme has no fonts.
    public func font(_ role: TextRole) -> Font? { type.font(role, scale: scale) }

    /// The same theme with spacing, control sizes and text sizes multiplied by
    /// `factor` (Customize's scale). Lines stay 1 point.
    public func scaled(by factor: Double) -> Theme {
        guard factor != 1, factor > 0 else { return self }
        var t = self
        t.scale = scale * factor
        t.space = space.scaled(by: factor)
        t.size = size.scaled(by: factor)
        return t
    }

    /// The same theme with another accent.
    public func with(accent: Color) -> Theme {
        var t = self
        t.accent = accent
        return t
    }

    /// The look menus, popovers and sheets draw with: the raised grey that
    /// floats above a surface, its 1-point line, a pressed wash for the
    /// highlighted item and the standard gap from what it points at.
    public var panelLook: PanelLook {
        PanelLook(background: gray.raised, line: gray.line, highlight: gray.pressed,
                  shortcutOpacity: 0.5, disabledOpacity: gray.disabledOpacity, gap: space.xs)
    }

    /// The look text fields and editors draw with: the placeholder grey,
    /// the accent behind a selection and a caret one line wide.
    public var textInputLook: TextInputLook {
        TextInputLook(placeholderOpacity: Theme.alpha(drawing: gray.tertiaryText, on: gray.surface, using: gray.text),
                      selectionOpacity: min(0.35, max(0.2, Theme.alpha(drawing: accent, on: gray.surface, using: gray.text))),
                      caretWidth: line)
    }

    /// The opacity at which `text` over `background` looks like `target`
    /// (least squares over the channels); used so the look stays a token.
    static func alpha(drawing target: Color, on background: Color, using text: Color) -> Double {
        var numerator = 0.0, denominator = 0.0
        for key in [\Color.red, \Color.green, \Color.blue] {
            let d = text[keyPath: key] - background[keyPath: key]
            guard abs(d) > 0.0001 else { continue }
            numerator += (target[keyPath: key] - background[keyPath: key]) * d
            denominator += d * d
        }
        guard denominator > 0 else { return 0.4 }
        return min(max(numerator / denominator, 0.2), 0.8)
    }

    /// Every colour the theme defines, for checks that nothing else is drawn.
    public var palette: [Color] {
        [accent, onAccent, gray.background, gray.surface, gray.raised, gray.line, gray.strongLine,
         gray.hover, gray.pressed, gray.text, gray.secondaryText, gray.tertiaryText]
    }
}

/// The greys. Solid where a surface must hide what is behind it; lines and
/// hover washes are white at low opacity so they read the same on any grey.
public struct Grays: Equatable, Sendable {
    /// Behind everything in a window.
    public var background = Color(hex: 0x0E0E0E)
    /// Sidebars, fields, panels.
    public var surface = Color(hex: 0x161616)
    /// Buttons, tracks, the selected row.
    public var raised = Color(hex: 0x202020)
    /// Every 1-point line: borders, dividers, tracks.
    public var line = Color(white: 1, opacity: 0.14)
    /// Lines that must stand out: a hovered border, a slider's thumb outline.
    public var strongLine = Color(white: 1, opacity: 0.32)
    /// Laid over a control the pointer is on.
    public var hover = Color(white: 1, opacity: 0.06)
    /// Laid over a control held down.
    public var pressed = Color(white: 1, opacity: 0.12)
    /// Body text.
    public var text = Color(hex: 0xEBEBEB)
    /// Labels and details.
    public var secondaryText = Color(hex: 0x9E9E9E)
    /// Hints, placeholders, section headers.
    public var tertiaryText = Color(hex: 0x6A6A6A)
    /// Opacity of a disabled control.
    public var disabledOpacity = 0.4
    public init() {}
}

/// Gaps and insets: multiples of 4 points.
public struct Spacing: Equatable, Sendable {
    public var xxs = 2.0
    public var xs = 4.0
    public var s = 8.0
    public var m = 12.0
    public var l = 16.0
    public var xl = 24.0
    public var xxl = 32.0
    public init() {}

    func scaled(by f: Double) -> Spacing {
        var s = self
        s.xxs *= f; s.xs *= f; s.s *= f; s.m *= f; s.l *= f; s.xl *= f; s.xxl *= f
        return s
    }
}

/// Sizes of controls, in points.
public struct Sizes: Equatable, Sendable {
    /// Buttons, fields, segmented controls, pickers.
    public var control = 24.0
    /// List rows.
    public var row = 28.0
    /// Toolbars.
    public var toolbar = 40.0
    /// Sidebars.
    public var sidebar = 200.0
    /// The switch of a toggle.
    public var toggleWidth = 26.0
    public var toggleHeight = 14.0
    /// A slider's thumb (square).
    public var thumb = 10.0
    /// A progress bar's height.
    public var progress = 4.0
    /// A scroll bar's width.
    public var scrollBar = 6.0
    public init() {}

    func scaled(by f: Double) -> Sizes {
        var s = self
        s.control *= f; s.row *= f; s.toolbar *= f; s.sidebar *= f
        s.toggleWidth *= f; s.toggleHeight *= f; s.thumb *= f; s.progress *= f; s.scrollBar *= f
        return s
    }
}

/// What a piece of text is for; the theme picks its font and size.
public enum TextRole: String, CaseIterable, Sendable {
    /// Running text and control titles.
    case body
    /// Small details under or beside body text.
    case caption
    /// Section headers and field labels (mono).
    case label
    /// Numbers, times, codes, shortcuts (mono).
    case mono
    /// A panel's or screen's title.
    case title
    /// The largest heading.
    case largeTitle
}

/// The fonts and the size of each role.
public struct TypeScale: Equatable {
    /// The proportional face (Geist in the house look).
    public var sans: FontFace?
    /// The monospaced face (Geist Mono).
    public var mono: FontFace?
    public var sizes: [TextRole: Double] = [.body: 13, .caption: 11, .label: 11, .mono: 12, .title: 15, .largeTitle: 22]

    public init(sans: FontFace?, mono: FontFace?) { self.sans = sans; self.mono = mono }

    /// The face a role uses: mono for labels and numbers, sans for the rest
    /// (each falls back to the other).
    public func face(_ role: TextRole) -> FontFace? {
        switch role {
        case .label, .mono: return mono ?? sans
        default: return sans ?? mono
        }
    }

    public func font(_ role: TextRole, scale: Double = 1) -> Font? {
        guard let f = face(role) else { return nil }
        return Font(f, size: (sizes[role] ?? 13) * scale)
    }

    public static func == (a: TypeScale, b: TypeScale) -> Bool {
        a.sans === b.sans && a.mono === b.mono && a.sizes == b.sizes
    }
}

struct ThemeKey: EnvironmentKey { static var defaultValue: Theme { Theme() } }

extension EnvironmentValues {
    /// The house look; set once with `.designRoot(theme:)`.
    public var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension View {
    /// Sets the theme for this view and everything inside it.
    public func theme(_ theme: Theme) -> some View { environment(\.theme, theme) }

    /// Changes only the accent for this view and everything inside it.
    public func accent(_ color: Color) -> some View { AccentScope(content: self, accent: color) }

    /// Gives text in this view the font of `role` and `color`.
    public func textStyle(_ role: TextRole, _ color: Color, theme: Theme) -> some View {
        environment(\.font, theme.font(role)).foregroundStyle(color)
    }

    /// The 1-point accent ring of a control with keyboard focus, inside its edge.
    public func focusRing(_ isFocused: Bool, theme: Theme) -> some View {
        // `.border` draws without taking clicks; a stroked shape would cover the control once visible.
        border(isFocused ? theme.accent : Color.clear, width: theme.line)
    }
}

/// Reads the theme and hands down the same theme with another accent.
public struct AccentScope<Content: View>: View {
    let content: Content
    let accent: Color
    @Environment(\.theme) var theme
    public var body: some View { content.environment(\.theme, theme.with(accent: accent)) }
}
