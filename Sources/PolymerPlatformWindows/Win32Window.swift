// Win32 windows: per-monitor DPI, input as `WindowEvent`s in points, a frame
// loop paced by the GPU presenter (the delegate waits for the display), and
// DWM's dark title bar with Mica on the frame. Content is drawn by the GPU
// into a flip-model swap chain, so the window has no redirection bitmap.
//
// Nothing here runs in `polymer check` except `selfCheck`, which tests the
// translations without making a window.
#if os(Windows)
import WinSDK
import Synchronization
import PolymerBase
import PolymerPlatform

/// Pure translations from Win32 messages, shared by the window and its self-check.
enum Win32Input {
    /// Points per wheel notch (120 units). A placeholder for a design token.
    static let pointsPerNotch = 40.0

    static func scale(dpi: UInt32) -> Double { dpi == 0 ? 1 : Double(dpi) / 96 }

    /// Client-area position in an LPARAM (signed: captured drags can go negative), in points.
    static func point(_ lParam: Int, scale: Double) -> Point {
        let x = Int16(truncatingIfNeeded: lParam & 0xffff), y = Int16(truncatingIfNeeded: (lParam >> 16) & 0xffff)
        return Point(x: Double(x) / scale, y: Double(y) / scale)
    }

    /// Wheel notches in a WPARAM (positive: away from the user).
    static func notches(_ wParam: UInt) -> Double { Double(Int16(truncatingIfNeeded: (wParam >> 16) & 0xffff)) / 120 }

    static func key(_ vk: Int, characters: String) -> PlatformKey {
        switch vk {
        case 0x09: return .tab
        case 0x0D: return .enter
        case 0x1B: return .escape
        case 0x20: return .space
        case 0x08: return .backspace
        case 0x2E: return .delete
        case 0x25: return .left
        case 0x26: return .up
        case 0x27: return .right
        case 0x28: return .down
        case 0x24: return .home
        case 0x23: return .end
        case 0x21: return .pageUp
        case 0x22: return .pageDown
        case 0x41...0x5A: return .character(Character(Unicode.Scalar(UInt8(vk + 0x20))))   // letters, unshifted
        case 0x30...0x39: return .character(Character(Unicode.Scalar(UInt8(vk))))
        default:
            if let c = characters.first, characters.count == 1, !(c.asciiValue.map { $0 < 0x20 || $0 == 0x7f } ?? false) {
                return .character(c)
            }
            return .other(vk)
        }
    }

    /// The event for a mouse or wheel message, or nil. `toClient` turns a screen position into a client one (wheel messages).
    static func event(_ message: UInt32, _ wParam: UInt, _ lParam: Int, scale: Double,
                      toClient: (Int, Int) -> (Int, Int)) -> WindowEvent? {
        switch message {
        case 0x0200: return .pointerMoved(point(lParam, scale: scale))
        case 0x0201: return .pointerDown(point(lParam, scale: scale), .primary)
        case 0x0202: return .pointerUp(point(lParam, scale: scale), .primary)
        case 0x0204: return .pointerDown(point(lParam, scale: scale), .secondary)
        case 0x0205: return .pointerUp(point(lParam, scale: scale), .secondary)
        case 0x0207: return .pointerDown(point(lParam, scale: scale), .middle)
        case 0x0208: return .pointerUp(point(lParam, scale: scale), .middle)
        case 0x02A3: return .pointerExited
        case 0x020A, 0x020E:
            let sx = Int(Int16(truncatingIfNeeded: lParam & 0xffff)), sy = Int(Int16(truncatingIfNeeded: (lParam >> 16) & 0xffff))
            let (cx, cy) = toClient(sx, sy)
            let at = Point(x: Double(cx) / scale, y: Double(cy) / scale), n = notches(wParam) * pointsPerNotch
            // Wheel away from the user shows what is above (content moves down): negative dy.
            return message == 0x020A ? .scroll(at, dx: 0, dy: -n) : .scroll(at, dx: n, dy: 0)
        default: return nil
        }
    }
}

@MainActor
public final class Win32WindowSystem: WindowSystem {
    var windows: [UInt: Win32Window] = [:]
    /// Set by `setNeedsFrame` from any thread to wake the loop.
    let wake: UInt
    static let className: [UInt16] = Array("PolymerWindow".utf16) + [0]
    nonisolated(unsafe) static weak var current: Win32WindowSystem?
    private var registered = false
    let clock = ContinuousClock()
    let start: ContinuousClock.Instant

    public init() {
        wake = UInt(bitPattern: CreateEventW(nil, false, false, nil))
        start = clock.now
        Self.current = self
    }

    var now: Double {
        let (s, a) = (clock.now - start).components
        return Double(s) + Double(a) / 1e18
    }

    private func register() throws(PlatformError) {
        if registered { return }
        _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT(bitPattern: -4))   // per-monitor v2
        var wc = WNDCLASSEXW()
        wc.cbSize = UInt32(MemoryLayout<WNDCLASSEXW>.size)
        wc.style = 0x0003   // CS_HREDRAW | CS_VREDRAW
        wc.lpfnWndProc = polymerWindowProc
        wc.hInstance = GetModuleHandleW(nil)
        wc.hCursor = LoadCursorW(nil, UnsafePointer<UInt16>(bitPattern: 32512))   // IDC_ARROW
        let atom = Self.className.withUnsafeBufferPointer { name in
            wc.lpszClassName = name.baseAddress
            return RegisterClassExW(&wc)
        }
        guard atom != 0 else { throw PlatformError("RegisterClassExW failed (Windows error \(GetLastError()))") }
        registered = true
    }

    public func makeWindow(title: String, width: Double, height: Double) throws(PlatformError) -> any PlatformWindow {
        try register()
        let dpi = GetDpiForSystem()
        let s = Win32Input.scale(dpi: dpi)
        let style: UInt32 = 0x00CF_0000   // WS_OVERLAPPEDWINDOW
        let exStyle: UInt32 = 0x0020_0000 // WS_EX_NOREDIRECTIONBITMAP: the swap chain is the only content
        var r = RECT(left: 0, top: 0, right: Int32((width * s).rounded()), bottom: Int32((height * s).rounded()))
        _ = AdjustWindowRectExForDpi(&r, style, false, exStyle, dpi)
        let wideTitle = Array(title.utf16) + [0]
        let cw = Int32(bitPattern: 0x8000_0000)   // CW_USEDEFAULT
        let hwnd = Self.className.withUnsafeBufferPointer { cls in
            wideTitle.withUnsafeBufferPointer { t in
                CreateWindowExW(exStyle, cls.baseAddress, t.baseAddress, style, cw, cw, r.right - r.left, r.bottom - r.top,
                                nil, nil, GetModuleHandleW(nil), nil)
            }
        }
        guard let hwnd else { throw PlatformError("CreateWindowExW failed (Windows error \(GetLastError()))") }
        // Dark title bar and Mica on the frame (Windows 11; ignored where unsupported).
        var dark: Int32 = 1, mica: Int32 = 2
        _ = DwmSetWindowAttribute(hwnd, 20, &dark, 4)   // DWMWA_USE_IMMERSIVE_DARK_MODE
        _ = DwmSetWindowAttribute(hwnd, 38, &mica, 4)   // DWMWA_SYSTEMBACKDROP_TYPE = DWMSBT_MAINWINDOW
        let w = Win32Window(hwnd, system: self, title: title)
        windows[UInt(bitPattern: hwnd)] = w
        return w
    }

    public func run() {
        var msg = MSG()
        while !windows.isEmpty {
            while PeekMessageW(&msg, nil, 0, 0, 0x0001) {   // PM_REMOVE
                if msg.message == 0x0012 { return }   // WM_QUIT
                TranslateMessage(&msg)
                DispatchMessageW(&msg)
            }
            var drew = false
            for w in Array(windows.values) where w.takeFrameRequest() {
                w.drawFrame(time: now)
                drew = true
            }
            if !drew {
                // Nothing to draw: sleep until input or a frame request.
                var h: HANDLE? = HANDLE(bitPattern: wake)
                _ = MsgWaitForMultipleObjectsEx(1, &h, INFINITE, 0x04FF, 0x0004)   // QS_ALLINPUT, MWMO_INPUTAVAILABLE
            }
        }
    }

    func removed(_ w: Win32Window) {
        windows[UInt(bitPattern: w.hwnd)] = nil
        if windows.isEmpty { PostQuitMessage(0) }
    }

    public func selfCheck() -> [String] {
        var failures: [String] = []
        func expect(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }
        expect(Win32Input.scale(dpi: 144) == 1.5 && Win32Input.scale(dpi: 96) == 1, "DPI 144 is scale 1.5, 96 is 1")
        let lp = (Int(UInt16(bitPattern: -6)) << 16) | 300   // x 300, y -6
        expect(Win32Input.point(lp, scale: 2) == Point(x: 150, y: -3), "client position, signed, in points")
        let noClient: (Int, Int) -> (Int, Int) = { ($0 - 100, $1 - 50) }
        expect(Win32Input.event(0x0201, 0, lp, scale: 2, toClient: noClient) == .pointerDown(Point(x: 150, y: -3), .primary), "left button down")
        expect(Win32Input.event(0x0205, 0, lp, scale: 1, toClient: noClient) == .pointerUp(Point(x: 300, y: -6), .secondary), "right button up")
        let wheelUp = UInt(UInt16(120)) << 16, screen = (200 << 16) | 400
        expect(Win32Input.event(0x020A, wheelUp, screen, scale: 2, toClient: noClient)
               == .scroll(Point(x: 150, y: 75), dx: 0, dy: -Win32Input.pointsPerNotch), "wheel away from the user scrolls up, at the client point")
        let wheelDown = UInt(UInt16(bitPattern: -240)) << 16
        expect(Win32Input.event(0x020A, wheelDown, screen, scale: 1, toClient: noClient)
               == .scroll(Point(x: 300, y: 150), dx: 0, dy: 2 * Win32Input.pointsPerNotch), "two notches towards the user")
        expect(Win32Input.event(0x02A3, 0, 0, scale: 1, toClient: noClient) == .pointerExited, "mouse leave")
        expect(Win32Input.event(0x0100, 0, 0, scale: 1, toClient: noClient) == nil, "keys are not pointer events")
        expect(Win32Input.key(0x09, characters: "\t") == .tab && Win32Input.key(0x0D, characters: "\r") == .enter, "tab and enter")
        expect(Win32Input.key(0x41, characters: "A") == .character("a"), "letters by key, unshifted")
        expect(Win32Input.key(0x35, characters: "%") == .character("5"), "digits by key")
        expect(Win32Input.key(0xBA, characters: "ö") == .character("ö"), "layout characters")
        expect(Win32Input.key(0x70, characters: "") == .other(0x70), "keys without characters keep their code")
        expect(Win32Input.key(0x26, characters: "") == .up && Win32Input.key(0x2E, characters: "") == .delete, "arrows and delete")
        return failures
    }
}

@MainActor
public final class Win32Window: PlatformWindow {
    let hwnd: HWND
    unowned let system: Win32WindowSystem
    public weak var delegate: WindowDelegate?
    public private(set) var scale: Double
    public private(set) var pixelWidth = 0
    public private(set) var pixelHeight = 0
    let needsFrame = Atomic<Bool>(true)
    var animating = false
    var trackingLeave = false
    let wake: UInt

    init(_ hwnd: HWND, system: Win32WindowSystem, title: String) {
        self.hwnd = hwnd
        self.system = system
        self.title = title
        wake = system.wake
        scale = Win32Input.scale(dpi: GetDpiForWindow(hwnd))
        updateSize()
    }

    public var nativeHandle: UInt { UInt(bitPattern: hwnd) }

    public var title: String {
        didSet { _ = (Array(title.utf16) + [0]).withUnsafeBufferPointer { SetWindowTextW(hwnd, $0.baseAddress) } }
    }

    public func show() { ShowWindow(hwnd, 5) }   // SW_SHOW
    public func close() { DestroyWindow(hwnd) }

    public nonisolated func setNeedsFrame() {
        needsFrame.store(true, ordering: .releasing)
        SetEvent(HANDLE(bitPattern: wake))
    }

    func takeFrameRequest() -> Bool { needsFrame.exchange(false, ordering: .acquiringAndReleasing) || animating }

    func drawFrame(time: Double) {
        guard let delegate, pixelWidth > 0, pixelHeight > 0 else { animating = false; return }
        animating = delegate.frame(time: time)
    }

    @discardableResult
    func updateSize() -> Bool {
        var r = RECT()
        GetClientRect(hwnd, &r)
        let w = Int(r.right - r.left), h = Int(r.bottom - r.top)
        let s = Win32Input.scale(dpi: GetDpiForWindow(hwnd))
        guard w != pixelWidth || h != pixelHeight || s != scale else { return false }
        pixelWidth = w; pixelHeight = h; scale = s
        return true
    }

    func handle(_ message: UInt32, _ wParam: UInt, _ lParam: Int) -> Int? {
        switch message {
        case 0x0005:   // WM_SIZE
            if updateSize() {
                delegate?.handle(.resized(width: pixelWidth, height: pixelHeight, scale: scale))
                // Windows runs its own loop while the user drags the edge: draw now.
                drawFrame(time: system.now)
            }
            return 0
        case 0x02E0:   // WM_DPICHANGED: move to the suggested rectangle (WM_SIZE follows)
            if let r = UnsafePointer<RECT>(bitPattern: lParam)?.pointee {
                SetWindowPos(hwnd, nil, r.left, r.top, r.right - r.left, r.bottom - r.top, 0x0014)   // SWP_NOZORDER | SWP_NOACTIVATE
            }
            if updateSize() { delegate?.handle(.resized(width: pixelWidth, height: pixelHeight, scale: scale)) }
            return 0
        case 0x000F:   // WM_PAINT
            var ps = PAINTSTRUCT()
            BeginPaint(hwnd, &ps); EndPaint(hwnd, &ps)
            drawFrame(time: system.now)
            return 0
        case 0x0014: return 1   // WM_ERASEBKGND: the GPU draws everything
        case 0x0010:   // WM_CLOSE
            if let delegate { delegate.handle(.closeRequested) } else { DestroyWindow(hwnd) }
            return 0
        case 0x0002:   // WM_DESTROY
            system.removed(self)
            return 0
        case 0x0100, 0x0104, 0x0101, 0x0105:   // key down / up (also with Alt)
            let vk = Int(wParam)
            let mods = Self.modifiers()
            if message == 0x0100 || message == 0x0104 {
                let chars = Self.characters(vk: UInt32(vk), scanCode: UInt32((lParam >> 16) & 0xff))
                delegate?.handle(.keyDown(Win32Input.key(vk, characters: chars), characters: chars, modifiers: mods,
                                          isRepeat: (lParam >> 30) & 1 == 1))
            } else {
                delegate?.handle(.keyUp(Win32Input.key(vk, characters: ""), modifiers: mods))
            }
            // Alt combinations still reach the system (Alt-F4, the window menu).
            return message == 0x0104 || message == 0x0105 ? nil : 0
        case 0x0102: return 0   // WM_CHAR: characters come with the key down
        default:
            let hwnd = self.hwnd
            guard let event = Win32Input.event(message, wParam, lParam, scale: scale, toClient: { x, y in
                var p = POINT(x: Int32(x), y: Int32(y))
                ScreenToClient(hwnd, &p)
                return (Int(p.x), Int(p.y))
            }) else { return nil }
            switch event {
            case .pointerMoved:
                if !trackingLeave {
                    var t = TRACKMOUSEEVENT(cbSize: UInt32(MemoryLayout<TRACKMOUSEEVENT>.size), dwFlags: 0x0002, hwndTrack: hwnd, dwHoverTime: 0)
                    trackingLeave = TrackMouseEvent(&t)
                }
            case .pointerExited: trackingLeave = false
            case .pointerDown: SetCapture(hwnd)
            case .pointerUp: ReleaseCapture()
            default: break
            }
            delegate?.handle(event)
            return 0
        }
    }

    static func modifiers() -> KeyModifiers {
        var m: KeyModifiers = []
        if GetKeyState(0x10) < 0 { m.insert(.shift) }
        if GetKeyState(0x11) < 0 { m.insert(.command) }   // Ctrl means what ⌘ means on the Mac
        if GetKeyState(0x12) < 0 { m.insert(.option) }
        if GetKeyState(0x5B) < 0 || GetKeyState(0x5C) < 0 { m.insert(.control) }
        return m
    }

    /// What the key types with the current layout and modifiers (without disturbing dead keys).
    static func characters(vk: UInt32, scanCode: UInt32) -> String {
        var state = [UInt8](repeating: 0, count: 256)
        GetKeyboardState(&state)
        var buf = [UInt16](repeating: 0, count: 8)
        let n = ToUnicode(vk, scanCode, state, &buf, 8, 0x4)
        return n > 0 ? String(decoding: buf[0..<Int(n)], as: UTF16.self) : ""
    }
}

/// The window procedure for every Polymer window.
func polymerWindowProc(_ hwnd: HWND?, _ message: UInt32, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT {
    guard let hwnd else { return 0 }
    let key = UInt(bitPattern: hwnd)
    let handled: Int? = MainActor.assumeIsolated {
        guard let w = Win32WindowSystem.current?.windows[key] else { return nil }
        return w.handle(message, UInt(wParam), Int(lParam))
    }
    if let handled { return LRESULT(handled) }
    return DefWindowProcW(hwnd, message, wParam, lParam)
}
#endif
