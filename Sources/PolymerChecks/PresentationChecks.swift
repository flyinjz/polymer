// Checks for menus, context menus, popovers, sheets and keyboard shortcuts.
import PolymerBase
import PolymerRender
import PolymerUI

@Observable
final class MenuModel {
    var log: [String] = []
    var showPopover = false
    var showSheet = false
    var name = ""
}

struct MenuSheet: View {
    let model: MenuModel
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Rename")
            TextField("Name", text: Binding(get: { model.name }, set: { model.name = $0 })).frame(width: 100)
            Button("Done") { dismiss() }
        }
        .padding(12)
    }
}

struct MenuScreen: View {
    let model: MenuModel
    let font: Font
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Menu("File") {
                    Button("New") { model.log.append("new") }.keyboardShortcut("n")
                    Button("Open") { model.log.append("open") }.keyboardShortcut("o", modifiers: [.command, .shift])
                    Divider()
                    Menu("Recent") {
                        Button("Alpha") { model.log.append("alpha") }
                        Button("Beta") { model.log.append("beta") }
                    }
                    Button("Close") { model.log.append("close") }.disabled(true)
                }
                Button("Info") { model.showPopover = true }
                    .popover(isPresented: Binding(get: { model.showPopover }, set: { model.showPopover = $0 })) {
                        Text("Details").padding(8)
                    }
                Button("Edit") { model.showSheet = true }
                    .sheet(isPresented: Binding(get: { model.showSheet }, set: { model.showSheet = $0 })) { MenuSheet(model: model) }
                Button("Save") { model.log.append("save") }.keyboardShortcut("s")
            }
            Text("Row")
                .contextMenu {
                    Button("Copy") { model.log.append("copy") }.keyboardShortcut("c")
                    Button("Delete") { model.log.append("delete") }
                }
        }
        .font(font)
        .frame(width: 320, height: 200, alignment: .topLeading)
    }
}

@Observable
final class SheetFocusModel {
    var show = false
    var name = ""
}

/// A window with a button that presents a sheet holding a text field.
struct SheetFocusScreen: View {
    let model: SheetFocusModel
    let font: Font
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Rename") { model.show = true }
            Text("Sheet target")
        }
        .font(font)
        .frame(width: 320, height: 200, alignment: .topLeading)
        .sheet(isPresented: Binding(get: { model.show }, set: { model.show = $0 })) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Rename album")
                TextField("Name", text: Binding(get: { model.name }, set: { model.name = $0 })).frame(width: 140)
                Button("Cancel") { model.show = false }
            }
            .font(font)
            .padding(12)
        }
    }
}

/// A sheet must not steal keystrokes into its first text field: the person
/// opened it, they did not ask to rename.
@MainActor
func sheetNoAutoFocus(_ c: inout CheckContext) throws {
    let font = Font(try TextReference.font(root: c.root, "Geist-Regular.otf"), size: 13)
    let model = SheetFocusModel()
    let tree = ViewTree(SheetFocusScreen(model: model, font: font))
    @MainActor func lines() -> [String] { tree.elementTree.split(separator: "\n").map { String($0.drop { $0 == " " }) } }
    _ = tree.render()
    c.expect(tree.focusedElement == nil, "nothing has focus at first")

    c.expect(tree.click(text: "Rename"), "the button presents the sheet")
    _ = tree.render()
    c.expect(model.show, "the sheet is up")
    c.expect(lines().contains { $0.hasPrefix("Sheet (") }, "a sheet is presented:\n\(tree.elementTree)")
    c.expect(lines().contains { $0.hasPrefix("TextField (") }, "it holds a text field:\n\(tree.elementTree)")
    c.expect(tree.focusedElement == nil, "presenting it focuses nothing: \(tree.focusedElement ?? "nil")")
    c.expect(!tree.acceptsTextInput, "so keystrokes have no field to reach")
    tree.type("Ada")
    c.expectEqual(model.name, "", "typing on presentation does not fill the field")

    // The field is still reachable: one Tab, then it types.
    tree.key("tab")
    c.expect(tree.focusedElement?.contains("TextField") == true,
             "Tab reaches the field: \(tree.focusedElement ?? "nil")")
    c.expect(tree.acceptsTextInput, "the field takes input once focused")
    tree.type("Ada")
    c.expectEqual(model.name, "Ada", "and then it types")
    c.expect(tree.click(text: "Cancel"), "the sheet closes")
    c.expect(!model.show && !lines().contains { $0.hasPrefix("Sheet (") }, "and its field goes with it")
}

@MainActor let presentationChecks: [Check] = [
    Check("ui.menus") { c in
        let font = Font(try TextReference.font(root: c.root, "Geist-Regular.otf"), size: 13)
        let model = MenuModel()
        let tree = ViewTree(MenuScreen(model: model, font: font))
        @MainActor func lines() -> [String] { tree.elementTree.split(separator: "\n").map { String($0.drop { $0 == " " }) } }
        @MainActor func panels(_ role: String) -> [String] { lines().filter { $0.hasPrefix(role + " (") } }
        _ = tree.render()
        c.expect(panels("Menu").isEmpty, "no menu at first")

        // A menu opens under its button; a click on an item runs it and closes the menu.
        let file = tree.point(ofText: "File") ?? .zero
        tree.click(at: file)
        let menu = panels("Menu")
        c.expectEqual(menu.count, 1, "the menu opened:\n\(tree.elementTree)")
        c.expect(menu.first?.hasPrefix("Menu (0, 17, ") == true, "under the button: \(menu)")
        c.expect(lines().contains { $0.hasPrefix("Text (") && $0.hasSuffix("\"cmd+n\"") } && lines().contains { $0.hasSuffix("\"shift+cmd+o\"") },
                 "items show their shortcuts:\n\(tree.elementTree)")
        c.expect(tree.accessibilityDescription.contains("menu ("), "the menu is in the accessibility tree:\n\(tree.accessibilityDescription)")
        tree.click(text: "New")
        c.expectEqual(model.log, ["new"], "the item ran")
        c.expect(panels("Menu").isEmpty, "and the menu closed")

        // Keyboard: arrows move (skipping disabled items, wrapping), Right opens a submenu, Return runs.
        tree.click(at: file)
        for _ in 0..<3 { tree.key("down") }
        c.expect(panels("Menu").first?.hasSuffix("highlighted \"Recent\"") == true, "down three times: \(panels("Menu"))")
        tree.key("down")
        c.expect(panels("Menu").first?.hasSuffix("highlighted \"New\"") == true, "the disabled item is skipped and it wraps: \(panels("Menu"))")
        tree.key("up")
        tree.key("right")
        c.expectEqual(panels("Menu").count, 2, "right opens the submenu:\n\(tree.elementTree)")
        tree.key("down"); tree.key("down")
        c.expect(panels("Menu").last?.hasSuffix("highlighted \"Beta\"") == true, "the submenu has its own highlight: \(panels("Menu"))")
        tree.key("left")
        c.expectEqual(panels("Menu").count, 1, "left closes the submenu")
        tree.key("right"); tree.key("down"); tree.key("return")
        c.expectEqual(model.log, ["new", "alpha"], "return runs the submenu item")
        c.expect(panels("Menu").isEmpty, "and every menu closes")

        // A click outside a menu closes it and goes no further.
        tree.click(at: file)
        tree.click(text: "Info")
        c.expect(panels("Menu").isEmpty && !model.showPopover, "the click closed the menu without pressing Info")
        tree.key("cmd+s")
        c.expectEqual(model.log.last, "save", "a shortcut runs its button from anywhere")
        tree.key("cmd+n")
        c.expectEqual(model.log.last, "save", "items of a closed menu are not reachable by shortcut")

        // Popover: under its button, Escape closes it.
        tree.click(text: "Info")
        _ = tree.render()
        let info = tree.point(ofText: "Info") ?? .zero
        let pop = panels("Popover")
        c.expectEqual(pop.count, 1, "the popover opened:\n\(tree.elementTree)")
        c.expect(pop.first.map { $0.contains(", 21, ") } == true, "4 points under its button (17 tall): \(pop) under \(info)")
        tree.key("escape")
        c.expect(!model.showPopover && panels("Popover").isEmpty, "escape closed it and set the binding")

        // Sheet: in the middle, takes input, dismiss closes it.
        tree.click(text: "Edit")
        _ = tree.render()
        let sheet = panels("Sheet")
        c.expectEqual(sheet.count, 1, "the sheet opened:\n\(tree.elementTree)")
        tree.click(text: "Info")
        c.expect(!model.showPopover, "nothing behind the sheet takes a click")
        tree.key("tab")
        tree.type("Ada")
        c.expectEqual(model.name, "Ada", "Tab stays in the sheet and focuses its field")
        tree.key("cmd+s")
        c.expectEqual(model.log.last, "save", "shortcuts behind the sheet don't run")
        c.expectEqual(model.log.count, 3, "(the log is unchanged)")
        tree.click(text: "Done")
        c.expect(!model.showSheet && panels("Sheet").isEmpty, "dismiss() closed it")

        // Context menu: at the click.
        let row = tree.point(ofText: "Row") ?? .zero
        c.expect(tree.contextClick(at: row), "right-click on the row opens its menu")
        c.expect(panels("Menu").first?.hasPrefix("Menu (\(Int(row.x)), \(Int(row.y)), ") == true, "at the click: \(panels("Menu")) at \(row)")
        tree.click(text: "Delete")
        c.expectEqual(model.log.last, "delete", "its item ran")
        c.expect(!tree.contextClick(at: Point(x: 300, y: 190)), "nothing to open where no view has a context menu")

        // Partial frames equal whole draws while menus open and close.
        var e = EnvironmentValues()
        e.displayScale = 2
        let m2 = MenuModel()
        let t2 = ViewTree(MenuScreen(model: m2, font: font), environment: e)
        _ = t2.render(background: .black)
        let steps: [@MainActor () -> Void] = [
            { t2.click(text: "File") }, { t2.key("down") }, { t2.key("down") }, { t2.key("escape") },
            { t2.click(text: "Info") }, { t2.key("escape") }, { t2.click(text: "Edit") }, { t2.click(text: "Done") },
        ]
        for (k, step) in steps.enumerated() {
            step()
            let img = t2.render(background: .black)
            var whole = Canvas(width: img.width, height: img.height, scale: 2, background: .black)
            if let l = t2.displayList { whole.draw(l) }
            c.expect(img == whole.bitmap, "after step \(k), a partial frame equals a whole draw")
        }
    },

    Check("ui.sheet.noAutoFocus", sheetNoAutoFocus),
    // The same check under the module's name, so `polymer check presentation.` runs it.
    Check("presentation.sheet.noAutoFocus", sheetNoAutoFocus),
]
