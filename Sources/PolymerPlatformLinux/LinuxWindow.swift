// Linux desktop backend: headless-first window runner and in-memory clipboard.
#if os(Linux)
import Glibc
import PolymerBase
import PolymerPlatform

public final class LinuxClipboard: Clipboard {
    private let backing = InMemoryClipboard()

    public init() {}

    public func getString() -> String? {
        backing.getString()
    }

    public func setString(_ text: String) {
        backing.setString(text)
    }
}

public struct LinuxWindowRunner: WindowRunner {
    private let headlessEvents: [WindowEvent]?

    /// Creates a Linux window runner. Supply `headlessEvents` to drive a deterministic
    /// scripted session headlessly; omitting it returns an actionable error explaining
    /// that interactive display windows require Windows (Win32) or macOS (AppKit).
    public init(headlessEvents: [WindowEvent]? = nil) {
        self.headlessEvents = headlessEvents
    }

    @MainActor
    public func runWindow(
        options: WindowOptions,
        onEvent: @escaping @MainActor (WindowEvent) -> Void,
        renderFrame: @escaping @MainActor () -> FrameBuffer,
        needsAnimation: @escaping @MainActor () -> Bool
    ) throws {
        if let headlessEvents {
            let runner = HeadlessWindowRunner(events: headlessEvents)
            try runner.runWindow(
                options: options,
                onEvent: onEvent,
                renderFrame: renderFrame,
                needsAnimation: needsAnimation
            )
            return
        }
        throw WindowError(
            "interactive native windows require Windows (Win32) or macOS (AppKit); "
                + "on Linux, use HeadlessWindowRunner or LinuxWindowRunner(headlessEvents:) for deterministic headless execution"
        )
    }
}
#endif
