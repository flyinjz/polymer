// Pure-Swift lossless audio decoders and encoders: WAV, AIFF, and FLAC.
// Standard library only — no Foundation, no OS codecs, bounds-checked throughout.
import PolymerBase

/// Errors produced by audio stream decoders and encoders.
public enum AudioDecoderError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidHeader(String)
    case unsupportedFormat(String)
    case truncatedData(String)
    case checksumMismatch(String)
    case invalidBitstream(String)

    public var description: String {
        switch self {
        case .invalidHeader(let msg): return "audio header error: \(msg)"
        case .unsupportedFormat(let msg): return "unsupported audio format: \(msg)"
        case .truncatedData(let msg): return "truncated audio data: \(msg)"
        case .checksumMismatch(let msg): return "audio checksum mismatch: \(msg)"
        case .invalidBitstream(let msg): return "invalid audio bitstream: \(msg)"
        }
    }
}

/// Decoded PCM audio in interleaved 64-bit float format (`[-1.0, 1.0]`),
/// with optional exact integer samples for bit-exact lossless verification.
public struct DecodedAudio: Equatable, Sendable {
    public var format: AudioFormat
    public var frames: Int
    public var samples: [Double]
    public var rawIntSamples: [Int32]?

    public init(format: AudioFormat, frames: Int, samples: [Double], rawIntSamples: [Int32]? = nil) {
        self.format = format
        self.frames = frames
        self.samples = samples
        self.rawIntSamples = rawIntSamples
    }
}

// MARK: - Binary Helpers

private extension Array where Element == UInt8 {
    @inline(__always) func u64le(at i: Int) -> UInt64 {
        guard i >= 0, i + 8 <= count else { return 0 }
        let lo = UInt64(u32le(at: i))
        let hi = UInt64(u32le(at: i + 4))
        return lo | (hi << 32)
    }

    @inline(__always) func fourCC(at i: Int) -> String {
        guard i >= 0, i + 4 <= count else { return "" }
        return String(decoding: self[i..<(i + 4)], as: UTF8.self)
    }

    @inline(__always) mutating func append(u16le v: UInt16) {
        append(UInt8(truncatingIfNeeded: v))
        append(UInt8(truncatingIfNeeded: v >> 8))
    }

    @inline(__always) mutating func append(u32le v: UInt32) {
        append(UInt8(truncatingIfNeeded: v))
        append(UInt8(truncatingIfNeeded: v >> 8))
        append(UInt8(truncatingIfNeeded: v >> 16))
        append(UInt8(truncatingIfNeeded: v >> 24))
    }

    @inline(__always) mutating func append(u24be v: UInt32) {
        append(UInt8(truncatingIfNeeded: v >> 16))
        append(UInt8(truncatingIfNeeded: v >> 8))
        append(UInt8(truncatingIfNeeded: v))
    }

    @inline(__always) mutating func append(ascii s: String) {
        append(contentsOf: s.utf8)
    }
}

@inline(__always)
private func doubleToInt16(_ s: Double) -> Int16 {
    let clamped = min(max(s, -1.0), 1.0)
    let scaled = (clamped * 32768.0).rounded()
    return Int16(min(max(scaled, -32768.0), 32767.0))
}

@inline(__always)
private func doubleToInt24(_ s: Double) -> Int32 {
    let clamped = min(max(s, -1.0), 1.0)
    let scaled = (clamped * 8_388_608.0).rounded()
    return Int32(min(max(scaled, -8_388_608.0), 8_388_607.0))
}

// MARK: - WAV Decoder & Encoder

public enum WAVDecoder {
    private static let extensibleSubFormatTail: [UInt8] = [
        0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71
    ]

    public static func decode(_ data: [UInt8]) throws(AudioDecoderError) -> DecodedAudio {
        guard data.count >= 12 else {
            throw AudioDecoderError.truncatedData("WAV file shorter than 12 bytes")
        }
        guard data.fourCC(at: 0) == "RIFF", data.fourCC(at: 8) == "WAVE" else {
            throw AudioDecoderError.invalidHeader("expected RIFF/WAVE header")
        }

        var foundFmt = false
        var formatTag: UInt16 = 0
        var channels = 0
        var sampleRate = 0
        var bitsPerSample = 0
        var dataRange: Range<Int>?

        var pos = 12
        while pos + 8 <= data.count {
            let chunkID = data.fourCC(at: pos)
            let chunkSize = Int(data.u32le(at: pos + 4))
            let bodyStart = pos + 8
            let bodyEnd = min(data.count, bodyStart + chunkSize)

            if chunkID == "fmt " {
                guard bodyStart + 16 <= bodyEnd else {
                    throw AudioDecoderError.truncatedData("WAV fmt chunk shorter than 16 bytes")
                }
                let rawTag = data.u16le(at: bodyStart)
                channels = Int(data.u16le(at: bodyStart + 2))
                sampleRate = Int(data.u32le(at: bodyStart + 4))
                bitsPerSample = Int(data.u16le(at: bodyStart + 14))

                if rawTag == 0xFFFE {
                    guard bodyStart + 40 <= bodyEnd else {
                        throw AudioDecoderError.truncatedData("WAVE_FORMAT_EXTENSIBLE fmt chunk shorter than 40 bytes")
                    }
                    let subTag = data.u16le(at: bodyStart + 24)
                    let tailMatch = Array(data[(bodyStart + 28)..<(bodyStart + 40)]) == extensibleSubFormatTail
                    guard tailMatch else {
                        throw AudioDecoderError.unsupportedFormat("unknown WAVE_FORMAT_EXTENSIBLE subformat GUID")
                    }
                    formatTag = subTag
                } else {
                    formatTag = rawTag
                }
                foundFmt = true
            } else if chunkID == "data" {
                dataRange = bodyStart..<bodyEnd
            }

            let paddedSize = chunkSize + (chunkSize & 1)
            let nextPos = bodyStart + paddedSize
            if nextPos <= pos { break }
            pos = nextPos
        }

        guard foundFmt else { throw AudioDecoderError.invalidHeader("missing WAV fmt chunk") }
        guard let range = dataRange else { throw AudioDecoderError.invalidHeader("missing WAV data chunk") }
        guard channels > 0, sampleRate > 0 else {
            throw AudioDecoderError.invalidHeader("invalid WAV channel count or sample rate")
        }

        let bytesPerSample = bitsPerSample / 8
        guard bitsPerSample % 8 == 0, bytesPerSample > 0 else {
            throw AudioDecoderError.unsupportedFormat("unsupported WAV bit depth \(bitsPerSample)")
        }
        let frameBytes = bytesPerSample * channels
        let availableBytes = range.count
        let frames = availableBytes / frameBytes
        let totalSamples = frames * channels

        var samples = [Double](repeating: 0.0, count: totalSamples)
        var rawInts: [Int32]? = (formatTag == 1) ? [Int32](repeating: 0, count: totalSamples) : nil
        var offset = range.lowerBound

        switch (formatTag, bitsPerSample) {
        case (1, 8):
            for i in 0..<totalSamples {
                let s = Int32(data[offset]) - 128
                rawInts?[i] = s
                samples[i] = Double(s) / 128.0
                offset += 1
            }
        case (1, 16):
            for i in 0..<totalSamples {
                let s = Int32(Int16(bitPattern: data.u16le(at: offset)))
                rawInts?[i] = s
                samples[i] = Double(s) / 32768.0
                offset += 2
            }
        case (1, 24):
            for i in 0..<totalSamples {
                let u = UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16)
                let s = Int32(bitPattern: u << 8) >> 8
                rawInts?[i] = s
                samples[i] = Double(s) / 8_388_608.0
                offset += 3
            }
        case (1, 32):
            for i in 0..<totalSamples {
                let s = Int32(bitPattern: data.u32le(at: offset))
                rawInts?[i] = s
                samples[i] = Double(s) / 2_147_483_648.0
                offset += 4
            }
        case (3, 32):
            for i in 0..<totalSamples {
                let f = Float(bitPattern: data.u32le(at: offset))
                samples[i] = Double(f)
                offset += 4
            }
        case (3, 64):
            for i in 0..<totalSamples {
                samples[i] = Double(bitPattern: data.u64le(at: offset))
                offset += 8
            }
        default:
            throw AudioDecoderError.unsupportedFormat("WAV format tag \(formatTag) with \(bitsPerSample)-bit depth is not supported")
        }

        return DecodedAudio(
            format: AudioFormat(sampleRate: Double(sampleRate), channelCount: channels, bitDepth: bitsPerSample),
            frames: frames,
            samples: samples,
            rawIntSamples: rawInts
        )
    }
}

public enum WAVEncoder {
    public static func encodePCM16(samples: [Double], sampleRate: Int, channels: Int) -> [UInt8] {
        encodePCM16(intSamples: samples.map(doubleToInt16), sampleRate: sampleRate, channels: channels)
    }

    public static func encodePCM16(intSamples: [Int16], sampleRate: Int, channels: Int) -> [UInt8] {
        let dataBytes = intSamples.count * 2
        var out = wavHeader(formatTag: 1, channels: channels, sampleRate: sampleRate, bitsPerSample: 16, dataBytes: dataBytes)
        for s in intSamples {
            out.append(u16le: UInt16(bitPattern: s))
        }
        return out
    }

    public static func encodePCM24(samples: [Double], sampleRate: Int, channels: Int) -> [UInt8] {
        encodePCM24(intSamples: samples.map(doubleToInt24), sampleRate: sampleRate, channels: channels)
    }

    public static func encodePCM24(intSamples: [Int32], sampleRate: Int, channels: Int) -> [UInt8] {
        let dataBytes = intSamples.count * 3
        var out = wavHeader(formatTag: 1, channels: channels, sampleRate: sampleRate, bitsPerSample: 24, dataBytes: dataBytes)
        for s in intSamples {
            let u = UInt32(bitPattern: s)
            out.append(UInt8(truncatingIfNeeded: u))
            out.append(UInt8(truncatingIfNeeded: u >> 8))
            out.append(UInt8(truncatingIfNeeded: u >> 16))
        }
        if dataBytes & 1 != 0 { out.append(0) }
        return out
    }

    public static func encodeFloat32(samples: [Double], sampleRate: Int, channels: Int) -> [UInt8] {
        let dataBytes = samples.count * 4
        var out = wavHeader(formatTag: 3, channels: channels, sampleRate: sampleRate, bitsPerSample: 32, dataBytes: dataBytes)
        for s in samples {
            out.append(u32le: Float(s).bitPattern)
        }
        return out
    }

    private static func wavHeader(formatTag: UInt16, channels: Int, sampleRate: Int, bitsPerSample: Int, dataBytes: Int) -> [UInt8] {
        let blockAlign = channels * (bitsPerSample / 8)
        let byteRate = sampleRate * blockAlign
        let riffSize = 36 + dataBytes + (dataBytes & 1)
        var out: [UInt8] = []
        out.reserveCapacity(44 + dataBytes)
        out.append(ascii: "RIFF")
        out.append(u32le: UInt32(riffSize))
        out.append(ascii: "WAVE")
        out.append(ascii: "fmt ")
        out.append(u32le: 16)
        out.append(u16le: formatTag)
        out.append(u16le: UInt16(channels))
        out.append(u32le: UInt32(sampleRate))
        out.append(u32le: UInt32(byteRate))
        out.append(u16le: UInt16(blockAlign))
        out.append(u16le: UInt16(bitsPerSample))
        out.append(ascii: "data")
        out.append(u32le: UInt32(dataBytes))
        return out
    }
}

// MARK: - AIFF Decoder & Encoder

public enum AIFFDecoder {
    /// Decodes an 80-bit big-endian IEEE 754 extended float (used by AIFF COMM sampleRate).
    public static func decodeExtended80(_ bytes: [UInt8], at offset: Int) -> Double {
        guard offset >= 0, offset + 10 <= bytes.count else { return 0.0 }
        let expon = Int(bytes.u16(at: offset))
        let sign: FloatingPointSign = (expon & 0x8000) != 0 ? .minus : .plus
        let exp = expon & 0x7FFF
        let hiMant = bytes.u32(at: offset + 2)
        let loMant = bytes.u32(at: offset + 6)
        if exp == 0 && hiMant == 0 && loMant == 0 { return 0.0 }
        if exp == 0x7FFF {
            return (hiMant == 0 && loMant == 0) ? (sign == .minus ? -.infinity : .infinity) : .nan
        }
        let unbiased = exp - 16383
        let hiPart = hiMant == 0 ? 0.0 : Double(sign: .plus, exponent: unbiased - 31, significand: Double(hiMant))
        let loPart = loMant == 0 ? 0.0 : Double(sign: .plus, exponent: unbiased - 63, significand: Double(loMant))
        let mag = hiPart + loPart
        return sign == .minus ? -mag : mag
    }

    public static func decode(_ data: [UInt8]) throws(AudioDecoderError) -> DecodedAudio {
        guard data.count >= 12 else {
            throw AudioDecoderError.truncatedData("AIFF file shorter than 12 bytes")
        }
        guard data.fourCC(at: 0) == "FORM" else {
            throw AudioDecoderError.invalidHeader("expected FORM header")
        }
        let formType = data.fourCC(at: 8)
        guard formType == "AIFF" || formType == "AIFC" else {
            throw AudioDecoderError.invalidHeader("expected AIFF or AIFC form type, got \(formType)")
        }

        var foundComm = false
        var channels = 0
        var numFrames = 0
        var bitsPerSample = 0
        var sampleRate = 0.0
        var littleEndian = false
        var isFloat32 = false
        var ssndRange: Range<Int>?

        var pos = 12
        while pos + 8 <= data.count {
            let chunkID = data.fourCC(at: pos)
            let chunkSize = Int(data.u32(at: pos + 4))
            let bodyStart = pos + 8
            let bodyEnd = min(data.count, bodyStart + chunkSize)

            if chunkID == "COMM" {
                guard bodyStart + 18 <= bodyEnd else {
                    throw AudioDecoderError.truncatedData("AIFF COMM chunk shorter than 18 bytes")
                }
                channels = Int(data.u16(at: bodyStart))
                numFrames = Int(data.u32(at: bodyStart + 2))
                bitsPerSample = Int(data.u16(at: bodyStart + 6))
                sampleRate = decodeExtended80(data, at: bodyStart + 8)
                if formType == "AIFC" && bodyStart + 22 <= bodyEnd {
                    let comp = data.fourCC(at: bodyStart + 18)
                    switch comp {
                    case "NONE", "twos":
                        littleEndian = false
                    case "sowt":
                        littleEndian = true
                    case "fl32", "FL32":
                        isFloat32 = true
                        littleEndian = false
                    default:
                        throw AudioDecoderError.unsupportedFormat("unsupported AIFC compression '\(comp)'")
                    }
                }
                foundComm = true
            } else if chunkID == "SSND" {
                guard bodyStart + 8 <= bodyEnd else {
                    throw AudioDecoderError.truncatedData("AIFF SSND chunk shorter than 8 bytes")
                }
                let ssndOffset = Int(data.u32(at: bodyStart))
                let soundStart = bodyStart + 8 + ssndOffset
                guard soundStart <= bodyEnd else {
                    throw AudioDecoderError.truncatedData("AIFF SSND offset past chunk end")
                }
                ssndRange = soundStart..<bodyEnd
            }

            let paddedSize = chunkSize + (chunkSize & 1)
            let nextPos = bodyStart + paddedSize
            if nextPos <= pos { break }
            pos = nextPos
        }

        guard foundComm else { throw AudioDecoderError.invalidHeader("missing AIFF COMM chunk") }
        guard channels > 0, sampleRate > 0, sampleRate.isFinite else {
            throw AudioDecoderError.invalidHeader("invalid AIFF COMM metadata")
        }
        if numFrames == 0 {
            return DecodedAudio(
                format: AudioFormat(sampleRate: sampleRate, channelCount: channels, bitDepth: bitsPerSample),
                frames: 0,
                samples: [],
                rawIntSamples: isFloat32 ? nil : []
            )
        }
        guard let range = ssndRange else { throw AudioDecoderError.invalidHeader("missing AIFF SSND chunk") }

        let bytesPerSample = (bitsPerSample + 7) / 8
        guard bytesPerSample > 0 else {
            throw AudioDecoderError.unsupportedFormat("unsupported AIFF bit depth \(bitsPerSample)")
        }
        let maxFramesInChunk = range.count / (bytesPerSample * channels)
        let frames = min(numFrames, maxFramesInChunk)
        let totalSamples = frames * channels

        var samples = [Double](repeating: 0.0, count: totalSamples)
        var rawInts: [Int32]? = isFloat32 ? nil : [Int32](repeating: 0, count: totalSamples)
        var offset = range.lowerBound

        if isFloat32 {
            guard bitsPerSample == 32 else {
                throw AudioDecoderError.unsupportedFormat("AIFC fl32 expects 32 bits")
            }
            for i in 0..<totalSamples {
                samples[i] = Double(Float(bitPattern: data.u32(at: offset)))
                offset += 4
            }
        } else {
            switch bitsPerSample {
            case 8:
                for i in 0..<totalSamples {
                    let s = Int32(Int8(bitPattern: data[offset]))
                    rawInts?[i] = s
                    samples[i] = Double(s) / 128.0
                    offset += 1
                }
            case 16:
                for i in 0..<totalSamples {
                    let raw = littleEndian ? data.u16le(at: offset) : data.u16(at: offset)
                    let s = Int32(Int16(bitPattern: raw))
                    rawInts?[i] = s
                    samples[i] = Double(s) / 32768.0
                    offset += 2
                }
            case 24:
                for i in 0..<totalSamples {
                    let u: UInt32
                    if littleEndian {
                        u = UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16)
                    } else {
                        u = (UInt32(data[offset]) << 16) | (UInt32(data[offset + 1]) << 8) | UInt32(data[offset + 2])
                    }
                    let s = Int32(bitPattern: u << 8) >> 8
                    rawInts?[i] = s
                    samples[i] = Double(s) / 8_388_608.0
                    offset += 3
                }
            case 32:
                for i in 0..<totalSamples {
                    let raw = littleEndian ? data.u32le(at: offset) : data.u32(at: offset)
                    let s = Int32(bitPattern: raw)
                    rawInts?[i] = s
                    samples[i] = Double(s) / 2_147_483_648.0
                    offset += 4
                }
            default:
                throw AudioDecoderError.unsupportedFormat("AIFF bit depth \(bitsPerSample) is not supported")
            }
        }

        return DecodedAudio(
            format: AudioFormat(sampleRate: sampleRate, channelCount: channels, bitDepth: bitsPerSample),
            frames: frames,
            samples: samples,
            rawIntSamples: rawInts
        )
    }
}

public enum AIFFEncoder {
    /// Encodes a finite Double as an 80-bit big-endian IEEE 754 extended float.
    public static func encodeExtended80(_ value: Double) -> [UInt8] {
        if value == 0.0 { return [UInt8](repeating: 0, count: 10) }
        let signBit: UInt16 = value < 0 ? 0x8000 : 0
        let v = abs(value)
        let exp = v.exponent
        let biasedExp = UInt16(exp + 16383) | signBit
        let scaled = Double(sign: .plus, exponent: 31, significand: v.significand)
        let hiMant = UInt32(scaled.rounded(.down))
        let rem = scaled - Double(hiMant)
        let loMant = UInt32(Double(sign: .plus, exponent: 32, significand: rem).rounded(.down))
        var out: [UInt8] = []
        out.reserveCapacity(10)
        out.append(u16: biasedExp)
        out.append(u32: hiMant)
        out.append(u32: loMant)
        return out
    }

    public static func encodePCM16(samples: [Double], sampleRate: Double, channels: Int) -> [UInt8] {
        encodePCM16(intSamples: samples.map(doubleToInt16), sampleRate: sampleRate, channels: channels)
    }

    public static func encodePCM16(intSamples: [Int16], sampleRate: Double, channels: Int) -> [UInt8] {
        let frames = channels > 0 ? intSamples.count / channels : 0
        let soundBytes = intSamples.count * 2
        var out = aiffHeader(channels: channels, frames: frames, bitsPerSample: 16, sampleRate: sampleRate, soundBytes: soundBytes)
        for s in intSamples {
            out.append(u16: UInt16(bitPattern: s))
        }
        return out
    }

    public static func encodePCM24(samples: [Double], sampleRate: Double, channels: Int) -> [UInt8] {
        encodePCM24(intSamples: samples.map(doubleToInt24), sampleRate: sampleRate, channels: channels)
    }

    public static func encodePCM24(intSamples: [Int32], sampleRate: Double, channels: Int) -> [UInt8] {
        let frames = channels > 0 ? intSamples.count / channels : 0
        let soundBytes = intSamples.count * 3
        var out = aiffHeader(channels: channels, frames: frames, bitsPerSample: 24, sampleRate: sampleRate, soundBytes: soundBytes)
        for s in intSamples {
            let u = UInt32(bitPattern: s)
            out.append(UInt8(truncatingIfNeeded: u >> 16))
            out.append(UInt8(truncatingIfNeeded: u >> 8))
            out.append(UInt8(truncatingIfNeeded: u))
        }
        if soundBytes & 1 != 0 { out.append(0) }
        return out
    }

    private static func aiffHeader(channels: Int, frames: Int, bitsPerSample: Int, sampleRate: Double, soundBytes: Int) -> [UInt8] {
        let ssndSize = 8 + soundBytes
        let formSize = 4 + (8 + 18) + (8 + ssndSize + (ssndSize & 1))
        var out: [UInt8] = []
        out.reserveCapacity(8 + formSize)
        out.append(ascii: "FORM")
        out.append(u32: UInt32(formSize))
        out.append(ascii: "AIFF")
        out.append(ascii: "COMM")
        out.append(u32: 18)
        out.append(u16: UInt16(channels))
        out.append(u32: UInt32(frames))
        out.append(u16: UInt16(bitsPerSample))
        out.append(contentsOf: encodeExtended80(sampleRate))
        out.append(ascii: "SSND")
        out.append(u32: UInt32(ssndSize))
        out.append(u32: 0) // offset
        out.append(u32: 0) // blockSize
        return out
    }
}

// MARK: - FLAC CRC, Bitstream, Decoder & Encoder

enum FLACCRC {
    static let crc8Table: [UInt8] = (0..<256).map { i -> UInt8 in
        var c = UInt8(i)
        for _ in 0..<8 {
            c = (c & 0x80) != 0 ? ((c << 1) ^ 0x07) : (c << 1)
        }
        return c
    }

    static let crc16Table: [UInt16] = (0..<256).map { i -> UInt16 in
        var c = UInt16(i) << 8
        for _ in 0..<8 {
            c = (c & 0x8000) != 0 ? ((c << 1) ^ 0x8005) : (c << 1)
        }
        return c
    }

    static func crc8(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        var crc: UInt8 = 0
        for b in bytes {
            crc = crc8Table[Int(crc ^ b)]
        }
        return crc
    }

    static func crc16(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for b in bytes {
            crc = (crc << 8) ^ crc16Table[Int((crc >> 8) ^ UInt16(b))]
        }
        return crc
    }
}

private struct FLACBitReader {
    let data: [UInt8]
    var bitPos: Int

    init(_ data: [UInt8], byteOffset: Int) {
        self.data = data
        self.bitPos = byteOffset * 8
    }

    var totalBits: Int { data.count * 8 }
    var bytePosition: Int { bitPos / 8 }
    var isByteAligned: Bool { (bitPos & 7) == 0 }
    var hasMoreBytes: Bool { bytePosition < data.count }

    mutating func alignToByte() {
        let rem = bitPos & 7
        if rem != 0 { bitPos += 8 - rem }
    }

    @inline(__always)
    mutating func readBit() throws(AudioDecoderError) -> UInt64 {
        guard bitPos < totalBits else {
            throw AudioDecoderError.truncatedData("unexpected end of FLAC bitstream")
        }
        let byte = data[bitPos >> 3]
        let shift = 7 - (bitPos & 7)
        bitPos += 1
        return UInt64((byte >> shift) & 1)
    }

    mutating func readBits(_ count: Int) throws(AudioDecoderError) -> UInt64 {
        guard count >= 0, count <= 64 else {
            throw AudioDecoderError.invalidBitstream("invalid bit read width \(count)")
        }
        guard count > 0 else { return 0 }
        guard bitPos + count <= totalBits else {
            throw AudioDecoderError.truncatedData("unexpected end of FLAC bitstream")
        }
        var value: UInt64 = 0
        var remaining = count
        while remaining > 0 {
            let byteIdx = bitPos >> 3
            let bitInByte = bitPos & 7
            let avail = 8 - bitInByte
            let take = min(remaining, avail)
            let shift = avail - take
            let mask: UInt8 = take == 8 ? 0xFF : UInt8((1 << take) - 1)
            let bits = (data[byteIdx] >> shift) & mask
            value = (value << UInt64(take)) | UInt64(bits)
            bitPos += take
            remaining -= take
        }
        return value
    }

    mutating func readSigned(_ bits: Int) throws(AudioDecoderError) -> Int64 {
        guard bits > 0, bits <= 64 else {
            throw AudioDecoderError.invalidBitstream("invalid signed bit width \(bits)")
        }
        let u = try readBits(bits)
        if bits == 64 { return Int64(bitPattern: u) }
        let shift = 64 - bits
        return Int64(bitPattern: u << UInt64(shift)) >> Int64(shift)
    }

    /// Counts zero bits until a terminating `1` bit.
    mutating func readUnary() throws(AudioDecoderError) -> Int {
        var count = 0
        while true {
            guard bitPos < totalBits else {
                throw AudioDecoderError.truncatedData("unterminated unary code in FLAC bitstream")
            }
            let byteIdx = bitPos >> 3
            let bitInByte = bitPos & 7
            if bitInByte == 0 && data[byteIdx] == 0 {
                count += 8
                bitPos += 8
                continue
            }
            let bit = (data[byteIdx] >> (7 - bitInByte)) & 1
            bitPos += 1
            if bit == 1 { return count }
            count += 1
        }
    }

    /// Reads FLAC's UTF-8 coded 31-bit or 36-bit integer (up to 7 bytes).
    mutating func readUTF8Int() throws(AudioDecoderError) -> UInt64 {
        let first = try readBits(8)
        if (first & 0x80) == 0 { return first }
        var leadingOnes = 0
        var probe: UInt64 = 0x80
        while (first & probe) != 0 && leadingOnes < 8 {
            leadingOnes += 1
            probe >>= 1
        }
        guard leadingOnes >= 2 && leadingOnes <= 7 else {
            throw AudioDecoderError.invalidBitstream("invalid UTF-8 coded frame/sample number")
        }
        let mask: UInt64 = leadingOnes == 7 ? 0 : ((1 << UInt64(7 - leadingOnes)) - 1)
        var value = first & mask
        for _ in 1..<leadingOnes {
            let cont = try readBits(8)
            guard (cont & 0xC0) == 0x80 else {
                throw AudioDecoderError.invalidBitstream("invalid UTF-8 continuation byte in FLAC header")
            }
            value = (value << 6) | (cont & 0x3F)
        }
        return value
    }
}

private struct FLACBitWriter {
    var bytes: [UInt8] = []
    private var curByte: UInt8 = 0
    private var bitsFilled: Int = 0

    mutating func writeBits(_ value: UInt64, count: Int) {
        guard count > 0 else { return }
        var remaining = count
        while remaining > 0 {
            let space = 8 - bitsFilled
            let take = min(remaining, space)
            let shift = remaining - take
            let mask: UInt64 = take == 64 ? UInt64.max : ((UInt64(1) << UInt64(take)) - 1)
            let chunk = UInt8((value >> UInt64(shift)) & mask)
            curByte = (curByte << UInt8(take)) | chunk
            bitsFilled += take
            remaining -= take
            if bitsFilled == 8 {
                bytes.append(curByte)
                curByte = 0
                bitsFilled = 0
            }
        }
    }

    mutating func writeSigned(_ value: Int64, bits: Int) {
        let mask: UInt64 = bits == 64 ? UInt64.max : ((UInt64(1) << UInt64(bits)) - 1)
        writeBits(UInt64(bitPattern: value) & mask, count: bits)
    }

    mutating func writeUnary(_ zeros: Int) {
        var z = zeros
        while z >= 32 {
            writeBits(0, count: 32)
            z -= 32
        }
        if z > 0 { writeBits(0, count: z) }
        writeBits(1, count: 1)
    }

    mutating func writeUTF8(_ value: UInt64) {
        if value < 0x80 {
            writeBits(value, count: 8)
        } else if value < 0x800 {
            writeBits(0xC0 | (value >> 6), count: 8)
            writeBits(0x80 | (value & 0x3F), count: 8)
        } else if value < 0x10000 {
            writeBits(0xE0 | (value >> 12), count: 8)
            writeBits(0x80 | ((value >> 6) & 0x3F), count: 8)
            writeBits(0x80 | (value & 0x3F), count: 8)
        } else if value < 0x200000 {
            writeBits(0xF0 | (value >> 18), count: 8)
            writeBits(0x80 | ((value >> 12) & 0x3F), count: 8)
            writeBits(0x80 | ((value >> 6) & 0x3F), count: 8)
            writeBits(0x80 | (value & 0x3F), count: 8)
        } else if value < 0x4000000 {
            writeBits(0xF8 | (value >> 24), count: 8)
            writeBits(0x80 | ((value >> 18) & 0x3F), count: 8)
            writeBits(0x80 | ((value >> 12) & 0x3F), count: 8)
            writeBits(0x80 | ((value >> 6) & 0x3F), count: 8)
            writeBits(0x80 | (value & 0x3F), count: 8)
        } else if value < 0x80000000 {
            writeBits(0xFC | (value >> 30), count: 8)
            writeBits(0x80 | ((value >> 24) & 0x3F), count: 8)
            writeBits(0x80 | ((value >> 18) & 0x3F), count: 8)
            writeBits(0x80 | ((value >> 12) & 0x3F), count: 8)
            writeBits(0x80 | ((value >> 6) & 0x3F), count: 8)
            writeBits(0x80 | (value & 0x3F), count: 8)
        } else {
            writeBits(0xFE, count: 8)
            writeBits(0x80 | ((value >> 30) & 0x3F), count: 8)
            writeBits(0x80 | ((value >> 24) & 0x3F), count: 8)
            writeBits(0x80 | ((value >> 18) & 0x3F), count: 8)
            writeBits(0x80 | ((value >> 12) & 0x3F), count: 8)
            writeBits(0x80 | ((value >> 6) & 0x3F), count: 8)
            writeBits(0x80 | (value & 0x3F), count: 8)
        }
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

public enum FLACDecoder {
    private struct StreamInfo {
        var minBlockSize: Int
        var maxBlockSize: Int
        var sampleRate: Int
        var channels: Int
        var bitsPerSample: Int
        var totalSamples: Int
    }

    public static func decode(_ data: [UInt8]) throws(AudioDecoderError) -> DecodedAudio {
        guard data.count >= 4, data.fourCC(at: 0) == "fLaC" else {
            throw AudioDecoderError.invalidHeader("expected 'fLaC' magic header")
        }

        var pos = 4
        var streamInfo: StreamInfo?
        var isLastBlock = false

        while !isLastBlock {
            guard pos + 4 <= data.count else {
                throw AudioDecoderError.truncatedData("truncated FLAC metadata block header")
            }
            let headerByte = data[pos]
            isLastBlock = (headerByte & 0x80) != 0
            let blockType = headerByte & 0x7F
            let blockLen = Int(data.u24(at: pos + 1))
            pos += 4
            guard pos + blockLen <= data.count else {
                throw AudioDecoderError.truncatedData("FLAC metadata block extends past EOF")
            }
            guard blockType != 127 else {
                throw AudioDecoderError.invalidHeader("invalid FLAC metadata block type 127")
            }

            if blockType == 0 {
                guard blockLen == 34 else {
                    throw AudioDecoderError.invalidHeader("STREAMINFO block must be 34 bytes, got \(blockLen)")
                }
                let minBlock = Int(data.u16(at: pos))
                let maxBlock = Int(data.u16(at: pos + 2))
                var br = FLACBitReader(data, byteOffset: pos + 10)
                let sr = Int(try br.readBits(20))
                let ch = Int(try br.readBits(3)) + 1
                let bps = Int(try br.readBits(5)) + 1
                let total = Int(try br.readBits(36))
                guard sr > 0, ch >= 1 && ch <= 8, bps >= 4 && bps <= 32 else {
                    throw AudioDecoderError.invalidHeader("invalid FLAC STREAMINFO parameters")
                }
                streamInfo = StreamInfo(
                    minBlockSize: minBlock,
                    maxBlockSize: maxBlock,
                    sampleRate: sr,
                    channels: ch,
                    bitsPerSample: bps,
                    totalSamples: total
                )
            }
            pos += blockLen
        }

        guard let info = streamInfo else {
            throw AudioDecoderError.invalidHeader("missing FLAC STREAMINFO block")
        }

        var reader = FLACBitReader(data, byteOffset: pos)
        var rawInts: [Int32] = []
        if info.totalSamples > 0 {
            rawInts.reserveCapacity(info.totalSamples * info.channels)
        }

        var channelBuffers: [[Int64]] = (0..<info.channels).map { _ in
            [Int64](repeating: 0, count: max(info.maxBlockSize, 4096))
        }

        while reader.hasMoreBytes {
            reader.alignToByte()
            if !reader.hasMoreBytes { break }
            let frameStart = reader.bytePosition

            // Frame header: 14-bit sync (0x3FFE), 1-bit reserved (0), 1-bit blocking strategy.
            let syncAndFlags = try reader.readBits(16)
            guard (syncAndFlags & 0xFFFE) == 0xFFF8 else {
                throw AudioDecoderError.invalidBitstream("invalid FLAC frame sync code 0x\(String(syncAndFlags, radix: 16))")
            }

            let blockSizeCode = Int(try reader.readBits(4))
            let sampleRateCode = Int(try reader.readBits(4))
            let channelAssign = Int(try reader.readBits(4))
            let sampleSizeCode = Int(try reader.readBits(3))
            let reservedBit = try reader.readBits(1)
            guard reservedBit == 0 else {
                throw AudioDecoderError.invalidBitstream("FLAC frame header reserved bit must be 0")
            }

            // UTF-8 coded frame or sample number.
            _ = try reader.readUTF8Int()

            let blockSize: Int
            switch blockSizeCode {
            case 1: blockSize = 192
            case 2...5: blockSize = 576 << (blockSizeCode - 2)
            case 6: blockSize = Int(try reader.readBits(8)) + 1
            case 7: blockSize = Int(try reader.readBits(16)) + 1
            case 8...15: blockSize = 256 << (blockSizeCode - 8)
            default:
                throw AudioDecoderError.invalidBitstream("reserved FLAC block size code 0")
            }

            let frameSampleRate: Int
            switch sampleRateCode {
            case 0: frameSampleRate = info.sampleRate
            case 1: frameSampleRate = 88_200
            case 2: frameSampleRate = 176_400
            case 3: frameSampleRate = 192_000
            case 4: frameSampleRate = 8_000
            case 5: frameSampleRate = 16_000
            case 6: frameSampleRate = 22_050
            case 7: frameSampleRate = 24_000
            case 8: frameSampleRate = 32_000
            case 9: frameSampleRate = 44_100
            case 10: frameSampleRate = 48_000
            case 11: frameSampleRate = 96_000
            case 12: frameSampleRate = Int(try reader.readBits(8)) * 1000
            case 13: frameSampleRate = Int(try reader.readBits(16))
            case 14: frameSampleRate = Int(try reader.readBits(16)) * 10
            default:
                throw AudioDecoderError.invalidBitstream("invalid FLAC sample rate code 15")
            }
            _ = frameSampleRate

            let frameChannels: Int
            if channelAssign <= 7 {
                frameChannels = channelAssign + 1
            } else if channelAssign <= 10 {
                frameChannels = 2
            } else {
                throw AudioDecoderError.invalidBitstream("reserved FLAC channel assignment \(channelAssign)")
            }
            guard frameChannels == info.channels else {
                throw AudioDecoderError.invalidBitstream("FLAC frame channel count mismatch")
            }

            let frameBps: Int
            switch sampleSizeCode {
            case 0: frameBps = info.bitsPerSample
            case 1: frameBps = 8
            case 2: frameBps = 12
            case 4: frameBps = 16
            case 5: frameBps = 20
            case 6: frameBps = 24
            case 7: frameBps = 32
            default:
                throw AudioDecoderError.invalidBitstream("reserved FLAC sample size code \(sampleSizeCode)")
            }

            let headerEnd = reader.bytePosition
            let expectedCRC8 = UInt8(try reader.readBits(8))
            let actualCRC8 = FLACCRC.crc8(data[frameStart..<headerEnd])
            guard actualCRC8 == expectedCRC8 else {
                throw AudioDecoderError.checksumMismatch("FLAC frame header CRC-8 mismatch (got \(actualCRC8), expected \(expectedCRC8))")
            }

            for ch in 0..<frameChannels {
                if channelBuffers[ch].count < blockSize {
                    channelBuffers[ch] = [Int64](repeating: 0, count: blockSize)
                }
                var subBps = frameBps
                if (channelAssign == 8 && ch == 1) || (channelAssign == 9 && ch == 0) || (channelAssign == 10 && ch == 1) {
                    subBps += 1
                }
                try decodeSubframe(&reader, out: &channelBuffers[ch], blockSize: blockSize, bitsPerSample: subBps)
            }

            // Channel decorrelation for stereo modes.
            if channelAssign == 8 {
                // Left-side: ch0 = left, ch1 = side -> right = left - side
                for i in 0..<blockSize {
                    channelBuffers[1][i] = channelBuffers[0][i] - channelBuffers[1][i]
                }
            } else if channelAssign == 9 {
                // Right-side: ch0 = side, ch1 = right -> left = right + side
                for i in 0..<blockSize {
                    channelBuffers[0][i] = channelBuffers[1][i] + channelBuffers[0][i]
                }
            } else if channelAssign == 10 {
                // Mid-side: ch0 = mid, ch1 = side
                for i in 0..<blockSize {
                    let side = channelBuffers[1][i]
                    let mid = (channelBuffers[0][i] << 1) + (side & 1)
                    channelBuffers[0][i] = (mid + side) >> 1
                    channelBuffers[1][i] = (mid - side) >> 1
                }
            }

            reader.alignToByte()
            let footerStart = reader.bytePosition
            let expectedCRC16 = UInt16(try reader.readBits(16))
            let actualCRC16 = FLACCRC.crc16(data[frameStart..<footerStart])
            guard actualCRC16 == expectedCRC16 else {
                throw AudioDecoderError.checksumMismatch("FLAC frame CRC-16 mismatch (got \(actualCRC16), expected \(expectedCRC16))")
            }

            // Append interleaved samples.
            for i in 0..<blockSize {
                for ch in 0..<frameChannels {
                    rawInts.append(Int32(truncatingIfNeeded: channelBuffers[ch][i]))
                }
            }

            if info.totalSamples > 0 && rawInts.count / info.channels >= info.totalSamples {
                break
            }
        }

        let frames = rawInts.count / info.channels
        let invScale = 1.0 / Double(Int64(1) << (info.bitsPerSample - 1))
        var samples = [Double](repeating: 0.0, count: rawInts.count)
        for i in 0..<rawInts.count {
            samples[i] = Double(rawInts[i]) * invScale
        }

        return DecodedAudio(
            format: AudioFormat(sampleRate: Double(info.sampleRate), channelCount: info.channels, bitDepth: info.bitsPerSample),
            frames: frames,
            samples: samples,
            rawIntSamples: rawInts
        )
    }

    private static func decodeSubframe(
        _ reader: inout FLACBitReader,
        out: inout [Int64],
        blockSize: Int,
        bitsPerSample: Int
    ) throws(AudioDecoderError) {
        let zeroPad = try reader.readBit()
        guard zeroPad == 0 else {
            throw AudioDecoderError.invalidBitstream("FLAC subframe padding bit must be 0")
        }
        let typeCode = Int(try reader.readBits(6))
        let hasWasted = try reader.readBit() != 0
        var wastedBits = 0
        if hasWasted {
            wastedBits = (try reader.readUnary()) + 1
        }
        let effectiveBps = bitsPerSample - wastedBits
        guard effectiveBps > 0 && effectiveBps <= 33 else {
            throw AudioDecoderError.invalidBitstream("invalid effective FLAC subframe bit depth \(effectiveBps)")
        }

        if typeCode == 0 {
            // CONSTANT
            let v = try reader.readSigned(effectiveBps)
            for i in 0..<blockSize { out[i] = v }
        } else if typeCode == 1 {
            // VERBATIM
            for i in 0..<blockSize {
                out[i] = try reader.readSigned(effectiveBps)
            }
        } else if typeCode >= 8 && typeCode <= 12 {
            // FIXED predictor
            let order = typeCode - 8
            guard order <= blockSize else {
                throw AudioDecoderError.invalidBitstream("FLAC FIXED order exceeds blockSize")
            }
            for i in 0..<order {
                out[i] = try reader.readSigned(effectiveBps)
            }
            try decodeResiduals(&reader, out: &out, blockSize: blockSize, predictorOrder: order)
            switch order {
            case 0:
                break
            case 1:
                for i in 1..<blockSize {
                    out[i] &+= out[i - 1]
                }
            case 2:
                for i in 2..<blockSize {
                    out[i] &+= (out[i - 1] << 1) &- out[i - 2]
                }
            case 3:
                for i in 3..<blockSize {
                    out[i] &+= 3 &* (out[i - 1] &- out[i - 2]) &+ out[i - 3]
                }
            case 4:
                for i in 4..<blockSize {
                    out[i] &+= (out[i - 1] &+ out[i - 3]) &* 4 &- 6 &* out[i - 2] &- out[i - 4]
                }
            default:
                break
            }
        } else if typeCode >= 32 && typeCode <= 63 {
            // LPC predictor
            let order = typeCode - 31
            guard order <= blockSize else {
                throw AudioDecoderError.invalidBitstream("FLAC LPC order exceeds blockSize")
            }
            for i in 0..<order {
                out[i] = try reader.readSigned(effectiveBps)
            }
            let precCode = Int(try reader.readBits(4))
            guard precCode != 15 else {
                throw AudioDecoderError.invalidBitstream("invalid FLAC LPC precision 15")
            }
            let precision = precCode + 1
            let qlpShift = Int(try reader.readSigned(5))
            guard qlpShift >= 0 else {
                throw AudioDecoderError.invalidBitstream("negative FLAC LPC shift \(qlpShift)")
            }
            var coeffs = [Int64](repeating: 0, count: order)
            for j in 0..<order {
                coeffs[j] = try reader.readSigned(precision)
            }
            try decodeResiduals(&reader, out: &out, blockSize: blockSize, predictorOrder: order)
            for i in order..<blockSize {
                var sum: Int64 = 0
                for j in 0..<order {
                    sum &+= coeffs[j] &* out[i - 1 - j]
                }
                out[i] &+= (sum >> qlpShift)
            }
        } else {
            throw AudioDecoderError.invalidBitstream("reserved FLAC subframe type \(typeCode)")
        }

        if wastedBits > 0 {
            for i in 0..<blockSize {
                out[i] <<= wastedBits
            }
        }
    }

    private static func decodeResiduals(
        _ reader: inout FLACBitReader,
        out: inout [Int64],
        blockSize: Int,
        predictorOrder: Int
    ) throws(AudioDecoderError) {
        let method = Int(try reader.readBits(2))
        guard method == 0 || method == 1 else {
            throw AudioDecoderError.invalidBitstream("reserved FLAC residual coding method \(method)")
        }
        let paramBits = method == 0 ? 4 : 5
        let escapeCode = method == 0 ? 15 : 31
        let partitionOrder = Int(try reader.readBits(4))
        let numPartitions = 1 << partitionOrder
        guard blockSize % numPartitions == 0 else {
            throw AudioDecoderError.invalidBitstream("FLAC blockSize \(blockSize) not divisible by \(numPartitions) partitions")
        }
        let basePartitionSamples = blockSize >> partitionOrder
        guard basePartitionSamples >= predictorOrder else {
            throw AudioDecoderError.invalidBitstream("FLAC partition smaller than predictor order")
        }

        var sampleIndex = predictorOrder
        for p in 0..<numPartitions {
            let count = p == 0 ? (basePartitionSamples - predictorOrder) : basePartitionSamples
            let riceParam = Int(try reader.readBits(paramBits))
            if riceParam == escapeCode {
                let rawBits = Int(try reader.readBits(5))
                if rawBits == 0 {
                    for _ in 0..<count {
                        out[sampleIndex] = 0
                        sampleIndex += 1
                    }
                } else {
                    for _ in 0..<count {
                        out[sampleIndex] = try reader.readSigned(rawBits)
                        sampleIndex += 1
                    }
                }
            } else {
                for _ in 0..<count {
                    let q = UInt64(try reader.readUnary())
                    let r = riceParam > 0 ? (try reader.readBits(riceParam)) : 0
                    let folded = (q << UInt64(riceParam)) | r
                    let signedVal: Int64 = (folded & 1) == 0 ? Int64(folded >> 1) : -Int64(folded >> 1) - 1
                    out[sampleIndex] = signedVal
                    sampleIndex += 1
                }
            }
        }
    }
}

public enum FLACEncoder {
    public enum SubframeMode: Equatable, Sendable {
        case auto
        case constant
        case verbatim
        case fixed(order: Int)
        case lpc(order: Int)
    }

    public struct Options: Equatable, Sendable {
        public var blockSize: Int
        public var subframeMode: SubframeMode
        public var allowMidSide: Bool
        public var useRice2: Bool

        public init(
            blockSize: Int = 1024,
            subframeMode: SubframeMode = .auto,
            allowMidSide: Bool = true,
            useRice2: Bool = false
        ) {
            self.blockSize = blockSize
            self.subframeMode = subframeMode
            self.allowMidSide = allowMidSide
            self.useRice2 = useRice2
        }
    }

    public static func encode(
        samples: [Double],
        sampleRate: Int,
        channels: Int,
        bitDepth: Int = 16,
        options: Options = Options()
    ) throws(AudioDecoderError) -> [UInt8] {
        guard bitDepth == 16 || bitDepth == 24 else {
            throw AudioDecoderError.unsupportedFormat("FLACEncoder supports 16-bit or 24-bit encoding")
        }
        let ints: [Int32]
        if bitDepth == 16 {
            ints = samples.map { Int32(doubleToInt16($0)) }
        } else {
            ints = samples.map(doubleToInt24)
        }
        return try encode(intSamples: ints, sampleRate: sampleRate, channels: channels, bitDepth: bitDepth, options: options)
    }

    public static func encode(
        intSamples: [Int32],
        sampleRate: Int,
        channels: Int,
        bitDepth: Int = 16,
        options: Options = Options()
    ) throws(AudioDecoderError) -> [UInt8] {
        guard channels >= 1 && channels <= 8 else {
            throw AudioDecoderError.unsupportedFormat("FLAC supports 1..8 channels")
        }
        guard sampleRate > 0 && sampleRate <= 655_350 else {
            throw AudioDecoderError.unsupportedFormat("FLAC sample rate out of range")
        }
        guard bitDepth >= 8 && bitDepth <= 24 else {
            throw AudioDecoderError.unsupportedFormat("FLACEncoder supports 8..24 bit depth")
        }
        let totalFrames = intSamples.count / channels
        let blockSize = max(16, min(options.blockSize, 65535))

        var out: [UInt8] = []
        out.append(ascii: "fLaC")

        // STREAMINFO metadata block (isLast = 1, type = 0, length = 34)
        out.append(0x80)
        out.append(u24be: 34)
        let minBlock = totalFrames > 0 ? min(blockSize, totalFrames) : blockSize
        out.append(u16: UInt16(minBlock))
        out.append(u16: UInt16(blockSize))
        out.append(u24be: 0) // minFrameSize unknown
        out.append(u24be: 0) // maxFrameSize unknown
        var infoBits = FLACBitWriter()
        infoBits.writeBits(UInt64(sampleRate), count: 20)
        infoBits.writeBits(UInt64(channels - 1), count: 3)
        infoBits.writeBits(UInt64(bitDepth - 1), count: 5)
        infoBits.writeBits(UInt64(totalFrames), count: 36)
        infoBits.alignToByte()
        out.append(contentsOf: infoBits.bytes)
        out.append(contentsOf: [UInt8](repeating: 0, count: 16)) // MD5 (0 = unset)

        var frameOffset = 0
        var frameNumber: UInt64 = 0
        while frameOffset < totalFrames {
            let n = min(blockSize, totalFrames - frameOffset)
            var chData: [[Int64]] = (0..<channels).map { _ in [Int64](repeating: 0, count: n) }
            for i in 0..<n {
                let base = (frameOffset + i) * channels
                for c in 0..<channels {
                    chData[c][i] = Int64(intSamples[base + c])
                }
            }

            let useMidSide = (channels == 2 && options.allowMidSide)
            let channelAssign: Int = useMidSide ? 10 : (channels - 1)
            if useMidSide {
                for i in 0..<n {
                    let l = chData[0][i]
                    let r = chData[1][i]
                    chData[0][i] = (l + r) >> 1
                    chData[1][i] = l - r
                }
            }

            var fw = FLACBitWriter()
            // Sync + fixed blocking strategy (0xFFF8)
            fw.writeBits(0xFFF8, count: 16)

            // Block size code
            let bsCode = blockSizeHeaderCode(n)
            fw.writeBits(UInt64(bsCode), count: 4)

            // Sample rate code (0 = from STREAMINFO)
            fw.writeBits(0, count: 4)

            // Channel assignment
            fw.writeBits(UInt64(channelAssign), count: 4)

            // Sample size code
            let ssCode: UInt64
            switch bitDepth {
            case 8: ssCode = 1
            case 12: ssCode = 2
            case 16: ssCode = 4
            case 20: ssCode = 5
            case 24: ssCode = 6
            default: ssCode = 0
            }
            fw.writeBits(ssCode, count: 3)
            fw.writeBits(0, count: 1) // reserved

            fw.writeUTF8(frameNumber)
            if bsCode == 6 {
                fw.writeBits(UInt64(n - 1), count: 8)
            } else if bsCode == 7 {
                fw.writeBits(UInt64(n - 1), count: 16)
            }

            fw.alignToByte()
            let crc8 = FLACCRC.crc8(fw.bytes[...])
            fw.writeBits(UInt64(crc8), count: 8)

            for c in 0..<channels {
                let subBps = (useMidSide && c == 1) ? (bitDepth + 1) : bitDepth
                encodeSubframe(&fw, samples: chData[c], bps: subBps, options: options)
            }

            fw.alignToByte()
            let crc16 = FLACCRC.crc16(fw.bytes[...])
            fw.writeBits(UInt64(crc16), count: 16)
            fw.alignToByte()
            out.append(contentsOf: fw.bytes)

            frameOffset += n
            frameNumber += 1
        }

        return out
    }

    private static func blockSizeHeaderCode(_ n: Int) -> Int {
        switch n {
        case 192: return 1
        case 576: return 2
        case 1152: return 3
        case 2304: return 4
        case 4608: return 5
        case 256: return 8
        case 512: return 9
        case 1024: return 10
        case 2048: return 11
        case 4096: return 12
        case 8192: return 13
        case 16384: return 14
        case 32768: return 15
        default: return n <= 256 ? 6 : 7
        }
    }

    private static func isAllConstant(_ samples: [Int64]) -> Bool {
        guard let first = samples.first else { return true }
        for s in samples where s != first { return false }
        return true
    }

    private static func encodeSubframe(_ fw: inout FLACBitWriter, samples: [Int64], bps: Int, options: Options) {
        let n = samples.count
        switch options.subframeMode {
        case .constant:
            if isAllConstant(samples) {
                writeConstant(&fw, value: samples[0], bps: bps)
            } else {
                writeVerbatim(&fw, samples: samples, bps: bps)
            }
        case .verbatim:
            writeVerbatim(&fw, samples: samples, bps: bps)
        case .fixed(let order):
            let clampedOrder = min(max(0, order), min(4, n))
            writeFixed(&fw, samples: samples, bps: bps, order: clampedOrder, useRice2: options.useRice2)
        case .lpc(let order):
            let clampedOrder = min(max(1, order), min(12, max(1, n - 1)))
            if n > clampedOrder {
                writeLPC(&fw, samples: samples, bps: bps, order: clampedOrder, useRice2: options.useRice2)
            } else {
                writeVerbatim(&fw, samples: samples, bps: bps)
            }
        case .auto:
            if isAllConstant(samples) {
                writeConstant(&fw, value: samples[0], bps: bps)
                return
            }
            if n <= 8 {
                writeVerbatim(&fw, samples: samples, bps: bps)
                return
            }
            // Pick best FIXED predictor order 0..4 by minimum sum of absolute residuals.
            var bestOrder = 0
            var bestScore = UInt64.max
            for order in 0...min(4, n - 1) {
                let res = fixedResiduals(samples, order: order)
                var score: UInt64 = 0
                for r in res {
                    score &+= UInt64(r < 0 ? -r : r)
                }
                if score < bestScore {
                    bestScore = score
                    bestOrder = order
                }
            }
            writeFixed(&fw, samples: samples, bps: bps, order: bestOrder, useRice2: options.useRice2)
        }
    }

    private static func writeConstant(_ fw: inout FLACBitWriter, value: Int64, bps: Int) {
        fw.writeBits(0, count: 1) // zero pad
        fw.writeBits(0, count: 6) // CONSTANT
        fw.writeBits(0, count: 1) // no wasted bits
        fw.writeSigned(value, bits: bps)
    }

    private static func writeVerbatim(_ fw: inout FLACBitWriter, samples: [Int64], bps: Int) {
        fw.writeBits(0, count: 1)
        fw.writeBits(1, count: 6) // VERBATIM
        fw.writeBits(0, count: 1)
        for s in samples {
            fw.writeSigned(s, bits: bps)
        }
    }

    private static func fixedResiduals(_ s: [Int64], order: Int) -> [Int64] {
        let n = s.count
        var res: [Int64] = []
        res.reserveCapacity(max(0, n - order))
        switch order {
        case 0:
            for i in 0..<n { res.append(s[i]) }
        case 1:
            for i in 1..<n { res.append(s[i] &- s[i - 1]) }
        case 2:
            for i in 2..<n { res.append(s[i] &- ((s[i - 1] << 1) &- s[i - 2])) }
        case 3:
            for i in 3..<n { res.append(s[i] &- (3 &* (s[i - 1] &- s[i - 2]) &+ s[i - 3])) }
        default:
            for i in 4..<n { res.append(s[i] &- ((s[i - 1] &+ s[i - 3]) &* 4 &- 6 &* s[i - 2] &- s[i - 4])) }
        }
        return res
    }

    private static func writeFixed(_ fw: inout FLACBitWriter, samples: [Int64], bps: Int, order: Int, useRice2: Bool) {
        fw.writeBits(0, count: 1)
        fw.writeBits(UInt64(8 + order), count: 6)
        fw.writeBits(0, count: 1)
        for i in 0..<order {
            fw.writeSigned(samples[i], bits: bps)
        }
        let residuals = fixedResiduals(samples, order: order)
        writeResiduals(&fw, residuals: residuals, blockSize: samples.count, predictorOrder: order, useRice2: useRice2)
    }

    private static func writeLPC(_ fw: inout FLACBitWriter, samples: [Int64], bps: Int, order: Int, useRice2: Bool) {
        let n = samples.count
        // Compute autocorrelation lags 0...order.
        var r = [Double](repeating: 0.0, count: order + 1)
        for lag in 0...order {
            var sum = 0.0
            for i in lag..<n {
                sum += Double(samples[i]) * Double(samples[i - lag])
            }
            r[lag] = sum
        }

        // Levinson-Durbin recursion for LPC coefficients.
        var lpc = [Double](repeating: 0.0, count: order)
        if r[0] > 1e-12 {
            var err = r[0]
            var prev = [Double](repeating: 0.0, count: order)
            for k in 0..<order {
                var acc = r[k + 1]
                for j in 0..<k { acc -= lpc[j] * r[k - j] }
                let refl = min(max(acc / err, -0.99), 0.99)
                for j in 0..<k { prev[j] = lpc[j] - refl * lpc[k - 1 - j] }
                prev[k] = refl
                for j in 0...k { lpc[j] = prev[j] }
                err *= (1.0 - refl * refl)
                if err <= 1e-12 { break }
            }
        }

        // Quantize coefficients to 12-bit signed integers with shift in 0...15.
        let precision = 12
        let maxCoeff = (1 << (precision - 1)) - 1
        var maxAbs = 0.0
        for c in lpc { maxAbs = max(maxAbs, abs(c)) }
        var shift = 10
        while shift > 0 && maxAbs * Double(1 << shift) > Double(maxCoeff) {
            shift -= 1
        }
        while shift < 15 && maxAbs > 0 && maxAbs * Double(1 << (shift + 1)) <= Double(maxCoeff) {
            shift += 1
        }
        let scale = Double(1 << shift)
        var qCoeffs = [Int64](repeating: 0, count: order)
        for j in 0..<order {
            let q = Int64((lpc[j] * scale).rounded())
            qCoeffs[j] = min(max(q, Int64(-maxCoeff)), Int64(maxCoeff))
        }

        // Compute exact integer residuals using the quantized predictor.
        var residuals: [Int64] = []
        residuals.reserveCapacity(n - order)
        for i in order..<n {
            var sum: Int64 = 0
            for j in 0..<order {
                sum &+= qCoeffs[j] &* samples[i - 1 - j]
            }
            residuals.append(samples[i] &- (sum >> shift))
        }

        fw.writeBits(0, count: 1)
        fw.writeBits(UInt64(31 + order), count: 6)
        fw.writeBits(0, count: 1)
        for i in 0..<order {
            fw.writeSigned(samples[i], bits: bps)
        }
        fw.writeBits(UInt64(precision - 1), count: 4)
        fw.writeSigned(Int64(shift), bits: 5)
        for j in 0..<order {
            fw.writeSigned(qCoeffs[j], bits: precision)
        }
        writeResiduals(&fw, residuals: residuals, blockSize: n, predictorOrder: order, useRice2: useRice2)
    }

    private static func writeResiduals(
        _ fw: inout FLACBitWriter,
        residuals: [Int64],
        blockSize: Int,
        predictorOrder: Int,
        useRice2: Bool
    ) {
        let method = useRice2 ? 1 : 0
        let paramBits = useRice2 ? 5 : 4
        let escapeCode = useRice2 ? 31 : 15
        let maxParam = escapeCode - 1

        // Single partition (partition order 0) is always valid when blockSize >= predictorOrder.
        fw.writeBits(UInt64(method), count: 2)
        fw.writeBits(0, count: 4) // partition order 0

        if residuals.isEmpty {
            fw.writeBits(0, count: paramBits)
            return
        }

        var sumFolded: UInt64 = 0
        var maxFolded: UInt64 = 0
        for r in residuals {
            let folded: UInt64 = r >= 0 ? UInt64(r) << 1 : (UInt64(-r) << 1) - 1
            sumFolded &+= folded
            if folded > maxFolded { maxFolded = folded }
        }
        let mean = sumFolded / UInt64(residuals.count)
        var k = 0
        var m = mean
        while m > 0 && k < maxParam {
            m >>= 1
            k += 1
        }
        // Prevent excessive unary quotients by raising k or falling back to escape raw coding.
        while (maxFolded >> UInt64(k)) > 64 && k < maxParam {
            k += 1
        }

        if (maxFolded >> UInt64(k)) > 256 {
            // Use escape raw bits encoding.
            var maxMag: UInt64 = 0
            for r in residuals {
                let mag = UInt64(r < 0 ? -r : r)
                if mag > maxMag { maxMag = mag }
            }
            var rawBits = 1
            while rawBits < 31 && (UInt64(1) << UInt64(rawBits - 1)) <= maxMag {
                rawBits += 1
            }
            fw.writeBits(UInt64(escapeCode), count: paramBits)
            fw.writeBits(UInt64(rawBits), count: 5)
            for r in residuals {
                fw.writeSigned(r, bits: rawBits)
            }
        } else {
            fw.writeBits(UInt64(k), count: paramBits)
            let remMask: UInt64 = k == 0 ? 0 : ((UInt64(1) << UInt64(k)) - 1)
            for r in residuals {
                let folded: UInt64 = r >= 0 ? UInt64(r) << 1 : (UInt64(-r) << 1) - 1
                let q = Int(folded >> UInt64(k))
                fw.writeUnary(q)
                if k > 0 {
                    fw.writeBits(folded & remMask, count: k)
                }
            }
        }
    }
}
