// Studio-grade 64-bit float DSP: buffers and a serial node graph, plus the
// building blocks a player needs — TPDF dither, RBJ biquad EQ, EBU R128
// loudness, a 4x oversampled true-peak limiter, crossfades and headphone
// crossfeed. Standard library only: no Foundation, no OS audio code.
import PolymerBase

// MARK: - Buffers and Nodes

/// Non-owning, zero-allocation interleaved 64-bit float audio buffer view.
public struct AudioBufferView {
    public let samples: UnsafeMutableBufferPointer<Double>
    public let channelCount: Int
    public let frameCapacity: Int

    @inlinable
    public init(samples: UnsafeMutableBufferPointer<Double>, channelCount: Int, frameCapacity: Int) {
        self.samples = samples
        self.channelCount = channelCount
        self.frameCapacity = frameCapacity
    }

    @inlinable
    public subscript(frame: Int, channel: Int) -> Double {
        get { samples[frame * channelCount + channel] }
        nonmutating set { samples[frame * channelCount + channel] = newValue }
    }

    @inlinable
    public func silence(frameCount: Int) {
        let count = min(frameCount, frameCapacity) * channelCount
        guard count > 0, let base = samples.baseAddress else { return }
        for i in 0..<count { base[i] = 0.0 }
    }

    @inlinable
    public func copy(from source: AudioBufferView, frameCount: Int) {
        let frames = min(frameCount, min(frameCapacity, source.frameCapacity))
        guard frames > 0, let dst = samples.baseAddress, let src = source.samples.baseAddress else { return }
        if dst == src { return }
        if channelCount == source.channelCount {
            for i in 0..<(frames * channelCount) { dst[i] = src[i] }
        } else {
            let ch = min(channelCount, source.channelCount)
            for f in 0..<frames {
                for c in 0..<ch {
                    dst[f * channelCount + c] = src[f * source.channelCount + c]
                }
            }
        }
    }
}

/// Owning, pre-allocated contiguous 64-bit float audio buffer. Allocate off
/// the audio thread; pass `.view` into `AudioGraph.render`.
public final class AudioBufferStorage: @unchecked Sendable {
    public let channelCount: Int
    public let frameCapacity: Int
    private let buffer: UnsafeMutableBufferPointer<Double>

    public init(frameCapacity: Int, channelCount: Int) {
        precondition(frameCapacity >= 0 && channelCount > 0, "invalid audio buffer dimensions")
        self.frameCapacity = frameCapacity
        self.channelCount = channelCount
        let total = max(1, frameCapacity * channelCount)
        let pointer = UnsafeMutablePointer<Double>.allocate(capacity: total)
        pointer.initialize(repeating: 0.0, count: total)
        self.buffer = UnsafeMutableBufferPointer(start: pointer, count: frameCapacity * channelCount)
    }

    deinit {
        buffer.baseAddress?.deallocate()
    }

    public var view: AudioBufferView {
        AudioBufferView(samples: buffer, channelCount: channelCount, frameCapacity: frameCapacity)
    }

    public func clear() {
        view.silence(frameCount: frameCapacity)
    }

    public func copy(from array: [Double]) {
        let count = min(array.count, buffer.count)
        guard count > 0, let dst = buffer.baseAddress else { return }
        array.withUnsafeBufferPointer { src in
            guard let s = src.baseAddress else { return }
            for i in 0..<count { dst[i] = s[i] }
        }
    }

    public func toArray(frameCount: Int? = nil) -> [Double] {
        let frames = min(frameCount ?? frameCapacity, frameCapacity)
        let count = frames * channelCount
        var out = [Double](repeating: 0.0, count: count)
        guard count > 0, let src = buffer.baseAddress else { return out }
        out.withUnsafeMutableBufferPointer { dst in
            guard let d = dst.baseAddress else { return }
            for i in 0..<count { d[i] = src[i] }
        }
        return out
    }
}

/// A stage in a serial audio graph. `process` runs on the audio thread and
/// must not allocate, lock or do I/O.
public protocol AudioNode: AnyObject {
    var name: String { get }
    var isBypassed: Bool { get set }
    func prepare(sampleRate: Double, channelCount: Int, maxFrames: Int)
    func process(input: AudioBufferView, output: AudioBufferView, frameCount: Int, sampleRate: Double)
    func reset()
}

extension AudioNode {
    public func prepare(sampleRate: Double, channelCount: Int, maxFrames: Int) {}
}

/// Peak and RMS levels of the last rendered block, in linear and dB form.
public struct AudioMeterSnapshot: Equatable, Sendable {
    public var peakLinear: Double
    public var rmsLinear: Double
    public var peakDB: Double
    public var rmsDB: Double

    public init(peakLinear: Double, rmsLinear: Double) {
        self.peakLinear = peakLinear
        self.rmsLinear = rmsLinear
        self.peakDB = AudioMath.linearToDB(peakLinear)
        self.rmsDB = AudioMath.linearToDB(rmsLinear)
    }
}

/// Linear gain.
public final class GainNode: AudioNode {
    public let name: String
    public var isBypassed: Bool = false
    public var gain: Double

    public init(name: String = "Gain", gain: Double = 1.0) {
        self.name = name
        self.gain = gain
    }

    public func process(input: AudioBufferView, output: AudioBufferView, frameCount: Int, sampleRate: Double) {
        let g = gain
        let count = frameCount * input.channelCount
        guard count > 0, let src = input.samples.baseAddress, let dst = output.samples.baseAddress else { return }
        if g == 1.0 {
            if src != dst { for i in 0..<count { dst[i] = src[i] } }
            return
        }
        for i in 0..<count { dst[i] = src[i] * g }
    }

    public func reset() {}
}

/// A serial chain of nodes and a master gain, with metering.
public final class AudioGraph {
    private var entries: [any AudioNode] = []
    private var scratchA: AudioBufferStorage?
    private var scratchB: AudioBufferStorage?

    public private(set) var maxFrames: Int = 0
    public private(set) var channelCount: Int = 2
    public private(set) var sampleRate: Double = 48_000.0
    public var masterGain: Double = 1.0
    public var nodeCount: Int { entries.count }

    public init() {}

    public func addNode(_ node: any AudioNode) {
        entries.append(node)
        if maxFrames > 0 {
            node.prepare(sampleRate: sampleRate, channelCount: channelCount, maxFrames: maxFrames)
        }
    }

    public func removeAllNodes() { entries.removeAll() }

    public func setBypassed(_ bypassed: Bool, at index: Int) {
        guard index >= 0 && index < entries.count else { return }
        entries[index].isBypassed = bypassed
    }

    public func prepare(maxFrames: Int, channelCount: Int, sampleRate: Double) {
        precondition(maxFrames > 0 && channelCount > 0 && sampleRate > 0)
        self.maxFrames = maxFrames
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.scratchA = AudioBufferStorage(frameCapacity: maxFrames, channelCount: channelCount)
        self.scratchB = AudioBufferStorage(frameCapacity: maxFrames, channelCount: channelCount)
        for node in entries {
            node.prepare(sampleRate: sampleRate, channelCount: channelCount, maxFrames: maxFrames)
        }
    }

    public func reset() {
        for node in entries { node.reset() }
    }

    public func meterSnapshot() -> AudioMeterSnapshot {
        AudioMeterSnapshot(peakLinear: lastPeak, rmsLinear: lastRMS)
    }
    private var lastPeak: Double = 0
    private var lastRMS: Double = 0

    /// Runs the chain for `frameCount` frames, applies the master gain and
    /// updates the meters.
    public func render(source: AudioBufferView, destination: AudioBufferView, frameCount: Int) {
        let frames = min(frameCount, min(maxFrames, min(source.frameCapacity, destination.frameCapacity)))
        guard frames > 0 else { return }

        var active = 0
        for node in entries where !node.isBypassed { active += 1 }

        if active == 0 {
            destination.copy(from: source, frameCount: frames)
        } else if active == 1 {
            for node in entries where !node.isBypassed {
                node.process(input: source, output: destination, frameCount: frames, sampleRate: sampleRate)
                break
            }
        } else {
            guard let bufA = scratchA?.view, let bufB = scratchB?.view else {
                destination.copy(from: source, frameCount: frames)
                return
            }
            var currentInput = source
            var useA = true
            var processed = 0
            for node in entries {
                if node.isBypassed { continue }
                processed += 1
                let output: AudioBufferView
                if processed == active {
                    output = destination
                } else {
                    output = useA ? bufA : bufB
                    useA.toggle()
                }
                node.process(input: currentInput, output: output, frameCount: frames, sampleRate: sampleRate)
                currentInput = output
            }
        }

        let gain = masterGain
        let count = frames * destination.channelCount
        guard count > 0, let dst = destination.samples.baseAddress else { return }
        var peak = 0.0, sumSq = 0.0
        for i in 0..<count {
            let s = dst[i] * gain
            if gain != 1.0 { dst[i] = s }
            let a = abs(s)
            if a > peak { peak = a }
            sumSq += s * s
        }
        lastPeak = peak
        lastRMS = (sumSq / Double(count)).squareRoot()
    }
}

// MARK: - Pure-Swift Audio Math

public enum AudioMath {
    /// log10, from `Math.log` so no libm is involved.
    @inlinable public static func log10(_ x: Double) -> Double { Math.log(x) * 0.43429448190325182765 }

    @inlinable public static func pow10(_ x: Double) -> Double {
        // 10^x = e^(x ln 10); avoids a foundation `pow`.
        Math.exp(x * 2.30258509299404568402)
    }

    @inlinable public static func tan(_ x: Double) -> Double { Math.sin(x) / Math.cos(x) }

    @inlinable public static func dbToLinear(_ db: Double) -> Double { pow10(db * 0.05) }

    @inlinable public static func linearToDB(_ linear: Double, floor: Double = -200.0) -> Double {
        if linear <= 0.0 { return floor }
        return max(floor, 20.0 * log10(linear))
    }

    /// Normalized sinc: sin(pi x) / (pi x).
    @inlinable public static func sinc(_ x: Double) -> Double {
        if abs(x) < 1e-12 { return 1.0 }
        let px = Double.pi * x
        return Math.sin(px) / px
    }

    /// Modified Bessel function of the first kind, order 0.
    public static func besselI0(_ x: Double) -> Double {
        let y = 0.25 * x * x
        var sum = 1.0, term = 1.0, k = 1.0
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

// MARK: - TPDF Dither

/// Deterministic xoshiro256** TPDF dither with optional first-order noise
/// shaping. Real-time safe: no allocation, no locks.
public final class TPDFDither: AudioNode {
    public let name: String = "TPDFDither"
    public var isBypassed: Bool = false
    public var targetBitDepth: Int
    public var noiseShaping: Bool

    private var s0: UInt64 = 0, s1: UInt64 = 0, s2: UInt64 = 0, s3: UInt64 = 0
    private let initialSeed: UInt64
    private var prevError: [Double]

    public init(targetBitDepth: Int = 16, noiseShaping: Bool = false, channelCount: Int = 2,
                seed: UInt64 = 0x9E37_79B9_7F4A_7C15) {
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
        s0 = splitmix64(); s1 = splitmix64(); s2 = splitmix64(); s3 = splitmix64()
    }

    @inline(__always)
    private func nextUInt64() -> UInt64 {
        let x = s1 &* 5
        let rot = (x << 7) | (x >> 57)
        let result = rot &* 9
        let t = s1 << 17
        s2 ^= s0; s3 ^= s1; s1 ^= s2; s0 ^= s3; s2 ^= t
        s3 = (s3 << 45) | (s3 >> 19)
        return result
    }

    /// Uniform in `[0, 1)`.
    @inline(__always)
    public func nextUniform() -> Double {
        Double(nextUInt64() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// Triangular noise in `(-1, 1)`: zero mean, variance 1/6.
    @inline(__always)
    public func nextTriangular() -> Double { nextUniform() - nextUniform() }

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

    @inline(__always)
    public func quantizeToInt16(_ sample: Double, channel: Int = 0) -> Int16 {
        Int16(quantize(sample, channel: channel, levels: 32768.0, low: -32768.0, high: 32767.0))
    }

    @inline(__always)
    public func quantizeToInt24(_ sample: Double, channel: Int = 0) -> Int32 {
        Int32(quantize(sample, channel: channel, levels: 8_388_608.0, low: -8_388_608.0, high: 8_388_607.0))
    }

    /// Dithers and quantizes to `targetBitDepth`, returned normalized.
    @inline(__always)
    public func ditherSample(_ sample: Double, channel: Int = 0) -> Double {
        let levels = Double(Int64(1) << (targetBitDepth - 1))
        return quantize(sample, channel: channel, levels: levels, low: -levels, high: levels - 1.0) / levels
    }

    @inline(__always)
    private func quantize(_ sample: Double, channel: Int, levels: Double, low: Double, high: Double) -> Double {
        let scaled = sample * levels
        let shaped = noiseShaping && channel < prevError.count ? (scaled - 0.5 * prevError[channel]) : scaled
        let dithered = shaped + nextTriangular()
        let q = min(max(dithered.rounded(), low), high)
        if noiseShaping && channel < prevError.count { prevError[channel] = q - shaped }
        return q
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

// MARK: - Biquad and Parametric EQ (RBJ Audio EQ Cookbook)

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
    public var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double

    public static let identity = BiquadCoefficients(b0: 1.0, b1: 0.0, b2: 0.0, a1: 0.0, a2: 0.0)

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    /// RBJ cookbook coefficients, normalized by a0.
    public static func design(_ type: BiquadType, sampleRate: Double) -> BiquadCoefficients {
        guard sampleRate > 0 else { return .identity }
        let nyquist = sampleRate * 0.499
        let b0, b1, b2, a0, a1, a2: Double

        switch type {
        case .lowPass(let freq, let q):
            let w0 = 2.0 * Double.pi * min(max(freq, 1.0), nyquist) / sampleRate
            let cosW0 = Math.cos(w0)
            let alpha = Math.sin(w0) / (2.0 * max(q, 1e-4))
            b0 = (1.0 - cosW0) * 0.5; b1 = 1.0 - cosW0; b2 = b0
            a0 = 1.0 + alpha; a1 = -2.0 * cosW0; a2 = 1.0 - alpha

        case .highPass(let freq, let q):
            let w0 = 2.0 * Double.pi * min(max(freq, 1.0), nyquist) / sampleRate
            let cosW0 = Math.cos(w0)
            let alpha = Math.sin(w0) / (2.0 * max(q, 1e-4))
            b0 = (1.0 + cosW0) * 0.5; b1 = -(1.0 + cosW0); b2 = b0
            a0 = 1.0 + alpha; a1 = -2.0 * cosW0; a2 = 1.0 - alpha

        case .bandPass(let freq, let q):
            let w0 = 2.0 * Double.pi * min(max(freq, 1.0), nyquist) / sampleRate
            let cosW0 = Math.cos(w0)
            let alpha = Math.sin(w0) / (2.0 * max(q, 1e-4))
            b0 = alpha; b1 = 0.0; b2 = -alpha
            a0 = 1.0 + alpha; a1 = -2.0 * cosW0; a2 = 1.0 - alpha

        case .notch(let freq, let q):
            let w0 = 2.0 * Double.pi * min(max(freq, 1.0), nyquist) / sampleRate
            let cosW0 = Math.cos(w0)
            let alpha = Math.sin(w0) / (2.0 * max(q, 1e-4))
            b0 = 1.0; b1 = -2.0 * cosW0; b2 = 1.0
            a0 = 1.0 + alpha; a1 = -2.0 * cosW0; a2 = 1.0 - alpha

        case .peaking(let freq, let q, let gainDB):
            let w0 = 2.0 * Double.pi * min(max(freq, 1.0), nyquist) / sampleRate
            let A = AudioMath.pow10(gainDB / 40.0)
            let cosW0 = Math.cos(w0)
            let alpha = Math.sin(w0) / (2.0 * max(q, 1e-4))
            b0 = 1.0 + alpha * A; b1 = -2.0 * cosW0; b2 = 1.0 - alpha * A
            a0 = 1.0 + alpha / A; a1 = -2.0 * cosW0; a2 = 1.0 - alpha / A

        case .lowShelf(let freq, let slope, let gainDB):
            let w0 = 2.0 * Double.pi * min(max(freq, 1.0), nyquist) / sampleRate
            let A = AudioMath.pow10(gainDB / 40.0)
            let cosW0 = Math.cos(w0), sinW0 = Math.sin(w0)
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
            let w0 = 2.0 * Double.pi * min(max(freq, 1.0), nyquist) / sampleRate
            let A = AudioMath.pow10(gainDB / 40.0)
            let cosW0 = Math.cos(w0), sinW0 = Math.sin(w0)
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

        let inv = 1.0 / a0
        return BiquadCoefficients(b0: b0 * inv, b1: b1 * inv, b2: b2 * inv, a1: a1 * inv, a2: a2 * inv)
    }

    /// `|H(e^{jw})|` at `frequency` Hz.
    public func magnitudeResponse(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2.0 * Double.pi * frequency / sampleRate
        let cos1 = Math.cos(w), sin1 = Math.sin(w)
        let cos2 = Math.cos(2.0 * w), sin2 = Math.sin(2.0 * w)
        let numRe = b0 + b1 * cos1 + b2 * cos2
        let numIm = -(b1 * sin1 + b2 * sin2)
        let denRe = 1.0 + a1 * cos1 + a2 * cos2
        let denIm = -(a1 * sin1 + a2 * sin2)
        let denSq = denRe * denRe + denIm * denIm
        guard denSq > 0 else { return 0 }
        return ((numRe * numRe + numIm * numIm) / denSq).squareRoot()
    }
}

/// Transposed direct form II state for one channel.
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

/// One biquad stage, 64-bit float, one state per channel.
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
        filterType = type
        coefficients = BiquadCoefficients.design(type, sampleRate: sampleRate)
    }

    public func setCoefficients(_ coefficients: BiquadCoefficients) {
        filterType = nil
        self.coefficients = coefficients
    }

    public func prepare(sampleRate: Double, channelCount: Int, maxFrames: Int) {
        if states.count < channelCount {
            states = [BiquadState](repeating: BiquadState(), count: channelCount)
        }
        if let filterType { coefficients = BiquadCoefficients.design(filterType, sampleRate: sampleRate) }
    }

    public func reset() {
        for i in 0..<states.count { states[i] = BiquadState() }
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

/// A cascade of biquad bands.
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
            self.bands.append(BiquadFilter(name: "Band \(i)", type: b, sampleRate: sampleRate, channelCount: currentChannels))
        }
    }

    public func addBand(_ type: BiquadType) {
        bands.append(BiquadFilter(name: "Band \(bands.count)", type: type, sampleRate: currentSampleRate, channelCount: currentChannels))
    }

    public func setBand(_ index: Int, type: BiquadType) {
        guard index >= 0 && index < bands.count else { return }
        bands[index].configure(type, sampleRate: currentSampleRate)
    }

    public func removeAllBands() { bands.removeAll() }

    public func prepare(sampleRate: Double, channelCount: Int, maxFrames: Int) {
        currentSampleRate = sampleRate
        currentChannels = max(1, channelCount)
        for band in bands { band.prepare(sampleRate: sampleRate, channelCount: currentChannels, maxFrames: maxFrames) }
    }

    public func reset() {
        for band in bands { band.reset() }
    }

    public func process(input: AudioBufferView, output: AudioBufferView, frameCount: Int, sampleRate: Double) {
        output.copy(from: input, frameCount: frameCount)
        for band in bands where !band.isBypassed {
            band.process(input: output, output: output, frameCount: frameCount, sampleRate: sampleRate)
        }
    }
}

// MARK: - EBU R128 Loudness and ReplayGain

/// ITU-R BS.1770-4 / EBU R128 loudness: K-weighting, 400 ms momentary blocks
/// with a 100 ms hop, an absolute -70 LUFS gate and a relative -10 LU gate.
public final class LoudnessMeter {
    public let sampleRate: Double
    public let channelCount: Int

    private let stage1Coeffs: BiquadCoefficients
    private let stage2Coeffs: BiquadCoefficients
    private var stage1States: [BiquadState]
    private var stage2States: [BiquadState]

    private let subBlockFrames: Int
    private var currentSubBlockCount = 0
    private var currentSubBlockEnergy = 0.0
    private var recentSubBlocks: [Double] = [0.0, 0.0, 0.0, 0.0]
    private var recentSubBlockCount = 0
    private var recentSubBlockPos = 0

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

    /// Pre-filter: +4 dB high shelf around 1681.97 Hz.
    public static func kWeightStage1(sampleRate: Double) -> BiquadCoefficients {
        let f0 = 1681.974450955533
        let g = 3.999843853973347
        let q = 0.7071752369554196
        let k = AudioMath.tan(Double.pi * f0 / sampleRate)
        let vh = AudioMath.pow10(g / 20.0)
        let vb = AudioMath.pow10(0.4996667741545416 * (g / 20.0))
        let a0 = 1.0 + k / q + k * k
        let inv = 1.0 / a0
        return BiquadCoefficients(
            b0: (vh + vb * k / q + k * k) * inv,
            b1: 2.0 * (k * k - vh) * inv,
            b2: (vh - vb * k / q + k * k) * inv,
            a1: 2.0 * (k * k - 1.0) * inv,
            a2: (1.0 - k / q + k * k) * inv
        )
    }

    /// RLB high-pass around 38.14 Hz.
    public static func kWeightStage2(sampleRate: Double) -> BiquadCoefficients {
        let f0 = 38.13547087602444
        let q = 0.5003270373238773
        let k = AudioMath.tan(Double.pi * f0 / sampleRate)
        let a0 = 1.0 + k / q + k * k
        let inv = 1.0 / a0
        return BiquadCoefficients(
            b0: 1.0, b1: -2.0, b2: 1.0,
            a1: 2.0 * (k * k - 1.0) * inv,
            a2: (1.0 - k / q + k * k) * inv
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

    /// Feeds interleaved samples.
    public func process(_ samples: [Double]) {
        let frames = samples.count / channelCount
        guard frames > 0 else { return }
        for f in 0..<frames {
            let base = f * channelCount
            var frameSumSq = 0.0
            for c in 0..<channelCount {
                // 5.1: LFE (c == 3) is not measured; surrounds get +1.5 dB.
                if channelCount >= 6 && c == 3 { continue }
                let weight: Double = (channelCount >= 5 && (c == 3 || c == 4)) ? 1.41 : 1.0
                let y1 = stage1States[c].process(samples[base + c], stage1Coeffs)
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
                    let mean = 0.25 * (recentSubBlocks[0] + recentSubBlocks[1] + recentSubBlocks[2] + recentSubBlocks[3])
                    blockMeanSquares.append(mean)
                    momentaryLUFS = Self.energyToLUFS(mean)
                }
            }
        }
    }

    public var integratedLUFS: Double {
        guard !blockMeanSquares.isEmpty else { return -200.0 }
        let absThreshold = AudioMath.pow10((-70.0 + 0.691) * 0.1)
        var absSum = 0.0, absCount = 0
        for e in blockMeanSquares where e > absThreshold {
            absSum += e; absCount += 1
        }
        guard absCount > 0 else { return -200.0 }
        let ungated = Self.energyToLUFS(absSum / Double(absCount))
        let relThreshold = AudioMath.pow10((ungated - 10.0 + 0.691) * 0.1)
        var relSum = 0.0, relCount = 0
        for e in blockMeanSquares where e > absThreshold && e > relThreshold {
            relSum += e; relCount += 1
        }
        guard relCount > 0 else { return -200.0 }
        return Self.energyToLUFS(relSum / Double(relCount))
    }

    /// Gain in dB that brings the programme to `targetLUFS`.
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

/// Lookahead limiter that measures inter-sample peaks with a 4x polyphase
/// FIR, so the output never exceeds the ceiling even between samples.
public final class TruePeakLimiter: AudioNode {
    public let name: String = "TruePeakLimiter"
    public var isBypassed: Bool = false

    public var ceilingDB: Double {
        didSet { ceilingLinear = AudioMath.dbToLinear(ceilingDB) }
    }
    public private(set) var ceilingLinear: Double
    public var lookaheadMs: Double
    public var releaseMs: Double

    static let osPhases = 4
    static let osTaps = 12
    private let osCoeffs: [Double]

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

    public init(ceilingDB: Double = -1.0, lookaheadMs: Double = 5.0, releaseMs: Double = 50.0,
                sampleRate: Double = 48_000.0, channelCount: Int = 2) {
        self.ceilingDB = ceilingDB
        self.ceilingLinear = AudioMath.dbToLinear(ceilingDB)
        self.lookaheadMs = max(0.5, lookaheadMs)
        self.releaseMs = max(5.0, releaseMs)
        self.osCoeffs = Self.buildOversampleTable()
        prepare(sampleRate: sampleRate, channelCount: channelCount, maxFrames: 0)
    }

    static func buildOversampleTable() -> [Double] {
        let phases = osPhases, taps = osTaps, beta = 7.0
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
        let requested = max(1, Int((sampleRate * lookaheadMs * 0.001).rounded()))
        lookaheadFrames = max(requested, Self.osTaps)
        osHistory = [Double](repeating: 0.0, count: Self.osTaps * self.channelCount)
        delayBuffer = [Double](repeating: 0.0, count: lookaheadFrames * self.channelCount)
        peakWindow = [Double](repeating: 0.0, count: lookaheadFrames)
        releaseCoeff = Math.exp(-1.0 / max(1.0, sampleRate * releaseMs * 0.001))
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

    /// 4x oversampled true peak (linear) of interleaved samples.
    public static func measureTruePeak(_ samples: [Double], channels: Int) -> Double {
        guard channels > 0, !samples.isEmpty else { return 0.0 }
        let frames = samples.count / channels
        let coeffs = buildOversampleTable()
        var hist = [Double](repeating: 0.0, count: osTaps * channels)
        var pos = 0
        var maxPeak = 0.0
        for f in 0..<frames {
            let base = f * channels
            let dst = pos * channels
            for c in 0..<channels {
                let s = samples[base + c]
                hist[dst + c] = s
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
        let taps = Self.osTaps, phases = Self.osPhases
        let ceiling = ceilingLinear
        let look = lookaheadFrames

        for f in 0..<frameCount {
            let inBase = f * input.channelCount
            let dst = osHistoryPos * channelCount
            var framePeak = 0.0

            for c in 0..<ch {
                let x = input.samples[inBase + c]
                osHistory[dst + c] = x
                let a = abs(x)
                if a > framePeak { framePeak = a }
            }
            osHistoryPos += 1
            if osHistoryPos == taps { osHistoryPos = 0 }

            for p in 0..<phases {
                let row = p * taps
                for c in 0..<ch {
                    var acc = 0.0
                    var hp = osHistoryPos
                    for k in 0..<taps {
                        acc += osHistory[hp * channelCount + c] * osCoeffs[row + k]
                        hp += 1
                        if hp == taps { hp = 0 }
                    }
                    let a = abs(acc)
                    if a > framePeak { framePeak = a }
                }
            }

            peakWindow[peakWindowPos] = framePeak
            peakWindowPos += 1
            if peakWindowPos == look { peakWindowPos = 0 }

            // Include the frame about to be output: it sits at peakWindowPos
            // after the ring advanced, i.e. the oldest slot.
            var windowMax = 0.0
            for i in 0..<look where peakWindow[i] > windowMax { windowMax = peakWindow[i] }

            let target = windowMax > ceiling ? (ceiling / windowMax) : 1.0
            if target < smoothedGain {
                smoothedGain = target
            } else {
                smoothedGain = target + (smoothedGain - target) * releaseCoeff
                if smoothedGain > target { smoothedGain = target }
            }

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
    /// Gains for a normalized position `t` in `[0, 1]`.
    @inlinable
    public static func gains(position t: Double, curve: CrossfadeCurve = .equalPower) -> (gainA: Double, gainB: Double) {
        let x = min(max(t, 0.0), 1.0)
        switch curve {
        case .linear: return (1.0 - x, x)
        case .equalPower:
            let angle = x * Double.pi * 0.5
            return (Math.cos(angle), Math.sin(angle))
        }
    }

    /// Mixes `a` and `b` into `output` over `frameCount` frames.
    public static func mix(a: AudioBufferView, b: AudioBufferView, output: AudioBufferView,
                           frameCount: Int, startPosition: Double, endPosition: Double,
                           curve: CrossfadeCurve = .equalPower) {
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

// MARK: - Headphone Crossfeed (BS2B-style complementary topology)

/// Low-frequency crossfeed for headphones: a complementary low-pass path
/// `H_C = k H_LP` plus a direct path `H_D = 1 - k H_LP`, so mono is preserved
/// exactly (`H_D + H_C == 1`) while each ear hears some of the other channel.
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
        alpha = 1.0 - Math.exp(-2.0 * Double.pi * fc / sampleRate)
        let ratio = AudioMath.dbToLinear(-abs(preset.feedDB))
        crossGain = ratio / (1.0 + ratio)
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
        let a = alpha, oneMinusA = 1.0 - a, k = crossGain
        var sL = lpL, sR = lpR
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
