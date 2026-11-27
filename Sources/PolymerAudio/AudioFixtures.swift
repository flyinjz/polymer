// Small in-memory files for checks and tools: FLAC, ID3v2 tags and MP3
// streams built bit by bit, so the decoders can be tested without any
// encoder installed and without touching anyone's music.
import PolymerBase
import PolymerPlatform

struct BitWriter {
    var bytes: [UInt8] = []
    private var acc: UInt8 = 0
    private var filled = 0

    mutating func bit(_ b: Bool) {
        acc = acc << 1 | (b ? 1 : 0)
        filled += 1
        if filled == 8 { bytes.append(acc); acc = 0; filled = 0 }
    }

    /// The low `bits` bits of `v`, most significant first (two's complement for negatives).
    mutating func write(_ v: Int64, _ bits: Int) {
        var i = bits - 1
        while i >= 0 { bit((v >> Int64(i)) & 1 != 0); i -= 1 }
    }

    mutating func write(_ v: Int, _ bits: Int) { write(Int64(v), bits) }

    mutating func align() { while filled != 0 { bit(false) } }
}

public enum AudioFixtures {
    /// MD5 of `bytes` as lowercase hex.
    public static func md5Hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var s: [UInt8] = []
        for b in MD5.digest(bytes) { s.append(digits[Int(b >> 4)]); s.append(digits[Int(b & 15)]) }
        return String(decoding: s, as: UTF8.self)
    }

    // MARK: FLAC

    /// A FLAC stream of interleaved integer `samples`. Frames cycle through the
    /// stereo decorrelation modes (independent, left/side, side/right,
    /// mid/side) and the subframe kinds (verbatim, fixed order 1 and 2,
    /// constant), so one file exercises every path a plain encoder takes.
    public static func flac(samples: [Int32], channels: Int, sampleRate: Int, bitsPerSample bps: Int,
                            blockSize: Int = 1024, comments: [String] = [], picture: CoverArt? = nil,
                            md5: Bool = true) -> [UInt8] {
        let total = samples.count / max(1, channels)
        var out = Array("fLaC".utf8)
        var blocks: [(type: UInt8, body: [UInt8])] = []

        var info = BitWriter()
        info.write(blockSize, 16); info.write(blockSize, 16)
        info.write(0, 24); info.write(0, 24)
        info.write(sampleRate, 20); info.write(channels - 1, 3); info.write(bps - 1, 5); info.write(total, 36)
        var digest = [UInt8](repeating: 0, count: 16)
        if md5 {
            var m = MD5()
            let bytesPer = (bps + 7) / 8
            for s in samples.prefix(total * channels) { for k in 0..<bytesPer { m.update(UInt8(truncatingIfNeeded: s >> Int32(8 * k))) } }
            digest = m.finish()
        }
        blocks.append((0, info.bytes + digest))

        if !comments.isEmpty {
            var b: [UInt8] = []
            func le32(_ v: Int) { for k in 0..<4 { b.append(UInt8(truncatingIfNeeded: v >> (8 * k))) } }
            let vendor = Array("Polymer".utf8)
            le32(vendor.count); b += vendor
            le32(comments.count)
            for c in comments { let u = Array(c.utf8); le32(u.count); b += u }
            blocks.append((4, b))
        }
        if let p = picture {
            var b: [UInt8] = []
            func be32(_ v: Int) { for k in (0..<4).reversed() { b.append(UInt8(truncatingIfNeeded: v >> (8 * k))) } }
            be32(p.pictureType)
            let mime = Array(p.mimeType.utf8), desc = Array(p.description.utf8)
            be32(mime.count); b += mime
            be32(desc.count); b += desc
            be32(1); be32(1); be32(24); be32(0)
            be32(p.bytes.count); b += p.bytes
            blocks.append((6, b))
        }
        for (i, block) in blocks.enumerated() {
            out.append((i == blocks.count - 1 ? 0x80 : 0) | block.type)
            let n = block.body.count
            out += [UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)]
            out += block.body
        }

        var start = 0, frame = 0
        while start < total {
            let n = min(blockSize, total - start)
            let assignment = channels == 2 ? [1, 8, 9, 10][frame % 4] : channels - 1
            var chans: [[Int64]] = (0..<channels).map { c in (0..<n).map { Int64(samples[(start + $0) * channels + c]) } }
            var widths = [Int](repeating: bps, count: channels)
            if channels == 2 {
                let l = chans[0], r = chans[1]
                let side = (0..<n).map { l[$0] - r[$0] }
                switch assignment {
                case 8: chans[1] = side; widths[1] += 1
                case 9: chans[0] = side; widths[0] += 1
                case 10: chans[0] = (0..<n).map { (l[$0] + r[$0]) >> 1 }; chans[1] = side; widths[1] += 1
                default: break
                }
            }
            var w = BitWriter()
            w.write(0xFFF8, 16)
            w.write(7, 4); w.write(0, 4)
            w.write(assignment, 4); w.write(0, 3); w.write(0, 1)
            for byte in utf8Number(frame) { w.write(Int(byte), 8) }
            w.write(n - 1, 16)
            var crc8: UInt8 = 0
            for b in w.bytes { crc8 = FLACSource.crc8Table[Int(crc8 ^ b)] }
            w.write(Int(crc8), 8)
            for c in 0..<channels { subframe(&w, chans[c], widths[c], kind: (frame + c) % 3) }
            w.align()
            var crc16: UInt16 = 0
            for b in w.bytes { crc16 = (crc16 << 8) ^ FLACSource.crc16Table[Int(UInt8(crc16 >> 8) ^ b)] }
            w.write(Int(crc16), 16)
            out += w.bytes
            start += n; frame += 1
        }
        return out
    }

    static func utf8Number(_ v: Int) -> [UInt8] {
        if v < 0x80 { return [UInt8(v)] }
        if v < 0x800 { return [UInt8(0xC0 | v >> 6), UInt8(0x80 | v & 63)] }
        if v < 0x10000 { return [UInt8(0xE0 | v >> 12), UInt8(0x80 | (v >> 6) & 63), UInt8(0x80 | v & 63)] }
        return [UInt8(0xF0 | (v >> 18) & 7), UInt8(0x80 | (v >> 12) & 63), UInt8(0x80 | (v >> 6) & 63), UInt8(0x80 | v & 63)]
    }

    static func subframe(_ w: inout BitWriter, _ x: [Int64], _ bits: Int, kind: Int) {
        let n = x.count
        w.write(0, 1)
        if x.allSatisfy({ $0 == x[0] }) {
            w.write(0, 6); w.write(0, 1); w.write(x[0], bits)
            return
        }
        let order = kind == 0 || n <= 2 ? -1 : kind == 1 ? 2 : 1
        if order < 0 {
            w.write(1, 6); w.write(0, 1)
            for v in x { w.write(v, bits) }
            return
        }
        w.write(8 + order, 6); w.write(0, 1)
        for i in 0..<order { w.write(x[i], bits) }
        let e: [Int64] = (order..<n).map { i in order == 1 ? x[i] - x[i - 1] : x[i] - 2 * x[i - 1] + x[i - 2] }
        let mean = e.isEmpty ? 0 : e.reduce(0) { $0 + UInt64($1.magnitude) } / UInt64(e.count)
        var k = 0
        while k < 14, UInt64(1) << UInt64(k + 1) <= mean { k += 1 }
        w.write(0, 2); w.write(0, 4); w.write(k, 4)
        for v in e {
            let u = v >= 0 ? UInt64(v) << 1 : (UInt64(-v) << 1) - 1
            let q = u >> UInt64(k)
            for _ in 0..<q { w.bit(false) }
            w.bit(true)
            w.write(Int64(u & ((1 << UInt64(k)) - 1)), k)
        }
    }

    // MARK: ID3v2

    /// An ID3v2.3 tag: the title in UTF-16, the rest in Latin-1, an APIC
    /// picture, then 16 bytes of padding.
    public static func id3v2(title: String?, artist: String?, album: String? = nil, track: String? = nil,
                             picture: CoverArt? = nil) -> [UInt8] {
        var body: [UInt8] = []
        func frame(_ id: String, _ data: [UInt8]) {
            body += Array(id.utf8)
            let n = data.count
            body += [UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)]
            body += [0, 0]
            body += data
        }
        func latin1(_ s: String) -> [UInt8] { s.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) } }
        if let t = title {
            var d: [UInt8] = [1, 0xFF, 0xFE]
            for u in t.utf16 { d.append(UInt8(truncatingIfNeeded: u)); d.append(UInt8(truncatingIfNeeded: u >> 8)) }
            frame("TIT2", d)
        }
        if let a = artist { frame("TPE1", [0] + latin1(a)) }
        if let a = album { frame("TALB", [0] + latin1(a)) }
        if let t = track { frame("TRCK", [0] + latin1(t)) }
        if let p = picture {
            frame("APIC", [0] + latin1(p.mimeType) + [0, UInt8(truncatingIfNeeded: p.pictureType)] + latin1(p.description) + [0] + p.bytes)
        }
        body += [UInt8](repeating: 0, count: 16)
        let n = body.count
        let size: [UInt8] = [UInt8((n >> 21) & 127), UInt8((n >> 14) & 127), UInt8((n >> 7) & 127), UInt8(n & 127)]
        return Array("ID3".utf8) + [3, 0, 0] + size + body
    }

    // MARK: MP3

    /// Bytes of one 128 kbit/s, 44.1 kHz MPEG-1 Layer III frame without padding.
    public static let mp3FrameBytes = 417

    static func mp3Frame(mono: Bool) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: mp3FrameBytes)
        f[0] = 0xFF; f[1] = 0xFB; f[2] = 0x90; f[3] = mono ? 0xC0 : 0x00
        return f
    }

    /// `frames` silent stereo frames (all side information zero), after an
    /// Info frame with a LAME tag when `delay` and `padding` are given.
    public static func mp3Silence(frames: Int, delay: Int? = nil, padding: Int? = nil) -> [UInt8] {
        var out: [UInt8] = []
        if let d = delay, let p = padding {
            var f = mp3Frame(mono: false)
            let x = 4 + 32
            f.replaceSubrange(x..<(x + 4), with: Array("Info".utf8))
            f[x + 7] = 1
            f[x + 8] = UInt8(truncatingIfNeeded: frames >> 24); f[x + 9] = UInt8(truncatingIfNeeded: frames >> 16)
            f[x + 10] = UInt8(truncatingIfNeeded: frames >> 8); f[x + 11] = UInt8(truncatingIfNeeded: frames)
            let l = x + 12
            f.replaceSubrange(l..<(l + 9), with: Array("LAME3.100".utf8))
            f[l + 21] = UInt8((d >> 4) & 255)
            f[l + 22] = UInt8((d & 15) << 4 | (p >> 8) & 15)
            f[l + 23] = UInt8(p & 255)
            out += f
        }
        for _ in 0..<frames { out += mp3Frame(mono: false) }
        return out
    }

    /// Mono frames where the first holds one spectral line (line 0, value 1,
    /// table 1, global gain 210, so the line requantises to exactly 1.0) and
    /// the rest are silent.
    public static func mp3SingleLine(frames: Int = 4) -> [UInt8] {
        var f = mp3Frame(mono: true)
        var side = BitWriter()
        side.write(0, 9); side.write(0, 5); side.write(0, 4)
        // Granule 0: part2_3 3 bits, one pair, gain 210, table 1 in region 0.
        side.write(3, 12); side.write(1, 9); side.write(210, 8); side.write(0, 4); side.write(0, 1)
        side.write(1, 5); side.write(0, 5); side.write(0, 5); side.write(0, 4); side.write(0, 3)
        side.write(0, 1); side.write(0, 1); side.write(0, 1)
        // Granule 1: empty.
        side.write(0, 59)
        side.align()
        for (i, b) in side.bytes.enumerated() { f[4 + i] = b }
        // Main data: code "01" for (1, 0), then the sign bit of x (0, positive).
        f[4 + 17] = 0b0100_0000
        var out = f
        for _ in 1..<max(1, frames) { out += mp3Frame(mono: true) }
        return out
    }
}
