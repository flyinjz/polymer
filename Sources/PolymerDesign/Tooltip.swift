// Tooltips: a small panel under a view while the pointer is on it. Shown at
// once (no timer, so renders stay deterministic) and gone when the pointer
// leaves. The text is also the view's accessibility hint.
import PolymerBase
import PolymerUI

extension View {
    /// Shows `text` in a small panel under this view while the pointer is on it.
    public func tooltip(_ text: String) -> some View { TooltipView(content: self, text: text) }
}

public struct TooltipView<Content: View>: View {
    let content: Content
    let text: String
    @Environment(\.theme) var theme
    @State var hovered = false

    /// The widest a tooltip gets before its text wraps.
    static var maxWidth: Double { 320 }

    public var body: some View {
        let t = theme
        let text = text
        content
            .onHover { h in hovered = h }
            .overlay(Group {
                if hovered {
                    GeometryReader { p in
                        TooltipPanel(text: text, theme: t)
                            .frame(width: Self.maxWidth, alignment: .topLeading)
                            .offset(x: 0, y: p.size.height + t.space.xs)
                    }
                }
            })
            .accessibilityHint(text)
    }
}

/// The tooltip's panel: caption text on the surface grey with a line.
public struct TooltipPanel: View {
    let text: String
    let theme: Theme
    public init(text: String, theme: Theme) { self.text = text; self.theme = theme }
    public var body: some View {
        Text(text)
            .textStyle(.caption, theme.gray.text, theme: theme)
            .padding(horizontal: theme.space.s, vertical: theme.space.xs)
            .background(Rectangle().fill(theme.gray.surface))
            .border(theme.gray.strongLine, width: theme.line)
    }
}
