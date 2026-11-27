// Windows on screen: the interface each OS backend implements (Win32 today,
// AppKit next). A window turns the OS's input into `WindowEvent`s in points,
// says when a frame can be drawn (paced by the display), and hands its native
// handle to the GPU backend, which presents into it.
import PolymerBase

public enum PointerButton: Sendable, Hashable { case primary, secondary, middle }

/// Modifier keys, by meaning: `command` is Ctrl on Windows and ⌘ on the Mac.
public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = KeyModifiers(rawValue: 1)
    public static let control = KeyModifiers(rawValue: 2)
    public static let option = KeyModifiers(rawValue: 4)
    public static let command = KeyModifiers(rawValue: 8)
}

/// A key, independent of the keyboard layout for the keys that have no character.
public enum PlatformKey: Sendable, Hashable {
    /// A key that types a character (as the layout gives it, unshifted for letters).
    case character(Character)
    case tab, enter, escape, space, backspace, delete
    case up, down, left, right, home, end, pageUp, pageDown
    /// Anything else, with the OS's own key code.
    case other(Int)
}

public enum WindowEvent: Sendable, Equatable {
    /// Positions are in points from the top-left of the content.
    case pointerMoved(Point)
    /// `clickCount` is 2 for a double click, 3 for a triple click (the OS's
    /// interval and distance), and so on.
    case pointerDown(Point, PointerButton, clickCount: Int = 1)
    case pointerUp(Point, PointerButton)
    /// The pointer left the content.
    case pointerExited
    /// Scrolling by a distance in points (positive `dy` moves content up, as a wheel turned towards the user).
    case scroll(Point, dx: Double, dy: Double)
    /// A key went down (`isRepeat` when held). `characters` is what it types, if anything.
    case keyDown(PlatformKey, characters: String, modifiers: KeyModifiers, isRepeat: Bool)
    case keyUp(PlatformKey, modifiers: KeyModifiers)
    /// Text typed (after dead keys and AltGr) or confirmed by an input method,
    /// never control characters. A key that types text sends its `keyDown`
    /// first; while a text input has focus the host gives the tree only this,
    /// so nothing is inserted twice.
    case text(String)
    /// An input method's text in progress, replacing the previous; `selectedRange`
    /// is its caret or selection, in characters. Empty ends it without inserting.
    case markedText(String, selectedRange: Range<Int>)
    /// The content's size in pixels or its scale (pixels per point) changed.
    case resized(width: Int, height: Int, scale: Double)
    /// The user asked to close the window (the close button, Alt-F4).
    case closeRequested
}

/// What a window tells its owner. Called on the main thread.
@MainActor
public protocol WindowDelegate: AnyObject {
    func handle(_ event: WindowEvent)
    /// Draw and present a frame for display time `time` (seconds). Return true
    /// to be called again at the next refresh (animating), false to wait for
    /// input or `PlatformWindow.setNeedsFrame()`.
    func frame(time: Double) -> Bool
}

@MainActor
public protocol PlatformWindow: AnyObject, Sendable {
    /// The OS's handle (an HWND on Windows), for the GPU backend to present into.
    var nativeHandle: UInt { get }
    /// Content size in pixels, and pixels per point.
    var pixelWidth: Int { get }
    var pixelHeight: Int { get }
    var scale: Double { get }
    var title: String { get set }
    var delegate: WindowDelegate? { get set }
    func show()
    func close()
    /// Where text input goes. Nil turns the input method off (the focused view
    /// takes no text); otherwise the caret's or marked text's rectangle in
    /// points, where the input method puts its candidates. Called often with
    /// the same value: windows act only on changes.
    func setTextInput(_ caret: Rect?)
    /// Asks for a frame soon. Safe from any thread (view invalidation calls it).
    nonisolated func setNeedsFrame()
}

/// The OS's windowing: makes windows and runs the event loop.
@MainActor
public protocol WindowSystem: AnyObject {
    /// A window with content `width` x `height` points, not shown yet.
    func makeWindow(title: String, width: Double, height: Double) throws(PlatformError) -> any PlatformWindow
    /// Handles events and paces frames until the last window closes.
    func run()
    /// Checks the backend's translations (input, scale) without opening anything;
    /// returns what failed, for `polymer check`.
    func selfCheck() -> [String]
}

public struct PlatformError: Error, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

extension Platform {
    nonisolated(unsafe) private static var _windows: (any WindowSystem)?

    /// Installed by the entry point with the files and process backends.
    public static func install(windows: any WindowSystem) { _windows = windows }

    /// The window system, or nil where there is none yet.
    public static var windows: (any WindowSystem)? { _windows }
}
