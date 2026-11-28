// Windows desktop backend: native Win32 window loop, StretchDIBits software
// presentation, dark title bar via DwmSetWindowAttribute, and UTF-16 clipboard.
#if os(Windows)
import WinSDK
import PolymerBase
import PolymerPlatform

// MARK: - Windows Clipboard

public struct WindowsClipboard: Clipboard {
    public init() {}

    public func getString() -> String? {
        guard OpenClipboard(nil) else { return nil }
        defer { CloseClipboard() }
        guard let handle = GetClipboardData(UINT(CF_UNICODETEXT)) else { return nil }
        guard let locked = GlobalLock(handle) else { return nil }
        defer { GlobalUnlock(handle) }

        let ptr = locked.assumingMemoryBound(to: UInt16.self)
        var length = 0
        while ptr[length] != 0 {
            length += 1
        }
        let units = UnsafeBufferPointer(start: ptr, count: length)
        return String(decoding: units, as: UTF16.self)
    }

    public func setString(_ text: String) {
        guard OpenClipboard(nil) else { return }
        defer { CloseClipboard() }
        EmptyClipboard()

        let utf16 = Array(text.utf16) + [0]
        let byteCount = SIZE_T(utf16.count * MemoryLayout<UInt16>.size)
        guard let hMem = GlobalAlloc(UINT(GMEM_MOVEABLE), byteCount) else { return }
        guard let locked = GlobalLock(hMem) else {
            GlobalFree(hMem)
            return
        }
        utf16.withUnsafeBytes { raw in
            if let src = raw.baseAddress {
                locked.copyMemory(from: src, byteCount: Int(byteCount))
            }
        }
        GlobalUnlock(hMem)
        if SetClipboardData(UINT(CF_UNICODETEXT), hMem) == nil {
            GlobalFree(hMem)
        }
    }
}

// MARK: - Windows Native Window Runner

public struct WindowsWindowRunner: WindowRunner {
    public init() {}

    @MainActor
    public func runWindow(
        options: WindowOptions,
        onEvent: @escaping @MainActor (WindowEvent) -> Void,
        renderFrame: @escaping @MainActor () -> FrameBuffer,
        needsAnimation: @escaping @MainActor () -> Bool
    ) throws {
        try Win32WindowHost.run(
            options: options,
            onEvent: onEvent,
            renderFrame: renderFrame,
            needsAnimation: needsAnimation
        )
    }
}

@MainActor
private final class Win32WindowState: WindowSession {
    let options: WindowOptions
    let onEvent: @MainActor (WindowEvent) -> Void
    let renderFrame: @MainActor () -> FrameBuffer
    let needsAnimation: @MainActor () -> Bool

    var hwnd: HWND?
    var scale: Double = 1.0
    var trackingMouseLeave: Bool = false
    var timerRunning: Bool = false
    var lastTickCounter: Int64 = 0
    var perfFrequency: Double = 1.0
    var bgraScratch: [UInt8] = []
    var closedDispatched: Bool = false

    var title: String {
        didSet {
            guard let hwnd else { return }
            let wide = Array(title.utf16) + [0]
            _ = SetWindowTextW(hwnd, wide)
        }
    }

    var cursor: CursorShape = .arrow

    init(
        options: WindowOptions,
        onEvent: @escaping @MainActor (WindowEvent) -> Void,
        renderFrame: @escaping @MainActor () -> FrameBuffer,
        needsAnimation: @escaping @MainActor () -> Bool
    ) {
        self.options = options
        self.title = options.title
        self.onEvent = onEvent
        self.renderFrame = renderFrame
        self.needsAnimation = needsAnimation
        var freq = LARGE_INTEGER()
        if QueryPerformanceFrequency(&freq), freq.QuadPart > 0 {
            self.perfFrequency = Double(freq.QuadPart)
        }
        var now = LARGE_INTEGER()
        if QueryPerformanceCounter(&now) {
            self.lastTickCounter = now.QuadPart
        }
    }

    func requestRedraw() {
        guard let hwnd else { return }
        _ = InvalidateRect(hwnd, nil, false)
    }

    func close() {
        guard let hwnd else { return }
        _ = DestroyWindow(hwnd)
    }

    func syncAnimationTimer() {
        guard let hwnd else { return }
        let want = needsAnimation()
        if want && !timerRunning {
            var now = LARGE_INTEGER()
            if QueryPerformanceCounter(&now) {
                lastTickCounter = now.QuadPart
            }
            // ~120 Hz tick cadence (8 ms interval) while animations are active.
            _ = SetTimer(hwnd, Win32WindowHost.animationTimerID, 8, nil)
            timerRunning = true
        } else if !want && timerRunning {
            _ = KillTimer(hwnd, Win32WindowHost.animationTimerID)
            timerRunning = false
        }
    }

    func handleTimerTick() {
        var now = LARGE_INTEGER()
        var dt = 1.0 / 60.0
        if QueryPerformanceCounter(&now) {
            let delta = now.QuadPart - lastTickCounter
            lastTickCounter = now.QuadPart
            if delta > 0 && perfFrequency > 0 {
                dt = min(max(Double(delta) / perfFrequency, 1e-4), 0.1)
            }
        }
        onEvent(.tick(dt: dt))
        requestRedraw()
        syncAnimationTimer()
    }

    func presentFrame(hdc: HDC) {
        let fb = renderFrame()
        guard !fb.isEmpty else { return }
        let pixelCount = fb.width * fb.height
        let byteCount = pixelCount * 4
        if bgraScratch.count < byteCount {
            bgraScratch = [UInt8](repeating: 0, count: byteCount)
        }
        // Convert RGBA8 to top-down BGRA8 expected by Win32 GDI StretchDIBits.
        for i in stride(from: 0, to: byteCount, by: 4) {
            bgraScratch[i] = fb.pixels[i + 2]
            bgraScratch[i + 1] = fb.pixels[i + 1]
            bgraScratch[i + 2] = fb.pixels[i]
            bgraScratch[i + 3] = fb.pixels[i + 3]
        }

        var bmi = BITMAPINFO()
        bmi.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        bmi.bmiHeader.biWidth = LONG(fb.width)
        bmi.bmiHeader.biHeight = -LONG(fb.height) // Negative height = top-down DIB.
        bmi.bmiHeader.biPlanes = 1
        bmi.bmiHeader.biBitCount = 32
        bmi.bmiHeader.biCompression = DWORD(BI_RGB)

        var client = RECT()
        if let hwnd {
            _ = GetClientRect(hwnd, &client)
        }
        let dstW = max(1, Int32(client.right - client.left))
        let dstH = max(1, Int32(client.bottom - client.top))

        bgraScratch.withUnsafeBytes { raw in
            _ = StretchDIBits(
                hdc,
                0, 0, dstW, dstH,
                0, 0, Int32(fb.width), Int32(fb.height),
                raw.baseAddress,
                &bmi,
                UINT(DIB_RGB_COLORS),
                DWORD(SRCCOPY)
            )
        }
    }
}

@MainActor
private enum Win32WindowHost {
    static let className = "PolymerWin32WindowClass"
    static let animationTimerID: UINT_PTR = 1
    static var classRegistered = false
    static var windows: [UInt: Win32WindowState] = [:]

    static func key(for hwnd: HWND) -> UInt {
        UInt(bitPattern: hwnd)
    }

    static func run(
        options: WindowOptions,
        onEvent: @escaping @MainActor (WindowEvent) -> Void,
        renderFrame: @escaping @MainActor () -> FrameBuffer,
        needsAnimation: @escaping @MainActor () -> Bool
    ) throws {
        let hInstance = GetModuleHandleW(nil)
        let wideClass = Array(className.utf16) + [0]

        if !classRegistered {
            var wc = WNDCLASSEXW()
            wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            wc.style = UINT(CS_HREDRAW | CS_VREDRAW)
            wc.lpfnWndProc = polymerWin32WndProc
            wc.hInstance = hInstance
            wc.hCursor = LoadCursorW(nil, UnsafePointer<UInt16>(bitPattern: 32512)) // IDC_ARROW
            wc.hbrBackground = nil
            let registered = wideClass.withUnsafeBufferPointer { ptr -> ATOM in
                wc.lpszClassName = ptr.baseAddress
                return RegisterClassExW(&wc)
            }
            if registered == 0 && GetLastError() != DWORD(ERROR_CLASS_ALREADY_EXISTS) {
                throw WindowError("RegisterClassExW failed with error \(GetLastError())")
            }
            classRegistered = true
        }

        var style = DWORD(WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX)
        if options.resizable {
            style |= DWORD(WS_THICKFRAME | WS_MAXIMIZEBOX)
        }

        var rect = RECT(left: 0, top: 0, right: LONG(options.width), bottom: LONG(options.height))
        _ = AdjustWindowRectEx(&rect, style, false, 0)
        let winW = Int32(rect.right - rect.left)
        let winH = Int32(rect.bottom - rect.top)

        let wideTitle = Array(options.title.utf16) + [0]
        guard let hwnd = CreateWindowExW(
            0,
            wideClass,
            wideTitle,
            style,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            winW,
            winH,
            nil,
            nil,
            hInstance,
            nil
        ) else {
            throw WindowError("CreateWindowExW failed with error \(GetLastError())")
        }

        let state = Win32WindowState(
            options: options,
            onEvent: onEvent,
            renderFrame: renderFrame,
            needsAnimation: needsAnimation
        )
        state.hwnd = hwnd
        let dpi = GetDpiForWindow(hwnd)
        state.scale = dpi > 0 ? Double(dpi) / 96.0 : 1.0
        windows[key(for: hwnd)] = state

        if options.darkGlass {
            enableDarkTitleBar(hwnd: hwnd)
        }

        _ = ShowWindow(hwnd, SW_SHOWDEFAULT)
        _ = UpdateWindow(hwnd)

        var client = RECT()
        _ = GetClientRect(hwnd, &client)
        let logicalW = Double(max(1, client.right - client.left)) / state.scale
        let logicalH = Double(max(1, client.bottom - client.top)) / state.scale
        onEvent(.resized(size: Size(width: logicalW, height: logicalH), scale: state.scale))
        state.requestRedraw()
        state.syncAnimationTimer()

        var msg = MSG()
        while GetMessageW(&msg, nil, 0, 0) {
            _ = TranslateMessage(&msg)
            _ = DispatchMessageW(&msg)
        }

        windows.removeValue(forKey: key(for: hwnd))
    }

    private static func enableDarkTitleBar(hwnd: HWND) {
        // Dynamically resolve DwmSetWindowAttribute from dwmapi.dll to avoid link-time dependency.
        typealias DwmSetWindowAttributeFn = @convention(c) (HWND, DWORD, UnsafeRawPointer?, DWORD) -> HRESULT
        let dllName = Array("dwmapi.dll".utf16) + [0]
        guard let module = LoadLibraryW(dllName) else { return }
        defer { _ = FreeLibrary(module) }
        guard let sym = GetProcAddress(module, "DwmSetWindowAttribute") else { return }
        let fn = unsafeBitCast(sym, to: DwmSetWindowAttributeFn.self)
        var enabled: DWORD = 1
        // DWMWA_USE_IMMERSIVE_DARK_MODE = 20 (Windows 10 2004+ / Windows 11).
        _ = fn(hwnd, 20, &enabled, DWORD(MemoryLayout<DWORD>.size))
    }

    static func pointFromLParam(_ lParam: LPARAM, scale: Double) -> Point {
        let rawX = Int16(truncatingIfNeeded: Int(lParam) & 0xFFFF)
        let rawY = Int16(truncatingIfNeeded: (Int(lParam) >> 16) & 0xFFFF)
        return Point(x: Double(rawX) / scale, y: Double(rawY) / scale)
    }

    static func currentModifiers() -> (shift: Bool, control: Bool, option: Bool, command: Bool) {
        let shift = (GetKeyState(Int32(VK_SHIFT)) & Int16(bitPattern: 0x8000)) != 0
        let control = (GetKeyState(Int32(VK_CONTROL)) & Int16(bitPattern: 0x8000)) != 0
        let option = (GetKeyState(Int32(VK_MENU)) & Int16(bitPattern: 0x8000)) != 0
        let command = ((GetKeyState(Int32(VK_LWIN)) | GetKeyState(Int32(VK_RWIN))) & Int16(bitPattern: 0x8000)) != 0
        return (shift, control, option, command)
    }

    static func mapVirtualKey(_ vk: UInt32) -> (name: String, defaultChar: String)? {
        switch Int32(vk) {
        case VK_TAB: return ("tab", "\t")
        case VK_RETURN: return ("return", "\r")
        case VK_ESCAPE: return ("escape", "\u{1B}")
        case VK_BACK: return ("delete", "\u{7F}")
        case VK_DELETE: return ("deleteforward", "\u{F728}")
        case VK_UP: return ("up", "\u{F700}")
        case VK_DOWN: return ("down", "\u{F701}")
        case VK_LEFT: return ("left", "\u{F702}")
        case VK_RIGHT: return ("right", "\u{F703}")
        case VK_HOME: return ("home", "\u{F729}")
        case VK_END: return ("end", "\u{F72B}")
        case VK_PRIOR: return ("pageup", "\u{F72C}")
        case VK_NEXT: return ("pagedown", "\u{F72D}")
        case VK_SPACE: return ("space", " ")
        default:
            if vk >= 0x30 && vk <= 0x39 {
                let s = String(Unicode.Scalar(vk)!)
                return (s, s)
            }
            if vk >= 0x41 && vk <= 0x5A {
                let lower = String(Unicode.Scalar(vk + 32)!)
                return (lower, lower)
            }
            return nil
        }
    }

    static func handleMessage(hwnd: HWND, uMsg: UINT, wParam: WPARAM, lParam: LPARAM) -> LRESULT {
        guard let state = windows[key(for: hwnd)] else {
            return DefWindowProcW(hwnd, uMsg, wParam, lParam)
        }

        switch uMsg {
        case UINT(WM_SIZE):
            let w = Int(lParam & 0xFFFF)
            let h = Int((lParam >> 16) & 0xFFFF)
            if w > 0 && h > 0 {
                let dpi = GetDpiForWindow(hwnd)
                if dpi > 0 { state.scale = Double(dpi) / 96.0 }
                let size = Size(width: Double(w) / state.scale, height: Double(h) / state.scale)
                state.onEvent(.resized(size: size, scale: state.scale))
                state.requestRedraw()
                state.syncAnimationTimer()
            }
            return 0

        case UINT(WM_GETMINMAXINFO):
            if let mmi = UnsafeMutablePointer<MINMAXINFO>(bitPattern: Int(truncatingIfNeeded: lParam)) {
                mmi.pointee.ptMinTrackSize.x = LONG(Double(state.options.minWidth) * state.scale)
                mmi.pointee.ptMinTrackSize.y = LONG(Double(state.options.minHeight) * state.scale)
                return 0
            }

        case UINT(WM_PAINT):
            var ps = PAINTSTRUCT()
            if let hdc = BeginPaint(hwnd, &ps) {
                state.presentFrame(hdc: hdc)
                _ = EndPaint(hwnd, &ps)
            }
            return 0

        case UINT(WM_ERASEBKGND):
            return 1

        case UINT(WM_MOUSEMOVE):
            if !state.trackingMouseLeave {
                var tme = TRACKMOUSEEVENT()
                tme.cbSize = DWORD(MemoryLayout<TRACKMOUSEEVENT>.size)
                tme.dwFlags = DWORD(TME_LEAVE)
                tme.hwndTrack = hwnd
                _ = TrackMouseEvent(&tme)
                state.trackingMouseLeave = true
            }
            state.onEvent(.pointerMoved(pointFromLParam(lParam, scale: state.scale)))
            state.requestRedraw()
            state.syncAnimationTimer()
            return 0

        case UINT(WM_MOUSELEAVE):
            state.trackingMouseLeave = false
            state.onEvent(.pointerExited)
            state.requestRedraw()
            state.syncAnimationTimer()
            return 0

        case UINT(WM_LBUTTONDOWN):
            _ = SetCapture(hwnd)
            state.onEvent(.pointerDown(pointFromLParam(lParam, scale: state.scale), .left))
            state.requestRedraw()
            state.syncAnimationTimer()
            return 0

        case UINT(WM_LBUTTONUP):
            _ = ReleaseCapture()
            state.onEvent(.pointerUp(pointFromLParam(lParam, scale: state.scale), .left))
            state.requestRedraw()
            state.syncAnimationTimer()
            return 0

        case UINT(WM_RBUTTONDOWN):
            state.onEvent(.pointerDown(pointFromLParam(lParam, scale: state.scale), .right))
            state.requestRedraw()
            state.syncAnimationTimer()
            return 0

        case UINT(WM_RBUTTONUP):
            state.onEvent(.pointerUp(pointFromLParam(lParam, scale: state.scale), .right))
            state.requestRedraw()
            state.syncAnimationTimer()
            return 0

        case UINT(WM_MBUTTONDOWN):
            state.onEvent(.pointerDown(pointFromLParam(lParam, scale: state.scale), .middle))
            state.requestRedraw()
            state.syncAnimationTimer()
            return 0

        case UINT(WM_MBUTTONUP):
            state.onEvent(.pointerUp(pointFromLParam(lParam, scale: state.scale), .middle))
            state.requestRedraw()
            state.syncAnimationTimer()
            return 0

        case UINT(WM_MOUSEWHEEL), UINT(WM_MOUSEHWHEEL):
            var pt = POINT(
                x: LONG(Int16(truncatingIfNeeded: Int(truncatingIfNeeded: lParam) & 0xFFFF)),
                y: LONG(Int16(truncatingIfNeeded: (Int(truncatingIfNeeded: lParam) >> 16) & 0xFFFF))
            )
            _ = ScreenToClient(hwnd, &pt)
            let wheelDelta = Int16(truncatingIfNeeded: Int(truncatingIfNeeded: wParam >> 16))
            let step = Double(wheelDelta) / 120.0 * 40.0
            let loc = Point(x: Double(pt.x) / state.scale, y: Double(pt.y) / state.scale)
            if uMsg == UINT(WM_MOUSEWHEEL) {
                state.onEvent(.scroll(at: loc, dx: 0, dy: step))
            } else {
                state.onEvent(.scroll(at: loc, dx: -step, dy: 0))
            }
            state.requestRedraw()
            state.syncAnimationTimer()
            return 0

        case UINT(WM_KEYDOWN), UINT(WM_SYSKEYDOWN), UINT(WM_KEYUP), UINT(WM_SYSKEYUP):
            let isDown = (uMsg == UINT(WM_KEYDOWN) || uMsg == UINT(WM_SYSKEYDOWN))
            let isRepeat = isDown && ((lParam & (1 << 30)) != 0)
            let mods = currentModifiers()
            if let mapped = mapVirtualKey(UInt32(truncatingIfNeeded: wParam)) {
                let chars: String
                if mapped.defaultChar.count == 1 && mapped.name.count == 1 && mods.shift {
                    chars = mapped.defaultChar.uppercased()
                } else {
                    chars = mapped.defaultChar
                }
                let ev = WindowKeyEvent(
                    key: mapped.name,
                    characters: chars,
                    shift: mods.shift,
                    control: mods.control,
                    option: mods.option,
                    command: mods.command,
                    isRepeat: isRepeat,
                    isDown: isDown
                )
                state.onEvent(.key(ev))
                state.requestRedraw()
                state.syncAnimationTimer()
                return 0
            }

        case UINT(WM_CHAR):
            let codeUnit = UInt32(truncatingIfNeeded: wParam)
            if codeUnit >= 0x20 && codeUnit != 0x7F, let scalar = Unicode.Scalar(codeUnit) {
                let text = String(scalar)
                let mods = currentModifiers()
                let ev = WindowKeyEvent(
                    key: text.lowercased(),
                    characters: text,
                    shift: mods.shift,
                    control: mods.control,
                    option: mods.option,
                    command: mods.command,
                    isRepeat: (lParam & (1 << 30)) != 0,
                    isDown: true
                )
                state.onEvent(.key(ev))
                state.requestRedraw()
                state.syncAnimationTimer()
                return 0
            }

        case UINT(WM_TIMER):
            if wParam == animationTimerID {
                state.handleTimerTick()
                return 0
            }

        case UINT(WM_DESTROY):
            if state.timerRunning {
                _ = KillTimer(hwnd, animationTimerID)
                state.timerRunning = false
            }
            if !state.closedDispatched {
                state.closedDispatched = true
                state.onEvent(.closed)
            }
            PostQuitMessage(0)
            return 0

        default:
            break
        }

        return DefWindowProcW(hwnd, uMsg, wParam, lParam)
    }
}

private let polymerWin32WndProc: WNDPROC = { hwnd, uMsg, wParam, lParam in
    guard let hwnd else { return 0 }
    let bits = Int(bitPattern: hwnd)
    return MainActor.assumeIsolated {
        Win32WindowHost.handleMessage(hwnd: HWND(bitPattern: bits)!, uMsg: uMsg, wParam: wParam, lParam: lParam)
    }
}
#endif
