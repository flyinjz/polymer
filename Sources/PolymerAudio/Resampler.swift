// Sample-rate conversion by windowed sinc (Kaiser window, beta 9), polyphase.
// The position is an exact fraction, so a stream of N input frames gives
// exactly ceil(N * out / in) output frames and timing never drifts. Common
// ratios (44.1 <-> 48 kHz and their multiples) have few enough phases to
// keep one filter per phase; others interpolate between 512 phases.
// The cutoff is 0.95 of the lower Nyquist frequency; when downsampling the
// filter widens so the stopband stays as deep. Gain at DC is exactly 1.
import PolymerBase
import PolymerPlatform

public final class Resampler: @unchecked Sendable {
    public let inputRate: Int
    public let outputRate: Int
    public let channels: Int
    /// Input frames per output frame as num / den, reduced.
    let num: Int, den: Int
    /// Taps on each side of the centre.
    let half: Int
    let taps: Int
    let phases: Int
    let exact: Bool
    let table: UnsafeMutablePointer<Float>
    let buf: UnsafeMutablePointer<Float>
    let capacityFrames: Int
    var count = 0, ipos = 0, frac = 0
    var totalIn = 0, totalOut = 0
    var zerosFed = 0

    /// Equal rates: `process` copies.
    public var isPassthrough: Bool { num == den }

    public init(from inputRate: Int, to outputRate: Int, channels: Int, zeroCrossings: Int = 32) {
        self.inputRate = inputRate; self.outputRate = outputRate; self.channels = channels
        var a = inputRate, b = outputRate
        while b != 0 { (a, b) = (b, a % b) }
        num = inputRate / a; den = outputRate / a
        let ratio = Double(outputRate) / Double(inputRate)
        let scale = min(1, ratio)
        let cutoff = 0.95 * scale
        half = num == den ? 1 : Int((Double(zeroCrossings) / scale).rounded(.up))
        taps = 2 * half
        exact = den <= 1024
        phases = exact ? den : 512
        table = .allocate(capacity: (phases + 1) * taps)
        capacityFrames = taps + 4096
        buf = .allocate(capacity: capacityFrames * channels)
        buf.initialize(repeating: 0, count: capacityFrames * channels)

        func besselI0(_ x: Double) -> Double {
            var sum = 1.0, term = 1.0, k = 1.0
            while term > 1e-12 * sum { term *= (x / (2 * k)) * (x / (2 * k)); sum += term; k += 1 }
            return sum
        }
        let beta = 9.0
        let i0beta = besselI0(beta)
        for p in 0...phases {
            let d = Double(p) / Double(phases)
            var row = [Double](repeating: 0, count: taps)
            var sum = 0.0
            for j in 0..<taps {
                let x = Double(j - half + 1) - d
                let r = x / Double(half)
                var h = 0.0
                if abs(r) < 1 {
                    let u = cutoff * x
                    let sinc = abs(u) < 1e-12 ? 1 : Math.sin(Double.pi * u) / (Double.pi * u)
                    h = cutoff * sinc * besselI0(beta * (1 - r * r).squareRoot()) / i0beta
                }
                row[j] = h
                sum += h
            }
            for j in 0..<taps { table[p * taps + j] = Float(sum != 0 ? row[j] / sum : 0) }
        }
        reset()
    }

    deinit { table.deallocate(); buf.deallocate() }

    /// Back to the start of a stream (after a seek).
    public func reset() {
        buf.update(repeating: 0, count: capacityFrames * channels)
        count = half; ipos = half; frac = 0
        totalIn = 0; totalOut = 0; zerosFed = 0
    }

    /// Output frames that `inputFrames` of input make in all.
    public func outputLength(forInput inputFrames: Int) -> Int { (inputFrames * den + num - 1) / num }

    /// Converts what it can: takes input frames until the output is full or the
    /// input used up. Returns the input frames consumed and output frames written.
    public func process(_ input: UnsafePointer<Float>, frames: Int, into output: UnsafeMutablePointer<Float>, capacity: Int) -> (consumed: Int, produced: Int) {
        if isPassthrough {
            let n = min(frames, capacity)
            output.update(from: input, count: n * channels)
            totalIn += n; totalOut += n
            return (n, n)
        }
        var consumed = 0, produced = 0
        while produced < capacity {
            if ipos + half < count {
                produce(output + produced * channels)
                produced += 1
                continue
            }
            if consumed == frames { break }
            compact()
            let n = min(frames - consumed, capacityFrames - count)
            (buf + count * channels).update(from: input + consumed * channels, count: n * channels)
            count += n; consumed += n; totalIn += n
        }
        totalOut += produced
        return (consumed, produced)
    }

    /// After the last input: writes the rest of the output (the filter's tail),
    /// up to `capacity` frames. Call until it returns 0.
    public func finish(into output: UnsafeMutablePointer<Float>, capacity: Int) -> Int {
        let target = outputLength(forInput: totalIn)
        if isPassthrough { return 0 }
        var produced = 0
        while produced < capacity && totalOut + produced < target {
            if ipos + half < count {
                produce(output + produced * channels)
                produced += 1
                continue
            }
            compact()
            let n = capacityFrames - count
            (buf + count * channels).update(repeating: 0, count: n * channels)
            count += n; zerosFed += n
        }
        totalOut += produced
        return produced
    }

    private func compact() {
        let keep = min(count, max(0, ipos - half + 1))
        if keep == 0 { return }
        let remain = count - keep
        if remain > 0 { buf.update(from: buf + keep * channels, count: remain * channels) }
        count = remain
        ipos -= keep
    }

    @inline(__always) private func produce(_ out: UnsafeMutablePointer<Float>) {
        let base = buf + (ipos - half + 1) * channels
        if exact {
            let row = table + frac * taps
            for c in 0..<channels {
                var s: Float = 0
                var p = base + c
                for j in 0..<taps { s += row[j] * p.pointee; p += channels }
                out[c] = s
            }
        } else {
            let pf = Double(frac) * Double(phases) / Double(den)
            let p0 = Int(pf)
            let t = Float(pf - Double(p0))
            let r0 = table + p0 * taps, r1 = r0 + taps
            for c in 0..<channels {
                var s0: Float = 0, s1: Float = 0
                var p = base + c
                for j in 0..<taps { let x = p.pointee; s0 += r0[j] * x; s1 += r1[j] * x; p += channels }
                out[c] = s0 + (s1 - s0) * t
            }
        }
        frac += num
        if frac >= den { ipos += frac / den; frac %= den }
    }
}
