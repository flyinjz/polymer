// WAV (RIFF and RF64): integer PCM of 8 to 32 bits, 32- and 64-bit float,
// WAVE_FORMAT_EXTENSIBLE, LIST/INFO tags and an embedded "id3 " chunk.
// Also the encoder used by checks and the file output.
import PolymerBase
import PolymerPlatform

public final class WAVSource: AudioSource, @unchecked Sendable {
    public let format: AudioFormat
    public let bitsPerSample: Int
    public let metadata: AudioMetadata
    public var frameCount: Int? { frames }
    public private(set) var position = 0

    let bytes: [UInt8]
    let dataStart: Int
    let frames: Int
    let isFloat: Bool
    let bytesPerSample: Int
    let blockAlign: Int

    public convenience init(_ bytes: [UInt8]) throws(AudioError) {
        try self.init(bytes, parsed: WAVSource.parse(bytes))
    }

    private init(_ bytes: [UInt8], parsed p: Parsed) {
        self.bytes = bytes
        format = AudioFormat(sampleRate: p.rate, channels: p.channels)
        bitsPerSample = p.bits
        isFloat = p.isFloat
        bytesPerSample = p.container / 8
        blockAlign = p.blockAlign
        dataStart = p.dataStart
        frames = p.dataSize / p.blockAlign
        metadata = p.metadata
    }

    struct Parsed {
        var rate = 0, channels = 0, bits = 0, container = 0, blockAlign = 0
        var isFloat = false
        var dataStart = 0, dataSize = 0
        var metadata = AudioMetadata()
    }

    static func parse(_ b: [UInt8]) throws(AudioError) -> Parsed {
        func fourCC(_ at: Int) -> String { String(decoding: b[min(at, b.count)..<min(at + 4, b.count)], as: UTF8.self) }
        guard b.count >= 12, fourCC(8) == "WAVE", fourCC(0) == "RIFF" || fourCC(0) == "RF64" else {
            throw AudioError("not a WAV file: it must start with RIFF....WAVE")
        }
        var p = Parsed()
        var haveFormat = false, haveData = false
        var ds64DataSize: UInt64?
        var at = 12
        while at + 8 <= b.count {
            let id = fourCC(at)
            var size = Int(b.u32le(at: at + 4))
            let body = at + 8
            switch id {
            case "ds64":
                ds64DataSize = UInt64(b.u32le(at: body + 8)) | UInt64(b.u32le(at: body + 12)) << 32
            case "fmt ":
                var tag = Int(b.u16le(at: body))
                p.channels = Int(b.u16le(at: body + 2))
                p.rate = Int(b.u32le(at: body + 4))
                p.blockAlign = Int(b.u16le(at: body + 12))
                p.container = Int(b.u16le(at: body + 14))
                p.bits = p.container
                if tag == 0xFFFE, size >= 40 {
                    let valid = Int(b.u16le(at: body + 18))
                    if valid > 0 && valid <= p.container { p.bits = valid }
                    tag = Int(b.u16le(at: body + 24))   // first two bytes of the sub-format GUID
                }
                switch tag {
                case 1: p.isFloat = false
                case 3: p.isFloat = true
                default:
                    throw AudioError("WAV format tag 0x\(String(tag, radix: 16)) is not PCM or float (compressed WAV such as ADPCM is not decoded)")
                }
                haveFormat = true
            case "data":
                if UInt32(size) == 0xFFFF_FFFF, let d = ds64DataSize { size = Int(min(d, UInt64(b.count - body))) }
                p.dataStart = body
                p.dataSize = min(size, b.count - body)
                haveData = true
            case "LIST":
                if fourCC(body) == "INFO" { readInfo(b, from: body + 4, to: min(body + size, b.count), into: &p.metadata) }
            case "id3 ", "ID3 ":
                ID3v2.read(Array(b[body..<min(body + size, b.count)]), into: &p.metadata)
            default: break
            }
            if id == "data" && UInt32(truncatingIfNeeded: size) == 0xFFFF_FFFF { break }
            at = body + size + (size & 1)
        }
        guard haveFormat else { throw AudioError("WAV file has no fmt chunk") }
        guard haveData else { throw AudioError("WAV file has no data chunk") }
        guard p.channels > 0, p.rate > 0 else { throw AudioError("WAV fmt chunk says \(p.channels) channels at \(p.rate) Hz") }
        let ok = p.isFloat ? (p.container == 32 || p.container == 64) : (p.container >= 8 && p.container <= 32 && p.container % 8 == 0)
        guard ok else { throw AudioError("WAV with \(p.container)-bit \(p.isFloat ? "float" : "integer") samples is not supported") }
        if p.blockAlign != p.channels * p.container / 8 { p.blockAlign = p.channels * p.container / 8 }
        return p
    }

    static func readInfo(_ b: [UInt8], from: Int, to: Int, into m: inout AudioMetadata) {
        var at = from
        while at + 8 <= to {
            let id = String(decoding: b[at..<at + 4], as: UTF8.self)
            let size = Int(b.u32le(at: at + 4))
            let end = min(at + 8 + size, to)
            let value = String(decoding: b[(at + 8)..<end].prefix { $0 != 0 }, as: UTF8.self)
            switch id {
            case "INAM": m.set("TITLE", value)
            case "IART": m.set("ARTIST", value)
            case "IPRD": m.set("ALBUM", value)
            case "ICRD": m.set("DATE", value)
            case "IGNR": m.set("GENRE", value)
            case "ICMT": m.set("COMMENT", value)
            case "ITRK", "IPRT": m.set("TRACKNUMBER", value)
            default: if !value.isEmpty { m.extra[id] = value }
            }
            at += 8 + size + (size & 1)
        }
    }

    static func readMetadata(_ bytes: [UInt8]) -> AudioMetadata { (try? parse(bytes))?.metadata ?? AudioMetadata() }

    public func seek(toFrame frame: Int) throws(AudioError) { position = max(0, min(frame, frames)) }

    public func read(into buffer: UnsafeMutablePointer<Float>, frames want: Int) -> Int {
        let n = max(0, min(want, frames - position))
        if n == 0 { return 0 }
        let count = n * format.channels
        let start = dataStart + position * blockAlign
        bytes.withUnsafeBufferPointer { raw in
            let p = raw.baseAddress! + start
            switch (isFloat, bytesPerSample) {
            case (true, 4):
                for i in 0..<count {
                    buffer[i] = Float(bitPattern: UInt32(p[i * 4]) | UInt32(p[i * 4 + 1]) << 8 | UInt32(p[i * 4 + 2]) << 16 | UInt32(p[i * 4 + 3]) << 24)
                }
            case (true, _):
                for i in 0..<count {
                    var v: UInt64 = 0
                    for k in 0..<8 { v |= UInt64(p[i * 8 + k]) << UInt64(8 * k) }
                    buffer[i] = Float(Double(bitPattern: v))
                }
            case (false, 1):
                for i in 0..<count { buffer[i] = Float(Int(p[i]) - 128) * (1 / 128) }
            case (false, 2):
                for i in 0..<count {
                    buffer[i] = Float(Int16(bitPattern: UInt16(p[i * 2]) | UInt16(p[i * 2 + 1]) << 8)) * (1 / 32768)
                }
            case (false, 3):
                for i in 0..<count {
                    let v = Int32(bitPattern: UInt32(p[i * 3]) << 8 | UInt32(p[i * 3 + 1]) << 16 | UInt32(p[i * 3 + 2]) << 24) >> 8
                    buffer[i] = Float(v) * (1 / 8_388_608)
                }
            default:
                for i in 0..<count {
                    let v = Int32(bitPattern: UInt32(p[i * 4]) | UInt32(p[i * 4 + 1]) << 8 | UInt32(p[i * 4 + 2]) << 16 | UInt32(p[i * 4 + 3]) << 24)
                    buffer[i] = Float(Double(v) * (1 / 2_147_483_648))
                }
            }
        }
        position += n
        return n
    }
}

public enum WAV {
    public enum Encoding: Sendable { case int16, int24, float32 }

    /// A WAV file of interleaved samples in [-1, 1]. Integers are scaled by
    /// 2^(bits-1), rounded and clipped, so decoding gives back k / 2^(bits-1) exactly.
    public static func encode(_ samples: [Float], format: AudioFormat, encoding: Encoding = .int16) -> [UInt8] {
        let bytesPer = encoding == .int16 ? 2 : encoding == .int24 ? 3 : 4
        let dataSize = samples.count * bytesPer
        var out: [UInt8] = []
        out.reserveCapacity(44 + dataSize)
        func u16(_ v: Int) { out.append(UInt8(truncatingIfNeeded: v)); out.append(UInt8(truncatingIfNeeded: v >> 8)) }
        func u32(_ v: Int) { u16(v & 0xFFFF); u16((v >> 16) & 0xFFFF) }
        func tag(_ s: String) { out.append(contentsOf: Array(s.utf8)) }
        tag("RIFF"); u32(36 + dataSize); tag("WAVE")
        tag("fmt "); u32(16)
        u16(encoding == .float32 ? 3 : 1); u16(format.channels); u32(format.sampleRate)
        u32(format.sampleRate * format.channels * bytesPer); u16(format.channels * bytesPer); u16(bytesPer * 8)
        tag("data"); u32(dataSize)
        for s in samples {
            switch encoding {
            case .int16:
                let v = Int(max(-32768, min(32767, (Double(s) * 32768).rounded())))
                u16(v)
            case .int24:
                let v = Int(max(-8_388_608, min(8_388_607, (Double(s) * 8_388_608).rounded())))
                out.append(UInt8(truncatingIfNeeded: v)); out.append(UInt8(truncatingIfNeeded: v >> 8)); out.append(UInt8(truncatingIfNeeded: v >> 16))
            case .float32:
                let v = s.bitPattern
                for k in 0..<4 { out.append(UInt8(truncatingIfNeeded: v >> UInt32(8 * k))) }
            }
        }
        return out
    }
}
