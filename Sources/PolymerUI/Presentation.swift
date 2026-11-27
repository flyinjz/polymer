// Menus, popovers and sheets, as in SwiftUI: `Menu`, `.contextMenu`,
// `.popover(isPresented:)`, `.sheet(isPresented:)`, with
// `.keyboardShortcut` and `@Environment(\.dismiss)`. They are presentations:
// content drawn above the root view, in a panel, laid out and hit-tested by
// the tree, listed in the element tree after the root. Menu items are the
// same Buttons as anywhere else, so one action has one definition wherever
// it appears (the command idea of DESIGN section 7). The panel's look is a
// placeholder until the design system decides it.
import PolymerBase
import PolymerRender

// MARK: Keyboard shortcuts

/// A key with modifiers that runs a button from anywhere in its window.
public struct KeyboardShortcut: Hashable, Sendable {
    public var key: KeyEquivalent
    public var modifiers: EventModifiers
    public init(_ key: KeyEquivalent, modifiers: EventModifiers = .command) { self.key = key; self.modifiers = modifiers }

    /// As the `key` text form: "cmd+shift+n".
    public var description: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("alt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(KeyEquivalent.names.first { $0.1 == key }?.0 ?? String(key.character))
        return parts.joined(separator: "+")
    }

    func matches(_ p: KeyPress) -> Bool {
        p.phase == .down && p.modifiers == modifiers && (p.key == key || String(p.key.character).lowercased() == String(key.character).lowercased())
    }
}

extension View {
    /// Runs the button this wraps when `key` with `modifiers` is pressed and
    /// nothing focused used it. Menu items show it.
    public func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> some View {
        ShortcutView(content: self, shortcut: KeyboardShortcut(key, modifiers: modifiers))
    }

    /// Runs the button this wraps when `shortcut` is pressed and nothing focused used it.
    public func keyboardShortcut(_ shortcut: KeyboardShortcut) -> some View {
        ShortcutView(content: self, shortcut: shortcut)
    }
}

struct ShortcutView<Content: View>: View, PrimitiveView {
    let content: Content
    let shortcut: KeyboardShortcut
    var body: Never { fatalError("ShortcutView is a built-in view") }
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? ShortcutNode) ?? ShortcutNode()
        n.shortcut = shortcut
        var c = c
        c.environment.keyboardShortcut = shortcut
        n.setChild(0, content, c)
        return n
    }
}

final class ShortcutNode: PassthroughNode {
    var shortcut = KeyboardShortcut("a")
    /// The button it runs.
    var button: TapNode? { first { ($0 as? TapNode)?.isButton == true } as? TapNode }
}

struct KeyboardShortcutKey: EnvironmentKey { static var defaultValue: KeyboardShortcut? { nil } }
struct MenuKey: EnvironmentKey { static var defaultValue: MenuContext? { nil } }
struct DismissKey: EnvironmentKey { static var defaultValue: DismissAction { DismissAction(run: nil) } }

/// What a menu tells the buttons in it.
@MainActor final class MenuContext {
    weak var presentation: Presentation?
    init(_ p: Presentation) { presentation = p }
}

extension EnvironmentValues {
    var keyboardShortcut: KeyboardShortcut? {
        get { self[KeyboardShortcutKey.self] }
        set { self[KeyboardShortcutKey.self] = newValue }
    }
    /// Set inside a menu: buttons there are menu items.
    var menu: MenuContext? {
        get { self[MenuKey.self] }
        set { self[MenuKey.self] = newValue }
    }
    /// Closes the sheet or popover the view is in (nothing elsewhere).
    public var dismiss: DismissAction {
        get { self[DismissKey.self] }
        set { self[DismissKey.self] = newValue }
    }
}

/// Closes the presentation a view is in: `@Environment(\.dismiss) var dismiss`, then `dismiss()`.
public struct DismissAction {
    let run: (@MainActor () -> Void)?
    @MainActor public func callAsFunction() { run?() }
}

// MARK: Presentations

enum PresentationKind { case menu, popover, sheet }

/// Content shown above the root view.
@MainActor final class Presentation {
    let kind: PresentationKind
    /// The view that presented it; the presentation goes when it does.
    weak var owner: Node?
    /// The panel node (Menu, Popover or Sheet) holding the content.
    let panel: PanelNode
    /// Where a context menu was asked for (screen points); nil: next to the owner.
    var point: Point?
    /// The menu this one opened from (a submenu).
    weak var parent: Presentation?
    /// Closes it (a binding set to false, or the menu taken away).
    var close: () -> Void = {}
    /// What its items are told (a menu). Kept here so it lives as long as the
    /// menu: the environment holding it is not kept by every item.
    private(set) lazy var menuContext = MenuContext(self)

    init(_ kind: PresentationKind, owner: Node) {
        self.kind = kind; self.owner = owner
        panel = PanelNode(kind)
    }
    var isModal: Bool { kind == .sheet }
    var frame: Rect { panel.frame }
}

/// The panel a presentation draws: its background, border and content.
final class PanelNode: Node {
    let kind: PresentationKind
    init(_ kind: PresentationKind) { self.kind = kind; super.init() }
    /// The highlighted item of a menu (by pointer or arrow keys), an index into `items`.
    var highlighted: Int?

    /// The look, read from the environment where the panel's content was resolved.
    var look = PanelLook()

    static let padding = 4.0

    override var role: String { switch kind { case .menu: "Menu"; case .popover: "Popover"; case .sheet: "Sheet" } }
    override var detail: String {
        guard let h = highlighted, h < items.count, let t = items[h].first(where: { $0 is TextNode }) as? TextNode else { return "" }
        return "highlighted \"\(t.string)\""
    }
    override var isHitTarget: Bool { true }
    private var inset: Double { kind == .menu ? PanelNode.padding : 0 }
    override func sizeThatFits(_ p: ProposedViewSize) -> Size {
        guard let c = children.first else { return .zero }
        let s = c.measure(ProposedViewSize(width: p.width.map { $0 - 2 * inset }, height: p.height.map { $0 - 2 * inset }))
        return Size(width: s.width + 2 * inset, height: s.height + 2 * inset)
    }
    override func placeChildren(in r: Rect) {
        guard let c = children.first else { return }
        let inner = r.inset(by: EdgeInsets(all: inset))
        // Menu items fill the menu's width.
        let s = c.measure(ProposedViewSize(inner.size))
        c.place(Rect(origin: inner.origin, size: kind == .menu ? inner.size : s))
    }

    /// The menu's items, in order.
    var items: [TapNode] {
        var out: [TapNode] = []
        func walk(_ n: Node) {
            if let t = n as? TapNode, t.isButton { out.append(t); return }
            for c in n.children { walk(c) }
        }
        if let c = children.first { walk(c) }
        return out
    }

    override func drawContent(_ list: inout DisplayList) {
        // Placeholder look: an opaque dark panel with a 1-point line around it.
        let f = frame
        list.fill(f, look.background)
        let w = 1.0
        list.fill(Rect(x: f.minX, y: f.minY, width: f.width, height: w), look.line)
        list.fill(Rect(x: f.minX, y: f.maxY - w, width: f.width, height: w), look.line)
        list.fill(Rect(x: f.minX, y: f.minY + w, width: w, height: f.height - 2 * w), look.line)
        list.fill(Rect(x: f.maxX - w, y: f.minY + w, width: w, height: f.height - 2 * w), look.line)
        if let h = highlighted, h < items.count { list.fill(items[h].contentFrame, look.highlight) }
        super.drawContent(&list)
    }

    override func hitTest(_ p: Point) -> Node? {
        guard frame.contains(p) else { return nil }
        return super.hitTest(p) ?? self
    }
}

/// The panel look (placeholders for design tokens). PolymerDesign themes it
/// with `.environment(\.panelLook, ...)`.
public struct PanelLook: Equatable, Sendable {
    public var background: Color
    public var line: Color
    public var highlight: Color
    /// A shortcut shown in a menu item: the text colour at this opacity.
    public var shortcutOpacity: Double
    /// A disabled menu item.
    public var disabledOpacity: Double
    /// Room between a popover and what it points at.
    public var gap: Double

    public init(background: Color = Color(white: 0.11), line: Color = Color(white: 1, opacity: 0.14),
                highlight: Color = Color(white: 1, opacity: 0.12), shortcutOpacity: Double = 0.5,
                disabledOpacity: Double = 0.4, gap: Double = 4) {
        self.background = background
        self.line = line
        self.highlight = highlight
        self.shortcutOpacity = shortcutOpacity
        self.disabledOpacity = disabledOpacity
        self.gap = gap
    }
}

struct PanelLookKey: EnvironmentKey { static var defaultValue: PanelLook { PanelLook() } }
extension EnvironmentValues {
    /// The look of menus, popovers and sheets; set with `.environment(\.panelLook, ...)`.
    public var panelLook: PanelLook {
        get { self[PanelLookKey.self] }
        set { self[PanelLookKey.self] = newValue }
    }
}

extension TreeState {
    func present(_ p: Presentation) {
        presentations.removeAll { $0 === p }
        presentations.append(p)
        layoutRequested = true
        // A sheet takes focus from what is behind it.
        if p.isModal, let f = focused, !f.isInside(p.panel) { setFocus(nil) }
    }

    func remove(_ p: Presentation) {
        // Submenus go with their menu.
        for child in presentations where child.parent === p { remove(child) }
        guard presentations.contains(where: { $0 === p }) else { return }
        presentations.removeAll { $0 === p }
        if let f = focused, f.isInside(p.panel) { setFocus(nil) }
        p.panel.unmount()
        layoutRequested = true
    }

    /// Closes every menu and popover above the top sheet (a click outside them).
    func closeTransient() {
        for p in presentations.reversed() {
            if p.isModal { break }
            p.close()
        }
    }

    /// The front-most sheet, if any: nothing behind it takes input.
    var modal: Presentation? { presentations.last { $0.isModal } }
}

// MARK: Popover and sheet

extension View {
    /// Shows `content` in a panel next to this view while `isPresented` is true.
    /// A click outside or Escape closes it (setting `isPresented` to false).
    public func popover<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        PresentingView(content: self, kind: .popover, isPresented: isPresented, presented: content)
    }
    /// Shows `content` in a panel in front of the window while `isPresented` is
    /// true; nothing behind it takes input until it closes.
    public func sheet<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        PresentingView(content: self, kind: .sheet, isPresented: isPresented, presented: content)
    }
}

struct PresentingView<Content: View, Presented: View>: View, PrimitiveView {
    let content: Content
    let kind: PresentationKind
    let isPresented: Binding<Bool>
    let presented: () -> Presented
    var body: Never { fatalError("PresentingView is a built-in view") }

    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? PresentingNode).flatMap { $0.kind == kind ? $0 : nil } ?? PresentingNode(kind)
        n.setChild(0, content, c)
        let shown = c.host?.track { isPresented.wrappedValue } ?? isPresented.wrappedValue
        if shown {
            let p = n.presentation ?? Presentation(kind, owner: n)
            n.presentation = p
            let binding = isPresented
            p.close = { binding.wrappedValue = false }
            var pc = c
            pc.environment.dismiss = DismissAction { binding.wrappedValue = false }
            pc.stackAxis = nil
            let view = c.host?.track { presented() } ?? presented()
            p.panel.setChild(0, view, pc)
            p.panel.tree = c.tree
            p.panel.scale = c.environment.displayScale
            p.panel.look = c.environment.panelLook
            p.panel.resolvedOnce = true
            if !c.tree.presentations.contains(where: { $0 === p }) { c.tree.present(p) }
            p.panel.invalidateLayout()
            c.tree.layoutRequested = true
        } else if let p = n.presentation {
            n.presentation = nil
            c.tree.remove(p)
        }
        return n
    }
}

final class PresentingNode: PassthroughNode {
    let kind: PresentationKind
    var presentation: Presentation?
    init(_ kind: PresentationKind) { self.kind = kind; super.init() }
    override func unmount() {
        if let p = presentation { tree?.remove(p); presentation = nil }
        super.unmount()
    }
}

// MARK: Menus

/// A button that opens a menu of `content` (Buttons, Dividers and other Menus).
public struct Menu<Label: View, Content: View>: View, PrimitiveView {
    let label: Label
    let content: () -> Content
    public init(@ViewBuilder content: @escaping () -> Content, @ViewBuilder label: () -> Label) {
        self.content = content; self.label = label()
    }
    public var body: Never { fatalError("Menu is a built-in view") }

    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? MenuNode) ?? MenuNode()
        let content = content
        n.build = { p, c in
            let v = c.host?.track { content() } ?? content()
            p.panel.setChild(0, MenuList(content: v), c)
        }
        n.context = c
        let inMenu = c.environment.menu != nil
        n.isSubmenu = inMenu
        // Opening the menu is the button's action; inside a menu, the item shows that it opens one.
        var bc = c
        bc.environment.menu = nil
        n.setChild(0, Button(action: { [weak n] in n?.toggle() }) {
            if inMenu { MenuItemLabel(label: label, trailing: "\u{203A}", enabled: c.environment.isEnabled) } else { label }
        }, bc)
        n.refresh()
        return n
    }
}

extension Menu where Label == Text {
    public init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(content: content) { Text(title) }
    }
}

/// The items of a menu, one under another.
struct MenuList<Content: View>: View, PrimitiveView {
    let content: Content
    var body: Never { fatalError("MenuList is a built-in view") }
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        reconcile(VStack(alignment: .leading, spacing: 0) { content }, existing, c)
    }
}

final class MenuNode: PassthroughNode {
    var build: ((Presentation, ResolveContext) -> Void)?
    var context: ResolveContext?
    var isSubmenu = false
    private(set) var presentation: Presentation?

    var button: TapNode? { children.first as? TapNode }

    func toggle() { if presentation == nil { open(at: nil) } else { closeMenu() } }

    /// Opens the menu: next to this view, or at `point` (a context menu).
    func open(at point: Point?) {
        guard presentation == nil, let tree, let c = context else { return }
        let p = Presentation(.menu, owner: self)
        p.point = point
        p.close = { [weak self] in self?.closeMenu() }
        if isSubmenu, let parent = c.environment.menu?.presentation { p.parent = parent }
        presentation = p
        tree.present(p)
        refresh()
    }

    func closeMenu() {
        guard let p = presentation else { return }
        presentation = nil
        tree?.remove(p)
    }

    /// Builds the open menu's items from the latest view values.
    func refresh() {
        guard let p = presentation, var c = context else { return }
        c.environment.menu = p.menuContext
        c.stackAxis = nil
        c.environment.dismiss = DismissAction { [weak self] in self?.closeMenu() }
        build?(p, c)
        p.panel.tree = c.tree
        p.panel.scale = c.environment.displayScale
        p.panel.look = c.environment.panelLook
        p.panel.resolvedOnce = true
        p.panel.invalidateLayout()
        c.tree.layoutRequested = true
    }

    override func unmount() {
        closeMenu()
        super.unmount()
    }
}

extension View {
    /// A menu of `items` that opens where the view is right-clicked (`ViewTree.contextClick(at:)`).
    public func contextMenu<Items: View>(@ViewBuilder menuItems: @escaping () -> Items) -> some View {
        ContextMenuView(content: self, items: menuItems)
    }
}

struct ContextMenuView<Content: View, Items: View>: View, PrimitiveView {
    let content: Content
    let items: () -> Items
    var body: Never { fatalError("ContextMenuView is a built-in view") }
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? ContextMenuNode) ?? ContextMenuNode()
        n.setChild(0, content, c)
        let items = items
        n.menu.build = { p, c in
            let v = c.host?.track { items() } ?? items()
            p.panel.setChild(0, MenuList(content: v), c)
        }
        n.menu.context = c
        n.menu.tree = c.tree
        n.menu.parent = n
        n.menu.refresh()
        return n
    }
}

final class ContextMenuNode: PassthroughNode {
    /// Holds the menu (not a child: the view itself shows no button).
    let menu = MenuNode()
    override func unmount() {
        menu.closeMenu()
        super.unmount()
    }
}

/// How a button looks as a menu item: its label, then its shortcut (or a
/// submenu's mark), across the menu; dimmed when disabled.
struct MenuItemLabel<Label: View>: View {
    let label: Label
    let trailing: String?
    let enabled: Bool
    @Environment(\.panelLook) private var look
    var body: some View {
        HStack(spacing: 16) {
            label
            Spacer(minLength: 0)
            if let trailing { Text(trailing).opacity(look.shortcutOpacity) }
        }
        .padding(horizontal: 8, vertical: 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(enabled ? 1 : look.disabledOpacity)
    }
}
