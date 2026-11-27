// Window layouts: a sidebar beside the detail, and a toolbar across the top.
// Lines between regions are 1 point; the sidebar is a solid surface, the
// toolbar the theme's material (content can pass under it).
import PolymerBase
import PolymerUI

/// A sidebar of the theme's width, a line, then the detail filling the rest:
/// `PSidebarLayout { sidebar rows } detail: { content }`. Paths: "sidebar"
/// (a component a person can hide) and "detail" (a part).
public struct PSidebarLayout<Sidebar: View, Detail: View>: View {
    let sidebar: Sidebar
    let detail: Detail
    @Environment(\.theme) var theme
    @Environment(\.elementPath) var parent
    @Environment(\.customizeModel) var model

    public init(@ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) {
        self.sidebar = sidebar(); self.detail = detail()
    }

    public var body: some View {
        let sidebarHidden = model?[ElementPath.join(parent, "sidebar")].hidden ?? false
        let sidebar = sidebar
        HStack(spacing: 0) {
            Component(name: "sidebar", role: "Sidebar", title: "Sidebar") { info in
                sidebar
                    .frame(width: info.theme.size.sidebar)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(Rectangle().fill(info.theme.gray.surface))
            }
            if !sidebarHidden {
                Rectangle().fill(theme.gray.line).frame(width: theme.line)
            }
            Part(name: "detail", role: "Detail", title: "Detail") {
                detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Rectangle().fill(theme.gray.background))
    }
}

/// A bar of controls across the top of a window or region, with a line under
/// it: `PToolbar { PButton(...); Spacer(); PButton(...) }`. Path "toolbar".
public struct PToolbar<Content: View>: View {
    let name: String
    let title: String
    let content: Content

    public init(_ title: String = "Toolbar", name: String = "toolbar", @ViewBuilder content: () -> Content) {
        self.title = title; self.name = name; self.content = content()
    }

    public var body: some View {
        let content = content
        Component(name: name, role: "Toolbar", title: title) { info in
            let t = info.theme
            HStack(spacing: t.space.s) { content }
                .padding(horizontal: t.space.m, vertical: 0)
                .frame(maxWidth: .infinity, minHeight: t.size.toolbar, maxHeight: t.size.toolbar)
                .background(t.material)
                .overlay(VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Rectangle().fill(t.gray.line).frame(height: t.line)
                })
        }
    }
}
