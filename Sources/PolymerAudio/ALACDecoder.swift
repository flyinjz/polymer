// Pure-Swift Apple Lossless (ALAC) decoder, encoder, and ISO BMFF / M4A container parser.
// Standard library only — no Foundation, no OS codecs, bounds-checked throughout.
import PolymerBase

/// Parsed 24-byte ALAC specific configuration (magic cookie).
public struct ALACConfig: Equatable, Hashable, Sendable {
    public var frameLength: UInt32
    public var compatibleVersion: UInt8
    public var bitDepth: UInt8
    public var pb: UInt8
    public var mb: UInt8
    public var kb: UInt8
    public var numChannels: UInt8
    public var maxRun: UInt16
    public var maxFrameBytes: UInt32
    public var avgBitRate: UInt32
    public var sampleRate: UInt32

    public init(
        frameLength: UInt32 = 4096,
        compatibleVersion: UInt8 = 0,
        bitDepth: UInt8 = 16,
        pb: UInt8 = 40,
        mb: UInt8 = 10,
        kb: UInt8 = 14,
        numChannels: UInt8 = 2,
        maxRun: UInt16 = 255,
        maxFrameBytes: UInt32 = 0,
        avgBitRate: UInt32 = 0,
        sampleRate: UInt32 = 44_100
    ) {
        self.frameLength = frameLength
        self.compatibleVersion = compatibleVersion
        self.bitDepth = bitDepth
        self.pb = pb
        self.mb = mb
        self.kb = kb
        self.numChannels = numChannels
        self.maxRun = maxRun
        self.maxFrameBytes = maxFrameBytes
        self.avgBitRate = avgBitRate
        self.sampleRate = sampleRate
    }

    /// Parses an ALAC magic cookie (raw 24-byte config, 28-byte versioned cookie, or 36-byte `alac` FullBox).
    public init(magicCookie bytes: [UInt8], offset: Int = 0) throws(AudioDecoderError) {
        guard offset >= 0, offset <= bytes.count else {
            throw AudioDecoderError.truncatedData("ALAC magic cookie offset out of range")
        }
        var pos = offset
        let rem = bytes.count - pos
        if rem >= 36, bytes.alacFourCC(at: pos + 4) == "alac" {
            // 12-byte FullBox header (size + 'alac' + version/flags) + 24-byte config.
            pos += 12
        } else if rem == 28 {
            // 4-byte version/flags + 24-byte config.
            pos += 4
        }
        guard pos + 24 <= bytes.count else {
            throw AudioDecoderError.truncatedData("ALAC magic cookie shorter than 24 bytes")
        }

        let frameLength = bytes.u32(at: pos)
        let compatibleVersion = bytes[pos + 4]
        let bitDepth = bytes[pos + 5]
        let pb = bytes[pos + 6]
        let mb = bytes[pos + 7]
        let kb = bytes[pos + 8]
        let numChannels = bytes[pos + 9]
        let maxRun = bytes.u16(at: pos + 10)
        let maxFrameBytes = bytes.u32(at: pos + 12)
        let avgBitRate = bytes.u32(at: pos + 16)
        let sampleRate = bytes.u32(at: pos + 20)

        guard compatibleVersion == 0 else {
            throw AudioDecoderError.unsupportedFormat("unsupported ALAC compatibleVersion \(compatibleVersion)")
        }
        guard frameLength > 0, sampleRate > 0 else {
            throw AudioDecoderError.invalidHeader("invalid ALAC frameLength or sampleRate")
        }
        guard bitDepth == 16 || bitDepth == 20 || bitDepth == 24 || bitDepth == 32 else {
            throw AudioDecoderError.unsupportedFormat("unsupported ALAC bitDepth \(bitDepth)")
        }
        guard numChannels >= 1 && numChannels <= 8 else {
            throw AudioDecoderError.unsupportedFormat("unsupported ALAC channel count \(numChannels)")
        }

        self.frameLength = frameLength
        self.compatibleVersion = compatibleVersion
        self.bitDepth = bitDepth
        self.pb = pb
        self.mb = mb
        self.kb = kb
        self.numChannels = numChannels
        self.maxRun = maxRun
        self.maxFrameBytes = maxFrameBytes
        self.avgBitRate = avgBitRate
        self.sampleRate = sampleRate
    }

    /// Serializes this configuration to the canonical 24-byte big-endian ALAC magic cookie.
    public func toBytes() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(24)
        out.append(u32: frameLength)
        out.append(compatibleVersion)
        out.append(bitDepth)
        out.append(pb)
        out.append(mb)
        out.append(kb)
        out.append(numChannels)
        out.append(u16: maxRun)
        out.append(u32: maxFrameBytes)
        out.append(u32: avgBitRate)
        out.append(u32: sampleRate)
        return out
    }
}

// MARK: - Private Binary & Bitstream Helpers

private extension Array where Element == UInt8 {
    @inline(__always) func alacFourCC(at i: Int) -> String {
        guard i >= 0, i + 4 <= count else { return "" }
        return String(decoding: self[i..<(i + 4)], as: UTF8.self)
    }

    @inline(__always) func u64be(at i: Int) -> UInt64 {
        guard i >= 0, i + 8 <= count else { return 0 }
        let hi = UInt64(u32(at: i))
        let lo = UInt64(u32(at: i + 4))
        return (hi << 32) | lo
    }

    @inline(__always) mutating func appendASCII(_ s: String) {
        append(contentsOf: s.utf8)
    }
}

@inline(__always)
private func signExtend32(_ value: Int32, bits: Int) -> Int32 {
    if bits >= 32 { return value }
    let shift = 32 - bits
    return (value << shift) >> shift
}

@inline(__always)
private func alacDoubleToInt16(_ s: Double) -> Int32 {
    let clamped = min(max(s, -1.0), 1.0)
    let scaled = (clamped * 32768.0).rounded()
    return Int32(min(max(scaled, -32768.0), 32767.0))
}

@inline(__always)
private func alacDoubleToInt24(_ s: Double) -> Int32 {
    let clamped = min(max(s, -1.0), 1.0)
    let scaled = (clamped * 8_388_608.0).rounded()
    return Int32(min(max(scaled, -8_388_608.0), 8_388_607.0))
}

@inline(__always)
private func lg3a(_ x: Int) -> Int {
    guard x > 0 else { return 0 }
    return 31 - UInt32(x).leadingZeroBitCount
}

private struct ALACBitReader {
    let data: [UInt8]
    let startBit: Int
    let endBit: Int
    var bitPos: Int

    init(_ data: [UInt8], byteOffset: Int = 0, byteLength: Int? = nil) {
        self.data = data
        let start = max(0, min(byteOffset, data.count))
        let len = min(byteLength ?? (data.count - start), data.count - start)
        self.startBit = start * 8
        self.endBit = (start + max(0, len)) * 8
        self.bitPos = self.startBit
    }

    var remainingBits: Int { endBit - bitPos }

    @inline(__always)
    mutating func readBit() throws(AudioDecoderError) -> UInt32 {
        guard bitPos < endBit else {
            throw AudioDecoderError.truncatedData("unexpected end of ALAC bitstream")
        }
        let byte = data[bitPos >> 3]
        let shift = 7 - (bitPos & 7)
        bitPos += 1
        return UInt32((byte >> shift) & 1)
    }

    mutating func readBits(_ count: Int) throws(AudioDecoderError) -> UInt32 {
        guard count >= 0, count <= 32 else {
            throw AudioDecoderError.invalidBitstream("invalid ALAC bit read count \(count)")
        }
        guard count > 0 else { return 0 }
        guard bitPos + count <= endBit else {
            throw AudioDecoderError.truncatedData("unexpected end of ALAC bitstream")
        }
        var value: UInt32 = 0
        var rem = count
        while rem > 0 {
            let byteIdx = bitPos >> 3
            let bitInByte = bitPos & 7
            let avail = 8 - bitInByte
            let take = min(rem, avail)
            let shift = avail - take
            let mask: UInt8 = take == 8 ? 0xFF : UInt8((1 << take) - 1)
            let chunk = (data[byteIdx] >> shift) & mask
            value = (value << UInt32(take)) | UInt32(chunk)
            bitPos += take
            rem -= take
        }
        return value
    }

    mutating func readSigned(_ bits: Int) throws(AudioDecoderError) -> Int32 {
        let raw = try readBits(bits)
        return signExtend32(Int32(bitPattern: raw), bits: bits)
    }

    /// Reads up to `maxOnes` consecutive `1` bits. If fewer than `maxOnes` ones are seen,
    /// the terminating `0` bit is consumed; if `maxOnes` ones are seen, no extra bit is consumed.
    mutating func readUnaryOnes(maxOnes: Int) throws(AudioDecoderError) -> Int {
        var count = 0
        while count < maxOnes {
            let bit = try readBit()
            if bit == 0 {
                return count
            }
            count += 1
        }
        return count
    }
}

private struct ALACBitWriter {
    var bytes: [UInt8] = []
    private var curByte: UInt8 = 0
    private var bitsFilled: Int = 0

    mutating func writeBits(_ value: UInt32, count: Int) {
        guard count > 0 else { return }
        var rem = count
        while rem > 0 {
            let space = 8 - bitsFilled
            let take = min(rem, space)
            let shift = rem - take
            let mask: UInt32 = take == 32 ? UInt32.max : ((UInt32(1) << UInt32(take)) - 1)
            let chunk = UInt8((value >> UInt32(shift)) & mask)
            curByte = (curByte << UInt8(take)) | chunk
            bitsFilled += take
            rem -= take
            if bitsFilled == 8 {
                bytes.append(curByte)
                curByte = 0
                bitsFilled = 0
            }
        }
    }

    mutating func writeSigned(_ value: Int32, bits: Int) {
        let mask: UInt32 = bits >= 32 ? UInt32.max : ((UInt32(1) << UInt32(bits)) - 1)
        writeBits(UInt32(bitPattern: value) & mask, count: bits)
    }

    mutating func alignToByte() {
        if bitsFilled > 0 {
            curByte <<= UInt8(8 - bitsFilled)
            bytes.append(curByte)
            curByte = 0
            bitsFilled = 0
        }
    }
}

// MARK: - Adaptive Golomb-Rice & Dynamic LPC Predictor (Shared Algorithm)

private enum ALACConstants {
    static let qbShift = 9
    static let qb = 1 << qbShift           // 512
    static let mmulShift = 2
    static let mdenShift = 9
    static let mOff = 1 << (mdenShift - 2) // 128
    static let bitOff = 24
    static let maxPrefix = 9
    static let maxMeanClamp: UInt32 = 0xFFFF
    static let meanClampVal = 0xFFFF

    static let idSCE: UInt32 = 0
    static let idCPE: UInt32 = 1
    static let idFIL: UInt32 = 5
    static let idDSE: UInt32 = 6
    static let idEND: UInt32 = 7
}

private enum ALACEntropy {
    @inline(__always)
    static func dynGet(
        _ reader: inout ALACBitReader,
        m: Int,
        k: Int,
        maxBits: Int
    ) throws(AudioDecoderError) -> UInt32 {
        let prefix = try reader.readUnaryOnes(maxOnes: ALACConstants.maxPrefix)
        if prefix == ALACConstants.maxPrefix {
            return try reader.readBits(maxBits)
        }
        if k <= 1 {
            return UInt32(prefix)
        }
        var result = UInt32(prefix) &* UInt32(m)
        let top = try reader.readBits(k - 1)
        if top > 0 {
            let lsb = try reader.readBit()
            result &+= ((top << 1) | lsb) &- 1
        }
        return result
    }

    @inline(__always)
    static func dynPut(
        _ writer: inout ALACBitWriter,
        value: UInt32,
        m: Int,
        k: Int,
        maxBits: Int
    ) {
        if k <= 1 {
            if value < UInt32(ALACConstants.maxPrefix) {
                let q = Int(value)
                if q > 0 { writer.writeBits((1 << UInt32(q)) - 1, count: q) }
                writer.writeBits(0, count: 1)
            } else {
                writer.writeBits((1 << UInt32(ALACConstants.maxPrefix)) - 1, count: ALACConstants.maxPrefix)
                writer.writeBits(value, count: maxBits)
            }
            return
        }
        let um = UInt32(m)
        let q = Int(value / um)
        let r = value % um
        if q < ALACConstants.maxPrefix {
            if q > 0 { writer.writeBits((1 << UInt32(q)) - 1, count: q) }
            writer.writeBits(0, count: 1)
            if r == 0 {
                writer.writeBits(0, count: k - 1)
            } else {
                writer.writeBits(r + 1, count: k)
            }
        } else {
            writer.writeBits((1 << UInt32(ALACConstants.maxPrefix)) - 1, count: ALACConstants.maxPrefix)
            writer.writeBits(value, count: maxBits)
        }
    }

    static func decodeResiduals(
        _ reader: inout ALACBitReader,
        count: Int,
        chanBits: Int,
        pb: Int,
        mbInit: Int,
        kb: Int
    ) throws(AudioDecoderError) -> [Int32] {
        var out = [Int32](repeating: 0, count: count)
        var mb = mbInit
        var zmode = 0
        var c = 0
        let wb = (1 << kb) - 1

        while c < count {
            let mShift = mb >> ALACConstants.qbShift
            var k = lg3a(mShift + 3)
            if k > kb { k = kb }
            if k < 1 { k = 1 }
            let m = (1 << k) - 1

            var n = try dynGet(&reader, m: m, k: k, maxBits: chanBits)
            n &+= UInt32(zmode)
            zmode = 0

            let mag = Int32(bitPattern: (n &+ 1) >> 1)
            let signedVal: Int32 = (n & 1) != 0 ? -mag : mag
            out[c] = signExtend32(signedVal, bits: chanBits)
            c += 1

            if n > ALACConstants.maxMeanClamp {
                mb = ALACConstants.meanClampVal
            } else {
                let updated = Int64(pb) * Int64(n) + Int64(mb) - ((Int64(pb) * Int64(mb)) >> ALACConstants.qbShift)
                mb = max(0, Int(updated))
            }

            if (mb << ALACConstants.mmulShift) < ALACConstants.qb && c < count {
                zmode = 1
                var kz = UInt32(mb).leadingZeroBitCount - ALACConstants.bitOff + ((mb + ALACConstants.mOff) >> ALACConstants.mdenShift)
                if kz > kb { kz = kb }
                if kz < 1 { kz = 1 }
                let mz = ((1 << kz) - 1) & wb
                let run = Int(try dynGet(&reader, m: mz, k: kz, maxBits: 16))
                guard c + run <= count else {
                    throw AudioDecoderError.invalidBitstream("ALAC zero-run length \(run) exceeds remaining samples")
                }
                c += run
                if run >= 65535 {
                    zmode = 0
                }
                mb = 0
            }
        }
        return out
    }

    static func encodeResiduals(
        _ writer: inout ALACBitWriter,
        residuals: [Int32],
        chanBits: Int,
        pb: Int,
        mbInit: Int,
        kb: Int
    ) {
        let count = residuals.count
        var mb = mbInit
        var zmode = 0
        var c = 0
        let wb = (1 << kb) - 1

        while c < count {
            let mShift = mb >> ALACConstants.qbShift
            var k = lg3a(mShift + 3)
            if k > kb { k = kb }
            if k < 1 { k = 1 }
            let m = (1 << k) - 1

            let del = Int64(signExtend32(residuals[c], bits: chanBits))
            let n: UInt32
            if del >= 0 {
                n = UInt32(del << 1)
            } else {
                n = UInt32(((-del) << 1) - 1)
            }

            let coded = n &- UInt32(zmode)
            dynPut(&writer, value: coded, m: m, k: k, maxBits: chanBits)
            zmode = 0
            c += 1

            if n > ALACConstants.maxMeanClamp {
                mb = ALACConstants.meanClampVal
            } else {
                let updated = Int64(pb) * Int64(n) + Int64(mb) - ((Int64(pb) * Int64(mb)) >> ALACConstants.qbShift)
                mb = max(0, Int(updated))
            }

            if (mb << ALACConstants.mmulShift) < ALACConstants.qb && c < count {
                var run = 0
                let maxRun = min(count - c, 65535)
                while run < maxRun && residuals[c + run] == 0 {
                    run += 1
                }
                var kz = UInt32(mb).leadingZeroBitCount - ALACConstants.bitOff + ((mb + ALACConstants.mOff) >> ALACConstants.mdenShift)
                if kz > kb { kz = kb }
                if kz < 1 { kz = 1 }
                let mz = ((1 << kz) - 1) & wb
                dynPut(&writer, value: UInt32(run), m: mz, k: kz, maxBits: 16)
                c += run
                zmode = run < 65535 ? 1 : 0
                mb = 0
            }
        }
    }
}

private enum ALACPredictor {
    static func reconstruct(
        residuals: [Int32],
        coefs initialCoefs: [Int16],
        numActive: Int,
        chanBits: Int,
        denShift: Int
    ) -> [Int32] {
        let num = residuals.count
        guard num > 0 else { return [] }
        var out = [Int32](repeating: 0, count: num)

        if numActive == 0 {
            for i in 0..<num {
                out[i] = signExtend32(residuals[i], bits: chanBits)
            }
            return out
        }

        if numActive == 31 {
            out[0] = signExtend32(residuals[0], bits: chanBits)
            for i in 1..<num {
                out[i] = signExtend32(out[i - 1] &+ residuals[i], bits: chanBits)
            }
            return out
        }

        var coefs = initialCoefs
        let lim = min(numActive + 1, num)
        out[0] = signExtend32(residuals[0], bits: chanBits)
        for j in 1..<lim {
            out[j] = signExtend32(out[j - 1] &+ residuals[j], bits: chanBits)
        }
        guard lim < num else { return out }

        let roundBias: Int64 = denShift > 0 ? Int64(1 << (denShift - 1)) : 0
        for j in lim..<num {
            let top = out[j - lim]
            var sum1: Int64 = roundBias
            for k in 0..<numActive {
                let diff = out[j - 1 - k] &- top
                sum1 &+= Int64(coefs[k]) &* Int64(diff)
            }
            let pred = Int32(truncatingIfNeeded: sum1 >> denShift)
            let del = residuals[j]
            out[j] = signExtend32(top &+ pred &+ del, bits: chanBits)

            if del > 0 {
                var rem = del
                var k = numActive - 1
                while k >= 0 && rem > 0 {
                    let dd = top &- out[j - 1 - k]
                    let sgn: Int32 = dd > 0 ? 1 : (dd < 0 ? -1 : 0)
                    coefs[k] &-= Int16(sgn)
                    if dd != 0 {
                        let step = Int32(truncatingIfNeeded: (Int64(dd) &* Int64(sgn)) >> denShift) &* Int32(numActive - k)
                        rem &-= step
                    }
                    k -= 1
                }
            } else if del < 0 {
                var rem = del
                var k = numActive - 1
                while k >= 0 && rem < 0 {
                    let dd = top &- out[j - 1 - k]
                    let sgn: Int32 = dd > 0 ? 1 : (dd < 0 ? -1 : 0)
                    coefs[k] &+= Int16(sgn)
                    if dd != 0 {
                        // Match Apple ALAC dp_dec.c arithmetic right shift of negative magnitude.
                        let step = Int32(truncatingIfNeeded: (-(Int64(dd) &* Int64(sgn))) >> denShift) &* Int32(numActive - k)
                        rem &-= step
                    }
                    k -= 1
                }
            }
        }
        return out
    }

    static func predict(
        samples: [Int32],
        coefs initialCoefs: [Int16],
        numActive: Int,
        chanBits: Int,
        denShift: Int
    ) -> [Int32] {
        let num = samples.count
        guard num > 0 else { return [] }
        var residuals = [Int32](repeating: 0, count: num)

        if numActive == 0 {
            for i in 0..<num {
                residuals[i] = signExtend32(samples[i], bits: chanBits)
            }
            return residuals
        }

        if numActive == 31 {
            residuals[0] = signExtend32(samples[0], bits: chanBits)
            for i in 1..<num {
                residuals[i] = signExtend32(samples[i] &- samples[i - 1], bits: chanBits)
            }
            return residuals
        }

        var coefs = initialCoefs
        let lim = min(numActive + 1, num)
        residuals[0] = signExtend32(samples[0], bits: chanBits)
        for j in 1..<lim {
            residuals[j] = signExtend32(samples[j] &- samples[j - 1], bits: chanBits)
        }
        guard lim < num else { return residuals }

        let roundBias: Int64 = denShift > 0 ? Int64(1 << (denShift - 1)) : 0
        for j in lim..<num {
            let top = samples[j - lim]
            var sum1: Int64 = roundBias
            for k in 0..<numActive {
                let diff = samples[j - 1 - k] &- top
                sum1 &+= Int64(coefs[k]) &* Int64(diff)
            }
            let pred = Int32(truncatingIfNeeded: sum1 >> denShift)
            let del = signExtend32(samples[j] &- top &- pred, bits: chanBits)
            residuals[j] = del

            if del > 0 {
                var rem = del
                var k = numActive - 1
                while k >= 0 && rem > 0 {
                    let dd = top &- samples[j - 1 - k]
                    let sgn: Int32 = dd > 0 ? 1 : (dd < 0 ? -1 : 0)
                    coefs[k] &-= Int16(sgn)
                    if dd != 0 {
                        let step = Int32(truncatingIfNeeded: (Int64(dd) &* Int64(sgn)) >> denShift) &* Int32(numActive - k)
                        rem &-= step
                    }
                    k -= 1
                }
            } else if del < 0 {
                var rem = del
                var k = numActive - 1
                while k >= 0 && rem < 0 {
                    let dd = top &- samples[j - 1 - k]
                    let sgn: Int32 = dd > 0 ? 1 : (dd < 0 ? -1 : 0)
                    coefs[k] &+= Int16(sgn)
                    if dd != 0 {
                        // Match Apple ALAC dp_enc.c arithmetic right shift of negative magnitude.
                        let step = Int32(truncatingIfNeeded: (-(Int64(dd) &* Int64(sgn))) >> denShift) &* Int32(numActive - k)
                        rem &-= step
                    }
                    k -= 1
                }
            }
        }
        return residuals
    }

    /// Computes initial quantized FIR LPC coefficients via autocorrelation + Levinson-Durbin.
    static func estimateCoefficients(samples: [Int32], order: Int, denShift: Int) -> [Int16] {
        guard order > 0, samples.count > order + 2 else {
            return [Int16](repeating: 0, count: max(0, order))
        }
        // Estimate on first-order differences to match ALAC's difference-from-top formulation.
        let n = samples.count
        var r = [Double](repeating: 0.0, count: order + 1)
        for lag in 0...order {
            var sum = 0.0
            for i in (lag + 1)..<n {
                let d0 = Double(samples[i] &- samples[i - 1])
                let d1 = Double(samples[i - lag] &- samples[i - lag - 1])
                sum += d0 * d1
            }
            r[lag] = sum
        }

        var lpc = [Double](repeating: 0.0, count: order)
        if r[0] > 1e-12 {
            var err = r[0]
            var prev = [Double](repeating: 0.0, count: order)
            for k in 0..<order {
                var acc = r[k + 1]
                for j in 0..<k { acc -= lpc[j] * r[k - j] }
                let refl = min(max(acc / err, -0.95), 0.95)
                for j in 0..<k { prev[j] = lpc[j] - refl * lpc[k - 1 - j] }
                prev[k] = refl
                for j in 0...k { lpc[j] = prev[j] }
                err *= (1.0 - refl * refl)
                if err <= 1e-12 { break }
            }
        }

        // Convert to ALAC's prediction weights around `top`: sum_k c[k] * (x[i-1-k] - top).
        let scale = Double(1 << denShift)
        var out = [Int16](repeating: 0, count: order)
        var cumulative = 1.0
        for k in 0..<order {
            let weight = k == 0 ? (1.0 + lpc[0]) : (lpc[k] - lpc[k - 1])
            cumulative = max(-2.0, min(2.0, weight))
            let q = Int32((cumulative * scale).rounded())
            out[k] = Int16(min(max(q, -32767), 32767))
        }
        return out
    }
}

// MARK: - ALAC Decoder

public enum ALACDecoder {
    private struct MP4Box {
        var type: String
        var payloadStart: Int
        var end: Int
    }

    private struct STSCEntry {
        var firstChunk: Int
        var samplesPerChunk: Int
    }

    private struct TrackSampleTable {
        var config: ALACConfig?
        var sampleSizes: [Int] = []
        var chunkOffsets: [Int] = []
        var stsc: [STSCEntry] = []
    }

    /// Decodes a complete ISO Base Media / MP4 / M4A container holding an ALAC audio track.
    public static func decodeM4A(_ data: [UInt8]) throws(AudioDecoderError) -> DecodedAudio {
        guard data.count >= 8 else {
            throw AudioDecoderError.truncatedData("M4A data shorter than 8 bytes")
        }

        let topBoxes = try parseBoxes(in: data, range: 0..<data.count)
        guard let moov = topBoxes.first(where: { $0.type == "moov" }) else {
            throw AudioDecoderError.invalidHeader("missing M4A 'moov' box")
        }

        var selectedTrack: TrackSampleTable?
        let moovChildren = try parseBoxes(in: data, range: moov.payloadStart..<moov.end)
        for box in moovChildren where box.type == "trak" {
            if let table = try parseTrack(in: data, range: box.payloadStart..<box.end),
               table.config != nil {
                selectedTrack = table
                break
            }
        }

        guard let track = selectedTrack, let config = track.config else {
            throw AudioDecoderError.invalidHeader("no ALAC audio track found in M4A container")
        }

        let channels = Int(config.numChannels)
        let bitDepth = Int(config.bitDepth)
        if track.sampleSizes.isEmpty {
            return DecodedAudio(
                format: AudioFormat(sampleRate: Double(config.sampleRate), channelCount: channels, bitDepth: bitDepth),
                frames: 0,
                samples: [],
                rawIntSamples: []
            )
        }

        guard !track.chunkOffsets.isEmpty, !track.stsc.isEmpty else {
            throw AudioDecoderError.invalidHeader("missing chunk offset or sample-to-chunk table in M4A")
        }

        var allRawInts: [Int32] = []
        allRawInts.reserveCapacity(track.sampleSizes.count * Int(config.frameLength) * channels)

        var sampleIdx = 0
        var stscIdx = 0
        for chunkIdx in 0..<track.chunkOffsets.count {
            let oneBasedChunk = chunkIdx + 1
            while stscIdx + 1 < track.stsc.count && track.stsc[stscIdx + 1].firstChunk <= oneBasedChunk {
                stscIdx += 1
            }
            let samplesInChunk = track.stsc[stscIdx].samplesPerChunk
            var fileOffset = track.chunkOffsets[chunkIdx]
            for _ in 0..<samplesInChunk {
                guard sampleIdx < track.sampleSizes.count else { break }
                let packetSize = track.sampleSizes[sampleIdx]
                sampleIdx += 1
                guard fileOffset >= 0, packetSize >= 0, fileOffset + packetSize <= data.count else {
                    throw AudioDecoderError.truncatedData("ALAC packet at offset \(fileOffset) size \(packetSize) exceeds M4A bounds")
                }
                let packet = Array(data[fileOffset..<(fileOffset + packetSize)])
                let decoded = try decodePacket(packet, config: config)
                allRawInts.append(contentsOf: decoded)
                fileOffset += packetSize
            }
            if sampleIdx >= track.sampleSizes.count { break }
        }

        let frames = allRawInts.count / channels
        let invScale = 1.0 / Double(Int64(1) << (bitDepth - 1))
        var doubles = [Double](repeating: 0.0, count: allRawInts.count)
        for i in 0..<allRawInts.count {
            doubles[i] = Double(allRawInts[i]) * invScale
        }

        return DecodedAudio(
            format: AudioFormat(sampleRate: Double(config.sampleRate), channelCount: channels, bitDepth: bitDepth),
            frames: frames,
            samples: doubles,
            rawIntSamples: allRawInts
        )
    }

    /// Decodes a single ALAC access unit (packet) into interleaved signed `Int32` PCM samples.
    public static func decodePacket(_ packet: [UInt8], config: ALACConfig) throws(AudioDecoderError) -> [Int32] {
        guard !packet.isEmpty else {
            throw AudioDecoderError.truncatedData("empty ALAC packet")
        }

        var reader = ALACBitReader(packet)
        let bitDepth = Int(config.bitDepth)
        let expectedChannels = Int(config.numChannels)
        var channelBuffers: [[Int32]] = []
        channelBuffers.reserveCapacity(expectedChannels)
        var numSamples = 0

        while reader.remainingBits >= 3 {
            let tag = try reader.readBits(3)
            if tag == ALACConstants.idEND {
                break
            } else if tag == ALACConstants.idSCE {
                let ch = try decodeSCE(&reader, config: config, bitDepth: bitDepth)
                if numSamples == 0 { numSamples = ch.count }
                channelBuffers.append(ch)
            } else if tag == ALACConstants.idCPE {
                let (left, right) = try decodeCPE(&reader, config: config, bitDepth: bitDepth)
                if numSamples == 0 { numSamples = left.count }
                channelBuffers.append(left)
                channelBuffers.append(right)
            } else if tag == ALACConstants.idDSE {
                _ = try reader.readBits(4) // elementInstanceTag
                let alignFlag = try reader.readBit()
                var count = Int(try reader.readBits(8))
                if count == 255 {
                    count += Int(try reader.readBits(8))
                }
                if alignFlag != 0 {
                    let rem = reader.bitPos & 7
                    if rem != 0 { reader.bitPos += 8 - rem }
                }
                for _ in 0..<count { _ = try reader.readBits(8) }
            } else if tag == ALACConstants.idFIL {
                var count = Int(try reader.readBits(4))
                if count == 15 {
                    count += Int(try reader.readBits(8)) - 1
                }
                for _ in 0..<count { _ = try reader.readBits(8) }
            } else {
                throw AudioDecoderError.unsupportedFormat("unsupported ALAC bitstream element tag \(tag)")
            }
        }

        guard channelBuffers.count == expectedChannels else {
            throw AudioDecoderError.invalidBitstream("ALAC packet decoded \(channelBuffers.count) channels, expected \(expectedChannels)")
        }
        guard numSamples > 0 else { return [] }

        var interleaved = [Int32](repeating: 0, count: numSamples * expectedChannels)
        for ch in 0..<expectedChannels {
            let src = channelBuffers[ch]
            guard src.count == numSamples else {
                throw AudioDecoderError.invalidBitstream("mismatched sample counts across ALAC channel elements")
            }
            for i in 0..<numSamples {
                interleaved[i * expectedChannels + ch] = src[i]
            }
        }
        return interleaved
    }

    private static func decodeSCE(
        _ reader: inout ALACBitReader,
        config: ALACConfig,
        bitDepth: Int
    ) throws(AudioDecoderError) -> [Int32] {
        _ = try reader.readBits(4) // elementInstanceTag
        let unused = try reader.readBits(12)
        guard unused == 0 else {
            throw AudioDecoderError.invalidBitstream("non-zero ALAC SCE header reserved field")
        }
        let hasSize = try reader.readBit() != 0
        let bytesShifted = Int(try reader.readBits(2))
        let isVerbatim = try reader.readBit() != 0
        let numSamples = hasSize ? Int(try reader.readBits(32)) : Int(config.frameLength)
        guard numSamples >= 0 && numSamples <= 1_048_576 else {
            throw AudioDecoderError.invalidBitstream("invalid ALAC SCE sample count \(numSamples)")
        }

        if isVerbatim {
            var out = [Int32](repeating: 0, count: numSamples)
            for i in 0..<numSamples {
                out[i] = try reader.readSigned(bitDepth)
            }
            return out
        }

        _ = try reader.readBits(8) // mixBits (0 for SCE)
        _ = try reader.readBits(8) // mixRes (0 for SCE)

        let modeU = Int(try reader.readBits(4))
        let denShiftU = Int(try reader.readBits(4))
        let pbFactorU = Int(try reader.readBits(3))
        let numU = Int(try reader.readBits(5))
        guard modeU == 0 || modeU == 15 else {
            throw AudioDecoderError.unsupportedFormat("unsupported ALAC predictor mode \(modeU)")
        }

        var coefsU = [Int16](repeating: 0, count: numU)
        for i in 0..<numU {
            coefsU[i] = Int16(truncatingIfNeeded: try reader.readSigned(16))
        }

        let extraBits = bytesShifted * 8
        let chanBits = bitDepth - extraBits
        guard chanBits > 0 && chanBits <= 32 else {
            throw AudioDecoderError.invalidBitstream("invalid ALAC shifted bit width \(chanBits)")
        }

        var extraLSBs: [UInt32] = []
        if extraBits > 0 {
            extraLSBs = [UInt32](repeating: 0, count: numSamples)
            for i in 0..<numSamples {
                extraLSBs[i] = try reader.readBits(extraBits)
            }
        }

        let effectivePB = (pbFactorU * Int(config.pb)) / 4
        let residuals = try ALACEntropy.decodeResiduals(
            &reader,
            count: numSamples,
            chanBits: chanBits,
            pb: effectivePB,
            mbInit: Int(config.mb),
            kb: Int(config.kb)
        )

        var out: [Int32]
        if modeU == 15 {
            let step1 = ALACPredictor.reconstruct(
                residuals: residuals,
                coefs: coefsU,
                numActive: 31,
                chanBits: chanBits,
                denShift: 0
            )
            out = ALACPredictor.reconstruct(
                residuals: step1,
                coefs: coefsU,
                numActive: numU,
                chanBits: chanBits,
                denShift: denShiftU
            )
        } else {
            out = ALACPredictor.reconstruct(
                residuals: residuals,
                coefs: coefsU,
                numActive: numU,
                chanBits: chanBits,
                denShift: denShiftU
            )
        }

        if extraBits > 0 {
            for i in 0..<numSamples {
                out[i] = signExtend32((out[i] << extraBits) | Int32(bitPattern: extraLSBs[i]), bits: bitDepth)
            }
        }
        return out
    }

    private static func decodeCPE(
        _ reader: inout ALACBitReader,
        config: ALACConfig,
        bitDepth: Int
    ) throws(AudioDecoderError) -> ([Int32], [Int32]) {
        _ = try reader.readBits(4) // elementInstanceTag
        let unused = try reader.readBits(12)
        guard unused == 0 else {
            throw AudioDecoderError.invalidBitstream("non-zero ALAC CPE header reserved field")
        }
        let hasSize = try reader.readBit() != 0
        let bytesShifted = Int(try reader.readBits(2))
        let isVerbatim = try reader.readBit() != 0
        let numSamples = hasSize ? Int(try reader.readBits(32)) : Int(config.frameLength)
        guard numSamples >= 0 && numSamples <= 1_048_576 else {
            throw AudioDecoderError.invalidBitstream("invalid ALAC CPE sample count \(numSamples)")
        }

        if isVerbatim {
            var left = [Int32](repeating: 0, count: numSamples)
            var right = [Int32](repeating: 0, count: numSamples)
            for i in 0..<numSamples {
                left[i] = try reader.readSigned(bitDepth)
                right[i] = try reader.readSigned(bitDepth)
            }
            return (left, right)
        }

        let mixBits = Int(try reader.readBits(8))
        let mixRes = Int(try reader.readBits(8))

        let modeU = Int(try reader.readBits(4))
        let denShiftU = Int(try reader.readBits(4))
        let pbFactorU = Int(try reader.readBits(3))
        let numU = Int(try reader.readBits(5))
        var coefsU = [Int16](repeating: 0, count: numU)
        for i in 0..<numU {
            coefsU[i] = Int16(truncatingIfNeeded: try reader.readSigned(16))
        }

        let modeV = Int(try reader.readBits(4))
        let denShiftV = Int(try reader.readBits(4))
        let pbFactorV = Int(try reader.readBits(3))
        let numV = Int(try reader.readBits(5))
        var coefsV = [Int16](repeating: 0, count: numV)
        for i in 0..<numV {
            coefsV[i] = Int16(truncatingIfNeeded: try reader.readSigned(16))
        }

        let extraBits = bytesShifted * 8
        let chanBits = bitDepth - extraBits + (mixRes != 0 ? 1 : 0)
        guard chanBits > 0 && chanBits <= 32 else {
            throw AudioDecoderError.invalidBitstream("invalid ALAC CPE channel bit width \(chanBits)")
        }

        var shiftL: [UInt32] = []
        var shiftR: [UInt32] = []
        if extraBits > 0 {
            shiftL = [UInt32](repeating: 0, count: numSamples)
            shiftR = [UInt32](repeating: 0, count: numSamples)
            for i in 0..<numSamples {
                shiftL[i] = try reader.readBits(extraBits)
                shiftR[i] = try reader.readBits(extraBits)
            }
        }

        let resU = try ALACEntropy.decodeResiduals(
            &reader,
            count: numSamples,
            chanBits: chanBits,
            pb: (pbFactorU * Int(config.pb)) / 4,
            mbInit: Int(config.mb),
            kb: Int(config.kb)
        )
        let uBuf: [Int32]
        if modeU == 15 {
            let s1 = ALACPredictor.reconstruct(residuals: resU, coefs: coefsU, numActive: 31, chanBits: chanBits, denShift: 0)
            uBuf = ALACPredictor.reconstruct(residuals: s1, coefs: coefsU, numActive: numU, chanBits: chanBits, denShift: denShiftU)
        } else {
            uBuf = ALACPredictor.reconstruct(residuals: resU, coefs: coefsU, numActive: numU, chanBits: chanBits, denShift: denShiftU)
        }

        let resV = try ALACEntropy.decodeResiduals(
            &reader,
            count: numSamples,
            chanBits: chanBits,
            pb: (pbFactorV * Int(config.pb)) / 4,
            mbInit: Int(config.mb),
            kb: Int(config.kb)
        )
        let vBuf: [Int32]
        if modeV == 15 {
            let s1 = ALACPredictor.reconstruct(residuals: resV, coefs: coefsV, numActive: 31, chanBits: chanBits, denShift: 0)
            vBuf = ALACPredictor.reconstruct(residuals: s1, coefs: coefsV, numActive: numV, chanBits: chanBits, denShift: denShiftV)
        } else {
            vBuf = ALACPredictor.reconstruct(residuals: resV, coefs: coefsV, numActive: numV, chanBits: chanBits, denShift: denShiftV)
        }

        var left = [Int32](repeating: 0, count: numSamples)
        var right = [Int32](repeating: 0, count: numSamples)
        let unshiftedBits = bitDepth - extraBits

        if mixRes != 0 {
            let mixRes64 = Int64(mixRes)
            for i in 0..<numSamples {
                let u = Int64(uBuf[i])
                let v = Int64(vBuf[i])
                let r = Int32(truncatingIfNeeded: u - ((v * mixRes64) >> mixBits))
                let l = r &+ Int32(truncatingIfNeeded: v)
                left[i] = signExtend32(l, bits: unshiftedBits)
                right[i] = signExtend32(r, bits: unshiftedBits)
            }
        } else {
            for i in 0..<numSamples {
                left[i] = signExtend32(uBuf[i], bits: unshiftedBits)
                right[i] = signExtend32(vBuf[i], bits: unshiftedBits)
            }
        }

        if extraBits > 0 {
            for i in 0..<numSamples {
                left[i] = signExtend32((left[i] << extraBits) | Int32(bitPattern: shiftL[i]), bits: bitDepth)
                right[i] = signExtend32((right[i] << extraBits) | Int32(bitPattern: shiftR[i]), bits: bitDepth)
            }
        }
        return (left, right)
    }

    // MARK: ISO BMFF / MP4 Box Parsing

    private static func parseBoxes(in data: [UInt8], range: Range<Int>) throws(AudioDecoderError) -> [MP4Box] {
        var boxes: [MP4Box] = []
        var pos = range.lowerBound
        while pos + 8 <= range.upperBound {
            let size32 = data.u32(at: pos)
            let type = data.alacFourCC(at: pos + 4)
            let headerSize: Int
            let boxEnd: Int
            if size32 == 0 {
                headerSize = 8
                boxEnd = range.upperBound
            } else if size32 == 1 {
                guard pos + 16 <= range.upperBound else {
                    throw AudioDecoderError.truncatedData("truncated 64-bit MP4 box header '\(type)'")
                }
                let size64 = data.u64be(at: pos + 8)
                guard size64 >= 16, size64 <= UInt64(range.upperBound - pos) else {
                    throw AudioDecoderError.truncatedData("invalid 64-bit MP4 box size for '\(type)'")
                }
                headerSize = 16
                boxEnd = pos + Int(size64)
            } else {
                guard size32 >= 8 else {
                    throw AudioDecoderError.invalidHeader("invalid MP4 box size \(size32) for '\(type)'")
                }
                headerSize = 8
                boxEnd = min(range.upperBound, pos + Int(size32))
            }
            boxes.append(MP4Box(type: type, payloadStart: pos + headerSize, end: boxEnd))
            if boxEnd <= pos { break }
            pos = boxEnd
        }
        return boxes
    }

    private static func parseTrack(in data: [UInt8], range: Range<Int>) throws(AudioDecoderError) -> TrackSampleTable? {
        let trakChildren = try parseBoxes(in: data, range: range)
        guard let mdia = trakChildren.first(where: { $0.type == "mdia" }) else { return nil }
        let mdiaChildren = try parseBoxes(in: data, range: mdia.payloadStart..<mdia.end)
        guard let minf = mdiaChildren.first(where: { $0.type == "minf" }) else { return nil }
        let minfChildren = try parseBoxes(in: data, range: minf.payloadStart..<minf.end)
        guard let stbl = minfChildren.first(where: { $0.type == "stbl" }) else { return nil }

        let stblChildren = try parseBoxes(in: data, range: stbl.payloadStart..<stbl.end)
        var table = TrackSampleTable()

        for box in stblChildren {
            switch box.type {
            case "stsd":
                table.config = try parseSTSD(in: data, range: box.payloadStart..<box.end)
            case "stsz":
                table.sampleSizes = try parseSTSZ(in: data, range: box.payloadStart..<box.end)
            case "stco":
                table.chunkOffsets = try parseSTCO(in: data, range: box.payloadStart..<box.end)
            case "co64":
                table.chunkOffsets = try parseCO64(in: data, range: box.payloadStart..<box.end)
            case "stsc":
                table.stsc = try parseSTSC(in: data, range: box.payloadStart..<box.end)
            default:
                break
            }
        }
        return table
    }

    private static func parseSTSD(in data: [UInt8], range: Range<Int>) throws(AudioDecoderError) -> ALACConfig? {
        guard range.count >= 8 else { return nil }
        let entryCount = Int(data.u32(at: range.lowerBound + 4))
        var pos = range.lowerBound + 8
        for _ in 0..<entryCount {
            guard pos + 8 <= range.upperBound else { break }
            let entrySize = Int(data.u32(at: pos))
            let entryType = data.alacFourCC(at: pos + 4)
            let entryEnd = min(range.upperBound, pos + max(8, entrySize))
            if entryType == "alac" {
                // AudioSampleEntry header is 28 bytes after the 8-byte box header (36 bytes total).
                let childStart = pos + 36
                if childStart < entryEnd {
                    let childBoxes = try parseBoxes(in: data, range: childStart..<entryEnd)
                    if let cookieBox = childBoxes.first(where: { $0.type == "alac" }) {
                        let cookieLen = cookieBox.end - cookieBox.payloadStart
                        if cookieLen >= 28 {
                            return try ALACConfig(magicCookie: Array(data[cookieBox.payloadStart..<cookieBox.end]))
                        } else if cookieLen >= 24 {
                            return try ALACConfig(magicCookie: Array(data[cookieBox.payloadStart..<cookieBox.end]))
                        }
                    }
                    // Fallback: raw 24-byte cookie directly after AudioSampleEntry.
                    if entryEnd - childStart >= 24 {
                        return try ALACConfig(magicCookie: Array(data[childStart..<entryEnd]))
                    }
                }
            }
            if entryEnd <= pos { break }
            pos = entryEnd
        }
        return nil
    }

    private static func parseSTSZ(in data: [UInt8], range: Range<Int>) throws(AudioDecoderError) -> [Int] {
        guard range.count >= 12 else {
            throw AudioDecoderError.truncatedData("truncated M4A stsz box")
        }
        let uniformSize = Int(data.u32(at: range.lowerBound + 4))
        let sampleCount = Int(data.u32(at: range.lowerBound + 8))
        if uniformSize > 0 {
            return [Int](repeating: uniformSize, count: sampleCount)
        }
        guard range.lowerBound + 12 + sampleCount * 4 <= range.upperBound else {
            throw AudioDecoderError.truncatedData("truncated M4A stsz sample size table")
        }
        var sizes: [Int] = []
        sizes.reserveCapacity(sampleCount)
        var pos = range.lowerBound + 12
        for _ in 0..<sampleCount {
            sizes.append(Int(data.u32(at: pos)))
            pos += 4
        }
        return sizes
    }

    private static func parseSTCO(in data: [UInt8], range: Range<Int>) throws(AudioDecoderError) -> [Int] {
        guard range.count >= 8 else {
            throw AudioDecoderError.truncatedData("truncated M4A stco box")
        }
        let count = Int(data.u32(at: range.lowerBound + 4))
        guard range.lowerBound + 8 + count * 4 <= range.upperBound else {
            throw AudioDecoderError.truncatedData("truncated M4A stco chunk offset table")
        }
        var offsets: [Int] = []
        offsets.reserveCapacity(count)
        var pos = range.lowerBound + 8
        for _ in 0..<count {
            offsets.append(Int(data.u32(at: pos)))
            pos += 4
        }
        return offsets
    }

    private static func parseCO64(in data: [UInt8], range: Range<Int>) throws(AudioDecoderError) -> [Int] {
        guard range.count >= 8 else {
            throw AudioDecoderError.truncatedData("truncated M4A co64 box")
        }
        let count = Int(data.u32(at: range.lowerBound + 4))
        guard range.lowerBound + 8 + count * 8 <= range.upperBound else {
            throw AudioDecoderError.truncatedData("truncated M4A co64 chunk offset table")
        }
        var offsets: [Int] = []
        offsets.reserveCapacity(count)
        var pos = range.lowerBound + 8
        for _ in 0..<count {
            offsets.append(Int(data.u64be(at: pos)))
            pos += 8
        }
        return offsets
    }

    private static func parseSTSC(in data: [UInt8], range: Range<Int>) throws(AudioDecoderError) -> [STSCEntry] {
        guard range.count >= 8 else {
            throw AudioDecoderError.truncatedData("truncated M4A stsc box")
        }
        let count = Int(data.u32(at: range.lowerBound + 4))
        guard range.lowerBound + 8 + count * 12 <= range.upperBound else {
            throw AudioDecoderError.truncatedData("truncated M4A stsc table")
        }
        var entries: [STSCEntry] = []
        entries.reserveCapacity(count)
        var pos = range.lowerBound + 8
        for _ in 0..<count {
            let firstChunk = Int(data.u32(at: pos))
            let samplesPerChunk = Int(data.u32(at: pos + 4))
            entries.append(STSCEntry(firstChunk: firstChunk, samplesPerChunk: samplesPerChunk))
            pos += 12
        }
        return entries
    }
}

// MARK: - ALAC Encoder (M4A Container + Verbatim & Compressed Packets)

public enum ALACEncoder {
    /// Encodes normalized 64-bit float PCM samples into a valid ISO BMFF M4A/ALAC stream.
    public static func encodeM4A(
        samples: [Double],
        sampleRate: Double,
        channelCount: Int,
        bitDepth: Int = 16,
        compressed: Bool = true
    ) throws(AudioDecoderError) -> [UInt8] {
        guard bitDepth == 16 || bitDepth == 24 else {
            throw AudioDecoderError.unsupportedFormat("ALACEncoder supports 16-bit and 24-bit encoding")
        }
        let intSamples: [Int32]
        if bitDepth == 16 {
            intSamples = samples.map(alacDoubleToInt16)
        } else {
            intSamples = samples.map(alacDoubleToInt24)
        }
        return try encodeM4A(
            intSamples: intSamples,
            sampleRate: sampleRate,
            channelCount: channelCount,
            bitDepth: bitDepth,
            compressed: compressed
        )
    }

    /// Encodes exact signed integer PCM samples (`Int32`) into a valid ISO BMFF M4A/ALAC stream.
    public static func encodeM4A(
        intSamples: [Int32],
        sampleRate: Double,
        channelCount: Int,
        bitDepth: Int = 16,
        compressed: Bool = true
    ) throws(AudioDecoderError) -> [UInt8] {
        guard channelCount == 1 || channelCount == 2 else {
            throw AudioDecoderError.unsupportedFormat("ALACEncoder supports mono or stereo audio")
        }
        guard bitDepth == 16 || bitDepth == 24 else {
            throw AudioDecoderError.unsupportedFormat("ALACEncoder supports 16-bit and 24-bit encoding")
        }
        guard sampleRate > 0 && sampleRate.isFinite else {
            throw AudioDecoderError.invalidHeader("invalid sampleRate \(sampleRate)")
        }

        let frameLength = 4096
        let srU32 = UInt32(sampleRate.rounded())
        var config = ALACConfig(
            frameLength: UInt32(frameLength),
            compatibleVersion: 0,
            bitDepth: UInt8(bitDepth),
            pb: 40,
            mb: 10,
            kb: 14,
            numChannels: UInt8(channelCount),
            maxRun: 255,
            maxFrameBytes: 0,
            avgBitRate: 0,
            sampleRate: srU32
        )

        let totalFrames = intSamples.count / channelCount
        var packets: [[UInt8]] = []
        var packetFrameCounts: [Int] = []
        var maxPktBytes: UInt32 = 0
        var totalPayloadBytes = 0

        var frameOffset = 0
        while frameOffset < totalFrames {
            let n = min(frameLength, totalFrames - frameOffset)
            let sliceStart = frameOffset * channelCount
            let sliceEnd = (frameOffset + n) * channelCount
            let pkt = try encodePacket(
                intSamples: Array(intSamples[sliceStart..<sliceEnd]),
                config: config,
                compressed: compressed
            )
            maxPktBytes = max(maxPktBytes, UInt32(pkt.count))
            totalPayloadBytes += pkt.count
            packets.append(pkt)
            packetFrameCounts.append(n)
            frameOffset += n
        }

        config.maxFrameBytes = maxPktBytes
        if totalFrames > 0 {
            let seconds = Double(totalFrames) / sampleRate
            config.avgBitRate = UInt32((Double(totalPayloadBytes) * 8.0 / max(seconds, 1e-6)).rounded())
        }

        return buildM4AContainer(
            config: config,
            packets: packets,
            packetFrameCounts: packetFrameCounts,
            totalFrames: totalFrames
        )
    }

    /// Encodes a single ALAC access unit (packet) for mono (SCE) or stereo (CPE) integer samples.
    public static func encodePacket(
        intSamples: [Int32],
        config: ALACConfig,
        compressed: Bool = true
    ) throws(AudioDecoderError) -> [UInt8] {
        let channels = Int(config.numChannels)
        let bitDepth = Int(config.bitDepth)
        guard channels == 1 || channels == 2 else {
            throw AudioDecoderError.unsupportedFormat("ALACEncoder packet supports 1 or 2 channels")
        }
        let numSamples = intSamples.count / channels
        let hasSize = numSamples != Int(config.frameLength)
        var writer = ALACBitWriter()

        if channels == 1 {
            encodeSCE(&writer, samples: intSamples, config: config, bitDepth: bitDepth, hasSize: hasSize, compressed: compressed)
        } else {
            var left = [Int32](repeating: 0, count: numSamples)
            var right = [Int32](repeating: 0, count: numSamples)
            for i in 0..<numSamples {
                left[i] = intSamples[i * 2]
                right[i] = intSamples[i * 2 + 1]
            }
            encodeCPE(&writer, left: left, right: right, config: config, bitDepth: bitDepth, hasSize: hasSize, compressed: compressed)
        }

        writer.writeBits(ALACConstants.idEND, count: 3)
        writer.alignToByte()
        return writer.bytes
    }

    private static func encodeSCE(
        _ writer: inout ALACBitWriter,
        samples: [Int32],
        config: ALACConfig,
        bitDepth: Int,
        hasSize: Bool,
        compressed: Bool
    ) {
        let numSamples = samples.count
        let bytesShifted = (compressed && bitDepth == 24) ? 1 : 0
        let extraBits = bytesShifted * 8
        let useCompressed = compressed && numSamples > 8

        writer.writeBits(ALACConstants.idSCE, count: 3)
        writer.writeBits(0, count: 4)  // elementInstanceTag
        writer.writeBits(0, count: 12) // unused
        writer.writeBits(hasSize ? 1 : 0, count: 1)
        writer.writeBits(useCompressed ? UInt32(bytesShifted) : 0, count: 2)
        writer.writeBits(useCompressed ? 0 : 1, count: 1) // escapeFlag
        if hasSize {
            writer.writeBits(UInt32(numSamples), count: 32)
        }

        if !useCompressed {
            for s in samples {
                writer.writeSigned(s, bits: bitDepth)
            }
            return
        }

        let chanBits = bitDepth - extraBits
        var shifted = [Int32](repeating: 0, count: numSamples)
        var lsbs: [UInt32] = []
        if extraBits > 0 {
            lsbs = [UInt32](repeating: 0, count: numSamples)
            let lsbMask = UInt32((1 << extraBits) - 1)
            for i in 0..<numSamples {
                lsbs[i] = UInt32(bitPattern: samples[i]) & lsbMask
                shifted[i] = samples[i] >> extraBits
            }
        } else {
            shifted = samples
        }

        let denShift = 9
        let pbFactor = 4
        let order = min(4, max(1, numSamples - 2))
        let coefs = ALACPredictor.estimateCoefficients(samples: shifted, order: order, denShift: denShift)
        let residuals = ALACPredictor.predict(
            samples: shifted,
            coefs: coefs,
            numActive: order,
            chanBits: chanBits,
            denShift: denShift
        )

        writer.writeBits(0, count: 8) // mixBits
        writer.writeBits(0, count: 8) // mixRes
        writer.writeBits(0, count: 4) // mode = 0
        writer.writeBits(UInt32(denShift), count: 4)
        writer.writeBits(UInt32(pbFactor), count: 3)
        writer.writeBits(UInt32(order), count: 5)
        for c in coefs {
            writer.writeSigned(Int32(c), bits: 16)
        }
        if extraBits > 0 {
            for lsb in lsbs {
                writer.writeBits(lsb, count: extraBits)
            }
        }
        ALACEntropy.encodeResiduals(
            &writer,
            residuals: residuals,
            chanBits: chanBits,
            pb: (pbFactor * Int(config.pb)) / 4,
            mbInit: Int(config.mb),
            kb: Int(config.kb)
        )
    }

    private static func encodeCPE(
        _ writer: inout ALACBitWriter,
        left: [Int32],
        right: [Int32],
        config: ALACConfig,
        bitDepth: Int,
        hasSize: Bool,
        compressed: Bool
    ) {
        let numSamples = left.count
        let bytesShifted = (compressed && bitDepth == 24) ? 1 : 0
        let extraBits = bytesShifted * 8
        let useCompressed = compressed && numSamples > 8

        writer.writeBits(ALACConstants.idCPE, count: 3)
        writer.writeBits(0, count: 4)  // elementInstanceTag
        writer.writeBits(0, count: 12) // unused
        writer.writeBits(hasSize ? 1 : 0, count: 1)
        writer.writeBits(useCompressed ? UInt32(bytesShifted) : 0, count: 2)
        writer.writeBits(useCompressed ? 0 : 1, count: 1)
        if hasSize {
            writer.writeBits(UInt32(numSamples), count: 32)
        }

        if !useCompressed {
            for i in 0..<numSamples {
                writer.writeSigned(left[i], bits: bitDepth)
                writer.writeSigned(right[i], bits: bitDepth)
            }
            return
        }

        var lShifted = [Int32](repeating: 0, count: numSamples)
        var rShifted = [Int32](repeating: 0, count: numSamples)
        var lLSBs: [UInt32] = []
        var rLSBs: [UInt32] = []
        if extraBits > 0 {
            lLSBs = [UInt32](repeating: 0, count: numSamples)
            rLSBs = [UInt32](repeating: 0, count: numSamples)
            let mask = UInt32((1 << extraBits) - 1)
            for i in 0..<numSamples {
                lLSBs[i] = UInt32(bitPattern: left[i]) & mask
                rLSBs[i] = UInt32(bitPattern: right[i]) & mask
                lShifted[i] = left[i] >> extraBits
                rShifted[i] = right[i] >> extraBits
            }
        } else {
            lShifted = left
            rShifted = right
        }

        // Stereo decorrelation: v = L - R, u = R + ((v * mixRes) >> mixBits).
        let mixBits = 2
        let mixRes = 2
        let chanBits = bitDepth - extraBits + 1
        var uBuf = [Int32](repeating: 0, count: numSamples)
        var vBuf = [Int32](repeating: 0, count: numSamples)
        for i in 0..<numSamples {
            let l = Int64(lShifted[i])
            let r = Int64(rShifted[i])
            let v = l - r
            let u = r + ((v * Int64(mixRes)) >> mixBits)
            uBuf[i] = Int32(truncatingIfNeeded: u)
            vBuf[i] = Int32(truncatingIfNeeded: v)
        }

        let denShift = 9
        let pbFactor = 4
        let order = min(4, max(1, numSamples - 2))
        let coefsU = ALACPredictor.estimateCoefficients(samples: uBuf, order: order, denShift: denShift)
        let coefsV = ALACPredictor.estimateCoefficients(samples: vBuf, order: order, denShift: denShift)
        let resU = ALACPredictor.predict(samples: uBuf, coefs: coefsU, numActive: order, chanBits: chanBits, denShift: denShift)
        let resV = ALACPredictor.predict(samples: vBuf, coefs: coefsV, numActive: order, chanBits: chanBits, denShift: denShift)

        writer.writeBits(UInt32(mixBits), count: 8)
        writer.writeBits(UInt32(mixRes), count: 8)

        writer.writeBits(0, count: 4)
        writer.writeBits(UInt32(denShift), count: 4)
        writer.writeBits(UInt32(pbFactor), count: 3)
        writer.writeBits(UInt32(order), count: 5)
        for c in coefsU { writer.writeSigned(Int32(c), bits: 16) }

        writer.writeBits(0, count: 4)
        writer.writeBits(UInt32(denShift), count: 4)
        writer.writeBits(UInt32(pbFactor), count: 3)
        writer.writeBits(UInt32(order), count: 5)
        for c in coefsV { writer.writeSigned(Int32(c), bits: 16) }

        if extraBits > 0 {
            for i in 0..<numSamples {
                writer.writeBits(lLSBs[i], count: extraBits)
                writer.writeBits(rLSBs[i], count: extraBits)
            }
        }

        let effPB = (pbFactor * Int(config.pb)) / 4
        ALACEntropy.encodeResiduals(&writer, residuals: resU, chanBits: chanBits, pb: effPB, mbInit: Int(config.mb), kb: Int(config.kb))
        ALACEntropy.encodeResiduals(&writer, residuals: resV, chanBits: chanBits, pb: effPB, mbInit: Int(config.mb), kb: Int(config.kb))
    }

    // MARK: ISO BMFF / M4A Container Builder

    private static func makeBox(_ type: String, payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(8 + payload.count)
        out.append(u32: UInt32(8 + payload.count))
        out.appendASCII(type)
        out.append(contentsOf: payload)
        return out
    }

    private static func makeFullBox(_ type: String, version: UInt8 = 0, flags: UInt32 = 0, payload: [UInt8]) -> [UInt8] {
        var body: [UInt8] = []
        body.reserveCapacity(4 + payload.count)
        body.append(version)
        body.append(UInt8((flags >> 16) & 0xFF))
        body.append(UInt8((flags >> 8) & 0xFF))
        body.append(UInt8(flags & 0xFF))
        body.append(contentsOf: payload)
        return makeBox(type, payload: body)
    }

    private static func buildM4AContainer(
        config: ALACConfig,
        packets: [[UInt8]],
        packetFrameCounts: [Int],
        totalFrames: Int
    ) -> [UInt8] {
        // ftyp box
        var ftypPayload: [UInt8] = []
        ftypPayload.appendASCII("M4A ")
        ftypPayload.append(u32: 0)
        ftypPayload.appendASCII("M4A ")
        ftypPayload.appendASCII("mp42")
        ftypPayload.appendASCII("isom")
        let ftyp = makeBox("ftyp", payload: ftypPayload)

        // mdat box payload
        var mdatPayload: [UInt8] = []
        for pkt in packets { mdatPayload.append(contentsOf: pkt) }
        let mdat = makeBox("mdat", payload: mdatPayload)

        // Build moov twice so stco carries the exact absolute file offset of mdat payload.
        let sampleRate = config.sampleRate
        func buildMoov(mdatPayloadOffset: UInt32) -> [UInt8] {
            // mvhd (version 0, 96 bytes payload)
            var mvhdBody = [UInt8](repeating: 0, count: 96)
            func writeU32(_ buf: inout [UInt8], at i: Int, _ v: UInt32) {
                buf[i] = UInt8((v >> 24) & 0xFF)
                buf[i + 1] = UInt8((v >> 16) & 0xFF)
                buf[i + 2] = UInt8((v >> 8) & 0xFF)
                buf[i + 3] = UInt8(v & 0xFF)
            }
            writeU32(&mvhdBody, at: 8, sampleRate)
            writeU32(&mvhdBody, at: 12, UInt32(totalFrames))
            writeU32(&mvhdBody, at: 16, 0x0001_0000) // rate 1.0
            mvhdBody[20] = 0x01 // volume 1.0
            writeU32(&mvhdBody, at: 32, 0x0001_0000) // identity matrix
            writeU32(&mvhdBody, at: 48, 0x0001_0000)
            writeU32(&mvhdBody, at: 64, 0x4000_0000)
            writeU32(&mvhdBody, at: 92, 2) // nextTrackID
            let mvhd = makeFullBox("mvhd", payload: mvhdBody)

            // tkhd (version 0, 80 bytes payload)
            var tkhdBody = [UInt8](repeating: 0, count: 80)
            writeU32(&tkhdBody, at: 8, 1) // trackID
            writeU32(&tkhdBody, at: 16, UInt32(totalFrames))
            tkhdBody[32] = 0x01 // volume 1.0
            writeU32(&tkhdBody, at: 36, 0x0001_0000)
            writeU32(&tkhdBody, at: 52, 0x0001_0000)
            writeU32(&tkhdBody, at: 68, 0x4000_0000)
            let tkhd = makeFullBox("tkhd", flags: 3, payload: tkhdBody)

            // mdhd (version 0, 20 bytes payload)
            var mdhdBody = [UInt8](repeating: 0, count: 20)
            writeU32(&mdhdBody, at: 8, sampleRate)
            writeU32(&mdhdBody, at: 12, UInt32(totalFrames))
            let mdhd = makeFullBox("mdhd", payload: mdhdBody)

            // hdlr
            var hdlrBody: [UInt8] = []
            hdlrBody.append(u32: 0)
            hdlrBody.appendASCII("soun")
            hdlrBody.append(u32: 0); hdlrBody.append(u32: 0); hdlrBody.append(u32: 0)
            hdlrBody.appendASCII("SoundHandler\0")
            let hdlr = makeFullBox("hdlr", payload: hdlrBody)

            // smhd
            let smhd = makeFullBox("smhd", payload: [0, 0, 0, 0])

            // stsd -> alac AudioSampleEntry -> alac magic cookie FullBox
            let alacCookieBox = makeFullBox("alac", payload: config.toBytes())
            var sampleEntryBody: [UInt8] = []
            sampleEntryBody.append(contentsOf: [0, 0, 0, 0, 0, 0]) // reserved
            sampleEntryBody.append(u16: 1) // dataReferenceIndex
            sampleEntryBody.append(u32: 0); sampleEntryBody.append(u32: 0) // reserved
            sampleEntryBody.append(u16: UInt16(config.numChannels))
            sampleEntryBody.append(u16: UInt16(config.bitDepth))
            sampleEntryBody.append(u32: 0)
            sampleEntryBody.append(u32: sampleRate << 16) // 16.16 fixed point
            sampleEntryBody.append(contentsOf: alacCookieBox)
            let alacEntry = makeBox("alac", payload: sampleEntryBody)

            var stsdBody: [UInt8] = []
            stsdBody.append(u32: 1) // entryCount
            stsdBody.append(contentsOf: alacEntry)
            let stsd = makeFullBox("stsd", payload: stsdBody)

            // stts (time-to-sample)
            var sttsBody: [UInt8] = []
            sttsBody.append(u32: UInt32(packetFrameCounts.count))
            for count in packetFrameCounts {
                sttsBody.append(u32: 1)
                sttsBody.append(u32: UInt32(count))
            }
            let stts = makeFullBox("stts", payload: sttsBody)

            // stsc (all samples in chunk 1)
            var stscBody: [UInt8] = []
            if packets.isEmpty {
                stscBody.append(u32: 0)
            } else {
                stscBody.append(u32: 1)
                stscBody.append(u32: 1)
                stscBody.append(u32: UInt32(packets.count))
                stscBody.append(u32: 1)
            }
            let stsc = makeFullBox("stsc", payload: stscBody)

            // stsz
            var stszBody: [UInt8] = []
            stszBody.append(u32: 0) // variable sample size
            stszBody.append(u32: UInt32(packets.count))
            for pkt in packets {
                stszBody.append(u32: UInt32(pkt.count))
            }
            let stsz = makeFullBox("stsz", payload: stszBody)

            // stco
            var stcoBody: [UInt8] = []
            if packets.isEmpty {
                stcoBody.append(u32: 0)
            } else {
                stcoBody.append(u32: 1)
                stcoBody.append(u32: mdatPayloadOffset)
            }
            let stco = makeFullBox("stco", payload: stcoBody)

            var stblPayload: [UInt8] = []
            stblPayload.append(contentsOf: stsd)
            stblPayload.append(contentsOf: stts)
            stblPayload.append(contentsOf: stsc)
            stblPayload.append(contentsOf: stsz)
            stblPayload.append(contentsOf: stco)
            let stbl = makeBox("stbl", payload: stblPayload)

            var minfPayload: [UInt8] = []
            minfPayload.append(contentsOf: smhd)
            minfPayload.append(contentsOf: stbl)
            let minf = makeBox("minf", payload: minfPayload)

            var mdiaPayload: [UInt8] = []
            mdiaPayload.append(contentsOf: mdhd)
            mdiaPayload.append(contentsOf: hdlr)
            mdiaPayload.append(contentsOf: minf)
            let mdia = makeBox("mdia", payload: mdiaPayload)

            var trakPayload: [UInt8] = []
            trakPayload.append(contentsOf: tkhd)
            trakPayload.append(contentsOf: mdia)
            let trak = makeBox("trak", payload: trakPayload)

            var moovPayload: [UInt8] = []
            moovPayload.append(contentsOf: mvhd)
            moovPayload.append(contentsOf: trak)
            return makeBox("moov", payload: moovPayload)
        }

        let probeMoov = buildMoov(mdatPayloadOffset: 0)
        let mdatDataOffset = UInt32(ftyp.count + probeMoov.count + 8)
        let finalMoov = buildMoov(mdatPayloadOffset: mdatDataOffset)

        var file: [UInt8] = []
        file.reserveCapacity(ftyp.count + finalMoov.count + mdat.count)
        file.append(contentsOf: ftyp)
        file.append(contentsOf: finalMoov)
        file.append(contentsOf: mdat)
        return file
    }
}
