// Audio output: the interface each OS backend implements (WASAPI today,
// CoreAudio next). An output owns two threads: a real-time one that asks the
// renderer for samples whenever the device wants them, and a feeder that lets
// the renderer decode ahead. Shared code never makes threads of its own.
import PolymerBase

/// A stream's shape: frames per second and interleaved channels per frame.
public struct AudioFormat: Sendable, Hashable, CustomStringConvertible {
    public var sampleRate: Int
    public var channels: Int
    public init(sampleRate: Int, channels: Int) { self.sampleRate = sampleRate; self.channels = channels }
    public var description: String { "\(sampleRate) Hz, \(channels) channel\(channels == 1 ? "" : "s")" }
}

/// What an output pulls samples from (`AudioEngine` in PolymerAudio).
public protocol AudioRenderer: AnyObject, Sendable {
    /// Real-time: writes `frames` interleaved frames of `channels` samples into `buffer`.
    /// Called on the output's real-time thread; must not allocate, lock or do I/O,
    /// and must always fill the whole buffer (silence when it has nothing).
    func render(_ buffer: UnsafeMutablePointer<Float>, frames: Int, channels: Int)
    /// Not real-time: decodes ahead. Called on the output's feeder thread after
    /// each device period, and repeatedly while it returns true (more to do now).
    func refill() -> Bool
}

/// A device stream (or a stand-in for one, in checks).
public protocol AudioOutput: AnyObject, Sendable {
    /// What the device is, for logs and settings ("WASAPI shared, Speakers (Realtek)").
    var name: String { get }
    /// The format `render` is called with. Fixed for the output's lifetime.
    var format: AudioFormat { get }
    /// Frames between `render` writing a sample and it being heard (device buffer plus stream latency).
    var latencyFrames: Int { get }
    /// Starts calling `renderer` (after one `refill` and one `render` to fill the device buffer).
    func start(_ renderer: any AudioRenderer) throws(PlatformError)
    /// Stops the threads and waits for them; `start` may be called again.
    func stop()
}

/// The OS's audio devices.
public protocol AudioOutputSystem: Sendable {
    /// A stream on the default output device in the device's own (shared) format.
    func makeDefaultOutput() throws(PlatformError) -> any AudioOutput
}

extension Platform {
    nonisolated(unsafe) private static var _audio: (any AudioOutputSystem)?

    /// Installed by the entry point with the other backends.
    public static func install(audio: any AudioOutputSystem) { _audio = audio }

    /// The audio output system, or nil where there is none yet.
    public static var audio: (any AudioOutputSystem)? { _audio }
}
