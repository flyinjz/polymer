// Text fields in the house look: the surface grey, a 1-point line that
// turns to the accent while the field has focus.
import PolymerBase
import PolymerUI

/// A one-line text field: `PTextField("Search", text: $query)`. The title is
/// the placeholder and names the field. Return runs `onSubmit`.
public struct PTextField: View {
    let title: String
    let name: String?
    let text: Binding<String>
    let commands: [Command]
    let submit: (@MainActor () -> Void)?
    @Environment(\.isEnabled) var isEnabled
    @FocusState var focused: Bool

    public init(_ title: String, text: Binding<String>, name: String? = nil, commands: [Command] = [],
                onSubmit: (@MainActor () -> Void)? = nil) {
        self.title = title; self.text = text; self.name = name; self.commands = commands; submit = onSubmit
    }

    public var body: some View {
        Component(name: name, role: "TextField", title: title, commands: commands) { info in
            let t = info.theme
            let submit = submit
            TextField(title, text: text)
                .onSubmit { submit?() }
                .textStyle(.body, t.gray.text, theme: t)
                .focused($focused)
                .padding(horizontal: t.space.s, vertical: 0)
                .frame(maxWidth: .infinity, minHeight: t.size.control, alignment: .leading)
                .background(Rectangle().fill(t.gray.surface))
                .border(focused ? t.accent : t.gray.line, width: t.line)
                .opacity(isEnabled ? 1 : t.gray.disabledOpacity)
        }
    }
}
