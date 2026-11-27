// A decoded stream as plain values, for callers that want the samples rather
// than an `AudioSource`: the AIFF and ALAC decoders produce this, and the
// encoders in this module take it apart again.
import PolymerBase

public struct DecodedAudioFormat: Equatable, Hashable, Sendable {
    public var sampleRate: Int
    public var channelCount: Int
    public var bitDepth: Int

    public init(sampleRate: Int, channelCount: Int, bitDepth: Int = 16) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitDepth = bitDepth
    }

    /// From a Double rate, as the decoders read it from a header.
    public init(sampleRate: Double, channelCount: Int, bitDepth: Int = 16) {
        self.init(sampleRate: Int(sampleRate.rounded()), channelCount: channelCount, bitDepth: bitDepth)
    }
}

public struct DecodedAudio: Equatable, Sendable {
    public var format: DecodedAudioFormat
    public var frames: Int
    /// Interleaved samples in [-1, 1].
    public var samples: [Double]
    /// The exact integer samples, for lossless verification (nil for float streams).
    public var rawIntSamples: [Int32]?

    public init(format: DecodedAudioFormat, frames: Int, samples: [Double], rawIntSamples: [Int32]? = nil) {
        self.format = format
        self.frames = frames
        self.samples = samples
        self.rawIntSamples = rawIntSamples
    }
}

/// Errors from the container decoders and encoders.
public enum AudioDecoderError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidHeader(String)
    case unsupportedFormat(String)
    case truncatedData(String)
    case checksumMismatch(String)
    case invalidBitstream(String)

    public var description: String {
        switch self {
        case .invalidHeader(let m): return "audio header error: \(m)"
        case .unsupportedFormat(let m): return "unsupported audio format: \(m)"
        case .truncatedData(let m): return "truncated audio data: \(m)"
        case .checksumMismatch(let m): return "audio checksum mismatch: \(m)"
        case .invalidBitstream(let m): return "invalid audio bitstream: \(m)"
        }
    }
}
