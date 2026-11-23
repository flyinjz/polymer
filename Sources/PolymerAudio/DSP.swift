// Studio-grade 64-bit float DSP:
// - Polyphase Kaiser-windowed sinc resampler
// - TPDF dither with optional 1st-order noise shaping
// - Parametric RBJ biquad EQ
// - EBU R128 K-weighted loudness meter & ReplayGain
// - 4x oversampled lookahead true-peak limiter
// - Equal-power / linear crossfader
// - BS2B-style headphone crossfeed with exact mono preservation
// - Null-test and IEEE 1057 sine-fit THD+N measurement utilities
import PolymerBase

// MARK: - Pure-Swift Audio Math

public enum AudioMath {
    @inlinable
    public static func log10(_ x: Double) -> Double {
        Math.log(x) * 0.43429448190325182765
    }

    @inlinable
    public static func pow10(_ x: Double) -> Double {
        Math.exp(x * 2.30258509299404568402)
    }

    @inlinable
    public static func tan(_ x: Double) -> Double {
        Math.sin(x) / Math.cos(x)
    }

    @inlinable
    public static func dbToLinear(_ db: Double) -> Double {
        pow10(db * 0.05)
    }

    @inlinable
    public static func linearToDB(_ linear: Double, floor: Double = -200.0) -> Double {
        if linear <= 0.0 { return floor }
        return max(floor, 20.0 * log10(linear))
    }

    /// Normalized sinc: sin(pi * x) / (pi * x).
    @inlinable
    public static func sinc(_ x: Double) -> Double {
        if abs(x) < 1e-12 { return 1.0 }
        let px = Double.pi * x
        return Math.sin(px) / px
    }

    /// Modified Bessel function of the first kind, order 0: I_0(x).
    public static func besselI0(_ x: Double) -> Double {
        let y = 0.25 * x * x
        var sum = 1.0
        var term = 1.0
        var k = 1.0
        while k < 64.0 {
            term *= y / (k * k)
            let next = sum + term
            if next == sum { break }
            sum = next
            k += 1.0
        }
        return sum
    }
}

// MARK: - Polyphase Windowed-Sinc Resampler

/// Polyphase Kaiser-windowed sinc resampler operating in 64-bit float.
/// Precomputes the polyphase filter bank on init; `process` performs zero heap allocations.
public final class SincResampler {
    public let sourceRate: Double
    public let targetRate: Double
    public let channelCount: Int
    public let taps: Int
    public let phases: Int
    public let kaiserBeta: Double

    /// Ratio of input frames consumed per output frame produced.
    public let step: Double
    /// Half-filter latency in input frames.
    public var latencyFrames: Int { taps / 2 }

    // Flattened (phases + 1) x taps polyphase coefficient table for linear phase interpolation.
    private let table: [Double]
    // Pre-allocated ring history buffer of length `taps * channelCount`.
    private var history: [Double]
    private var historyWritePos: Int = 0
    private var fracPos: Double = 0.0

    public init(
        sourceRate: Double,
        targetRate: Double,
        channelCount: Int,
        taps: Int = 64,
        phases: Int = 512,
        kaiserBeta: Double = 10.6
    ) {
        precondition(sourceRate > 0 && targetRate > 0 && channelCount > 0)
        self.sourceRate = sourceRate
        self.targetRate = targetRate
        self.channelCount = channelCount
        self.phases = max(16, phases)
        self.kaiserBeta = kaiserBeta
        self.step = sourceRate / targetRate

        let ratio = min(1.0, targetRate / sourceRate)
        // Scale tap count when downsampling so stopband attenuation stays > 100 dB right at target Nyquist.
        let scaledTaps = Int((Double(max(16, taps)) / ratio).rounded(.up))
        let evenTaps = (scaledTaps + 1) & ~1
        self.taps = evenTaps

        let cutoff = 0.445 * ratio
        let halfTaps = Double(evenTaps) * 0.5
        let invI0 = 1.0 / AudioMath.besselI0(kaiserBeta)

        var coeffTable = [Double](repeating: 0.0, count: (self.phases + 1) * evenTaps)
        for p in 0...self.phases {
            let frac = Double(p) / Double(self.phases)
            let rowStart = p * evenTaps
            var sum = 0.0
            for k in 0..<evenTaps {
                // Distance from filter center: center is at (halfTaps - 1) + frac.
                let x = Double(k) - (halfTaps - 1.0 + frac)
                let norm = x / halfTaps
                let w: Double
                if abs(norm) >= 1.0 {
                    w = 0.0
                } else {
                    let arg = kaiserBeta * (1.0 - norm * norm).squareRoot()
                    w = AudioMath.besselI0(arg) * invI0
                }
                let h = 2.0 * cutoff * AudioMath.sinc(2.0 * cutoff * x) * w
                coeffTable[rowStart + k] = h
                sum += h
            }
            if abs(sum) > 1e-15 {
                let invSum = 1.0 / sum
                for k in 0..<evenTaps {
                    coeffTable[rowStart + k] *= invSum
                }
            }
        }
        self.table = coeffTable
        self.history = [Double](repeating: 0.0, count: evenTaps * channelCount)
    }

    public func reset() {
        for i in 0..<history.count { history[i] = 0.0 }
        historyWritePos = 0
        fracPos = 0.0
    }

    /// Streams interleaved input frames into interleaved output frames with zero heap allocations.
    public func process(
        input: UnsafeBufferPointer<Double>,
        inputFrames: Int,
        output: UnsafeMutableBufferPointer<Double>,
        outputFrameCapacity: Int
    ) -> (consumedFrames: Int, producedFrames: Int) {
        guard let inBase = input.baseAddress, let outBase = output.baseAddress else {
            return (0, 0)
        }
        let ch = channelCount
        let nTaps = taps
        let nPhases = phases
        var inIndex = 0
        var outIndex = 0

        // Helper to push one input frame into the circular history buffer.
        @inline(__always)
        func pushInputFrame(_ frame: Int) {
            let dstBase = historyWritePos * ch
            let srcBase = frame * ch
            for c in 0..<ch {
                history[dstBase + c] = inBase[srcBase + c]
            }
            historyWritePos += 1
            if historyWritePos == nTaps { historyWritePos = 0 }
        }

        // Advance integer input frames while fracPos >= 1.0, then synthesize output frame.
        while outIndex < outputFrameCapacity {
            while fracPos >= 1.0 {
                if inIndex >= inputFrames {
                    return (inIndex, outIndex)
                }
                pushInputFrame(inIndex)
                inIndex += 1
                fracPos -= 1.0
            }

            let scaledPhase = fracPos * Double(nPhases)
            let phaseIdx = Int(scaledPhase)
            let alpha = scaledPhase - Double(phaseIdx)
            let oneMinusAlpha = 1.0 - alpha
            let row0 = phaseIdx * nTaps
            let row1 = (phaseIdx + 1) * nTaps

            let outBaseOffset = outIndex * ch
            for c in 0..<ch {
                var acc = 0.0
                var hPos = historyWritePos // oldest sample in ring
                for k in 0..<nTaps {
                    let w = table[row0 + k] * oneMinusAlpha + table[row1 + k] * alpha
                    acc += history[hPos * ch + c] * w
                    hPos += 1
                    if hPos == nTaps { hPos = 0 }
                }
                outBase[outBaseOffset + c] = acc
            }

            outIndex += 1
            fracPos += step
        }

        return (inIndex, outIndex)
    }

    /// Convenience offline resampling with automatic latency compensation.
    public static func resample(
        _ input: [Double],
        from sourceRate: Double,
        to targetRate: Double,
        channels: Int,
        taps: Int = 64,
        phases: Int = 512
    ) -> [Double] {
        guard channels > 0, !input.isEmpty else { return [] }
        let inFrames = input.count / channels
        if sourceRate == targetRate { return input }

        let resampler = SincResampler(
            sourceRate: sourceRate,
            targetRate: targetRate,
            channelCount: channels,
            taps: taps,
            phases: phases
        )
        let padFrames = resampler.taps
        let expectedOutFrames = Int((Double(inFrames) * targetRate / sourceRate).rounded())
        let totalInFrames = inFrames + padFrames
        var paddedIn = [Double](repeating: 0.0, count: totalInFrames * channels)
        for i in 0..<(inFrames * channels) { paddedIn[i] = input[i] }

        // Pre-fill half the filter history with zeros so frame 0 aligns at center tap.
        let preDelayOut = Int((Double(resampler.latencyFrames) * targetRate / sourceRate).rounded())
        let totalOutCap = expectedOutFrames + preDelayOut + 16
        var rawOut = [Double](repeating: 0.0, count: totalOutCap * channels)

        let produced = paddedIn.withUnsafeBufferPointer { inBuf in
            rawOut.withUnsafeMutableBufferPointer { outBuf in
                resampler.process(
                    input: inBuf,
                    inputFrames: totalInFrames,
                    output: outBuf,
                    outputFrameCapacity: totalOutCap
                ).producedFrames
            }
        }

        let startFrame = min(preDelayOut, produced)
        let copyFrames = min(expectedOutFrames, max(0, produced - startFrame))
        var result = [Double](repeating: 0.0, count: copyFrames * channels)
        let startSample = startFrame * channels
        for i in 0..<(copyFrames * channels) {
            result[i] = rawOut[startSample + i]
        }
        return result
    }
}

// MARK: - TPDF Dither

/// Deterministic xoshiro256** TPDF dither with optional 1st-order high-pass noise shaping.
/// Real-time safe: zero heap allocations, zero locks.
public final class TPDFDither: AudioNode {
    public let name: String = "TPDFDither"
    public var isBypassed: Bool = false
    public var targetBitDepth: Int
    public var noiseShaping: Bool

    private var s0: UInt64 = 0
    private var s1: UInt64 = 0
    private var s2: UInt64 = 0
    private var s3: UInt64 = 0
    private let initialSeed: UInt64
    private var prevError: [Double]

    public init(targetBitDepth: Int = 16, noiseShaping: Bool = false, channelCount: Int = 2, seed: UInt64 = 0x9E37_79B9_7F4A_7C15) {
        self.targetBitDepth = max(8, min(24, targetBitDepth))
        self.noiseShaping = noiseShaping
        self.initialSeed = seed
        self.prevError = [Double](repeating: 0.0, count: max(1, channelCount))
        seedPRNG(seed)
    }

    private func seedPRNG(_ seed: UInt64) {
        var z = seed
        func splitmix64() -> UInt64 {
            z &+= 0x9E37_79B9_7F4A_7C15
            var x = z
            x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
            x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
            return x ^ (x >> 31)
        }
        s0 = splitmix64()
        s1 = splitmix64()
        s2 = splitmix64()
        s3 = splitmix64()
    }

    @inline(__always)
    private func nextUInt64() -> UInt64 {
        let x = s1 &* 5
        let rot = (x << 7) | (x >> 57)
        let result = rot &* 9
        let t = s1 << 17
        s2 ^= s0
        s3 ^= s1
        s1 ^= s2
        s0 ^= s3
        s2 ^= t
        s3 = (s3 << 45) | (s3 >> 19)
        return result
    }

    /// Uniform random Double in `[0.0, 1.0)`.
    @inline(__always)
    public func nextUniform() -> Double {
        Double(nextUInt64() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// Triangular PDF noise in `(-1.0, 1.0)` with zero mean and variance `1/6`.
    @inline(__always)
    public func nextTriangular() -> Double {
        nextUniform() - nextUniform()
    }

    public func prepare(sampleRate: Double, channelCount: Int, maxFrames: Int) {
        if prevError.count < channelCount {
            prevError = [Double](repeating: 0.0, count: channelCount)
        }
        reset()
    }

    public func reset() {
        for i in 0..<prevError.count { prevError[i] = 0.0 }
        seedPRNG(initialSeed)
    }

    /// Quantizes a normalized `[-1.0, 1.0]` sample to 16-bit signed integer with TPDF dither.
    @inline(__always)
    public func quantizeToInt16(_ sample: Double, channel: Int = 0) -> Int16 {
        let scale = 32768.0
        let scaled = sample * scale
        let shaped = noiseShaping && channel < prevError.count ? (scaled - 0.5 * prevError[channel]) : scaled
        let dithered = shaped + nextTriangular()
        let q = min(max(dithered.rounded(), -32768.0), 32767.0)
        if noiseShaping && channel < prevError.count {
            prevError[channel] = q - shaped
        }
        return Int16(q)
    }

    /// Quantizes a normalized `[-1.0, 1.0]` sample to 24-bit signed integer with TPDF dither.
    @inline(__always)
    public func quantizeToInt24(_ sample: Double, channel: Int = 0) -> Int32 {
        let scale = 8_388_608.0
        let scaled = sample * scale
        let shaped = noiseShaping && channel < prevError.count ? (scaled - 0.5 * prevError[channel]) : scaled
        let dithered = shaped + nextTriangular()
        let q = min(max(dithered.rounded(), -8_388_608.0), 8_388_607.0)
        if noiseShaping && channel < prevError.count {
            prevError[channel] = q - shaped
        }
        return Int32(q)
    }

    /// Dithers and quantizes a normalized sample to `targetBitDepth`, returning normalized Double.
    @inline(__always)
    public func ditherSample(_ sample: Double, channel: Int = 0) -> Double {
        let levels = Double(Int64(1) << (targetBitDepth - 1))
        let maxPos = levels - 1.0
        let scaled = sample * levels
        let shaped = noiseShaping && channel < prevError.count ? (scaled - 0.5 * prevError[channel]) : scaled
        let dithered = shaped + nextTriangular()
        let q = min(max(dithered.rounded(), -levels), maxPos)
        if noiseShaping && channel < prevError.count {
            prevError[channel] = q - shaped
        }
        return q / levels
    }

    public func process(input: AudioBufferView, output: AudioBufferView, frameCount: Int, sampleRate: Double) {
        let ch = input.channelCount
        for f in 0..<frameCount {
            let base = f * ch
            for c in 0..<ch {
                output.samples[base + c] = ditherSample(input.samples[base + c], channel: c)
            }
        }
    }
}

// MARK: - Parametric Biquad EQ (RBJ Audio EQ Cookbook, 64-bit Float TDF-II)

public enum BiquadType: Equatable, Hashable, Sendable {
    case lowPass(frequency: Double, q: Double)
    case highPass(frequency: Double, q: Double)
    case bandPass(frequency: Double, q: Double)
    case notch(frequency: Double, q: Double)
    case peaking(frequency: Double, q: Double, gainDB: Double)
    case lowShelf(frequency: Double, slope: Double, gainDB: Double)
    case highShelf(frequency: Double, slope: Double, gainDB: Double)
}

public struct BiquadCoefficients: Equatable, Sendable {
    public var b0: Double
    public var b1: Double
    public var b2: Double
    public var a1: Double
    public var a2: Double

    public static let identity = BiquadCoefficients(b0: 1.0, b1: 0.0, b2: 0.0, a1: 0.0, a2: 0.0)

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    /// Computes normalized RBJ Audio EQ Cookbook biquad coefficients in 64-bit float.
    public static func design(_ type: BiquadType, sampleRate: Double) -> BiquadCoefficients {
        guard sampleRate > 0 else { return .identity }
        let nyquist = sampleRate * 0.499

        let b0, b1, b2, a0, a1, a2: Double
        switch type {
        case .lowPass(let freq, let q):
            let f = min(max(freq, 1.0), nyquist)
            let w0 = 2.0 * Double.pi * f / sampleRate
            let cosW0 = Math.cos(w0)
            let alpha = Math.sin(w0) / (2.0 * max(q, 1e-4))
            b0 = (1.0 - cosW0) * 0.5
            b1 = 1.0 - cosW0
            b2 = (1.0 - cosW0) * 0.5
            a0 = 1.0 + alpha
            a1 = -2.0 * cosW0
            a2 = 1.0 - alpha

        case .highPass(let freq, let q):
            let f = min(max(freq, 1.0), nyquist)
            let w0 = 2.0 * Double.pi * f / sampleRate
            let cosW0 = Math.cos(w0)
            let alpha = Math.sin(w0) / (2.0 * max(q, 1e-4))
            b0 = (1.0 + cosW0) * 0.5
            b1 = -(1.0 + cosW0)
            b2 = (1.0 + cosW0) * 0.5
            a0 = 1.0 + alpha
            a1 = -2.0 * cosW0
            a2 = 1.0 - alpha

        case .bandPass(let freq, let q):
            let f = min(max(freq, 1.0), nyquist)
            let w0 = 2.0 * Double.pi * f / sampleRate
            let cosW0 = Math.cos(w0)
            let alpha = Math.sin(w0) / (2.0 * max(q, 1e-4))
            b0 = alpha
            b1 = 0.0
            b2 = -alpha
            a0 = 1.0 + alpha
            a1 = -2.0 * cosW0
            a2 = 1.0 - alpha

        case .notch(let freq, let q):
            let f = min(max(freq, 1.0), nyquist)
            let w0 = 2.0 * Double.pi * f / sampleRate
            let cosW0 = Math.cos(w0)
            let alpha = Math.sin(w0) / (2.0 * max(q, 1e-4))
            b0 = 1.0
            b1 = -2.0 * cosW0
            b2 = 1.0
            a0 = 1.0 + alpha
            a1 = -2.0 * cosW0
            a2 = 1.0 - alpha

        case .peaking(let freq, let q, let gainDB):
            let f = min(max(freq, 1.0), nyquist)
            let A = AudioMath.pow10(gainDB / 40.0)
            let w0 = 2.0 * Double.pi * f / sampleRate
            let cosW0 = Math.cos(w0)
            let alpha = Math.sin(w0) / (2.0 * max(q, 1e-4))
            b0 = 1.0 + alpha * A
            b1 = -2.0 * cosW0
            b2 = 1.0 - alpha * A
            a0 = 1.0 + alpha / A
            a1 = -2.0 * cosW0
            a2 = 1.0 - alpha / A

        case .lowShelf(let freq, let slope, let gainDB):
            let f = min(max(freq, 1.0), nyquist)
            let A = AudioMath.pow10(gainDB / 40.0)
            let w0 = 2.0 * Double.pi * f / sampleRate
            let cosW0 = Math.cos(w0)
            let sinW0 = Math.sin(w0)
            let s = max(slope, 1e-4)
            let alpha = sinW0 * 0.5 * max(0.0, (A + 1.0 / A) * (1.0 / s - 1.0) + 2.0).squareRoot()
            let twoSqrtAAlpha = 2.0 * A.squareRoot() * alpha
            b0 = A * ((A + 1.0) - (A - 1.0) * cosW0 + twoSqrtAAlpha)
            b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cosW0)
            b2 = A * ((A + 1.0) - (A - 1.0) * cosW0 - twoSqrtAAlpha)
            a0 = (A + 1.0) + (A - 1.0) * cosW0 + twoSqrtAAlpha
            a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cosW0)
            a2 = (A + 1.0) + (A - 1.0) * cosW0 - twoSqrtAAlpha

        case .highShelf(let freq, let slope, let gainDB):
            let f = min(max(freq, 1.0), nyquist)
            let A = AudioMath.pow10(gainDB / 40.0)
            let w0 = 2.0 * Double.pi * f / sampleRate
            let cosW0 = Math.cos(w0)
            let sinW0 = Math.sin(w0)
            let s = max(slope, 1e-4)
            let alpha = sinW0 * 0.5 * max(0.0, (A + 1.0 / A) * (1.0 / s - 1.0) + 2.0).squareRoot()
            let twoSqrtAAlpha = 2.0 * A.squareRoot() * alpha
            b0 = A * ((A + 1.0) + (A - 1.0) * cosW0 + twoSqrtAAlpha)
            b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cosW0)
            b2 = A * ((A + 1.0) + (A - 1.0) * cosW0 - twoSqrtAAlpha)
            a0 = (A + 1.0) - (A - 1.0) * cosW0 + twoSqrtAAlpha
            a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cosW0)
            a2 = (A + 1.0) - (A - 1.0) * cosW0 - twoSqrtAAlpha
        }

        let invA0 = 1.0 / a0
        return BiquadCoefficients(b0: b0 * invA0, b1: b1 * invA0, b2: b2 * invA0, a1: a1 * invA0, a2: a2 * invA0)
    }

    /// Exact analytical magnitude response `|H(e^{j w})|` at `frequency` Hz.
    public func magnitudeResponse(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2.0 * Double.pi * frequency / sampleRate
        let cos1 = Math.cos(w), sin1 = Math.sin(w)
        let cos2 = Math.cos(2.0 * w), sin2 = Math.sin(2.0 * w)
        let numRe = b0 + b1 * cos1 + b2 * cos2
        let numIm = -(b1 * sin1 + b2 * sin2)
        let denRe = 1.0 + a1 * cos1 + a2 * cos2
        let denIm = -(a1 * sin1 + a2 * sin2)
        let numSq = numRe * numRe + numIm * numIm
        let denSq = denRe * denRe + denIm * denIm
        guard denSq > 0 else { return 0 }
        return (numSq / denSq).squareRoot()
    }
}

public struct BiquadState: Sendable {
    public var z1: Double = 0.0
    public var z2: Double = 0.0

    public init() {}

    @inline(__always)
    public mutating func process(_ x: Double, _ c: BiquadCoefficients) -> Double {
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        return y
    }
}

/// Multi-channel 64-bit float Transposed Direct Form II biquad filter.
public final class BiquadFilter: AudioNode {
    public let name: String
    public var isBypassed: Bool = false
    public private(set) var coefficients: BiquadCoefficients
    public private(set) var filterType: BiquadType?
    private var states: [BiquadState]

    public init(name: String = "Biquad", coefficients: BiquadCoefficients = .identity, channelCount: Int = 2) {
        self.name = name
        self.coefficients = coefficients
        self.filterType = nil
        self.states = [BiquadState](repeating: BiquadState(), count: max(1, channelCount))
    }

    public init(name: String = "Biquad", type: BiquadType, sampleRate: Double, channelCount: Int = 2) {
        self.name = name
        self.filterType = type
        self.coefficients = BiquadCoefficients.design(type, sampleRate: sampleRate)
        self.states = [BiquadState](repeating: BiquadState(), count: max(1, channelCount))
    }

    public func configure(_ type: BiquadType, sampleRate: Double) {
        self.filterType = type
        self.coefficients = BiquadCoefficients.design(type, sampleRate: sampleRate)
    }

    public func setCoefficients(_ coefficients: BiquadCoefficients) {
        self.filterType = nil
        self.coefficients = coefficients
    }

    public func prepare(sampleRate: Double, channelCount: Int, maxFrames: Int) {
        if states.count < channelCount {
            states = [BiquadState](repeating: BiquadState(), count: channelCount)
        }
        if let filterType {
            coefficients = BiquadCoefficients.design(filterType, sampleRate: sampleRate)
        }
    }

    public func reset() {
        for i in 0..<states.count {
            states[i] = BiquadState()
        }
    }

    @inline(__always)
    public func processSample(_ x: Double, channel: Int = 0) -> Double {
        states[channel].process(x, coefficients)
    }

    public func process(input: AudioBufferView, output: AudioBufferView, frameCount: Int, sampleRate: Double) {
        let ch = min(input.channelCount, states.count)
        let c = coefficients
        for f in 0..<frameCount {
            let base = f * input.channelCount
            for channel in 0..<ch {
                output.samples[base + channel] = states[channel].process(input.samples[base + channel], c)
            }
        }
    }
}

/// Multi-band parametric equalizer executing a cascade of 64-bit float biquad bands.
/// Real-time safe: zero allocations during `process`.
public final class ParametricEQ: AudioNode {
    public let name: String = "ParametricEQ"
    public var isBypassed: Bool = false
    public private(set) var bands: [BiquadFilter] = []
    private var currentSampleRate: Double = 48_000.0
    private var currentChannels: Int = 2

    public init(bands: [BiquadType] = [], sampleRate: Double = 48_000.0, channelCount: Int = 2) {
        self.currentSampleRate = sampleRate
        self.currentChannels = max(1, channelCount)
        for (i, b) in bands.enumerated() {
            self.bands.append(BiquadFilter(name: "Band \(i)", type: b, sampleRate: sampleRate, channelCount: self.currentChannels))
        }
    }

    public func addBand(_ type: BiquadType) {
        bands.append(BiquadFilter(name: "Band \(bands.count)", type: type, sampleRate: currentSampleRate, channelCount: currentChannels))
    }

    public func setBand(_ index: Int, type: BiquadType) {
        guard index >= 0 && index < bands.count else { return }
        bands[index].configure(type, sampleRate: currentSampleRate)
    }

    public func removeAllBands() {
        bands.removeAll()
    }

    public func prepare(sampleRate: Double, channelCount: Int, maxFrames: Int) {
        currentSampleRate = sampleRate
        currentChannels = max(1, channelCount)
        for band in bands {
            band.prepare(sampleRate: sampleRate, channelCount: currentChannels, maxFrames: maxFrames)
        }
    }

    public func reset() {
        for band in bands { band.reset() }
    }

    public func process(input: AudioBufferView, output: AudioBufferView, frameCount: Int, sampleRate: Double) {
        output.copy(from: input, frameCount: frameCount)
        for i in 0..<bands.count {
            let band = bands[i]
            if band.isBypassed { continue }
            band.process(input: output, output: output, frameCount: frameCount, sampleRate: sampleRate)
        }
    }
}

// MARK: - EBU R128 Loudness Meter & ReplayGain

/// ITU-R BS.1770-4 / EBU R128 loudness meter with K-weighting filters,
/// 400 ms momentary blocks (100 ms hop), absolute (-70 LUFS) and relative (-10 LU) gating.
public final class LoudnessMeter {
    public let sampleRate: Double
    public let channelCount: Int

    private let stage1Coeffs: BiquadCoefficients
    private let stage2Coeffs: BiquadCoefficients
    private var stage1States: [BiquadState]
    private var stage2States: [BiquadState]

    // 100 ms sub-block accumulator (4 sub-blocks = 400 ms momentary window).
    private let subBlockFrames: Int
    private var currentSubBlockCount: Int = 0
    private var currentSubBlockEnergy: Double = 0.0
    private var recentSubBlocks: [Double] = [0.0, 0.0, 0.0, 0.0]
    private var recentSubBlockCount: Int = 0
    private var recentSubBlockPos: Int = 0

    // Mean square energy of every completed 400 ms overlapping block.
    private var blockMeanSquares: [Double] = []
    public private(set) var momentaryLUFS: Double = -200.0

    public init(sampleRate: Double, channelCount: Int) {
        precondition(sampleRate > 0 && channelCount > 0)
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.stage1Coeffs = Self.kWeightStage1(sampleRate: sampleRate)
        self.stage2Coeffs = Self.kWeightStage2(sampleRate: sampleRate)
        self.stage1States = [BiquadState](repeating: BiquadState(), count: channelCount)
        self.stage2States = [BiquadState](repeating: BiquadState(), count: channelCount)
        self.subBlockFrames = max(1, Int((sampleRate * 0.1).rounded()))
    }

    /// Stage 1: ITU-R BS.1770-4 pre-filter high-shelf (+4 dB above ~1681.97 Hz).
    public static func kWeightStage1(sampleRate: Double) -> BiquadCoefficients {
        let f0 = 1681.974450955533
        let g = 3.999843853973347
        let q = 0.7071752369554196
        let k = AudioMath.tan(Double.pi * f0 / sampleRate)
        let vh = AudioMath.pow10(g / 20.0)
        let vb = pow(base: vh, 0.4996667741545416)
        let a0 = 1.0 + k / q + k * k
        let invA0 = 1.0 / a0
        return BiquadCoefficients(
            b0: (vh + vb * k / q + k * k) * invA0,
            b1: 2.0 * (k * k - vh) * invA0,
            b2: (vh - vb * k / q + k * k) * invA0,
            a1: 2.0 * (k * k - 1.0) * invA0,
            a2: (1.0 - k / q + k * k) * invA0
        )
    }

    /// Stage 2: ITU-R BS.1770-4 RLB high-pass (~38.135 Hz).
    public static func kWeightStage2(sampleRate: Double) -> BiquadCoefficients {
        let f0 = 38.13547087602444
        let q = 0.5003270373238773
        let k = AudioMath.tan(Double.pi * f0 / sampleRate)
        let a0 = 1.0 + k / q + k * k
        let invA0 = 1.0 / a0
        return BiquadCoefficients(
            b0: 1.0,
            b1: -2.0,
            b2: 1.0,
            a1: 2.0 * (k * k - 1.0) * invA0,
            a2: (1.0 - k / q + k * k) * invA0
        )
    }

    public func reset() {
        for i in 0..<channelCount {
            stage1States[i] = BiquadState()
            stage2States[i] = BiquadState()
        }
        currentSubBlockCount = 0
        currentSubBlockEnergy = 0.0
        recentSubBlocks = [0.0, 0.0, 0.0, 0.0]
        recentSubBlockCount = 0
        recentSubBlockPos = 0
        blockMeanSquares.removeAll(keepingCapacity: true)
        momentaryLUFS = -200.0
    }

    /// Feeds interleaved 64-bit float audio frames into the loudness meter.
    public func process(_ samples: [Double]) {
        let frames = samples.count / channelCount
        guard frames > 0 else { return }

        for f in 0..<frames {
            let base = f * channelCount
            var frameSumSq = 0.0
            for c in 0..<channelCount {
                let weight: Double = (channelCount >= 5 && (c == 3 || c == 4)) ? 1.41 : 1.0
                if channelCount >= 6 && c == 3 { continue } // LFE excluded in 5.1
                let x = samples[base + c]
                let y1 = stage1States[c].process(x, stage1Coeffs)
                let y2 = stage2States[c].process(y1, stage2Coeffs)
                frameSumSq += weight * y2 * y2
            }
            currentSubBlockEnergy += frameSumSq
            currentSubBlockCount += 1

            if currentSubBlockCount == subBlockFrames {
                let subMean = currentSubBlockEnergy / Double(subBlockFrames)
                recentSubBlocks[recentSubBlockPos] = subMean
                recentSubBlockPos = (recentSubBlockPos + 1) & 3
                if recentSubBlockCount < 4 { recentSubBlockCount += 1 }
                currentSubBlockEnergy = 0.0
                currentSubBlockCount = 0

                if recentSubBlockCount == 4 {
                    let blockMean = 0.25 * (recentSubBlocks[0] + recentSubBlocks[1] + recentSubBlocks[2] + recentSubBlocks[3])
                    blockMeanSquares.append(blockMean)
                    momentaryLUFS = Self.energyToLUFS(blockMean)
                }
            }
        }
    }

    /// Integrated gated loudness in LUFS per EBU R128 / ITU-R BS.1770-4.
    public var integratedLUFS: Double {
        guard !blockMeanSquares.isEmpty else { return -200.0 }
        // Step 1: Absolute gate at -70.0 LUFS.
        let absThresholdEnergy = AudioMath.pow10((-70.0 + 0.691) * 0.1)
        var absSum = 0.0
        var absCount = 0
        for e in blockMeanSquares where e > absThresholdEnergy {
            absSum += e
            absCount += 1
        }
        guard absCount > 0 else { return -200.0 }

        // Step 2: Relative gate at (ungated loudness - 10.0 LU).
        let ungatedLUFS = Self.energyToLUFS(absSum / Double(absCount))
        let relThresholdEnergy = AudioMath.pow10((ungatedLUFS - 10.0 + 0.691) * 0.1)
        var relSum = 0.0
        var relCount = 0
        for e in blockMeanSquares where e > absThresholdEnergy && e > relThresholdEnergy {
            relSum += e
            relCount += 1
        }
        guard relCount > 0 else { return -200.0 }
        return Self.energyToLUFS(relSum / Double(relCount))
    }

    /// ReplayGain adjustment in dB to reach `targetLUFS` (e.g. -18.0 or -14.0 LUFS).
    public func replayGainDB(targetLUFS: Double = -18.0) -> Double {
        let integrated = integratedLUFS
        guard integrated > -199.0 else { return 0.0 }
        return targetLUFS - integrated
    }

    @inline(__always)
    private static func energyToLUFS(_ energy: Double) -> Double {
        if energy <= 0.0 { return -200.0 }
        return max(-200.0, -0.691 + 10.0 * AudioMath.log10(energy))
    }
}

// MARK: - 4x Oversampled Lookahead True-Peak Limiter

/// 4x oversampled lookahead true-peak limiter in 64-bit float.
/// Zero heap allocations and zero locks inside `process`.
public final class TruePeakLimiter: AudioNode {
    public let name: String = "TruePeakLimiter"
    public var isBypassed: Bool = false

    public var ceilingDB: Double {
        didSet { ceilingLinear = AudioMath.dbToLinear(ceilingDB) }
    }
    public private(set) var ceilingLinear: Double
    public var lookaheadMs: Double
    public var releaseMs: Double

    // 4x oversampling polyphase FIR (4 phases x 12 taps = 48-tap Kaiser-windowed sinc).
    private static let osPhases = 4
    private static let osTaps = 12
    private let osCoeffs: [Double] // 4 * 12

    // Pre-allocated per-channel oversampling history, lookahead audio ring, and peak ring.
    private var channelCount: Int = 2
    private var lookaheadFrames: Int = 240
    private var osHistory: [Double] = []
    private var osHistoryPos: Int = 0
    private var delayBuffer: [Double] = []
    private var delayPos: Int = 0
    private var peakWindow: [Double] = []
    private var peakWindowPos: Int = 0
    private var smoothedGain: Double = 1.0
    private var releaseCoeff: Double = 0.999

    public init(ceilingDB: Double = -1.0, lookaheadMs: Double = 5.0, releaseMs: Double = 50.0, sampleRate: Double = 48_000.0, channelCount: Int = 2) {
        self.ceilingDB = ceilingDB
        self.ceilingLinear = AudioMath.dbToLinear(ceilingDB)
        self.lookaheadMs = max(0.5, lookaheadMs)
        self.releaseMs = max(5.0, releaseMs)
        self.osCoeffs = Self.buildOversampleTable()
        prepare(sampleRate: sampleRate, channelCount: channelCount, maxFrames: 0)
    }

    private static func buildOversampleTable() -> [Double] {
        let phases = osPhases
        let taps = osTaps
        let beta = 7.0
        let invI0 = 1.0 / AudioMath.besselI0(beta)
        let half = Double(taps) * 0.5
        var coeffs = [Double](repeating: 0.0, count: phases * taps)
        for p in 0..<phases {
            let frac = Double(p) / Double(phases)
            var sum = 0.0
            for k in 0..<taps {
                let x = Double(k) - (half - 1.0 + frac)
                let norm = x / half
                let w = abs(norm) >= 1.0 ? 0.0 : AudioMath.besselI0(beta * (1.0 - norm * norm).squareRoot()) * invI0
                let h = AudioMath.sinc(x) * w
                coeffs[p * taps + k] = h
                sum += h
            }
            if abs(sum) > 1e-12 {
                let inv = 1.0 / sum
                for k in 0..<taps { coeffs[p * taps + k] *= inv }
            }
        }
        return coeffs
    }

    public func prepare(sampleRate: Double, channelCount: Int, maxFrames: Int) {
        self.channelCount = max(1, channelCount)
        // Lookahead covers requested lookahead + half the oversampling FIR group delay.
        let requested = max(1, Int((sampleRate * lookaheadMs * 0.001).rounded()))
        self.lookaheadFrames = max(requested, Self.osTaps)
        self.osHistory = [Double](repeating: 0.0, count: Self.osTaps * self.channelCount)
        self.delayBuffer = [Double](repeating: 0.0, count: self.lookaheadFrames * self.channelCount)
        self.peakWindow = [Double](repeating: 0.0, count: self.lookaheadFrames)
        self.releaseCoeff = Math.exp(-1.0 / max(1.0, sampleRate * releaseMs * 0.001))
        reset()
    }

    public func reset() {
        for i in 0..<osHistory.count { osHistory[i] = 0.0 }
        for i in 0..<delayBuffer.count { delayBuffer[i] = 0.0 }
        for i in 0..<peakWindow.count { peakWindow[i] = 0.0 }
        osHistoryPos = 0
        delayPos = 0
        peakWindowPos = 0
        smoothedGain = 1.0
    }

    /// Measures the 4x oversampled true peak (linear) of an interleaved audio buffer.
    public static func measureTruePeak(_ samples: [Double], channels: Int) -> Double {
        guard channels > 0, !samples.isEmpty else { return 0.0 }
        let frames = samples.count / channels
        let coeffs = buildOversampleTable()
        var hist = [Double](repeating: 0.0, count: osTaps * channels)
        var pos = 0
        var maxPeak = 0.0

        for f in 0..<frames {
            let base = f * channels
            let hDst = pos * channels
            for c in 0..<channels {
                let s = samples[base + c]
                hist[hDst + c] = s
                if abs(s) > maxPeak { maxPeak = abs(s) }
            }
            pos += 1
            if pos == osTaps { pos = 0 }

            for p in 0..<osPhases {
                let row = p * osTaps
                for c in 0..<channels {
                    var acc = 0.0
                    var hp = pos
                    for k in 0..<osTaps {
                        acc += hist[hp * channels + c] * coeffs[row + k]
                        hp += 1
                        if hp == osTaps { hp = 0 }
                    }
                    let a = abs(acc)
                    if a > maxPeak { maxPeak = a }
                }
            }
        }
        return maxPeak
    }

    public func process(input: AudioBufferView, output: AudioBufferView, frameCount: Int, sampleRate: Double) {
        let ch = min(input.channelCount, channelCount)
        let nTaps = Self.osTaps
        let nPhases = Self.osPhases
        let ceilLin = ceilingLinear
        let look = lookaheadFrames

        for f in 0..<frameCount {
            let inBase = f * input.channelCount
            let hDst = osHistoryPos * channelCount
            var frameTruePeak = 0.0

            // Push incoming frame into oversampling history.
            for c in 0..<ch {
                let x = input.samples[inBase + c]
                osHistory[hDst + c] = x
                let ax = abs(x)
                if ax > frameTruePeak { frameTruePeak = ax }
            }
            osHistoryPos += 1
            if osHistoryPos == nTaps { osHistoryPos = 0 }

            // Evaluate 4x oversampled inter-sample peaks.
            for p in 0..<nPhases {
                let row = p * nTaps
                for c in 0..<ch {
                    var acc = 0.0
                    var hp = osHistoryPos
                    for k in 0..<nTaps {
                        acc += osHistory[hp * channelCount + c] * osCoeffs[row + k]
                        hp += 1
                        if hp == nTaps { hp = 0 }
                    }
                    let a = abs(acc)
                    if a > frameTruePeak { frameTruePeak = a }
                }
            }

            // Record peak into lookahead window and find maximum peak within the lookahead horizon.
            peakWindow[peakWindowPos] = frameTruePeak
            peakWindowPos += 1
            if peakWindowPos == look { peakWindowPos = 0 }

            var windowMax = 0.0
            for i in 0..<look {
                if peakWindow[i] > windowMax { windowMax = peakWindow[i] }
            }

            let targetGain = windowMax > ceilLin ? (ceilLin / windowMax) : 1.0
            if targetGain < smoothedGain {
                // Instantaneous downward envelope tracking to guarantee <= ceiling.
                smoothedGain = targetGain
            } else {
                // Smooth exponential release.
                smoothedGain = targetGain + (smoothedGain - targetGain) * releaseCoeff
                if smoothedGain > targetGain { smoothedGain = targetGain }
            }

            // Output delayed frame scaled by gain, and store new incoming frame in delay ring.
            let dBase = delayPos * channelCount
            let outBase = f * output.channelCount
            let g = smoothedGain
            for c in 0..<ch {
                let delayed = delayBuffer[dBase + c]
                delayBuffer[dBase + c] = input.samples[inBase + c]
                output.samples[outBase + c] = delayed * g
            }
            delayPos += 1
            if delayPos == look { delayPos = 0 }
        }
    }
}

// MARK: - Crossfade

public enum CrossfadeCurve: Equatable, Hashable, Sendable {
    case linear
    case equalPower
}

public enum Crossfader {
    /// Returns `(gainA, gainB)` for normalized crossfade position `t` in `[0, 1]`.
    @inlinable
    public static func gains(position t: Double, curve: CrossfadeCurve = .equalPower) -> (gainA: Double, gainB: Double) {
        let x = min(max(t, 0.0), 1.0)
        switch curve {
        case .linear:
            return (1.0 - x, x)
        case .equalPower:
            let angle = x * Double.pi * 0.5
            return (Math.cos(angle), Math.sin(angle))
        }
    }

    /// Mixes `a` and `b` into `output` over `frameCount` frames with zero allocations.
    public static func mix(
        a: AudioBufferView,
        b: AudioBufferView,
        output: AudioBufferView,
        frameCount: Int,
        startPosition: Double,
        endPosition: Double,
        curve: CrossfadeCurve = .equalPower
    ) {
        guard frameCount > 0 else { return }
        let ch = min(output.channelCount, min(a.channelCount, b.channelCount))
        let invDen = frameCount > 1 ? 1.0 / Double(frameCount - 1) : 0.0
        for f in 0..<frameCount {
            let frac = frameCount > 1 ? Double(f) * invDen : 1.0
            let t = startPosition + (endPosition - startPosition) * frac
            let (gA, gB) = gains(position: t, curve: curve)
            let base = f * ch
            for c in 0..<ch {
                output.samples[base + c] = a.samples[base + c] * gA + b.samples[base + c] * gB
            }
        }
    }
}

// MARK: - Headphone Crossfeed (BS2B Complementary Topology)

/// Bauer / BS2B-style stereo headphone crossfeed in 64-bit float.
///
/// Uses a complementary low-pass crossfeed path `H_C(z) = k * H_LP(z)` and
/// direct high-shelf path `H_D(z) = 1 - k * H_LP(z)`, guaranteeing exact
/// unity mono preservation (`H_D + H_C == 1`) while providing natural
/// low-frequency interaural crossfeed and high-frequency head shadow.
public final class HeadphoneCrossfeed: AudioNode {
    public struct Preset: Equatable, Hashable, Sendable {
        public var cutoffHz: Double
        public var feedDB: Double

        public init(cutoffHz: Double, feedDB: Double) {
            self.cutoffHz = cutoffHz
            self.feedDB = feedDB
        }

        public static let standard = Preset(cutoffHz: 700.0, feedDB: 4.5)
        public static let cmoy = Preset(cutoffHz: 700.0, feedDB: 6.0)
        public static let jmeier = Preset(cutoffHz: 650.0, feedDB: 9.5)
    }

    public let name: String = "HeadphoneCrossfeed"
    public var isBypassed: Bool = false
    public private(set) var preset: Preset

    private var alpha: Double = 0.0
    private var crossGain: Double = 0.0
    private var lpL: Double = 0.0
    private var lpR: Double = 0.0

    public init(preset: Preset = .standard, sampleRate: Double = 48_000.0) {
        self.preset = preset
        configure(preset: preset, sampleRate: sampleRate)
    }

    public func configure(preset: Preset, sampleRate: Double) {
        self.preset = preset
        let fc = min(max(preset.cutoffHz, 100.0), sampleRate * 0.25)
        self.alpha = 1.0 - Math.exp(-2.0 * Double.pi * fc / sampleRate)
        let ratio = AudioMath.dbToLinear(-abs(preset.feedDB))
        self.crossGain = ratio / (1.0 + ratio)
    }

    public func prepare(sampleRate: Double, channelCount: Int, maxFrames: Int) {
        configure(preset: preset, sampleRate: sampleRate)
        reset()
    }

    public func reset() {
        lpL = 0.0
        lpR = 0.0
    }

    public func process(input: AudioBufferView, output: AudioBufferView, frameCount: Int, sampleRate: Double) {
        if input.channelCount != 2 || output.channelCount != 2 {
            output.copy(from: input, frameCount: frameCount)
            return
        }
        let a = alpha
        let oneMinusA = 1.0 - a
        let k = crossGain
        var sL = lpL
        var sR = lpR

        for f in 0..<frameCount {
            let idx = f * 2
            let inL = input.samples[idx]
            let inR = input.samples[idx + 1]
            sL = a * inL + oneMinusA * sL
            sR = a * inR + oneMinusA * sR
            output.samples[idx] = inL + k * (sR - sL)
            output.samples[idx + 1] = inR + k * (sL - sR)
        }

        lpL = sL
        lpR = sR
    }
}

// MARK: - Audio Measurement & Verification Utilities

public struct NullTestResult: Equatable, Sendable {
    public var peakDifference: Double
    public var rmsDifference: Double
    public var peakDifferenceDB: Double
    public var rmsDifferenceDB: Double
}

public struct THDNResult: Equatable, Sendable {
    public var fundamentalAmplitude: Double
    public var residualRMS: Double
    public var thdnRatio: Double
    public var thdnDB: Double
}

public enum AudioMetrics {
    /// Computes peak and RMS null difference between two equal-length signals.
    public static func nullDifference(a: [Double], b: [Double]) -> NullTestResult {
        let count = min(a.count, b.count)
        guard count > 0 else {
            return NullTestResult(peakDifference: 0, rmsDifference: 0, peakDifferenceDB: -200, rmsDifferenceDB: -200)
        }
        var peak = 0.0
        var sumSq = 0.0
        for i in 0..<count {
            let d = abs(a[i] - b[i])
            if d > peak { peak = d }
            sumSq += d * d
        }
        let rms = (sumSq / Double(count)).squareRoot()
        return NullTestResult(
            peakDifference: peak,
            rmsDifference: rms,
            peakDifferenceDB: AudioMath.linearToDB(peak),
            rmsDifferenceDB: AudioMath.linearToDB(rms)
        )
    }

    /// Returns the peak null difference in dBFS (`-200.0` for bit-exact identical signals).
    public static func nullDifferenceDB(a: [Double], b: [Double]) -> Double {
        nullDifference(a: a, b: b).peakDifferenceDB
    }

    /// Measures THD+N via exact IEEE 1057 least-squares sine fit at `fundamentalHz`
    /// (zero spectral leakage even for non-integer cycle counts).
    public static func measureTHDN(
        signal: [Double],
        sampleRate: Double,
        fundamentalHz: Double,
        skipEdgeSamples: Int = 0
    ) -> THDNResult {
        let start = min(max(0, skipEdgeSamples), signal.count)
        let end = max(start, signal.count - max(0, skipEdgeSamples))
        let n = end - start
        guard n > 4, sampleRate > 0, fundamentalHz > 0 else {
            return THDNResult(fundamentalAmplitude: 0, residualRMS: 0, thdnRatio: 1, thdnDB: 0)
        }

        let omega = 2.0 * Double.pi * fundamentalHz / sampleRate
        var scc = 0.0, sss = 0.0, scs = 0.0
        var syc = 0.0, sys = 0.0

        for idx in start..<end {
            let angle = omega * Double(idx)
            let c = Math.cos(angle)
            let s = Math.sin(angle)
            let y = signal[idx]
            scc += c * c
            sss += s * s
            scs += c * s
            syc += y * c
            sys += y * s
        }

        let det = scc * sss - scs * scs
        guard abs(det) > 1e-18 else {
            return THDNResult(fundamentalAmplitude: 0, residualRMS: 0, thdnRatio: 1, thdnDB: 0)
        }
        let ampCos = (sss * syc - scs * sys) / det
        let ampSin = (scc * sys - scs * syc) / det
        let amp = (ampCos * ampCos + ampSin * ampSin).squareRoot()
        let fundRMS = amp * 0.70710678118654752440

        var errSq = 0.0
        for idx in start..<end {
            let angle = omega * Double(idx)
            let fitted = ampCos * Math.cos(angle) + ampSin * Math.sin(angle)
            let r = signal[idx] - fitted
            errSq += r * r
        }
        let residualRMS = (errSq / Double(n)).squareRoot()
        let ratio = fundRMS > 0 ? (residualRMS / fundRMS) : 1.0
        return THDNResult(
            fundamentalAmplitude: amp,
            residualRMS: residualRMS,
            thdnRatio: ratio,
            thdnDB: AudioMath.linearToDB(ratio)
        )
    }

    /// Extracts single-frequency DFT magnitude (linear) for tone/attenuation checks.
    public static func toneMagnitude(
        signal: [Double],
        sampleRate: Double,
        frequencyHz: Double,
        skipEdgeSamples: Int = 0
    ) -> Double {
        measureTHDN(signal: signal, sampleRate: sampleRate, fundamentalHz: frequencyHz, skipEdgeSamples: skipEdgeSamples).fundamentalAmplitude
    }
}
