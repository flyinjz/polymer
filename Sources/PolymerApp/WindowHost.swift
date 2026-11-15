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
    public init(tree: ViewTree, window: any PlatformWindow, backend: any GPUBackend, background: Color,
                offscreen: Bool = false) throws(GPUError) {
        self.tree = tree
        self.window = window
        self.background = background
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
        case .pointerDown(let p, .primary): _ = tree.pointerDown(at: p)
        case .pointerUp(let p, .primary): _ = tree.pointerUp(at: p)
        case .pointerDown, .pointerUp: break   // other buttons: right-click menus come with commands (PolymerApp)
        case .pointerExited: tree.pointerExited()
        case .scroll(let p, let dx, let dy): _ = tree.scroll(at: p, dx: dx, dy: dy)
        case .keyDown(let key, let characters, let modifiers, let isRepeat):
            _ = tree.key(Self.keyPress(key, characters: characters, modifiers: modifiers, isRepeat: isRepeat))
        case .keyUp: break
        case .resized(let w, let h, let s): resize(width: w, height: h, scale: s)
        case .closeRequested: window.close()
        }
        window.setNeedsFrame()
    }

    private func resize(width: Int, height: Int, scale: Double) {
        tree.proposedSize = ProposedViewSize(width: Double(width) / scale, height: Double(height) / scale)
        if tree.environment.displayScale != scale { tree.environment.displayScale = scale }
        do { try presenter.resize(width: width, height: height) } catch { log.error("resizing: \(error)") }
    }

    public func frame(time: Double) -> Bool {
        presenter.waitForFrame()
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
                try renderer.draw(list, into: target!, regions: regions, background: background)
                try presenter.present(target!, damage: presented)
                framesPresented += 1
            }
            lastDamage = presented
        } catch {
            log.error("drawing a frame: \(error)")
        }
        return tree.isAnimating || tree.needsUpdate
    }

    /// This frame's display list and what changed since the last one.
    private func record() -> (DisplayList, [PixelRect]) {
        // Draws on the CPU too until ViewTree can record without drawing (asked of PolymerUI).
        _ = tree.render(background: background)
        return (tree.displayList!, tree.damage)
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
