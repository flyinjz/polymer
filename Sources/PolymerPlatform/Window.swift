// Shared windowing, clipboard, and audio-output platform interfaces.
// Standard library + PolymerBase only — OS implementations live in
// PolymerPlatformWindows, PolymerPlatformMac, and PolymerPlatformLinux.
import PolymerBase
import Synchronization

/// Pointer cursor shapes supported across desktop platforms.
public enum CursorShape: String, CaseIterable, Equatable, Hashable, Sendable {
    case arrow
    case iBeam
    case pointingHand
    case resizeLeftRight
    case resizeUpDown
    case openHand
    case closedHand
}

/// Mouse buttons reported by window pointer events.
public enum WindowMouseButton: Equatable, Hashable, Sendable {
    case left
    case right
    case middle
}

/// A keyboard event delivered by a native or headless window.
/// `key` follows PolymerUI's `KeyPress` naming ("tab", "return", "escape",
/// "delete", "up", "down", "left", "right", "a", etc.).
public struct WindowKeyEvent: Equatable, Hashable, Sendable {
    public var key: String
    public var characters: String
    public var shift: Bool
    public var control: Bool
    public var option: Bool
    public var command: Bool
    public var isRepeat: Bool
    public var isDown: Bool

    public init(
        key: String,
        characters: String = "",
        shift: Bool = false,
        control: Bool = false,
        option: Bool = false,
        command: Bool = false,
        isRepeat: Bool = false,
        isDown: Bool = true
    ) {
        self.key = key
        self.characters = characters
        self.shift = shift
        self.control = control
        self.option = option
        self.command = command
        self.isRepeat = isRepeat
        self.isDown = isDown
    }

    /// Formats the key event as a `KeyPress` shortcut string (e.g. "shift+tab", "cmd+k").
    public var keyPressText: String {
        var parts: [String] = []
        if control { parts.append("ctrl") }
        if option { parts.append("option") }
        if shift { parts.append("shift") }
        if command { parts.append("cmd") }
        parts.append(key)
        return parts.joined(separator: "+")
    }
}

/// Input, resize, animation tick, and lifecycle events emitted by a window.
public enum WindowEvent: Equatable, Sendable {
    case resized(size: Size, scale: Double)
    case pointerMoved(Point)
    case pointerDown(Point, WindowMouseButton)
    case pointerUp(Point, WindowMouseButton)
    case pointerExited
    case scroll(at: Point, dx: Double, dy: Double)
    case key(WindowKeyEvent)
    case tick(dt: Double)
    case closed
}

/// Creation options for a native or headless window.
public struct WindowOptions: Equatable, Hashable, Sendable {
    public var title: String
    public var width: Int
    public var height: Int
    public var resizable: Bool
    public var darkGlass: Bool
    public var minWidth: Int
    public var minHeight: Int

    public init(
        title: String = "Polymer",
        width: Int = 960,
        height: Int = 640,
        resizable: Bool = true,
        darkGlass: Bool = true,
        minWidth: Int = 320,
        minHeight: Int = 240
    ) {
        self.title = title
        self.width = max(1, width)
        self.height = max(1, height)
        self.resizable = resizable
        self.darkGlass = darkGlass
        self.minWidth = max(1, minWidth)
        self.minHeight = max(1, minHeight)
    }
}

/// Lightweight 8-bit RGBA straight-alpha framebuffer (top-to-bottom rows).
/// Keeps `PolymerPlatform` independent of `PolymerRender` while converting trivially
/// to and from `PolymerRender.Bitmap`.
public struct FrameBuffer: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = max(0, width)
        self.height = max(0, height)
        self.pixels = pixels
    }

    public static let empty = FrameBuffer(width: 0, height: 0, pixels: [])

    @inlinable
    public var isEmpty: Bool {
        width <= 0 || height <= 0 || pixels.count < width * height * 4
    }

    @inlinable
    public var byteCount: Int { width * height * 4 }
}

/// Error thrown when a platform window backend cannot open or present a window.
public struct WindowError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { "window: \(message)" }
}

// MARK: - Clipboard

/// System or in-memory text clipboard.
public protocol Clipboard: Sendable {
    func getString() -> String?
    func setString(_ text: String)
}

/// Thread-safe in-memory clipboard for headless tests and platforms without a display server.
public final class InMemoryClipboard: Clipboard {
    private let storage: Mutex<String?>

    public init(initial: String? = nil) {
        self.storage = Mutex(initial)
    }

    public func getString() -> String? {
        storage.withLock { $0 }
    }

    public func setString(_ text: String) {
        storage.withLock { $0 = text }
    }
}

// MARK: - Window Session & Runner

/// Handle to an active window for live property updates.
@MainActor
public protocol WindowSession: AnyObject {
    var title: String { get set }
    var cursor: CursorShape { get set }
    func requestRedraw()
    func close()
}

/// Opens and drives a window event/render loop until closed.
public protocol WindowRunner: Sendable {
    @MainActor
    func runWindow(
        options: WindowOptions,
        onEvent: @escaping @MainActor (WindowEvent) -> Void,
        renderFrame: @escaping @MainActor () -> FrameBuffer,
        needsAnimation: @escaping @MainActor () -> Bool
    ) throws
}

/// Deterministic headless `WindowRunner` that replays a scripted `[WindowEvent]` sequence,
/// collects rendered `FrameBuffer`s, and returns cleanly without touching any display server.
public final class HeadlessWindowRunner: WindowRunner {
    private struct State: Sendable {
        var scriptedEvents: [WindowEvent]
        var renderOnEveryEvent: Bool
        var maxAnimationTicks: Int
        var tickInterval: Double
        var scale: Double
        var renderedFrames: [FrameBuffer] = []
        var dispatchedEvents: [WindowEvent] = []
        var lastOptions: WindowOptions?
        var animationTickCount: Int = 0
    }

    private let state: Mutex<State>

    public init(
        events: [WindowEvent] = [],
        renderOnEveryEvent: Bool = false,
        maxAnimationTicks: Int = 4,
        tickInterval: Double = 1.0 / 60.0,
        scale: Double = 1.0
    ) {
        self.state = Mutex(State(
            scriptedEvents: events,
            renderOnEveryEvent: renderOnEveryEvent,
            maxAnimationTicks: max(0, maxAnimationTicks),
            tickInterval: tickInterval > 0 ? tickInterval : (1.0 / 60.0),
            scale: scale > 0 ? scale : 1.0
        ))
    }

    public var renderedFrames: [FrameBuffer] {
        state.withLock { $0.renderedFrames }
    }

    public var dispatchedEvents: [WindowEvent] {
        state.withLock { $0.dispatchedEvents }
    }

    public var lastOptions: WindowOptions? {
        state.withLock { $0.lastOptions }
    }

    public var animationTickCount: Int {
        state.withLock { $0.animationTickCount }
    }

    public func reset(events: [WindowEvent]? = nil) {
        state.withLock { s in
            if let events { s.scriptedEvents = events }
            s.renderedFrames.removeAll(keepingCapacity: true)
            s.dispatchedEvents.removeAll(keepingCapacity: true)
            s.lastOptions = nil
            s.animationTickCount = 0
        }
    }

    @MainActor
    public func runWindow(
        options: WindowOptions,
        onEvent: @escaping @MainActor (WindowEvent) -> Void,
        renderFrame: @escaping @MainActor () -> FrameBuffer,
        needsAnimation: @escaping @MainActor () -> Bool
    ) throws {
        let config = state.withLock { s -> (events: [WindowEvent], renderEach: Bool, maxTicks: Int, dt: Double, scale: Double) in
            s.lastOptions = options
            s.renderedFrames.removeAll(keepingCapacity: true)
            s.dispatchedEvents.removeAll(keepingCapacity: true)
            s.animationTickCount = 0
            return (s.scriptedEvents, s.renderOnEveryEvent, s.maxAnimationTicks, s.tickInterval, s.scale)
        }

        var dispatched: [WindowEvent] = []
        var frames: [FrameBuffer] = []
        var sawClose = false
        var dirty = false

        func dispatch(_ event: WindowEvent) {
            dispatched.append(event)
            onEvent(event)
            dirty = true
        }

        func captureFrame() {
            frames.append(renderFrame())
            dirty = false
        }

        let startsWithResize: Bool
        if case .resized = config.events.first {
            startsWithResize = true
        } else {
            startsWithResize = false
        }

        if !startsWithResize {
            dispatch(.resized(size: Size(width: Double(options.width), height: Double(options.height)), scale: config.scale))
            captureFrame()
        }

        for event in config.events {
            if case .closed = event {
                if dirty { captureFrame() }
                dispatch(.closed)
                sawClose = true
                break
            }
            dispatch(event)
            if config.renderEach {
                captureFrame()
            } else {
                switch event {
                case .resized, .tick:
                    captureFrame()
                default:
                    break
                }
            }
        }

        var ticks = 0
        if !sawClose {
            while ticks < config.maxTicks && needsAnimation() {
                dispatch(.tick(dt: config.dt))
                captureFrame()
                ticks += 1
            }
            if dirty || frames.isEmpty {
                captureFrame()
            }
            dispatch(.closed)
        }

        state.withLock { s in
            s.dispatchedEvents = dispatched
            s.renderedFrames = frames
            s.animationTickCount = ticks
        }
    }
}

// MARK: - Audio Output Discovery

/// Audio output sharing mode requested from the OS audio backend.
public enum AudioOutputMode: String, CaseIterable, Equatable, Hashable, Sendable {
    case shared
    case exclusive
}

/// Static capabilities of an audio output endpoint.
public struct AudioDeviceInfo: Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var isDefault: Bool
    public var sampleRates: [Double]
    public var channelCount: Int

    public init(
        id: String,
        name: String,
        isDefault: Bool = false,
        sampleRates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000],
        channelCount: Int = 2
    ) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.sampleRates = sampleRates
        self.channelCount = max(1, channelCount)
    }
}

/// Platform audio-output device enumeration interface.
public protocol AudioOutputBackend: Sendable {
    func listDevices() -> [AudioDeviceInfo]
    func defaultDevice() -> AudioDeviceInfo?
}

/// Deterministic headless audio output backend for tests and offline rendering.
public struct HeadlessAudioOutputBackend: AudioOutputBackend {
    public let devices: [AudioDeviceInfo]

    public init(devices: [AudioDeviceInfo]? = nil) {
        self.devices = devices ?? [
            AudioDeviceInfo(
                id: "headless-default",
                name: "Polymer Null Output (64-bit)",
                isDefault: true,
                sampleRates: [44_100, 48_000, 88_200, 96_000, 176_400, 192_000],
                channelCount: 2
            ),
        ]
    }

    public func listDevices() -> [AudioDeviceInfo] {
        devices
    }

    public func defaultDevice() -> AudioDeviceInfo? {
        devices.first(where: \.isDefault) ?? devices.first
    }
}

// MARK: - Platform Desktop Registry

/// Thread-safe holder for desktop-level platform services installed alongside `Platform`.
public enum PlatformDesktop {
    private struct Storage: Sendable {
        var windowRunner: (any WindowRunner)?
        var clipboard: any Clipboard = InMemoryClipboard()
        var audioOutput: any AudioOutputBackend = HeadlessAudioOutputBackend()
    }

    private static let storage = Mutex(Storage())

    public static var windowRunner: (any WindowRunner)? {
        storage.withLock { $0.windowRunner }
    }

    public static var clipboard: any Clipboard {
        storage.withLock { $0.clipboard }
    }

    public static var audioOutput: any AudioOutputBackend {
        storage.withLock { $0.audioOutput }
    }

    public static func install(
        windowRunner: (any WindowRunner)? = nil,
        clipboard: (any Clipboard)? = nil,
        audioOutput: (any AudioOutputBackend)? = nil
    ) {
        storage.withLock { s in
            if let windowRunner { s.windowRunner = windowRunner }
            if let clipboard { s.clipboard = clipboard }
            if let audioOutput { s.audioOutput = audioOutput }
        }
    }
}

extension Platform {
    public static var windowRunner: (any WindowRunner)? {
        PlatformDesktop.windowRunner
    }

    public static var clipboard: any Clipboard {
        PlatformDesktop.clipboard
    }

    public static var audioOutput: any AudioOutputBackend {
        PlatformDesktop.audioOutput
    }

    /// Installs desktop backends (window runner, clipboard, audio output).
    /// Passing `nil` leaves the current or default headless service in place.
    public static func installDesktop(
        windowRunner: (any WindowRunner)? = nil,
        clipboard: (any Clipboard)? = nil,
        audioOutput: (any AudioOutputBackend)? = nil
    ) {
        PlatformDesktop.install(
            windowRunner: windowRunner,
            clipboard: clipboard,
            audioOutput: audioOutput
        )
    }
}
