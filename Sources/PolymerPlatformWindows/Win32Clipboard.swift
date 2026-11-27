// The Windows clipboard's text (CF_UNICODETEXT), with "\n" line breaks on
// our side and CRLF on the clipboard's. Installed by the entry point; checks
// never make one, so they never touch the owner's clipboard (the conversions
// are checked in `Win32WindowSystem.selfCheck`).
#if os(Windows)
import WinSDK
import PolymerPlatform

public final class Win32Clipboard: Clipboard {
    /// A message-only window that owns what we put on the clipboard (made on first use).
    private var owner: HWND?
    private static let unicodeText: UInt32 = 13   // CF_UNICODETEXT

    public init() {}

    deinit { if let owner { DestroyWindow(owner) } }

    public var string: String? {
        get {
            guard IsClipboardFormatAvailable(Self.unicodeText), open() else { return nil }
            defer { _ = CloseClipboard() }
            guard let h = GetClipboardData(Self.unicodeText), let p = GlobalLock(h) else { return nil }
            defer { _ = GlobalUnlock(h) }
            let units = UnsafeBufferPointer(start: p.assumingMemoryBound(to: UInt16.self), count: Int(GlobalSize(h)) / 2)
            return Win32Input.clipboardText(units)
        }
        set {
            guard open() else { return }
            defer { _ = CloseClipboard() }
            _ = EmptyClipboard()
            guard let newValue else { return }
            let units = Win32Input.clipboardUnits(newValue)
            guard let h = GlobalAlloc(0x0002, SIZE_T(units.count * 2)) else { return }   // GMEM_MOVEABLE
            guard let p = GlobalLock(h) else { _ = GlobalFree(h); return }
            units.withUnsafeBytes { p.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            _ = GlobalUnlock(h)
            // The clipboard owns the memory once it takes it.
            if SetClipboardData(Self.unicodeText, h) == nil { _ = GlobalFree(h) }
        }
    }

    /// Opens the clipboard, retrying briefly while another program has it open.
    private func open() -> Bool {
        if owner == nil {
            let cls = Array("STATIC".utf16) + [0]
            owner = cls.withUnsafeBufferPointer {
                CreateWindowExW(0, $0.baseAddress, nil, 0, 0, 0, 0, 0, HWND(bitPattern: -3), nil, GetModuleHandleW(nil), nil)   // HWND_MESSAGE
            }
        }
        for _ in 0..<5 {
            if OpenClipboard(owner) { return true }
            Sleep(2)
        }
        return false
    }
}
#endif
