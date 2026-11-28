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

    /// Client-area position in an LPARAM (signed: captured drags can go negative), in pixels.
    static func pixels(_ lParam: Int) -> (x: Int, y: Int) {
        (Int(Int16(truncatingIfNeeded: lParam & 0xffff)), Int(Int16(truncatingIfNeeded: (lParam >> 16) & 0xffff)))
    }

    /// Client-area position in an LPARAM, in points.
    static func point(_ lParam: Int, scale: Double) -> Point {
        let (x, y) = pixels(lParam)
        return Point(x: Double(x) / scale, y: Double(y) / scale)
    }

    /// A press, remembered to count the clicks of the next one.
    struct Click: Equatable {
        var button: PointerButton
        var x: Int, y: Int
        /// Message time in milliseconds (wraps around).
        var time: UInt32
        var count: Int
    }

    /// A press at pixel (x, y): one more click than `last` when it is the same
    /// button within `interval` ms and inside the double-click rectangle
    /// (`width` x `height` pixels, centred on the last press), else one.
    static func click(after last: Click?, button: PointerButton, x: Int, y: Int, time: UInt32,
                      interval: UInt32, width: Int, height: Int) -> Click {
        var count = 1
        if let l = last, l.button == button, time &- l.time <= interval,
           abs(x - l.x) <= width / 2, abs(y - l.y) <= height / 2 {
            count = l.count + 1
        }
        return Click(button: button, x: x, y: y, time: time, count: count)
    }

    /// The text in a WM_CHAR unit, or nil: control characters (they come as
    /// keys) and the first half of a surrogate pair (kept in `pendingHigh`).
    static func character(_ unit: UInt16, pendingHigh: inout UInt16?) -> String? {
        switch unit {
        case 0xD800...0xDBFF:
            pendingHigh = unit
            return nil
        case 0xDC00...0xDFFF:
            guard let h = pendingHigh else { return nil }
            pendingHigh = nil
            let v = 0x10000 + ((UInt32(h) - 0xD800) << 10) + (UInt32(unit) - 0xDC00)
            return Unicode.Scalar(v).map { String(Character($0)) }
        default:
            pendingHigh = nil
            guard unit >= 0x20, unit != 0x7F, let s = Unicode.Scalar(unit) else { return nil }
            return String(Character(s))
        }
    }

    /// The text in a WM_UNICHAR (a UTF-32 scalar), or nil for control characters and invalid values.
    static func unichar(_ wParam: UInt) -> String? {
        guard wParam >= 0x20, wParam != 0x7F, wParam <= 0x10FFFF, let s = Unicode.Scalar(UInt32(wParam)) else { return nil }
        return String(Character(s))
    }

    /// Keys that only carry text: VK_PROCESSKEY (the input method has the key) and VK_PACKET (injected text).
    static func isTextOnlyKey(_ vk: Int) -> Bool { vk == 0xE5 || vk == 0xE7 }

    /// The number of whole characters in the first `offset` UTF-16 units of `units`.
    static func characterOffset(_ units: [UInt16], utf16 offset: Int) -> Int {
        var n = 0, u = 0
        for ch in String(decoding: units, as: UTF16.self) {
            let w = ch.utf16.count
            if u + w > offset { break }
            u += w; n += 1
        }
        return n
    }

    /// An input method's composition as marked text: its characters, and the
    /// clause being converted (attributes 1 and 3, one byte per UTF-16 unit)
    /// as the selection, else the caret at `cursor` (UTF-16), all in characters.
    static func marked(_ units: [UInt16], cursor: Int, attributes: [UInt8]) -> (String, Range<Int>) {
        let text = String(decoding: units, as: UTF16.self)
        let isTarget: (UInt8) -> Bool = { $0 == 1 || $0 == 3 }   // ATTR_TARGET_CONVERTED, ATTR_TARGET_NOTCONVERTED
        if let a = attributes.firstIndex(where: isTarget), let b = attributes.lastIndex(where: isTarget) {
            return (text, characterOffset(units, utf16: a)..<characterOffset(units, utf16: b + 1))
        }
        let c = characterOffset(units, utf16: min(max(cursor, 0), units.count))
        return (text, c..<c)
    }

    /// A rectangle in points as the pixels covering it.
    static func pixelRect(_ r: Rect, scale: Double) -> PixelRect {
        let x = Int((r.minX * scale).rounded(.down)), y = Int((r.minY * scale).rounded(.down))
        let x1 = Int((r.maxX * scale).rounded(.up)), y1 = Int((r.maxY * scale).rounded(.up))
        return PixelRect(x: x, y: y, width: max(0, x1 - x), height: max(0, y1 - y))
    }

    /// Text for the clipboard: CRLF line breaks, ending in NUL.
    static func clipboardUnits(_ s: String) -> [UInt16] {
        var out: [UInt16] = []
        out.reserveCapacity(s.utf16.count + 1)
        var afterCR = false
        for u in s.utf16 {
            if u == 0x0A, !afterCR { out.append(0x0D) }
            out.append(u)
            afterCR = u == 0x0D
        }
        out.append(0)
        return out
    }

    /// Text from the clipboard, up to its NUL, with CRLF and CR as "\n".
    static func clipboardText<S: Sequence>(_ units: S) -> String where S.Element == UInt16 {
        var out: [UInt16] = []
        var afterCR = false
        for u in units {
            if u == 0 { break }
            if u == 0x0A, afterCR { afterCR = false; continue }
            afterCR = u == 0x0D
            out.append(afterCR ? 0x0A : u)
        }
        return String(decoding: out, as: UTF16.self)
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
        expect(Win32Input.event(0x0204, 0, lp, scale: 2, toClient: noClient) == .pointerDown(Point(x: 150, y: -3), .secondary), "right button down")
        let px = Win32Input.pixels(lp)
        expect(px.x == 300 && px.y == -6, "client position in pixels, signed")

        // Click counting: same button, within the time and the rectangle (4 x 4 here: 2 either way).
        let first = Win32Input.click(after: nil, button: .primary, x: 10, y: 10, time: 1000, interval: 500, width: 4, height: 4)
        let second = Win32Input.click(after: first, button: .primary, x: 12, y: 9, time: 1400, interval: 500, width: 4, height: 4)
        let third = Win32Input.click(after: second, button: .primary, x: 12, y: 9, time: 1800, interval: 500, width: 4, height: 4)
        expect(first.count == 1 && second.count == 2 && third.count == 3, "double and triple clicks")
        expect(Win32Input.click(after: second, button: .primary, x: 12, y: 9, time: 1901, interval: 500, width: 4, height: 4).count == 1, "too slow starts again")
        expect(Win32Input.click(after: second, button: .primary, x: 15, y: 9, time: 1500, interval: 500, width: 4, height: 4).count == 1, "too far starts again")
        expect(Win32Input.click(after: second, button: .secondary, x: 12, y: 9, time: 1500, interval: 500, width: 4, height: 4).count == 1, "another button starts again")
        let late = Win32Input.Click(button: .primary, x: 0, y: 0, time: UInt32.max - 100, count: 1)
        expect(Win32Input.click(after: late, button: .primary, x: 0, y: 0, time: 200, interval: 500, width: 4, height: 4).count == 2, "message time wraps around")

        // WM_CHAR and WM_UNICHAR text.
        var high: UInt16?
        expect(Win32Input.character(0x41, pendingHigh: &high) == "A" && Win32Input.character(0xE9, pendingHigh: &high) == "é", "characters")
        expect(Win32Input.character(0x08, pendingHigh: &high) == nil && Win32Input.character(0x0D, pendingHigh: &high) == nil
               && Win32Input.character(0x7F, pendingHigh: &high) == nil, "control characters come as keys")
        let firstHalf = Win32Input.character(0xD83D, pendingHigh: &high)
        let secondHalf = Win32Input.character(0xDE00, pendingHigh: &high)
        expect(firstHalf == nil && secondHalf == "\u{1F600}" && high == nil, "a surrogate pair is one character")
        expect(Win32Input.character(0xDE00, pendingHigh: &high) == nil, "a lone low surrogate is dropped")
        expect(Win32Input.unichar(0x1F600) == "\u{1F600}" && Win32Input.unichar(0x0D) == nil && Win32Input.unichar(0x110000) == nil, "WM_UNICHAR")
        expect(Win32Input.isTextOnlyKey(0xE5) && Win32Input.isTextOnlyKey(0xE7) && !Win32Input.isTextOnlyKey(0x41), "input method and packet keys")

        // Input method compositions, in characters (the emoji is two UTF-16 units).
        let comp = Array("a\u{1F600}bc".utf16)
        expect(Win32Input.characterOffset(comp, utf16: 3) == 2 && Win32Input.characterOffset(comp, utf16: 2) == 1, "UTF-16 offsets as characters")
        let (mt, sel) = Win32Input.marked(comp, cursor: 3, attributes: [0, 1, 1, 1, 2])
        expect(mt == "a\u{1F600}bc" && sel == 1..<3, "the converting clause is the selection")
        expect(Win32Input.marked(comp, cursor: 3, attributes: []).1 == 2..<2, "else the cursor")
        expect(Win32Input.marked(comp, cursor: 99, attributes: [0, 0, 0, 0, 0]).1 == 4..<4, "the cursor is clamped")
        expect(Win32Input.pixelRect(Rect(x: 10.25, y: 4, width: 1, height: 15.5), scale: 2) == PixelRect(x: 20, y: 8, width: 3, height: 31), "caret pixels cover the rectangle")

        // Clipboard text: CRLF there, "\n" here.
        expect(Win32Input.clipboardUnits("a\nb\r\nc") == Array("a\r\nb\r\nc".utf16) + [0], "copied line breaks are CRLF, ending in NUL")
        expect(Win32Input.clipboardText(Array("a\r\nb\rc\nd".utf16) + [0, 0x41]) == "a\nb\nc\nd", "pasted line breaks are \\n, up to the NUL")
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
    /// The last press, to count double and triple clicks.
    var lastClick: Win32Input.Click?
    /// The first half of a character outside the BMP, until WM_CHAR brings the second.
    var pendingHighSurrogate: UInt16?
    /// Where text goes, in client pixels; nil while the focused view takes no text.
    var textInput: PixelRect?
    /// Whether the input method is associated with the window (on until init turns it off).
    var imeOn = true
    /// An input method composition is shown as marked text.
    var hasMarkedText = false

    init(_ hwnd: HWND, system: Win32WindowSystem, title: String) {
        self.hwnd = hwnd
        self.system = system
        self.title = title
        wake = system.wake
        scale = Win32Input.scale(dpi: GetDpiForWindow(hwnd))
        updateSize()
        setIME(false)   // until a text field takes focus
    }

    public func setTextInput(_ caret: Rect?) {
        let r = caret.map { Win32Input.pixelRect($0, scale: scale) }
        guard r != textInput || (r != nil) != imeOn else { return }
        textInput = r
        setIME(r != nil)
        if r != nil { placeIME() }
    }

    /// Associates the input method with the window, or removes it (cancelling a composition).
    func setIME(_ on: Bool) {
        guard on != imeOn else { return }
        imeOn = on
        if !on, hasMarkedText, let himc = ImmGetContext(hwnd) {
            _ = ImmNotifyIME(himc, 0x15, 0x4, 0)   // NI_COMPOSITIONSTR, CPS_CANCEL
            _ = ImmReleaseContext(hwnd, himc)
        }
        hasMarkedText = false
        _ = ImmAssociateContextEx(hwnd, nil, on ? 0x10 : 0)   // IACE_DEFAULT, or no context
    }

    /// Puts the input method's composition at the caret and its candidates below, never over the text.
    func placeIME() {
        guard let r = textInput, let himc = ImmGetContext(hwnd) else { return }
        defer { _ = ImmReleaseContext(hwnd, himc) }
        let area = RECT(left: Int32(r.x), top: Int32(r.y), right: Int32(r.x + r.width), bottom: Int32(r.y + r.height))
        var cf = COMPOSITIONFORM()
        cf.dwStyle = 0x0002   // CFS_POINT
        cf.ptCurrentPos = POINT(x: area.left, y: area.top)
        cf.rcArea = area
        _ = ImmSetCompositionWindow(himc, &cf)
        var cand = CANDIDATEFORM()
        cand.dwIndex = 0
        cand.dwStyle = 0x0080   // CFS_EXCLUDE: anywhere but over `rcArea`
        cand.ptCurrentPos = POINT(x: area.left, y: area.bottom)
        cand.rcArea = area
        _ = ImmSetCandidateWindow(himc, &cand)
    }

    /// The composition string `kind` (GCS_*) as UTF-16 units, or attribute bytes.
    func compositionBytes(_ himc: HIMC, _ kind: UInt32) -> [UInt8] {
        let n = Int(ImmGetCompositionStringW(himc, kind, nil, 0))
        guard n > 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: n)
        let got = bytes.withUnsafeMutableBytes { Int(ImmGetCompositionStringW(himc, kind, $0.baseAddress, UInt32(n))) }
        return got > 0 ? Array(bytes[0..<min(got, n)]) : []
    }

    func compositionUnits(_ himc: HIMC, _ kind: UInt32) -> [UInt16] {
        let b = compositionBytes(himc, kind)
        return stride(from: 0, to: b.count - 1, by: 2).map { UInt16(b[$0]) | UInt16(b[$0 + 1]) << 8 }
    }

    /// WM_IME_COMPOSITION: the confirmed text goes in as `.text`, the text in progress as `.markedText`.
    func composition(_ flags: Int) {
        guard let himc = ImmGetContext(hwnd) else { return }
        defer { _ = ImmReleaseContext(hwnd, himc) }
        if flags & 0x0800 != 0 {   // GCS_RESULTSTR
            let result = compositionUnits(himc, 0x0800)
            if !result.isEmpty {
                hasMarkedText = false
                delegate?.handle(.text(String(decoding: result, as: UTF16.self)))
            }
        }
        if flags & 0x0008 != 0 {   // GCS_COMPSTR
            let units = compositionUnits(himc, 0x0008)
            let attributes = flags & 0x0010 != 0 ? compositionBytes(himc, 0x0010) : []   // GCS_COMPATTR
            let cursor = flags & 0x0080 != 0 ? Int(ImmGetCompositionStringW(himc, 0x0080, nil, 0)) : units.count   // GCS_CURSORPOS
            let (text, selected) = Win32Input.marked(units, cursor: cursor, attributes: attributes)
            if !text.isEmpty || hasMarkedText {
                hasMarkedText = !text.isEmpty
                delegate?.handle(.markedText(text, selectedRange: selected))
            }
        } else if flags & 0x0800 == 0, hasMarkedText {
            // Neither: the composition was cancelled.
            hasMarkedText = false
            delegate?.handle(.markedText("", selectedRange: 0..<0))
        }
        // The delegate moves the candidates with the marked text (`setTextInput`).
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
                _ = needsFrame.exchange(false, ordering: .acquiringAndReleasing)
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
            // The input method's keys and injected text arrive as text, not as keys.
            if Win32Input.isTextOnlyKey(vk) { return nil }
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
        case 0x0102:   // WM_CHAR: text after dead keys and AltGr (control characters come as keys)
            if let s = Win32Input.character(UInt16(truncatingIfNeeded: wParam), pendingHigh: &pendingHighSurrogate) {
                delegate?.handle(.text(s))
            }
            return 0
        case 0x0109:   // WM_UNICHAR
            if wParam == 0xFFFF { return 1 }   // UNICODE_NOCHAR: asks whether the window takes it
            if let s = Win32Input.unichar(wParam) { delegate?.handle(.text(s)) }
            return 0
        case 0x010D:   // WM_IME_STARTCOMPOSITION: no system composition window, the text field shows it
            placeIME()
            return 0
        case 0x010F:   // WM_IME_COMPOSITION, read here (DefWindowProc would send the result again as WM_CHAR)
            composition(lParam)
            return 0
        case 0x010E:   // WM_IME_ENDCOMPOSITION
            if hasMarkedText {
                hasMarkedText = false
                delegate?.handle(.markedText("", selectedRange: 0..<0))
            }
            return 0
        case 0x0281:   // WM_IME_SETCONTEXT: the candidates stay, the composition window goes (marked text shows it)
            return Int(DefWindowProcW(hwnd, message, WPARAM(wParam), LPARAM(lParam & ~0x8000_0000)))   // ISC_SHOWUICOMPOSITIONWINDOW
        default:
            let hwnd = self.hwnd
            guard var event = Win32Input.event(message, wParam, lParam, scale: scale, toClient: { x, y in
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
            case .pointerDown(let p, let button, _):
                SetCapture(hwnd)
                // Counted here, with the system's double-click time and rectangle (the class has no CS_DBLCLKS).
                let (x, y) = Win32Input.pixels(lParam), dpi = GetDpiForWindow(hwnd)
                let c = Win32Input.click(after: lastClick, button: button, x: x, y: y,
                                         time: UInt32(bitPattern: GetMessageTime()), interval: GetDoubleClickTime(),
                                         width: Int(GetSystemMetricsForDpi(36, dpi)), height: Int(GetSystemMetricsForDpi(37, dpi)))   // SM_CXDOUBLECLK, SM_CYDOUBLECLK
                lastClick = c
                event = .pointerDown(p, button, clickCount: c.count)
            case .pointerUp:
                if wParam & 0x13 == 0 { ReleaseCapture() }   // no MK_LBUTTON, MK_RBUTTON or MK_MBUTTON left down
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
