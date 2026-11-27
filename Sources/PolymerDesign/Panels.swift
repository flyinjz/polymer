// Panels: the look of sheets, popovers and any boxed group. A solid surface
// with a 1-point line, so a panel never stacks translucent veils over the
// window. `.panelSheet` and `.panelPopover` present content in one.
import PolymerBase
import PolymerUI

/// A boxed group with an optional title: `PPanel("Export") { ... }`.
public struct PPanel<Content: View>: View {
    let title: String?
    let name: String
    let content: Content

    public init(_ title: String? = nil, name: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.name = name ?? title.map { ElementPath.slug($0) } ?? "panel"
        self.content = content()
    }

    public var body: some View {
        let title = title, content = content
        Component(name: name, role: "Panel", title: title ?? "Panel") { info in
            let t = info.theme
            VStack(alignment: .leading, spacing: t.space.m) {
                if let title { Text(title).textStyle(.title, t.gray.text, theme: t) }
                content
            }
            .padding(t.space.l)
            .background(Rectangle().fill(t.gray.surface))
            // `.border`, not a stroked shape: a stroke takes clicks across its whole frame.
            .border(t.gray.line, width: t.line)
        }
    }
}

extension View {
    /// Shows `content` in a panel in front of the window while `isPresented`
    /// is true; Escape or `dismiss` closes it.
    public func panelSheet<Content: View>(isPresented: Binding<Bool>, title: String? = nil,
                                          @ViewBuilder content: @escaping () -> Content) -> some View {
        sheet(isPresented: isPresented) { PPanel(title, name: "sheet") { content() } }
    }

    /// Shows `content` in a panel next to this view while `isPresented` is true;
    /// a click outside closes it.
    public func panelPopover<Content: View>(isPresented: Binding<Bool>,
                                            @ViewBuilder content: @escaping () -> Content) -> some View {
        popover(isPresented: isPresented) { PPanel(nil, name: "popover") { content() } }
    }
}
