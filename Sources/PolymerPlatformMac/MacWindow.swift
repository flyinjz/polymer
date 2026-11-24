// macOS desktop backend: native AppKit NSWindow + CGImage presentation + NSPasteboard.
#if os(macOS)
import AppKit
import CoreGraphics
import PolymerBase
import PolymerPlatform

// MARK: - macOS Clipboard

public struct MacClipboard: Clipboard {
    public init() {}

    public func getString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    public func setString(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}

// MARK: - macOS Native Window Runner

public struct MacWindowRunner: WindowRunner {
    public init() {}

    @MainActor
    public func runWindow(
        options: WindowOptions,
        onEvent: @escaping @MainActor (WindowEvent) -> Void,
        renderFrame: @escaping @MainActor () -> FrameBuffer,
        needsAnimation: @escaping @MainActor () -> Bool
    ) throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        var styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if options.resizable {
            styleMask.insert(.resizable)
        }
        if options.darkGlass {
            styleMask.insert(.fullSizeContentView)
        }

        let contentRect = NSRect(x: 0, y: 0, width: options.width, height: options.height)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = options.title
        window.minSize = NSSize(width: options.minWidth, height: options.minHeight)
        window.acceptsMouseMovedEvents = true
        window.center()

        if options.darkGlass {
            window.appearance = NSAppearance(named: .darkAqua)
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = NSColor(calibratedWhite: 0.05, alpha: 0.96)
        }

        let hostView = MacPolymerView(
            frame: contentRect,
            onEvent: onEvent,
            renderFrame: renderFrame,
            needsAnimation: needsAnimation
        )
        let delegate = MacWindowDelegate(hostView: hostView)
        window.delegate = delegate
        window.contentView = hostView
        window.makeFirstResponder(hostView)
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)

        let scale = Double(window.backingScaleFactor)
        onEvent(.resized(size: Size(width: Double(contentRect.width), height: Double(contentRect.height)), scale: scale))
        hostView.needsDisplay = true
        hostView.syncAnimationTimer()

        app.run()
        // Keep delegate alive through the run loop.
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
private final class MacWindowDelegate: NSObject, NSWindowDelegate {
    private unowned let hostView: MacPolymerView

    init(hostView: MacPolymerView) {
        self.hostView = hostView
    }

    func windowDidResize(_ notification: Notification) {
        hostView.emitResize()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        hostView.emitResize()
    }

    func windowWillClose(_ notification: Notification) {
        hostView.shutdown()
        NSApplication.shared.stop(nil)
    }
}

@MainActor
private final class MacPolymerView: NSView, WindowSession {
    private let onEvent: @MainActor (WindowEvent) -> Void
    private let renderFrame: @MainActor () -> FrameBuffer
    private let needsAnimation: @MainActor () -> Bool

    private var animationTimer: Timer?
    private var lastTickTimestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var closedDispatched = false

    var title: String {
        get { window?.title ?? "" }
        set { window?.title = newValue }
    }

    var cursor: CursorShape = .arrow {
        didSet {
            switch cursor {
            case .arrow: NSCursor.arrow.set()
            case .iBeam: NSCursor.iBeam.set()
            case .pointingHand: NSCursor.pointingHand.set()
            case .resizeLeftRight: NSCursor.resizeLeftRight.set()
            case .resizeUpDown: NSCursor.resizeUpDown.set()
            case .openHand: NSCursor.openHand.set()
            case .closedHand: NSCursor.closedHand.set()
            }
        }
    }

    init(
        frame: NSRect,
        onEvent: @escaping @MainActor (WindowEvent) -> Void,
        renderFrame: @escaping @MainActor () -> FrameBuffer,
        needsAnimation: @escaping @MainActor () -> Bool
    ) {
        self.onEvent = onEvent
        self.renderFrame = renderFrame
        self.needsAnimation = needsAnimation
        super.init(frame: frame)
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MacPolymerView does not support nib decoding")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func requestRedraw() {
        needsDisplay = true
    }

    func close() {
        window?.close()
    }

    func emitResize() {
        let scale = Double(window?.backingScaleFactor ?? 1.0)
        onEvent(.resized(size: Size(width: Double(bounds.width), height: Double(bounds.height)), scale: scale))
        needsDisplay = true
        syncAnimationTimer()
    }

    func syncAnimationTimer() {
        let want = needsAnimation()
        if want && animationTimer == nil {
            lastTickTimestamp = ProcessInfo.processInfo.systemUptime
            let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleTick()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            animationTimer = timer
        } else if !want, let timer = animationTimer {
            timer.invalidate()
            animationTimer = nil
        }
    }

    private func handleTick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = min(max(now - lastTickTimestamp, 1e-4), 0.1)
        lastTickTimestamp = now
        onEvent(.tick(dt: dt))
        needsDisplay = true
        syncAnimationTimer()
    }

    func shutdown() {
        animationTimer?.invalidate()
        animationTimer = nil
        if !closedDispatched {
            closedDispatched = true
            onEvent(.closed)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let fb = renderFrame()
        guard !fb.isEmpty else { return }

        let data = Data(fb.pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        guard let image = CGImage(
            width: fb.width,
            height: fb.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: fb.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return }

        ctx.saveGState()
        // Compensate for isFlipped = true so the top-down RGBA framebuffer renders upright.
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: bounds)
        ctx.restoreGState()
    }

    private func localPoint(from event: NSEvent) -> Point {
        let p = convert(event.locationInWindow, from: nil)
        return Point(x: Double(p.x), y: Double(p.y))
    }

    private func dispatchAndRefresh(_ event: WindowEvent) {
        onEvent(event)
        needsDisplay = true
        syncAnimationTimer()
    }

    override func mouseMoved(with event: NSEvent) {
        dispatchAndRefresh(.pointerMoved(localPoint(from: event)))
    }

    override func mouseDragged(with event: NSEvent) {
        dispatchAndRefresh(.pointerMoved(localPoint(from: event)))
    }

    override func rightMouseDragged(with event: NSEvent) {
        dispatchAndRefresh(.pointerMoved(localPoint(from: event)))
    }

    override func mouseExited(with event: NSEvent) {
        dispatchAndRefresh(.pointerExited)
    }

    override func mouseDown(with event: NSEvent) {
        dispatchAndRefresh(.pointerDown(localPoint(from: event), .left))
    }

    override func mouseUp(with event: NSEvent) {
        dispatchAndRefresh(.pointerUp(localPoint(from: event), .left))
    }

    override func rightMouseDown(with event: NSEvent) {
        dispatchAndRefresh(.pointerDown(localPoint(from: event), .right))
    }

    override func rightMouseUp(with event: NSEvent) {
        dispatchAndRefresh(.pointerUp(localPoint(from: event), .right))
    }

    override func otherMouseDown(with event: NSEvent) {
        dispatchAndRefresh(.pointerDown(localPoint(from: event), .middle))
    }

    override func otherMouseUp(with event: NSEvent) {
        dispatchAndRefresh(.pointerUp(localPoint(from: event), .middle))
    }

    override func scrollWheel(with event: NSEvent) {
        let mul: Double = event.hasPreciseScrollingDeltas ? 1.0 : 12.0
        dispatchAndRefresh(.scroll(
            at: localPoint(from: event),
            dx: Double(event.scrollingDeltaX) * mul,
            dy: Double(event.scrollingDeltaY) * mul
        ))
    }

    override func keyDown(with event: NSEvent) {
        if let keyEvent = Self.translateKeyEvent(event, isDown: true) {
            dispatchAndRefresh(.key(keyEvent))
        }
    }

    override func keyUp(with event: NSEvent) {
        if let keyEvent = Self.translateKeyEvent(event, isDown: false) {
            dispatchAndRefresh(.key(keyEvent))
        }
    }

    private static func translateKeyEvent(_ event: NSEvent, isDown: Bool) -> WindowKeyEvent? {
        let mods = event.modifierFlags
        let keyName: String
        switch event.keyCode {
        case 48: keyName = "tab"
        case 36, 76: keyName = "return"
        case 53: keyName = "escape"
        case 51: keyName = "delete"
        case 117: keyName = "deleteforward"
        case 126: keyName = "up"
        case 125: keyName = "down"
        case 123: keyName = "left"
        case 124: keyName = "right"
        case 115: keyName = "home"
        case 119: keyName = "end"
        case 116: keyName = "pageup"
        case 121: keyName = "pagedown"
        case 49: keyName = "space"
        default:
            guard let raw = event.charactersIgnoringModifiers, !raw.isEmpty else { return nil }
            keyName = raw.lowercased()
        }
        return WindowKeyEvent(
            key: keyName,
            characters: event.characters ?? "",
            shift: mods.contains(.shift),
            control: mods.contains(.control),
            option: mods.contains(.option),
            command: mods.contains(.command),
            isRepeat: isDown && event.isARepeat,
            isDown: isDown
        )
    }
}
#endif
