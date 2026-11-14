// A live view tree: keeps the nodes of a root view, re-evaluates the views
// whose state changed, lays out, draws, and takes input. Windows and the
// headless tools both drive one of these.
import PolymerBase
import PolymerText
import PolymerRender

@MainActor
public final class ViewTree {
    private let state = TreeState()
    private let glyphCache = GlyphCache()
    private var root: Node?
    private var resolveRoot: (Node?, ResolveContext) -> Node
    private var needsResolve = true
    private var needsLayout = true

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

    /// Number of view bodies evaluated since the tree was made.
    public var bodyEvaluations: Int { state.bodyEvaluations }

    /// Re-evaluates the views whose state changed and lays the tree out.
    /// Returns true when anything was evaluated.
    @discardableResult
    public func update() -> Bool {
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
            for p in pending {
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
            if !state.layoutRequested { return }
        }
        state.layoutRequested = false
        Logger("PolymerUI").error("Layout did not settle after 8 passes: a row in a lazy stack changes size every time it is measured. Give rows a size that depends only on their content and the width offered.")
    }

    /// Draws the tree into a new image of the root's size at the display scale.
    public func render(background: Color = .clear) -> Bitmap {
        update()
        let scale = environment.displayScale
        var canvas = Canvas(width: Int((size.width * scale).rounded()), height: Int((size.height * scale).rounded()),
                            scale: scale, background: background)
        canvas.glyphCache = glyphCache
        root?.draw(&canvas)
        return canvas.bitmap
    }

    /// The element tree as text: role, frame in points, and details, one element per line.
    public var elementTree: String {
        update()
        var out = ""
        root?.dump(into: &out, depth: 0, focused: state.focused)
        return out
    }

    // MARK: Input

    /// Clicks at a point (points from the top-left). A focusable view under
    /// the point takes focus (buttons do not, as on macOS). Returns true when
    /// a button or tap handler ran or focus moved.
    @discardableResult
    public func click(at point: Point) -> Bool {
        update()
        let hit = root?.hitTest(point)
        var focusedNow = false
        var n = hit
        while let node = n {
            if node.focusesOnClick {
                if state.focused !== node { state.setFocus(node); focusedNow = true }
                break
            }
            n = node.parent
        }
        n = hit
        while let node = n {
            if let action = node.tapAction { action(); return true }
            n = node.parent
        }
        return focusedNow
    }

    // MARK: Keyboard

    /// Sends a key press to the focused view, then to each view around it,
    /// until one handles it. Tab and Shift-Tab that nothing handled move
    /// focus to the next or previous focusable view, in drawing order.
    /// Returns true when the press was handled or moved focus.
    @discardableResult
    public func key(_ press: KeyPress) -> Bool {
        update()
        var n = state.focused
        while let node = n {
            if node.handle(press) == .handled { return true }
            n = node.parent
        }
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
        if let root { collect(root) }
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
        update()
        guard let node = root?.first(where: { ($0 as? TextNode)?.string == text }) else { return false }
        let f = node.screenFrame
        return click(at: Point(x: f.midX, y: f.midY))
    }

    /// Scrolls the scroll view under `point` by (dx, dy) points: positive dy
    /// moves down the content. A scroll view at its limit passes the scroll
    /// to the one around it. Returns true when something moved; the tree
    /// then needs drawing again. It needs `update()` (which `render` runs)
    /// only when a lazy stack inside has other rows in view.
    @discardableResult
    public func scroll(at point: Point, dx: Double = 0, dy: Double) -> Bool {
        update()
        var n = root?.hitTest(point)
        while let node = n {
            if let s = node as? ScrollNode, s.scroll(dx: dx, dy: dy) { return true }
            n = node.parent
        }
        return false
    }
}
