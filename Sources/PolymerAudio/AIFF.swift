// AIFF and AIFC: PCM of 8 to 32 bits, little-endian "sowt", 32-bit float
// "fl32", the 80-bit extended sample rate, NAME/AUTH/ANNO/(c) tags and an
// embedded ID3 chunk. Decoding is bounds-checked, and `AIFFSource` streams
// from the SSND chunk the same way `WAVSource` streams from `data`.
import PolymerBase
import PolymerPlatform

@inline(__always) private func aiffFourCC(_ bytes: [UInt8], _ at: Int) -> String {
    guard at >= 0, at + 4 <= bytes.count else { return "" }
    return String(decoding: bytes[at..<(at + 4)], as: UTF8.self)
}

public enum AIFFDecoder {
    /// The big-endian 80-bit IEEE 754 extended float used by AIFF's COMM.
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
        let magnitude = hiPart + loPart
        return sign == .minus ? -magnitude : magnitude
    }

    /// The COMM chunk plus where the samples live, for `AIFFSource`.
    struct Header {
        var rate = 0.0
        var channels = 0
        var bits = 0
        var frames = 0
        var soundStart = 0
        var soundBytes = 0
        var littleEndian = false
        var isFloat = false
        var metadata = AudioMetadata()
    }

    static func parseHeader(_ data: [UInt8]) throws(AudioDecoderError) -> Header {
        guard data.count >= 12 else { throw .truncatedData("AIFF file shorter than 12 bytes") }
        guard aiffFourCC(data, 0) == "FORM" else { throw .invalidHeader("expected a FORM header") }
        let formType = aiffFourCC(data, 8)
        guard formType == "AIFF" || formType == "AIFC" else {
            throw .invalidHeader("expected AIFF or AIFC, got '\(formType)'")
        }

        var h = Header()
        var foundComm = false
        var ssnd: Range<Int>?
        var pos = 12
        while pos + 8 <= data.count {
            let id = aiffFourCC(data, pos)
            let size = Int(data.u32(at: pos + 4))
            let body = pos + 8
            let end = min(data.count, body + size)
            switch id {
            case "COMM":
                guard body + 18 <= end else { throw .truncatedData("AIFF COMM chunk shorter than 18 bytes") }
                h.channels = Int(data.u16(at: body))
                h.frames = Int(data.u32(at: body + 2))
                h.bits = Int(data.u16(at: body + 6))
                h.rate = decodeExtended80(data, at: body + 8)
                if formType == "AIFC", body + 22 <= end {
                    switch aiffFourCC(data, body + 18) {
                    case "NONE", "twos": break
                    case "sowt": h.littleEndian = true
                    case "fl32", "FL32": h.isFloat = true
                    case let other: throw .unsupportedFormat("AIFC compression '\(other)' is not decoded")
                    }
                }
                foundComm = true
            case "SSND":
                guard body + 8 <= end else { throw .truncatedData("AIFF SSND chunk shorter than 8 bytes") }
                let start = body + 8 + Int(data.u32(at: body))
                guard start <= end else { throw .truncatedData("AIFF SSND offset runs past its chunk") }
                ssnd = start..<end
            case "NAME":
                h.metadata.title = tagText(data, body, end)
            case "AUTH":
                h.metadata.artist = tagText(data, body, end)
            case "ANNO":
                h.metadata.comment = tagText(data, body, end)
            case "(c) ":
                h.metadata.extra["COPYRIGHT"] = tagText(data, body, end)
            case "ID3 ", "id3 ":
                ID3v2.read(Array(data[body..<end]), into: &h.metadata)
            default: break
            }
            let next = body + size + (size & 1)
            if next <= pos { break }
            pos = next
        }

        guard foundComm else { throw .invalidHeader("AIFF file has no COMM chunk") }
        guard h.channels > 0, h.rate > 0, h.rate.isFinite else {
            throw .invalidHeader("AIFF COMM says \(h.channels) channels at \(h.rate) Hz")
        }
        guard let range = ssnd else { throw .invalidHeader("AIFF file has no SSND chunk") }
        h.soundStart = range.lowerBound
        h.soundBytes = range.count
        let unit = (h.bits + 7) / 8
        guard unit > 0 else { throw .unsupportedFormat("AIFF bit depth \(h.bits)") }
        if h.frames == 0 { h.frames = range.count / (unit * h.channels) }
        h.frames = min(h.frames, range.count / (unit * h.channels))
        return h
    }

    private static func tagText(_ data: [UInt8], _ from: Int, _ to: Int) -> String? {
        guard from < to else { return nil }
        var text = String(decoding: data[from..<to], as: UTF8.self)
        while let last = text.last, last == "\0" || last == " " || last == "\r" || last == "\n" { text.removeLast() }
        return text.isEmpty ? nil : text
    }

    public static func decode(_ data: [UInt8]) throws(AudioDecoderError) -> DecodedAudio {
        let h = try parseHeader(data)
        let format = DecodedAudioFormat(sampleRate: h.rate, channelCount: h.channels, bitDepth: h.bits)
        let total = h.frames * h.channels
        if total == 0 { return DecodedAudio(format: format, frames: 0, samples: [], rawIntSamples: h.isFloat ? nil : []) }

        let unit = (h.bits + 7) / 8
        var samples = [Double](repeating: 0, count: total)
        var rawInts: [Int32]? = h.isFloat ? nil : [Int32](repeating: 0, count: total)
        var at = h.soundStart

        if h.isFloat {
            guard h.bits == 32 else { throw .unsupportedFormat("AIFC fl32 expects 32 bits") }
            for i in 0..<total {
                samples[i] = Double(Float(bitPattern: data.u32(at: at)))
                at += 4
            }
        } else {
            switch h.bits {
            case 8:
                for i in 0..<total {
                    let s = Int32(Int8(bitPattern: data[at]))
                    rawInts?[i] = s
                    samples[i] = Double(s) / 128.0
                    at += 1
                }
            case 16:
                for i in 0..<total {
                    let raw = h.littleEndian ? data.u16le(at: at) : data.u16(at: at)
                    let s = Int32(Int16(bitPattern: raw))
                    rawInts?[i] = s
                    samples[i] = Double(s) / 32768.0
                    at += 2
                }
            case 24:
                for i in 0..<total {
                    let u: UInt32 = h.littleEndian
                        ? UInt32(data[at]) | UInt32(data[at + 1]) << 8 | UInt32(data[at + 2]) << 16
                        : UInt32(data[at]) << 16 | UInt32(data[at + 1]) << 8 | UInt32(data[at + 2])
                    let s = Int32(bitPattern: u << 8) >> 8
                    rawInts?[i] = s
                    samples[i] = Double(s) / 8_388_608.0
                    at += 3
                }
            case 32:
                for i in 0..<total {
                    let raw = h.littleEndian ? data.u32le(at: at) : data.u32(at: at)
                    let s = Int32(bitPattern: raw)
                    rawInts?[i] = s
                    samples[i] = Double(s) / 2_147_483_648.0
                    at += 4
                }
            default:
                throw .unsupportedFormat("AIFF bit depth \(h.bits) is not decoded")
            }
        }
        return DecodedAudio(format: format, frames: h.frames, samples: samples, rawIntSamples: rawInts)
    }
}

/// An AIFF/AIFC file as a seekable `AudioSource`, reading straight from `bytes`.
public final class AIFFSource: AudioSource, @unchecked Sendable {
    public let format: AudioFormat
    public let bitsPerSample: Int
    public let metadata: AudioMetadata
    public var frameCount: Int? { frames }
    public private(set) var position = 0

    let bytes: [UInt8]
    let frames: Int
    let soundStart: Int
    let isFloat: Bool
    let littleEndian: Bool
    let bytesPerSample: Int
    let blockAlign: Int

    public init(_ bytes: [UInt8]) throws(AudioError) {
        let h: AIFFDecoder.Header
        do { h = try AIFFDecoder.parseHeader(bytes) } catch { throw AudioError("\(error)") }
        self.bytes = bytes
        self.format = AudioFormat(sampleRate: Int(h.rate.rounded()), channels: h.channels)
        self.bitsPerSample = h.bits
        self.metadata = h.metadata
        self.frames = h.frames
        self.soundStart = h.soundStart
        self.isFloat = h.isFloat
        self.littleEndian = h.littleEndian
        self.bytesPerSample = (h.bits + 7) / 8
        self.blockAlign = self.bytesPerSample * h.channels
    }

    public static func readMetadata(_ bytes: [UInt8]) -> AudioMetadata {
        ((try? AIFFDecoder.parseHeader(bytes))?.metadata) ?? AudioMetadata()
    }

    public func seek(toFrame frame: Int) throws(AudioError) { position = max(0, min(frame, frames)) }

    public func read(into buffer: UnsafeMutablePointer<Float>, frames want: Int) -> Int {
        let n = max(0, min(want, frames - position))
        if n == 0 { return 0 }
        let count = n * format.channels
        let start = soundStart + position * blockAlign
        let unit = bytesPerSample
        let little = littleEndian
        bytes.withUnsafeBufferPointer { raw in
            let p = raw.baseAddress! + start
            if isFloat {
                for i in 0..<count {
                    let b = p + i * 4
                    let u = little
                        ? UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
                        : UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
                    buffer[i] = Float(bitPattern: u)
                }
            } else {
                switch unit {
                case 1:
                    for i in 0..<count { buffer[i] = Float(Int8(bitPattern: p[i])) * (1 / 128) }
                case 2:
                    for i in 0..<count {
                        let b = p + i * 2
                        let u = little ? UInt16(b[0]) | UInt16(b[1]) << 8 : UInt16(b[0]) << 8 | UInt16(b[1])
                        buffer[i] = Float(Int16(bitPattern: u)) * (1 / 32768)
                    }
                case 3:
                    for i in 0..<count {
                        let b = p + i * 3
                        let u: UInt32 = little
                            ? UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16
                            : UInt32(b[0]) << 16 | UInt32(b[1]) << 8 | UInt32(b[2])
                        buffer[i] = Float(Int32(bitPattern: u << 8) >> 8) * (1 / 8_388_608)
                    }
                default:
                    for i in 0..<count {
                        let b = p + i * 4
                        let u = little
                            ? UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
                            : UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
                        buffer[i] = Float(Double(Int32(bitPattern: u)) * (1 / 2_147_483_648))
                    }
                }
            }
        }
        position += n
        return n
    }
}

public enum AIFFEncoder {
    /// Encodes a finite value as an 80-bit big-endian extended float.
    public static func encodeExtended80(_ value: Double) -> [UInt8] {
        if value == 0.0 { return [UInt8](repeating: 0, count: 10) }
        let signBit: UInt16 = value < 0 ? 0x8000 : 0
        let v = abs(value)
        let biasedExp = UInt16(v.exponent + 16383) | signBit
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

    private static func int16(_ s: Float) -> Int16 {
        Int16(max(-32768, min(32767, (Double(s) * 32768).rounded())))
    }

    private static func int24(_ s: Float) -> Int32 {
        Int32(max(-8_388_608, min(8_388_607, (Double(s) * 8_388_608).rounded())))
    }

    public static func encodePCM16(_ samples: [Float], sampleRate: Int, channels: Int,
                                   metadata: AudioMetadata? = nil) -> [UInt8] {
        encodePCM16(intSamples: samples.map(int16), sampleRate: sampleRate, channels: channels, metadata: metadata)
    }

    public static func encodePCM16(intSamples: [Int16], sampleRate: Int, channels: Int,
                                   metadata: AudioMetadata? = nil) -> [UInt8] {
        var out = header(channels: channels, frames: channels > 0 ? intSamples.count / channels : 0,
                         bits: 16, sampleRate: Double(sampleRate), soundBytes: intSamples.count * 2,
                         metadata: metadata)
        for s in intSamples { out.append(u16: UInt16(bitPattern: s)) }
        if intSamples.count * 2 & 1 != 0 { out.append(0) }
        return out
    }

    public static func encodePCM24(_ samples: [Float], sampleRate: Int, channels: Int,
                                   metadata: AudioMetadata? = nil) -> [UInt8] {
        encodePCM24(intSamples: samples.map(int24), sampleRate: sampleRate, channels: channels, metadata: metadata)
    }

    public static func encodePCM24(intSamples: [Int32], sampleRate: Int, channels: Int,
                                   metadata: AudioMetadata? = nil) -> [UInt8] {
        var out = header(channels: channels, frames: channels > 0 ? intSamples.count / channels : 0,
                         bits: 24, sampleRate: Double(sampleRate), soundBytes: intSamples.count * 3,
                         metadata: metadata)
        for s in intSamples {
            let u = UInt32(bitPattern: s)
            out.append(UInt8(truncatingIfNeeded: u >> 16))
            out.append(UInt8(truncatingIfNeeded: u >> 8))
            out.append(UInt8(truncatingIfNeeded: u))
        }
        if intSamples.count * 3 & 1 != 0 { out.append(0) }
        return out
    }

    /// FORM, COMM, the optional text chunks, then SSND's 8-byte offset/blocksize.
    private static func header(channels: Int, frames: Int, bits: Int, sampleRate: Double,
                               soundBytes: Int, metadata: AudioMetadata?) -> [UInt8] {
        var chunks: [UInt8] = []
        chunks.append(contentsOf: Array("COMM".utf8))
        chunks.append(u32: 18)
        chunks.append(u16: UInt16(channels))
        chunks.append(u32: UInt32(frames))
        chunks.append(u16: UInt16(bits))
        chunks.append(contentsOf: encodeExtended80(sampleRate))

        func textChunk(_ id: String, _ text: String?) {
            guard let text, !text.isEmpty else { return }
            chunks.append(contentsOf: Array(id.utf8))
            chunks.append(u32: UInt32(text.utf8.count))
            chunks.append(contentsOf: Array(text.utf8))
            if text.utf8.count & 1 != 0 { chunks.append(0) }
        }
        textChunk("NAME", metadata?.title)
        textChunk("AUTH", metadata?.artist)
        textChunk("ANNO", metadata?.comment)
        textChunk("(c) ", metadata?.extra["COPYRIGHT"])

        chunks.append(contentsOf: Array("SSND".utf8))
        chunks.append(u32: UInt32(8 + soundBytes))
        chunks.append(u32: 0) // offset
        chunks.append(u32: 0) // block size

        let formSize = 4 + chunks.count + soundBytes + (soundBytes & 1)
        var out: [UInt8] = []
        out.reserveCapacity(8 + formSize)
        out.append(contentsOf: Array("FORM".utf8))
        out.append(u32: UInt32(formSize))
        out.append(contentsOf: Array("AIFF".utf8))
        out.append(contentsOf: chunks)
        return out
    }
}
