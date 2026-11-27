// The clipboard's text. Text fields cut, copy and paste through a
// `Clipboard`; the entry point installs the system's for a window
// (`Platform.install(clipboard:)`), and headless trees keep a
// `MemoryClipboard`, so checks never touch the real one.
import PolymerBase

/// Where cut, copied and pasted text goes. Line breaks are "\n" whatever the
/// OS uses on its clipboard (backends convert).
public protocol Clipboard: AnyObject {
    var string: String? { get set }
}

/// A clipboard that lives in memory.
public final class MemoryClipboard: Clipboard {
    public var string: String?
    public init(_ string: String? = nil) { self.string = string }
}

extension Platform {
    nonisolated(unsafe) private static var _clipboard: (any Clipboard)?

    /// Installed by the entry point (an app with windows); checks never install it.
    public static func install(clipboard: any Clipboard) { _clipboard = clipboard }

    /// The system clipboard, or nil where none is installed. Hand it to a
    /// `WindowHost`; never read it from checks.
    public static var clipboard: (any Clipboard)? { _clipboard }
}
