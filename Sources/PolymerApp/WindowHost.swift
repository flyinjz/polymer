// A view tree in a window: the window's events go to the tree, its frames are
// drawn by the GPU and presented, redrawing and recompositing only the
// damage. Frames are asked for only when something changed or an animation
// runs; the presenter paces them to the display. Shared by every OS.
import PolymerBase
import PolymerPlatform
import PolymerRender
import PolymerGPU
import PolymerUI

@MainActor
public final class WindowHost: WindowDelegate {
    public let tree: ViewTree
    public let window: any PlatformWindow
    public let renderer: GPURenderer
    public let presenter: any GPUPresenter
    public var background: Color
    /// Overrides the display's time (checks step it by hand).
    public var clock: (() -> Double)?
    public private(set) var framesPresented = 0
    /// What the last frame redrew and presented (pixels).
    public private(set) var lastDamage: [PixelRect] = []
    private var target: GPUTexture?
    private let log = Logger("window")

    /// `offscreen` presents into images instead of the window (for checks).
    /// `clipboard` is the system's (`Platform.clipboard`, from the entry point);
    /// without one the tree keeps its own in memory.
    public init(tree: ViewTree, window: any PlatformWindow, backend: any GPUBackend, background: Color,
                offscreen: Bool = false, clipboard: (any Clipboard)? = nil) throws(GPUError) {
        self.tree = tree
        self.window = window
        self.background = background
        if let clipboard { tree.clipboard = clipboard }
        renderer = try GPURenderer(backend: backend)
        presenter = try backend.makePresenter(windowHandle: offscreen ? 0 : window.nativeHandle,
                                              width: window.pixelWidth, height: window.pixelHeight)
        tree.onInvalidate { [weak window] in window?.setNeedsFrame() }
        window.delegate = self
        resize(width: window.pixelWidth, height: window.pixelHeight, scale: window.scale)
    }

    isolated deinit {
        if let target { renderer.backend.destroy(target) }
    }

    public func handle(_ event: WindowEvent) {
        switch event {
        case .pointerMoved(let p): tree.pointerMoved(to: p)
        case .pointerDown(let p, .primary, let clicks):
            _ = tree.pointerDown(at: p, clickCount: clicks)
            syncTextInput()
        case .pointerUp(let p, .primary): _ = tree.pointerUp(at: p)
        // Right-click opens the context menu on the press, as on macOS (the same on every OS).
        case .pointerDown(let p, .secondary, _): _ = tree.contextClick(at: p)
        case .pointerDown, .pointerUp: break
        case .pointerExited: tree.pointerExited()
        case .scroll(let p, let dx, let dy): _ = tree.scroll(at: p, dx: dx, dy: dy)
        case .keyDown(let key, let characters, let modifiers, let isRepeat):
            // A key that types text into a text field arrives again as `.text`: only that one inserts.
            if !(Self.typesText(characters, modifiers: modifiers) && tree.acceptsTextInput) {
                _ = tree.key(Self.keyPress(key, characters: characters, modifiers: modifiers, isRepeat: isRepeat))
            }
            syncTextInput()
        case .keyUp: break
        case .text(let s):
            _ = tree.insertText(s)
            syncTextInput()
        case .markedText(let s, let selected):
            // Ending with nothing marked changes nothing (no undo step, the selection stays).
            if !s.isEmpty || tree.markedTextRange != nil { _ = tree.setMarkedText(s, selectedRange: selected) }
            syncTextInput()
        case .resized(let w, let h, let s):
            resize(width: w, height: h, scale: s)
            window.setNeedsFrame()
        case .closeRequested: window.close()
        }
        if tree.needsUpdate || tree.isAnimating { window.setNeedsFrame() }
    }

    private func resize(width: Int, height: Int, scale: Double) {
        tree.proposedSize = ProposedViewSize(width: Double(width) / scale, height: Double(height) / scale)
        if tree.environment.displayScale != scale { tree.environment.displayScale = scale }
        do { try presenter.resize(width: width, height: height) } catch { log.error("resizing: \(error)") }
    }

    public func frame(time: Double) -> Bool {
        tree.time = clock?() ?? time
        do {
            let (list, damage) = record()
            let w = presenter.width, h = presenter.height
            var regions = damage, presented = damage
            if target == nil || target!.width != w || target!.height != h {
                if let target { renderer.backend.destroy(target) }
                let t = try renderer.makeTarget(width: w, height: h)
                try renderer.clear(t, to: background)
                target = t
                regions = [list.fullRect]
                presented = [PixelRect(x: 0, y: 0, width: w, height: h)]
            }
            if !regions.isEmpty {
                // Only wait on the swap chain's frame-latency semaphore when we are actually
                // going to call `present`: consuming the waitable object without a matching
                // `Present1` leaves the semaphore at zero and stalls the next frame for 1 s.
                presenter.waitForFrame()
                try renderer.draw(list, into: target!, regions: regions, background: background)
                try presenter.present(target!, damage: presented)
                framesPresented += 1
            }
            lastDamage = presented
        } catch {
            log.error("drawing a frame: \(error)")
        }
        // Focus or layout may have moved the caret (or a view took focus by itself).
        syncTextInput()
        return tree.isAnimating || tree.needsUpdate
    }

    /// Tells the window whether the focused view takes text, and where its
    /// caret or marked text is (for the input method's candidates).
    private func syncTextInput() {
        var caret: Rect?
        if tree.acceptsTextInput, let selected = tree.selectedTextRange {
            let range = tree.markedTextRange.map { selected.isEmpty ? $0 : selected } ?? (selected.lowerBound..<selected.lowerBound)
            caret = tree.firstRect(forCharacterRange: range)
        }
        window.setTextInput(caret)
    }

    /// True when a key down with these characters types them (the window
    /// sends them again as `.text`): printable, and not a shortcut. Ctrl with
    /// Alt is AltGr on Windows, which types.
    public static func typesText(_ characters: String, modifiers: KeyModifiers) -> Bool {
        guard !characters.isEmpty, !modifiers.contains(.control) else { return false }
        if modifiers.contains(.command), !modifiers.contains(.option) { return false }
        for s in characters.unicodeScalars {
            if s.value < 0x20 || s.value == 0x7F || (0xF700...0xF8FF).contains(s.value) { return false }
        }
        return true
    }

    /// This frame's display list and what changed since the last one.
    private func record() -> (DisplayList, [PixelRect]) {
        // The GPU draws it: no CPU rasterisation, only recording and damage.
        tree.record(background: background)
    }

    /// A platform key as SwiftUI's `KeyPress`.
    public static func keyPress(_ key: PlatformKey, characters: String, modifiers: KeyModifiers, isRepeat: Bool) -> KeyPress {
        let k: KeyEquivalent = switch key {
        case .character(let c): KeyEquivalent(c)
        case .tab: .tab
        case .enter: .return
        case .escape: .escape
        case .space: .space
        case .backspace: .delete
        case .delete: .deleteForward
        case .up: .upArrow
        case .down: .downArrow
        case .left: .leftArrow
        case .right: .rightArrow
        case .home: .home
        case .end: .end
        case .pageUp: .pageUp
        case .pageDown: .pageDown
        case .other: KeyEquivalent("\u{0}")
        }
        var m: EventModifiers = []
        if modifiers.contains(.shift) { m.insert(.shift) }
        if modifiers.contains(.control) { m.insert(.control) }
        if modifiers.contains(.option) { m.insert(.option) }
        if modifiers.contains(.command) { m.insert(.command) }
        return KeyPress(key: k, characters: characters, modifiers: m, phase: isRepeat ? .repeat : .down)
    }
}
