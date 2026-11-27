// FLAC: every subframe kind (constant, verbatim, fixed, LPC), wasted bits,
// both Rice codings with escapes, all channel decorrelations, 4 to 32 bits
// per sample, header CRC-8 and frame CRC-16 checked, MD5 of the whole
// stream checkable, sample-exact seeking (seek table, else bisection on
// frame headers). A frame that fails its CRC plays as silence.
import PolymerBase
import PolymerPlatform

public final class FLACSource: AudioSource, @unchecked Sendable {
    public let format: AudioFormat
    public let bitsPerSample: Int
    public let metadata: AudioMetadata
    public var frameCount: Int? { info.total > 0 ? info.total : nil }
    public var position: Int { pendingStart + pendingIndex }
    /// Frames whose CRC-16 failed or whose body could not be decoded (played as silence).
    public private(set) var damagedFrames = 0

    struct StreamInfo {
        var minBlock = 0, maxBlock = 0, rate = 0, channels = 0, bps = 0, total = 0
        var md5: [UInt8] = []
    }
    struct SeekPoint { var sample: Int; var offset: Int }

    let info: StreamInfo
    let seekPoints: [SeekPoint]
    let frameStart: Int
    let data: UnsafeMutableBufferPointer<UInt8>
    let capacity: Int
    /// Block size of fixed-blocksize streams (frame numbers times this give sample numbers).
    var nominalBlock: Int

    // Decoding state, preallocated.
    let samples: UnsafeMutablePointer<Int64>   // capacity per channel
    let coefs = UnsafeMutablePointer<Int64>.allocate(capacity: 32)
    let pending: UnsafeMutablePointer<Float>
    var pendingStart = 0, pendingFrames = 0, pendingIndex = 0
    var cursor: Int

    public init(_ bytes: [UInt8]) throws(AudioError) {
        let parsed = try FLACSource.parseMetadata(bytes)
        info = parsed.info
        seekPoints = parsed.seek
        frameStart = parsed.frameStart
        metadata = parsed.metadata
        format = AudioFormat(sampleRate: info.rate, channels: info.channels)
        bitsPerSample = info.bps
        capacity = max(16, info.maxBlock > 0 ? info.maxBlock : 65535)
        data = .allocate(capacity: max(1, bytes.count))
        _ = data.initialize(from: bytes)
        samples = .allocate(capacity: capacity * info.channels)
        samples.initialize(repeating: 0, count: capacity * info.channels)
        pending = .allocate(capacity: capacity * info.channels)
        pending.initialize(repeating: 0, count: capacity * info.channels)
        coefs.initialize(repeating: 0, count: 32)
        cursor = frameStart
        nominalBlock = info.maxBlock
        if bytes.count > 0, let h = header(at: frameStart) { nominalBlock = h.blockSize }
        else if bytes.count > 0, let p = findHeader(from: frameStart, limit: bytes.count) { cursor = p; nominalBlock = header(at: p)?.blockSize ?? nominalBlock }
    }

    deinit {
        data.deallocate(); samples.deallocate(); coefs.deallocate(); pending.deallocate()
    }

    // MARK: Metadata

    static func parseMetadata(_ b: [UInt8]) throws(AudioError) -> (info: StreamInfo, seek: [SeekPoint], frameStart: Int, metadata: AudioMetadata) {
        var at = ID3v2.totalSize(b)
        var metadata = AudioMetadata()
        if at > 0 { ID3v2.read(b, into: &metadata) }
        guard at + 4 <= b.count, b[at] == 0x66, b[at + 1] == 0x4C, b[at + 2] == 0x61, b[at + 3] == 0x43 else {
            throw AudioError("not a FLAC stream: it must start with fLaC")
        }
        at += 4
        var info: StreamInfo?
        var seek: [SeekPoint] = []
        var last = false
        while !last {
            guard at + 4 <= b.count else { throw AudioError("FLAC metadata runs past the end of the file (truncated download?)") }
            last = b[at] & 0x80 != 0
            let type = b[at] & 0x7F
            let length = Int(b.u24(at: at + 1))
            let body = at + 4
            guard body + length <= b.count else { throw AudioError("FLAC metadata block \(type) runs past the end of the file") }
            switch type {
            case 0:
                guard length >= 34 else { throw AudioError("FLAC STREAMINFO is \(length) bytes, 34 expected") }
                var r = ByteReader(Array(b[body..<body + 34]))
                var s = StreamInfo()
                s.minBlock = Int(r.u16()); s.maxBlock = Int(r.u16())
                r.skip(6)
                let packed = UInt64(r.u32()) << 32 | UInt64(r.u32())
                s.rate = Int(packed >> 44)
                s.channels = Int((packed >> 41) & 7) + 1
                s.bps = Int((packed >> 36) & 31) + 1
                s.total = Int(packed & 0xF_FFFF_FFFF)
                s.md5 = Array(b[(body + 18)..<(body + 34)])
                info = s
            case 3:
                var i = body
                while i + 18 <= body + length {
                    let sample = UInt64(b.u32(at: i)) << 32 | UInt64(b.u32(at: i + 4))
                    let offset = UInt64(b.u32(at: i + 8)) << 32 | UInt64(b.u32(at: i + 12))
                    if sample != UInt64.max, offset < UInt64(b.count) { seek.append(SeekPoint(sample: Int(sample), offset: Int(offset))) }
                    i += 18
                }
            case 4: VorbisComment.read(b[body..<body + length], into: &metadata)
            case 6: if let p = FLACPicture.parse(b[body..<body + length]) { metadata.pictures.append(p) }
            default: break
            }
            at = body + length
        }
        guard let s = info else { throw AudioError("FLAC stream has no STREAMINFO block") }
        guard s.rate > 0 else { throw AudioError("FLAC STREAMINFO gives a sample rate of 0") }
        guard s.bps >= 4 else { throw AudioError("FLAC with \(s.bps) bits per sample is not valid (4 to 32)") }
        return (s, seek.sorted { $0.sample < $1.sample }, at, metadata)
    }

    /// Tags and pictures without decoding.
    public static func readMetadata(_ bytes: [UInt8]) throws(AudioError) -> AudioMetadata {
        try parseMetadata(bytes).metadata
    }

    // MARK: Frame headers

    struct Header {
        var blockSize: Int, firstSample: Int, assignment: Int, channels: Int, bps: Int, length: Int
    }

    static let crc8Table: [UInt8] = (0..<256).map { i in
        var c = UInt8(i)
        for _ in 0..<8 { c = c & 0x80 != 0 ? (c << 1) ^ 0x07 : c << 1 }
        return c
    }
    static let crc16Table: [UInt16] = (0..<256).map { i in
        var c = UInt16(i) << 8
        for _ in 0..<8 { c = c & 0x8000 != 0 ? (c << 1) ^ 0x8005 : c << 1 }
        return c
    }

    func header(at p: Int) -> Header? {
        let n = data.count
        guard p >= 0, p + 6 <= n, data[p] == 0xFF, data[p + 1] & 0xFE == 0xF8 else { return nil }
        let variable = data[p + 1] & 1 != 0
        let bsCode = Int(data[p + 2] >> 4), rateCode = Int(data[p + 2] & 15)
        let assignment = Int(data[p + 3] >> 4), sizeCode = Int((data[p + 3] >> 1) & 7)
        guard bsCode != 0, rateCode != 15, assignment <= 10, sizeCode != 3, data[p + 3] & 1 == 0 else { return nil }
        var i = p + 4
        let first = data[i]
        var value: UInt64, extra: Int
        switch first {
        case 0x00...0x7F: value = UInt64(first); extra = 0
        case 0xC0...0xDF: value = UInt64(first & 0x1F); extra = 1
        case 0xE0...0xEF: value = UInt64(first & 0x0F); extra = 2
        case 0xF0...0xF7: value = UInt64(first & 0x07); extra = 3
        case 0xF8...0xFB: value = UInt64(first & 0x03); extra = 4
        case 0xFC...0xFD: value = UInt64(first & 0x01); extra = 5
        case 0xFE: value = 0; extra = 6
        default: return nil
        }
        i += 1
        for _ in 0..<extra {
            guard i < n, data[i] & 0xC0 == 0x80 else { return nil }
            value = value << 6 | UInt64(data[i] & 0x3F)
            i += 1
        }
        var blockSize: Int
        switch bsCode {
        case 1: blockSize = 192
        case 2...5: blockSize = 576 << (bsCode - 2)
        case 6: guard i < n else { return nil }; blockSize = Int(data[i]) + 1; i += 1
        case 7: guard i + 1 < n else { return nil }; blockSize = (Int(data[i]) << 8 | Int(data[i + 1])) + 1; i += 2
        default: blockSize = 256 << (bsCode - 8)
        }
        if rateCode == 12 { i += 1 } else if rateCode == 13 || rateCode == 14 { i += 2 }
        guard i < n else { return nil }
        var crc: UInt8 = 0
        for k in p..<i { crc = FLACSource.crc8Table[Int(crc ^ data[k])] }
        guard crc == data[i] else { return nil }
        let bpsTable = [0, 8, 12, 0, 16, 20, 24, 32]
        let bps = sizeCode == 0 ? info.bps : bpsTable[sizeCode]
        let channels = assignment < 8 ? assignment + 1 : 2
        let firstSample = variable ? Int(value) : Int(value) * max(1, nominalBlock)
        return Header(blockSize: blockSize, firstSample: firstSample, assignment: assignment, channels: channels, bps: bps, length: i + 1 - p)
    }

    /// The next byte offset in from..<limit holding a valid header for this stream.
    func findHeader(from: Int, limit: Int) -> Int? {
        var p = max(from, 0)
        let end = min(limit, data.count - 6)
        while p < end {
            if data[p] == 0xFF, data[p + 1] & 0xFE == 0xF8, let h = header(at: p), h.channels == info.channels, h.blockSize <= capacity {
                return p
            }
            p += 1
        }
        return nil
    }

    // MARK: Subframes

    @inline(__always) static func signed(_ r: inout BitReader, _ bits: Int) -> Int64 {
        if bits <= 32 { return Int64(r.readSigned(bits)) }
        let v = r.read64(bits)
        let shift = UInt64(64 - bits)
        return Int64(bitPattern: v << shift) >> Int64(shift)
    }

    func residual(_ r: inout BitReader, _ out: UnsafeMutablePointer<Int64>, _ n: Int, _ order: Int) -> Bool {
        let method = r.read(2)
        guard method < 2 else { return false }
        let paramBits = method == 0 ? 4 : 5
        let escape = method == 0 ? 15 : 31
        let partitionOrder = Int(r.read(4))
        let per = n >> partitionOrder
        guard per << partitionOrder == n, per >= order else { return false }
        var i = order
        for part in 0..<(1 << partitionOrder) {
            let count = part == 0 ? per - order : per
            let k = Int(r.read(paramBits))
            if k == escape {
                let raw = Int(r.read(5))
                for _ in 0..<count { out[i] = raw == 0 ? 0 : FLACSource.signed(&r, raw); i += 1 }
            } else {
                for _ in 0..<count {
                    let q = r.unary(limit: 1 << 24)
                    let u = UInt64(q) << UInt64(k) | UInt64(r.read(k))
                    out[i] = Int64(bitPattern: u >> 1) ^ (0 &- Int64(bitPattern: u & 1))
                    i += 1
                }
            }
            if r.position > r.bitCount { return false }
        }
        return true
    }

    func subframe(_ r: inout BitReader, _ out: UnsafeMutablePointer<Int64>, _ n: Int, _ bps: Int) -> Bool {
        if r.bit() { return false }
        let type = Int(r.read(6))
        var wasted = 0
        if r.bit() { wasted = r.unary(limit: 40) + 1 }
        let bits = bps - wasted
        guard bits > 0 else { return false }
        switch type {
        case 0:
            let v = FLACSource.signed(&r, bits)
            for i in 0..<n { out[i] = v }
        case 1:
            for i in 0..<n { out[i] = FLACSource.signed(&r, bits) }
        case 8...12:
            let order = type - 8
            guard order <= n else { return false }
            for i in 0..<order { out[i] = FLACSource.signed(&r, bits) }
            guard residual(&r, out, n, order) else { return false }
            switch order {
            case 1: for i in 1..<n { out[i] = out[i] &+ out[i - 1] }
            case 2: for i in 2..<n { out[i] = out[i] &+ 2 &* out[i - 1] &- out[i - 2] }
            case 3: for i in 3..<n { out[i] = out[i] &+ 3 &* out[i - 1] &- 3 &* out[i - 2] &+ out[i - 3] }
            case 4: for i in 4..<n { out[i] = out[i] &+ 4 &* out[i - 1] &- 6 &* out[i - 2] &+ 4 &* out[i - 3] &- out[i - 4] }
            default: break
            }
        case 32...63:
            let order = type - 31
            guard order <= n else { return false }
            for i in 0..<order { out[i] = FLACSource.signed(&r, bits) }
            let precision = Int(r.read(4)) + 1
            guard precision < 16 else { return false }
            let shift = Int(r.readSigned(5))
            guard shift >= 0 else { return false }
            for j in 0..<order { coefs[j] = Int64(r.readSigned(precision)) }
            guard residual(&r, out, n, order) else { return false }
            let s = Int64(shift)
            for i in order..<n {
                var sum: Int64 = 0
                for j in 0..<order { sum = sum &+ coefs[j] &* out[i - 1 - j] }
                out[i] = out[i] &+ (sum >> s)
            }
        default:
            return false
        }
        if wasted > 0 { let w = Int64(wasted); for i in 0..<n { out[i] = out[i] << w } }
        return r.position <= r.bitCount
    }

    enum FrameResult { case ok(Header, next: Int), damaged(Header), none }

    /// Decodes the frame at `p` into `samples` (per channel, `capacity` apart).
    func decodeFrame(at p: Int) -> FrameResult {
        guard let h = header(at: p), h.channels == info.channels, h.blockSize <= capacity, h.bps > 0 else { return .none }
        var r = BitReader(UnsafePointer(data.baseAddress!), count: data.count, bitPosition: (p + h.length) * 8)
        let n = h.blockSize
        for c in 0..<h.channels {
            var bits = h.bps
            if (h.assignment == 8 && c == 1) || (h.assignment == 9 && c == 0) || (h.assignment == 10 && c == 1) { bits += 1 }
            guard subframe(&r, samples + c * capacity, n, bits) else { return .damaged(h) }
        }
        r.alignToByte()
        let end = r.byteOffset
        guard end + 2 <= data.count else { return .damaged(h) }
        var crc: UInt16 = 0
        for k in p..<end { crc = (crc << 8) ^ FLACSource.crc16Table[Int(UInt8(crc >> 8) ^ data[k])] }
        guard crc == UInt16(data[end]) << 8 | UInt16(data[end + 1]) else { return .damaged(h) }
        let a = samples, b = samples + capacity
        switch h.assignment {
        case 8: for i in 0..<n { b[i] = a[i] &- b[i] }                 // left, side
        case 9: for i in 0..<n { a[i] = a[i] &+ b[i] }                 // side, right
        case 10:                                                       // mid, side
            for i in 0..<n {
                let side = b[i]
                let mid = (a[i] << 1) | (side & 1)
                a[i] = (mid &+ side) >> 1
                b[i] = (mid &- side) >> 1
            }
        default: break
        }
        return .ok(h, next: end + 2)
    }

    /// Decodes the next frame from `cursor` into `pending`. False at the end.
    func nextFrame() -> Bool {
        let channels = info.channels
        while cursor < data.count - 6 {
            switch decodeFrame(at: cursor) {
            case .ok(let h, let next):
                let scale = 1 / Float(Double(1 << UInt64(h.bps - 1)))
                for c in 0..<channels {
                    let src = samples + c * capacity
                    for i in 0..<h.blockSize { pending[i * channels + c] = Float(src[i]) * scale }
                }
                setPending(h, frames: h.blockSize)
                cursor = next
                return true
            case .damaged(let h):
                damagedFrames += 1
                pending.update(repeating: 0, count: h.blockSize * channels)
                setPending(h, frames: h.blockSize)
                cursor = findHeader(from: cursor + 1, limit: data.count) ?? data.count
                return true
            case .none:
                cursor = findHeader(from: cursor + 1, limit: data.count) ?? data.count
            }
        }
        return false
    }

    private func setPending(_ h: Header, frames: Int) {
        pendingStart = h.firstSample
        pendingIndex = 0
        pendingFrames = info.total > 0 ? max(0, min(frames, info.total - h.firstSample)) : frames
    }

    // MARK: AudioSource

    public func read(into buffer: UnsafeMutablePointer<Float>, frames want: Int) -> Int {
        let channels = info.channels
        var done = 0
        while done < want {
            if pendingIndex >= pendingFrames {
                if !nextFrame() { break }
                continue
            }
            let n = min(want - done, pendingFrames - pendingIndex)
            (buffer + done * channels).update(from: pending + pendingIndex * channels, count: n * channels)
            pendingIndex += n
            done += n
        }
        return done
    }

    public func seek(toFrame frame: Int) throws(AudioError) {
        let target = max(0, info.total > 0 ? min(frame, info.total) : frame)
        if info.total > 0 && target >= info.total {
            cursor = data.count; pendingStart = info.total; pendingFrames = 0; pendingIndex = 0
            return
        }
        // A start no later than the target: seek table first, then bisection on frame headers.
        var best = frameStart
        var bestSample = 0
        for p in seekPoints where p.sample <= target {
            let at = frameStart + p.offset
            if p.sample >= bestSample, let h = header(at: at), h.firstSample == p.sample { best = at; bestSample = p.sample }
        }
        var lo = best, hi = data.count
        while hi - lo > 64 {
            let mid = lo + (hi - lo) / 2
            guard let p = findHeader(from: mid, limit: hi), let h = header(at: p) else { hi = mid; continue }
            if h.firstSample <= target {
                if h.firstSample >= bestSample { best = p; bestSample = h.firstSample }
                lo = p + 1
            } else {
                hi = mid
            }
        }
        cursor = best
        pendingFrames = 0; pendingIndex = 0; pendingStart = bestSample
        while nextFrame() {
            if pendingStart + pendingFrames > target {
                pendingIndex = max(0, target - pendingStart)
                return
            }
        }
        pendingStart = target; pendingFrames = 0; pendingIndex = 0
    }

    // MARK: Verification

    /// Decodes the whole stream from the start, checking every CRC and the
    /// STREAMINFO MD5. `frames` counts sample frames (as `frameCount` does),
    /// `damaged` counts FLAC frames that failed their CRC or could not be
    /// decoded. `md5Matches` is nil when the encoder left the MD5 empty.
    public func verify() -> (frames: Int, damaged: Int, md5Matches: Bool?) {
        let savedCursor = cursor, savedStart = pendingStart, savedFrames = pendingFrames, savedIndex = pendingIndex
        defer { cursor = savedCursor; pendingStart = savedStart; pendingFrames = savedFrames; pendingIndex = savedIndex }
        var md5 = MD5()
        var damaged = 0
        var p = frameStart
        let bytesPer = (info.bps + 7) / 8
        var produced = 0
        while p < data.count - 6 {
            switch decodeFrame(at: p) {
            case .ok(let h, let next):
                let n = info.total > 0 ? max(0, min(h.blockSize, info.total - produced)) : h.blockSize
                for i in 0..<n {
                    for c in 0..<info.channels {
                        let v = UInt64(bitPattern: samples[c * capacity + i])
                        for k in 0..<bytesPer { md5.update(UInt8(truncatingIfNeeded: v >> UInt64(8 * k))) }
                    }
                }
                produced += n
                p = next
            case .damaged:
                damaged += 1
                p = findHeader(from: p + 1, limit: data.count) ?? data.count
            case .none:
                p = findHeader(from: p + 1, limit: data.count) ?? data.count
            }
        }
        let digest = md5.finish()
        let empty = info.md5.allSatisfy { $0 == 0 }
        return (produced, damaged, empty ? nil : digest == info.md5)
    }
}
