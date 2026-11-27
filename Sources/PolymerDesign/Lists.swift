// Rows and section headers for lists, sidebars and settings: full width, a
// 1-point line under each, the chosen row raised with an accent bar.
import PolymerBase
import PolymerUI

/// A row in a list: `PListRow("Blue Train", detail: "10:43", isSelected: chosen) { open() }`,
/// or with any content: `PListRow("Blue Train") { ... } label: { ... }`.
public struct PListRow<Label: View>: View {
    let title: String
    let name: String?
    let isSelected: Bool
    let commands: [Command]
    let action: @MainActor () -> Void
    let label: Label
    @Environment(\.isEnabled) var isEnabled
    @State var hovered = false
    @FocusState var focused: Bool

    /// `title` names the row for people, screen readers and its path.
    public init(_ title: String, isSelected: Bool = false, name: String? = nil, commands: [Command] = [],
                action: @escaping @MainActor () -> Void, @ViewBuilder label: () -> Label) {
        self.title = title; self.isSelected = isSelected; self.name = name; self.commands = commands
        self.action = action; self.label = label()
    }

    public var body: some View {
        Component(name: name, role: "Row", title: title, commands: commands) { info in
            let t = info.theme
            Button(action: action) {
                label
                    .padding(horizontal: t.space.m, vertical: 0)
                    .frame(maxWidth: .infinity, minHeight: t.size.row, alignment: .leading)
                    .background(Rectangle().fill(isSelected ? t.gray.raised : Theme.hitFill))
                    .overlay(Rectangle().fill(hovered && isEnabled && !isSelected ? t.gray.hover : Color.clear))
                    .overlay(HStack(spacing: 0) {
                        Rectangle().fill(isSelected ? t.accent : Color.clear).frame(width: 2 * t.line)
                        Spacer(minLength: 0)
                    })
                    .overlay(VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Rectangle().fill(t.gray.line).frame(height: t.line)
                    })
                    .focusRing(focused, theme: t)
            }
            .buttonStyle(PlainButtonStyle())
            .focused($focused)
            .onHover { h in hovered = h }
            .opacity(isEnabled ? 1 : t.gray.disabledOpacity)
            .accessibilityLabel(title)
            .accessibilityValue(isSelected ? "Selected" : "")
        }
    }
}

extension PListRow where Label == PRowLabel {
    /// A row of a title and, at its end, a detail in mono (a time, a count).
    public init(_ title: String, detail: String? = nil, isSelected: Bool = false, name: String? = nil,
                commands: [Command] = [], action: @escaping @MainActor () -> Void) {
        self.init(title, isSelected: isSelected, name: name, commands: commands, action: action) {
            PRowLabel(title: title, detail: detail)
        }
    }
}

/// A row's title and detail.
public struct PRowLabel: View {
    let title: String
    let detail: String?
    @Environment(\.theme) var theme
    public init(title: String, detail: String? = nil) { self.title = title; self.detail = detail }
    public var body: some View {
        HStack(spacing: theme.space.s) {
            Text(title).textStyle(.body, theme.gray.text, theme: theme)
            Spacer(minLength: theme.space.s)
            if let detail { Text(detail).textStyle(.mono, theme.gray.secondaryText, theme: theme) }
        }
    }
}

/// The title over a group of rows, in small mono grey with a line under it:
/// `PSectionHeader("Playlists")`. Write it in sentence case; it is not capitalised.
public struct PSectionHeader: View {
    let title: String
    let name: String?
    public init(_ title: String, name: String? = nil) { self.title = title; self.name = name }

    public var body: some View {
        Component(name: name, role: "SectionHeader", title: title) { info in
            let t = info.theme
            Text(title)
                .textStyle(.label, t.gray.tertiaryText, theme: t)
                .padding(EdgeInsets(top: t.space.l, leading: t.space.m, bottom: t.space.xs, trailing: t.space.m))
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Rectangle().fill(t.gray.line).frame(height: t.line)
                })
                .accessibilityAddTraits(.isHeader)
        }
    }
}
