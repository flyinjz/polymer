// An output with no device: the caller drives it, one period at a time, on
// its own thread. Used by checks and tools to run the engine headlessly and
// deterministically, and to render to a WAV file.
import PolymerBase
import PolymerPlatform

public final class OfflineAudioOutput: AudioOutput, @unchecked Sendable {
    public let name = "Offline"
    public let format: AudioFormat
    public var latencyFrames: Int
    /// Frames per `render` call, like a device period.
    public let periodFrames: Int
    /// Everything rendered so far, interleaved, when capturing.
    public private(set) var captured: [Float] = []
    public let capture: Bool

    private var renderer: (any AudioRenderer)?
    private var scratch: [Float]

    public init(format: AudioFormat, periodFrames: Int = 480, latencyFrames: Int = 0, capture: Bool = true) {
        self.format = format
        self.periodFrames = max(1, periodFrames)
        self.latencyFrames = latencyFrames
        self.capture = capture
        scratch = [Float](repeating: 0, count: max(1, periodFrames) * format.channels)
    }

    public func start(_ renderer: any AudioRenderer) throws(PlatformError) {
        self.renderer = renderer
    }

    public func stop() { renderer = nil }

    /// Runs about `frames` frames (whole periods): each period lets the
    /// renderer decode ahead until it has nothing more to do, then renders.
    /// `refillsPerPeriod` limits the decoding to model a slow feeder (nil: unlimited).
    public func pump(frames: Int, refillsPerPeriod: Int? = nil) {
        guard let r = renderer else { return }
        let periods = (frames + periodFrames - 1) / periodFrames
        for _ in 0..<periods {
            var n = 0
            while refillsPerPeriod.map({ n < $0 }) ?? true, r.refill() { n += 1 }
            scratch.withUnsafeMutableBufferPointer { b in r.render(b.baseAddress!, frames: periodFrames, channels: format.channels) }
            if capture { captured.append(contentsOf: scratch) }
        }
    }

    /// Forgets what was captured.
    public func clearCapture() { captured.removeAll(keepingCapacity: true) }

    /// The capture as a WAV file.
    public func wav(encoding: WAV.Encoding = .float32) -> [UInt8] { WAV.encode(captured, format: format, encoding: encoding) }
}
