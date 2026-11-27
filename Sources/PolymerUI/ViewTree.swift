// A live view tree: keeps the nodes of a root view, re-evaluates the views
// whose state changed, lays out, draws, and takes input. Windows and the
// headless tools both drive one of these.
import PolymerBase
import PolymerText
import PolymerRender
import protocol PolymerPlatform.Clipboard
import class PolymerPlatform.MemoryClipboard

@MainActor
public final class ViewTree {
    private let state = TreeState()
    private let glyphCache = GlyphCache()
    private var root: Node?
    private var resolveRoot: (Node?, ResolveContext) -> Node
    private var needsResolve = true
    private var needsLayout = true
    /// Where the pointer is (screen points), nil when outside.
    private var pointer: Point?
    /// The button or tap handler the pointer went down on.
    private weak var pressedNode: Node?
    /// The drag gesture following the pointer while it is down.
    private weak var dragNode: DragGestureNode?
    /// The text field following the pointer while it is down (selecting by dragging).
    private weak var textNode: TextInputNode?
    /// The last frame: what it drew, its pixels and background.
    private var lastList: DisplayList?
    private var spareList: DisplayList?
    /// The list recorded since the last `render()`, and the damage it repeated
    /// (a window records and draws on the GPU; `render()` then needs no new list).
    private var pendingList: DisplayList?
    private var pendingDamage: [PixelRect] = []
    /// The background the last recorded list was damaged against.
    private var recordedBackground: Color?
    private var frameCanvas: Canvas?
    private var frameBackground: Color?

    /// Pixel rectangles the last recorded frame changed: the whole image the
    /// first time (or after a size or background change), then only what
    /// changed since the frame before; empty when nothing did.
    public private(set) var damage: [PixelRect] = []
    /// What the last `render()` drew, in drawing order.
    public var displayList: DisplayList? { lastList }

    /// Environment of the root view. `displayScale` is the pixels per point images are drawn at.
    public var environment: EnvironmentValues { didSet { needsResolve = true } }
    /// Size offered to the root view; nil in a dimension uses the view's ideal size.
    public var proposedSize: ProposedViewSize = .unspecified { didSet { needsLayout = true } }
    /// Size the root view chose, in points. Valid after `update()`.
    public private(set) var size: Size = .zero

    public init<Root: View>(_ root: Root, environment: EnvironmentValues = EnvironmentValues()) {
        resolveRoot = { existing, c in reconcile(root, existing, c) }
        self.environment = environment
    }

    /// Replaces the root view. State is kept where the new view has the same structure.
    public func setRoot<Root: View>(_ root: Root) {
        resolveRoot = { existing, c in reconcile(root, existing, c) }
        needsResolve = true
    }

    /// True when `update()` has work to do.
    public var needsUpdate: Bool { needsResolve || needsLayout || state.layoutRequested || !state.queue.isEmpty }

    /// Called, possibly from another thread, when a view's state changed and
    /// the tree needs an `update()`. A window uses it to schedule a frame.
    public func onInvalidate(_ handler: (@Sendable () -> Void)?) { state.queue.onPush(handler) }

    /// The time in seconds, for animations. A window sets it to the display's
    /// frame time before each frame; headless checks step it.
    public var time: Double {
        get { state.now }
        set { state.now = newValue }
    }

    /// True while an animation is still moving at `time`: a window keeps drawing frames.
    public var isAnimating: Bool { state.pruneAnimations() }

    /// Number of view bodies evaluated since the tree was made.
    public var bodyEvaluations: Int { state.bodyEvaluations }

    /// Re-evaluates the views whose state changed and lays the tree out.
    /// Returns true when anything was evaluated.
    @discardableResult
    public func update() -> Bool {
        state.pruneGhosts()
        var changed = updateOnce()
        // Views may have set a @FocusState, or the focused view may have left; settle focus, then evaluate what that changed.
        for _ in 0..<4 {
            if !state.syncFocus(root: root) { break }
            if updateOnce() { changed = true }
        }
        return changed
    }

    private func updateOnce() -> Bool {
        var changed = false
        state.pass += 1
        // Changes made inside withAnimation animate everything this update moves.
        defer { state.passAnimation = nil }
        if needsResolve {
            needsResolve = false
            let c = ResolveContext(environment: environment, stackAxis: nil, tree: state, host: nil)
            let new = resolveRoot(root, c)
            if new !== root { root?.unmount(); root = new }
            changed = true
        }
        var rounds = 0
        while true {
            let pending = state.queue.drain()
            if pending.isEmpty { break }
            rounds += 1
            if rounds > 64 {
                Logger("PolymerUI").error("A view changes state every time its body runs, so the tree never settles. Change state in actions (button handlers, callbacks), not in body.")
                break
            }
            var hosts: [any ViewHost] = []
            for (p, animation) in pending {
                if state.passAnimation == nil, let animation { state.passAnimation = animation }
                if let h = p.host, !h.isDirty { h.isDirty = true; hosts.append(h) }
            }
            // Outer views first: evaluating one brings the views inside it up to date too.
            hosts.sort { $0.depth < $1.depth }
            for h in hosts where h.isDirty { h.reevaluate(); changed = true }
        }
        if changed || needsLayout || state.layoutRequested { layout() }
        return changed
    }

    private func layout() {
        needsLayout = false
        guard let root else { state.layoutRequested = false; return }
        let scale = environment.displayScale
        // A lazy stack asks for another pass when rows it built were not the
        // size it estimated; that settles after a pass or two.
        for _ in 0..<8 {
            state.layoutRequested = false
            var s = root.measure(proposedSize)
            s = Size(width: (s.width * scale).rounded(.up) / scale, height: (s.height * scale).rounded(.up) / scale)
            root.place(Rect(origin: .zero, size: s))
            size = s
            if !state.layoutRequested { placePresentations(); return }
        }
        state.layoutRequested = false
        Logger("PolymerUI").error("Layout did not settle after 8 passes: a row in a lazy stack changes size every time it is measured. Give rows a size that depends only on their content and the width offered.")
    }

    /// Records the tree as a display list and works out what changed since the
    /// last frame, without drawing anything on the CPU: what a window using a
    /// GPU renderer needs. `update()` runs first.
    ///
    /// The damage is the whole image the first time (or after a size or
    /// background change), then only the pixels that can differ.
    public func record(background: Color = .clear) -> (DisplayList, [PixelRect]) {
        update()
        let scale = environment.displayScale
        let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
        var list = spareList.flatMap { $0.width == w && $0.height == h && $0.scale == scale ? $0 : nil }
            ?? DisplayList(width: w, height: h, scale: scale)
        spareList = nil
        list.removeAll()
        root?.draw(&list)
        for p in state.presentations { p.panel.draw(&list) }
        let damage: [PixelRect]
        if let old = lastList, old.width == w, old.height == h, old.scale == scale, recordedBackground == background {
            damage = list.damage(since: old)
        } else {
            damage = w > 0 && h > 0 ? [list.fullRect] : []
        }
        recordedBackground = background
        spareList = lastList
        lastList = list
        self.damage = damage
        pendingList = list
        pendingDamage = damage
        return (list, damage)
    }

    /// Draws the tree into an image of the root's size at the display scale.
    ///
    /// The tree is recorded as a display list and compared with the last
    /// frame's; only the pixels that can differ (`damage`) are drawn again
    /// into the kept image. The result is identical to drawing everything.
    /// A list `record()` made for this frame is drawn rather than recorded again.
    public func render(background: Color = .clear) -> Bitmap {
        // Only reuse a recorded list when nothing has changed since (a window records, then presents).
        let reused = !needsUpdate ? pendingList : nil
        let (list, recorded): (DisplayList, [PixelRect])
        if let reused, recordedBackground == background { (list, recorded) = (reused, pendingDamage) }
        else { (list, recorded) = record(background: background) }
        let scale = environment.displayScale
        let w = list.width, h = list.height
        if var canvas = frameCanvas, canvas.width == w, canvas.height == h, canvas.scale == scale,
           frameBackground == background {
            frameCanvas = nil   // the only reference, so drawing doesn't copy the pixels
            damage = recorded
            for r in damage {
                canvas.clear(r, to: background)
                canvas.draw(list, in: r)
            }
            frameCanvas = canvas
        } else {
            var canvas = Canvas(width: w, height: h, scale: scale, background: background)
            canvas.glyphCache = glyphCache
            canvas.draw(list)
            damage = w > 0 && h > 0 ? [list.fullRect] : []
            frameCanvas = canvas
            frameBackground = background
        }
        pendingList = nil
        pendingDamage = []
        return frameCanvas!.bitmap
    }

    /// The element tree as text: role, frame in points, and details, one element per line.
    public var elementTree: String {
        update()
        var out = ""
        root?.dump(into: &out, depth: 0, focused: state.focused)
        for p in state.presentations { p.panel.dump(into: &out, depth: 0, focused: state.focused) }
        return out
    }

    // MARK: Input

    /// Clicks at a point (points from the top-left): the pointer moves there,
    /// goes down and comes up. Returns true when a button or tap handler ran
    /// or focus moved.
    @discardableResult
    public func click(at point: Point, count: Int = 1) -> Bool {
        pointerMoved(to: point)
        let focusMoved = pointerDown(at: point, clickCount: count)
        return pointerUp(at: point) || focusMoved
    }

    /// The pointer moved to `point` (points from the top-left). Updates
    /// hover handlers, and whether a held button shows as pressed.
    public func pointerMoved(to point: Point) {
        update()
        pointer = point
        if let d = dragNode, d.pointerMoved(to: point, time: state.now) { cancelPress() }
        if let t = textNode { t.pointerDragged(to: point) }
        if let top = state.presentations.last, top.kind == .menu, top.frame.contains(point) {
            let items = top.panel.items
            if let i = items.firstIndex(where: { $0.isEnabled && $0.contentFrame.contains(point) }) { top.panel.highlighted = i }
        }
        if let b = pressedNode as? TapNode, b.isButton { setPressed(b, b.isUnderPointer(point)) }
        state.updateHover(point)
    }

    /// The pointer left the window: hover handlers are told it is gone.
    public func pointerExited() {
        pointer = nil
        state.updateHover(nil)
    }

    /// The pointer went down at `point`. A focusable view under it takes
    /// focus (buttons do not, as on macOS); a button under it shows as
    /// pressed. Returns true when focus moved.
    @discardableResult
    public func pointerDown(at point: Point, clickCount: Int = 1) -> Bool {
        if pointer != point { pointerMoved(to: point) }
        // A press outside every menu and popover closes them and goes no further; behind a sheet, nothing takes it.
        if !state.presentations.isEmpty, !state.presentations.contains(where: { $0.frame.contains(point) }) {
            pressedNode = nil; dragNode = nil; textNode = nil
            state.closeTransient()
            return false
        }
        let hit = hitTest(point)
        var focusMoved = false
        var n = hit
        while let node = n {
            if node.focusesOnClick {
                if state.focused !== node { state.setFocus(node); focusMoved = true }
                break
            }
            n = node.parent
        }
        n = hit
        pressedNode = nil
        while let node = n {
            // A disabled button swallows the press rather than passing it outward.
            if let t = node as? TapNode, t.isButton, !t.isEnabled { break }
            if node.tapAction != nil { pressedNode = node; break }
            n = node.parent
        }
        if let b = pressedNode as? TapNode, b.isButton { setPressed(b, true) }
        // Interactive glass answers the press without taking it.
        state.pressInteractiveGlass(at: point)
        // The nearest drag gesture around what was hit follows the press; once it moves far enough the press is its.
        dragNode = nil
        n = hit
        while let node = n {
            if let d = node as? DragGestureNode, d.isEnabled { dragNode = d; break }
            n = node.parent
        }
        if let d = dragNode, d.pointerDown(at: point, time: state.now) { cancelPress() }
        // A text field under the press places its caret there and follows a drag to select.
        textNode = nil
        n = hit
        while let node = n {
            if let t = node as? TextInputNode, t.isEnabled { textNode = t; t.pointerDown(at: point, clickCount: clickCount); cancelPress(); break }
            n = node.parent
        }
        return focusMoved
    }

    /// The pointer came up at `point`. The button or tap handler it went
    /// down on runs if the pointer is still over it. Returns true when one ran.
    @discardableResult
    public func pointerUp(at point: Point) -> Bool {
        if pointer != point { pointerMoved(to: point) }
        state.pressInteractiveGlass(at: nil)
        if let t = textNode { textNode = nil; t.pointerUp() }
        if let d = dragNode {
            dragNode = nil
            if d.pointerUp(at: point, time: state.now) { pressedNode = nil; return true }
        }
        guard let node = pressedNode else { return false }
        pressedNode = nil
        let b = node as? TapNode
        if let b, b.isButton { setPressed(b, false) }
        // A button counts its whole label area; a tap handler only what it draws.
        let over: Bool
        if let b, b.isButton { over = b.isUnderPointer(point) } else {
            var h = hitTest(point)
            while let x = h, x !== node { h = x.parent }
            over = h != nil
        }
        guard over, node.isMounted, let action = node.tapAction else { return false }
        action()
        return true
    }

    /// Presses at `start`, moves to `end` in `steps` even steps, and lets go:
    /// what a person dragging does. Time is not advanced (set `time` between
    /// calls for a drag with a speed). Returns true when the release ended a
    /// drag gesture or ran a button or tap handler.
    @discardableResult
    public func drag(from start: Point, to end: Point, steps: Int = 4) -> Bool {
        pointerMoved(to: start)
        pointerDown(at: start)
        let n = max(1, steps)
        for k in 1...n {
            let t = Double(k) / Double(n)
            pointerMoved(to: Point(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
        }
        return pointerUp(at: end)
    }

    /// A drag took the press: the button or tap handler under it will not run.
    private func cancelPress() {
        if let b = pressedNode as? TapNode, b.isButton { setPressed(b, false) }
        pressedNode = nil
    }

    private func setPressed(_ b: TapNode, _ down: Bool) {
        if b.pressed.peek != down { b.pressed.value = down }
    }

    // MARK: Text input

    /// Where text fields cut, copy and paste. A `MemoryClipboard` unless a
    /// window installs the system's; headless trees never touch the real one.
    public var clipboard: any Clipboard {
        get { state.clipboard ?? MemoryClipboard() }
        set { state.clipboard = newValue }
    }

    private var focusedText: TextInputNode? { state.focused as? TextInputNode }

    /// True when the focused text field cannot take typed text now: a menu is
    /// open over it, or a sheet is open that does not hold it.
    private var textInputCovered: Bool {
        if state.presentations.last?.kind == .menu { return true }
        if let modal = state.modal, let f = state.focused, !f.isInside(modal.panel) { return true }
        return false
    }

    /// True when the focused view takes text: a window turns its input method on.
    public var acceptsTextInput: Bool {
        update()
        return focusedText?.isEnabled == true && !textInputCovered
    }

    /// Text from the keyboard or an input method, inserted at the caret of the
    /// focused text field (replacing the selection or marked text). Returns false when no text field has focus.
    @discardableResult
    public func insertText(_ text: String) -> Bool {
        update()
        guard let t = focusedText, t.isEnabled, !textInputCovered else { return false }
        t.insert(text)
        return true
    }

    /// Types `text` one character at a time as key presses, as a person would:
    /// each goes to the focused view (and a run of typing undoes as one step).
    public func type(_ text: String) {
        for ch in text { key(KeyPress(key: KeyEquivalent(ch), characters: String(ch))) }
    }

    /// An input method's text in progress (marked text) for the focused text field;
    /// `selectedRange` is the caret or selection within it, in characters.
    @discardableResult
    public func setMarkedText(_ text: String, selectedRange: Range<Int>) -> Bool {
        update()
        guard let t = focusedText, t.isEnabled, !textInputCovered else { return false }
        t.setMarked(text, selected: selectedRange)
        return true
    }

    /// The input method confirmed its marked text as it stands.
    public func unmarkText() { focusedText?.unmark() }

    /// The marked text's range in the focused text field, in characters; nil when there is none.
    public var markedTextRange: Range<Int>? { focusedText?.markedRange }
    /// The selection (or caret, when empty) in the focused text field, in characters.
    public var selectedTextRange: Range<Int>? { focusedText?.selectedRange }

    /// Where the first line of `range` of the focused text field is on screen
    /// (points): an input method shows its candidates there.
    public func firstRect(forCharacterRange range: Range<Int>) -> Rect? {
        update()
        return focusedText?.firstRect(for: range)
    }

    // MARK: Accessibility

    /// The accessibility tree: what a screen reader sees, built now from the
    /// view tree. The root is a group the size of the tree.
    public var accessibilityTree: AccessibilityElement {
        update()
        let inner = (root?.accessibilityElements(AccessibilityEdits(), focused: state.focused) ?? [])
            + state.presentations.flatMap { $0.panel.accessibilityElements(AccessibilityEdits(), focused: state.focused) }
        return AccessibilityElement(role: .group, label: "", value: nil, hint: nil, traits: [], frame: Rect(origin: .zero, size: size),
                                    isEnabled: true, isFocused: false, children: inner, nodeID: nil)
    }

    /// The accessibility tree as text, one element per line (the root's children at the top level).
    public var accessibilityDescription: String {
        var out = ""
        for e in accessibilityTree.children { e.dump(into: &out) }
        return out
    }

    /// Does what a screen reader's "press" does on the first button whose
    /// label is `label`: runs its action if it is enabled. Returns false when
    /// there is no such button or it is disabled.
    @discardableResult
    public func accessibilityPress(label: String) -> Bool {
        func find(_ e: AccessibilityElement) -> AccessibilityElement? {
            if e.role == .button, e.label == label { return e }
            for c in e.children { if let f = find(c) { return f } }
            return nil
        }
        guard let e = find(accessibilityTree), e.isEnabled, let id = e.nodeID,
              let node = firstNode(where: { ObjectIdentifier($0) == id }), let action = node.tapAction else { return false }
        action()
        return true
    }

    // MARK: Keyboard

    /// Keys that ask for the context menu (Shift+F10, and the menu key some
    /// keyboards have). `KeyEquivalent` is a character, so they are spelled
    /// as the function-key characters a platform sends.
    static let contextMenuKeys: [KeyEquivalent] = [KeyEquivalent("\u{F70D}"), KeyEquivalent("\u{F735}")]

    /// Sends a key press to the focused view, then to each view around it,
    /// until one handles it. Tab and Shift-Tab that nothing handled move
    /// focus to the next or previous focusable view, in drawing order.
    /// Returns true when the press was handled or moved focus.
    @discardableResult
    public func key(_ press: KeyPress) -> Bool {
        update()
        // The context menu key opens the focused view's menu before a text field can use it.
        if press.phase != .up, Self.contextMenuKeys.contains(press.key), openContextMenuForFocused() { return true }
        var n = state.focused
        while let node = n {
            if node.handle(press) == .handled { return true }
            n = node.parent
        }
        if let top = state.presentations.last, presentationKey(top, press) { return true }
        if runShortcut(press) { return true }
        guard press.key == .tab, press.phase == .down, press.modifiers.subtracting(.shift).isEmpty else { return false }
        return moveFocus(backward: press.modifiers.contains(.shift))
    }

    /// Sends a key press written as text: "tab", "shift+tab", "down", "space", "cmd+a", "x".
    /// Returns false when nothing handled it; stops with an error when the text names no key.
    @discardableResult
    public func key(_ text: String) -> Bool {
        guard let press = KeyPress(text) else {
            Logger("PolymerUI").error("\"\(text)\" is not a key. Use a character, or one of: \(KeyEquivalent.names.map(\.0).joined(separator: ", ")); add modifiers as shift+, ctrl+, alt+, cmd+.")
            return false
        }
        return key(press)
    }

    /// The focused element's line from the element tree, followed by the
    /// first text inside it (`Button (0, 25, 24x17) focused "Add"`), or nil
    /// when nothing has focus.
    public var focusedElement: String? {
        update()
        guard let f = state.focused else { return nil }
        var out = ""
        f.dump(into: &out, depth: 0, focused: f)
        guard var line = out.split(separator: "\n").first.map(String.init) else { return nil }
        if !line.contains("\""), let text = f.first(where: { $0 is TextNode }) as? TextNode { line += " \"\(text.string)\"" }
        return line
    }

    /// Moves focus to the next (or previous) focusable view, wrapping around.
    private func moveFocus(backward: Bool) -> Bool {
        var all: [Node] = []
        func collect(_ n: Node) { if n.acceptsFocus { all.append(n) }; for c in n.children { collect(c) } }
        // Behind a sheet nothing takes focus; inside a menu, popover or sheet, Tab stays in it.
        let scope: Node? = state.modal?.panel ?? state.presentations.last { p in state.focused.map { $0.isInside(p.panel) } ?? false }?.panel ?? root
        if let scope { collect(scope) }
        guard !all.isEmpty else { return false }
        let i = all.firstIndex { $0 === state.focused }
        let next: Int = switch (i, backward) {
        case (nil, false): 0
        case (nil, true): all.count - 1
        case (let i?, false): (i + 1) % all.count
        case (let i?, true): (i + all.count - 1) % all.count
        }
        state.setFocus(all[next])
        return true
    }

    /// Clicks the middle of the first text that reads exactly `text`.
    /// Returns false when there is no such text or nothing handles the click.
    @discardableResult
    public func click(text: String) -> Bool {
        guard let p = point(ofText: text) else { return false }
        return click(at: p)
    }

    /// The middle of the first text that reads exactly `text`, in screen points; nil when there is none.
    public func point(ofText text: String) -> Point? {
        update()
        guard let node = firstNode(where: { ($0 as? TextNode)?.string == text }) else { return nil }
        let f = node.screenFrame
        return Point(x: f.midX, y: f.midY)
    }

    /// Scrolls the scroll view under `point` by (dx, dy) points: positive dy
    /// moves down the content. A scroll view at its limit passes the scroll
    /// to the one around it. Returns true when something moved; the tree
    /// then needs drawing again. It needs `update()` (which `render` runs)
    /// only when a lazy stack inside has other rows in view.
    @discardableResult
    public func scroll(at point: Point, dx: Double = 0, dy: Double) -> Bool {
        update()
        var n = hitTest(point)
        while let node = n {
            if let s = node as? ScrollNode, s.scroll(dx: dx, dy: dy) {
                // Content moved under the pointer.
                if pointer != nil, !state.hoverNodes.isEmpty { update(); state.updateHover(pointer) }
                return true
            }
            n = node.parent
        }
        return false
    }

    // MARK: Menus, popovers and sheets

    /// Right-click (or the context menu key) at `point`: opens the context menu
    /// of the view there. Returns true when one opened.
    @discardableResult
    public func contextClick(at point: Point) -> Bool {
        update()
        if !state.presentations.contains(where: { $0.frame.contains(point) }) { state.closeTransient() }
        var n = hitTest(point)
        while let x = n {
            if let cm = x as? ContextMenuNode { cm.menu.open(at: point); update(); return true }
            n = x.parent
        }
        return false
    }

    /// Opens the context menu of the nearest view around the focused one, at
    /// the focused view's middle (Shift+F10 and the context menu key).
    /// Returns false when nothing focused has a context menu.
    @discardableResult
    public func openContextMenuForFocused() -> Bool {
        update()
        guard let f = state.focused else { return false }
        var n: Node? = f
        while let x = n {
            if let cm = x as? ContextMenuNode {
                let p = f.screenFrame
                let at = p.isEmpty ? Point(x: p.minX, y: p.minY) : Point(x: p.midX, y: p.midY)
                cm.menu.open(at: at)
                update()
                return true
            }
            n = x.parent
        }
        return false
    }

    /// The pointer shape at `point` (points): the nearest `.pointerStyle(_:)`
    /// around what is drawn there; `.iBeam` over an enabled text field;
    /// `.arrow` otherwise.
    public func pointerStyle(at point: Point) -> PointerStyle {
        update()
        var n = hitTest(point)
        var overText = false
        while let x = n {
            if let s = x as? PointerStyleNode { return s.style }
            if let t = x as? TextInputNode, t.isEnabled { overText = true }
            n = x.parent
        }
        return overText ? .iBeam : .arrow
    }

    /// The front-most node under `p`: in a menu, popover or sheet first; nothing behind a sheet.
    private func hitTest(_ p: Point) -> Node? {
        for pr in state.presentations.reversed() {
            if pr.frame.contains(p) { return pr.panel.hitTest(p) }
            if pr.isModal { return nil }
        }
        return root?.hitTest(p)
    }

    /// The first node matching, front-most presentation first, then the root view.
    private func firstNode(where match: (Node) -> Bool) -> Node? {
        for pr in state.presentations.reversed() { if let n = pr.panel.first(where: match) { return n } }
        return root?.first(where: match)
    }

    /// Places menus, popovers and sheets: a menu under its button (a submenu
    /// beside its item, a context menu at the click), a popover under its view
    /// (above it if there is no room), a sheet in the middle; all kept inside the tree.
    private func placePresentations() {
        guard !state.presentations.isEmpty else { return }
        let window = Rect(origin: .zero, size: size)
        let scale = environment.displayScale
        func snap(_ v: Double) -> Double { (v * scale).rounded() / scale }
        for p in state.presentations {
            let ideal = p.panel.measure(.unspecified)
            let s = Size(width: min(ideal.width, window.width), height: min(ideal.height, window.height))
            let a = p.owner?.screenFrame ?? .zero
            var o: Point
            switch p.kind {
            case .sheet:
                o = Point(x: (window.width - s.width) / 2, y: (window.height - s.height) / 2)
            case .popover:
                o = Point(x: a.midX - s.width / 2, y: a.maxY + environment.panelLook.gap)
                if o.y + s.height > window.maxY { o.y = a.minY - environment.panelLook.gap - s.height }
            case .menu:
                // A context menu's corner goes on the pixel the click is in (snapping it to the nearest could put it half a point away).
                if let pt = p.point { o = Point(x: (pt.x * scale).rounded(.down) / scale, y: (pt.y * scale).rounded(.down) / scale) }
                else if let parent = p.parent { o = Point(x: parent.frame.maxX, y: a.minY - PanelNode.padding) }
                else { o = Point(x: a.minX, y: a.maxY) }
            }
            o.x = min(max(o.x, 0), max(0, window.width - s.width))
            o.y = min(max(o.y, 0), max(0, window.height - s.height))
            p.panel.place(Rect(x: snap(o.x), y: snap(o.y), width: s.width, height: s.height))
        }
    }

    /// Keys for the front-most presentation that nothing focused used:
    /// arrows, Return and Escape in a menu; Escape closes a popover.
    private func presentationKey(_ top: Presentation, _ press: KeyPress) -> Bool {
        guard press.phase != .up else { return false }
        if top.kind == .popover, press.key == .escape { top.close(); return true }
        guard top.kind == .menu else { return false }
        let items = top.panel.items
        let enabled = items.indices.filter { items[$0].isEnabled }
        switch press.key {
        case .downArrow, .upArrow:
            guard !enabled.isEmpty else { return true }
            let down = press.key == .downArrow
            if let h = top.panel.highlighted, let k = enabled.firstIndex(of: h) {
                top.panel.highlighted = enabled[(k + (down ? 1 : enabled.count - 1)) % enabled.count]
            } else {
                top.panel.highlighted = down ? enabled.first : enabled.last
            }
        case .return, .space, .rightArrow:
            guard let h = top.panel.highlighted, h < items.count, items[h].isEnabled else { return true }
            // Right opens a submenu; it does nothing on a plain item.
            if press.key == .rightArrow, !(items[h].parent is MenuNode) { return true }
            items[h].tapAction?()
        case .leftArrow:
            if top.parent != nil { top.close() }
        case .escape:
            top.close()
        default:
            return false
        }
        return true
    }

    /// Runs the button with a `.keyboardShortcut` matching `press`: in the
    /// front-most sheet if there is one, else anywhere in the root view.
    private func runShortcut(_ press: KeyPress) -> Bool {
        guard press.phase == .down, !press.modifiers.isEmpty || press.key == .return || press.key == .escape else { return false }
        let scope: Node? = state.modal?.panel ?? root
        guard let s = scope?.first(where: { ($0 as? ShortcutNode)?.shortcut.matches(press) == true && ($0 as? ShortcutNode)?.button?.isEnabled == true }) as? ShortcutNode,
              let action = s.button?.tapAction else { return false }
        action()
        return true
    }
}
