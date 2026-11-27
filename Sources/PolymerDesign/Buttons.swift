// Buttons in the house look: four kinds, square, a 1-point line, the accent
// only on the primary action and the focus ring.
import PolymerBase
import PolymerUI

/// What a button is for, and so how it looks.
public enum PButtonKind: String, CaseIterable, Sendable {
    /// The one main action of a screen or panel: filled with the accent.
    case primary
    /// Every other action: raised grey with a line.
    case secondary
    /// Quiet actions in toolbars and rows: text only, a wash on hover.
    case plain
    /// A square button with one symbol.
    case icon
}

/// The button style behind `PButton`; usable on any `Button` with
/// `.buttonStyle(HouseButtonStyle(kind:theme:))`.
public struct HouseButtonStyle: ButtonStyle {
    public var kind: PButtonKind
    public var theme: Theme
    public var isHovered: Bool
    public var isFocused: Bool

    public init(kind: PButtonKind, theme: Theme, isHovered: Bool = false, isFocused: Bool = false) {
        self.kind = kind; self.theme = theme; self.isHovered = isHovered; self.isFocused = isFocused
    }

    public func makeBody(configuration: Configuration) -> some View {
        let t = theme
        let fill = Self.fill(kind, t)
        let wash: Color = configuration.isPressed ? t.gray.pressed : isHovered ? t.gray.hover : Color.clear
        let text: Color = kind == .primary ? t.onAccent : t.gray.text
        let border: Color = kind == .secondary ? (isHovered ? t.gray.strongLine : t.gray.line) : Color.clear
        let side = t.size.control
        configuration.label
            .environment(\.font, t.font(kind == .icon ? .title : .body))
            .foregroundStyle(text)
            .padding(horizontal: kind == .icon ? 0 : t.space.m, vertical: 0)
            .frame(minWidth: side, minHeight: side)
            .frame(width: kind == .icon ? side : nil, height: side)
            .background(Rectangle().fill(fill))
            .overlay(Rectangle().fill(wash))
            .border(border, width: t.line)
            .focusRing(isFocused, theme: t)
    }

    /// The accent for primary, raised grey for secondary, nothing visible for the rest.
    static func fill(_ kind: PButtonKind, _ t: Theme) -> Color {
        switch kind {
        case .primary: return t.accent
        case .secondary: return t.gray.raised
        case .plain, .icon: return Theme.hitFill
        }
    }
}

/// A button: `PButton("Save", kind: .primary) { save() }`. Its path is
/// `name` (the title's slug by default); its right-click menu has its
/// commands and Customize, where a person can switch it between styles.
public struct PButton: View {
    let title: String
    let symbol: String?
    let kind: PButtonKind
    let name: String?
    let shortcut: KeyboardShortcut?
    let commands: [Command]
    let action: @MainActor () -> Void

    @Environment(\.isEnabled) var isEnabled
    @State var hovered = false
    @FocusState var focused: Bool

    public init(_ title: String, kind: PButtonKind = .secondary, name: String? = nil, shortcut: KeyboardShortcut? = nil,
                commands: [Command] = [], action: @escaping @MainActor () -> Void) {
        self.title = title; symbol = nil; self.kind = kind; self.name = name
        self.shortcut = shortcut; self.commands = commands; self.action = action
    }

    /// A square button showing `symbol` (one character of the icon font);
    /// `help` names it for people, screen readers and its path.
    public init(symbol: String, help: String, name: String? = nil, shortcut: KeyboardShortcut? = nil,
                commands: [Command] = [], action: @escaping @MainActor () -> Void) {
        title = help; self.symbol = symbol; kind = .icon; self.name = name
        self.shortcut = shortcut; self.commands = commands; self.action = action
    }

    static let textStyles = [PButtonKind.secondary, .primary, .plain].map(\.rawValue)

    public var body: some View {
        let isIcon = symbol != nil
        Component(name: name, role: "Button", title: title, styles: isIcon ? [] : Self.textStyles,
                  defaultStyle: kind.rawValue, commands: commands) { info in
            let k = isIcon ? PButtonKind.icon : (PButtonKind(rawValue: info.style) ?? kind)
            let style = HouseButtonStyle(kind: k, theme: info.theme, isHovered: hovered && isEnabled, isFocused: focused)
            styled(Button(action: action) { Text(symbol ?? title) }, style: style)
                .focused($focused)
                .onHover { h in hovered = h }
                .opacity(isEnabled ? 1 : info.theme.gray.disabledOpacity)
                .accessibilityLabel(title)
        }
    }

    @ViewBuilder
    func styled<B: View>(_ b: B, style: HouseButtonStyle) -> some View {
        if let s = shortcut {
            b.keyboardShortcut(s.key, modifiers: s.modifiers).buttonStyle(style)
        } else {
            b.buttonStyle(style)
        }
    }
}
