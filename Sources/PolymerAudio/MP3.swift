// MPEG-1, MPEG-2 and MPEG-2.5 Layer III, written from ISO/IEC 11172-3 and
// 13818-3: Huffman decoding, requantisation, M/S and intensity stereo, alias
// reduction, IMDCT and polyphase synthesis. Gapless playback follows the
// Xing/Info and LAME headers: the encoder delay plus the decoder's own 529
// samples are skipped and the padding is trimmed, as other decoders do.
// Layer I and II streams are not decoded.
import PolymerBase
import PolymerPlatform

/// One frame header.
struct MP3Header: Equatable {
    var mpeg1: Bool
    /// 0...8 into the sample rate and band tables.
    var rateIndex: Int
    var crc: Bool
    var bitrate: Int
    var sampleRate: Int
    var padding: Int
    var mode: Int
    var modeExtension: Int
    var frameBytes: Int
    /// The bits every frame of one stream shares (version, layer, rate).
    var kind: Int

    var channels: Int { mode == 3 ? 1 : 2 }
    var granules: Int { mpeg1 ? 2 : 1 }
    var samples: Int { mpeg1 ? 1152 : 576 }
    var sideInfoBytes: Int { mpeg1 ? (mode == 3 ? 17 : 32) : (mode == 3 ? 9 : 17) }
}

public enum MP3 {
    static func header(_ p: UnsafePointer<UInt8>, count: Int, at i: Int) -> MP3Header? {
        guard i >= 0, i + 4 <= count else { return nil }
        let b0 = p[i], b1 = p[i + 1], b2 = p[i + 2], b3 = p[i + 3]
        guard b0 == 0xFF, b1 & 0xE0 == 0xE0 else { return nil }
        let version = Int(b1 >> 3) & 3
        guard version != 1, (b1 >> 1) & 3 == 1 else { return nil }
        let bitrateIndex = Int(b2 >> 4)
        let rateBits = Int(b2 >> 2) & 3
        guard bitrateIndex != 0, bitrateIndex != 15, rateBits != 3, b3 & 3 != 2 else { return nil }
        let mpeg1 = version == 3
        let family = version == 3 ? 0 : version == 2 ? 1 : 2
        let rateIndex = family * 3 + rateBits
        let rate = MP3Tables.sampleRates[rateIndex]
        let bitrate = MP3Tables.bitrates[mpeg1 ? 0 : 1][bitrateIndex] * 1000
        let padding = Int(b2 >> 1) & 1
        return MP3Header(mpeg1: mpeg1, rateIndex: rateIndex, crc: b1 & 1 == 0, bitrate: bitrate, sampleRate: rate,
                         padding: padding, mode: Int(b3 >> 6), modeExtension: Int(b3 >> 4) & 3,
                         frameBytes: (mpeg1 ? 144 : 72) * bitrate / rate + padding,
                         kind: Int(b1 & 0xFE) << 8 | Int(b2 & 0x0C))
    }

    static func header(_ bytes: [UInt8], at i: Int) -> MP3Header? {
        bytes.withUnsafeBufferPointer { b in b.baseAddress.flatMap { header($0, count: b.count, at: i) } }
    }

    /// The offset of the first Layer III frame at or after `start` (searching
    /// at most `limit` bytes) that is followed by another frame of the same
    /// stream, by the end of the data or by an ID3v1 tag.
    public static func findFrame(_ bytes: [UInt8], from start: Int, limit: Int) -> Int? {
        sync(bytes, from: start, end: bytes.count, limit: limit, kind: nil)
    }

    static func sync(_ bytes: [UInt8], from start: Int, end: Int, limit: Int, kind: Int?) -> Int? {
        bytes.withUnsafeBufferPointer { b -> Int? in
            guard let p = b.baseAddress else { return nil }
            let count = min(end, b.count)
            var i = max(0, start)
            let last = min(count - 4, i + limit)
            while i <= last {
                if p[i] == 0xFF, let h = header(p, count: count, at: i), kind == nil || h.kind == kind {
                    let next = i + h.frameBytes
                    if next == count { return i }
                    if let h2 = header(p, count: count, at: next), h2.kind == h.kind { return i }
                    if next + 3 <= count, p[next] == 0x54, p[next + 1] == 0x41, p[next + 2] == 0x47 { return i }
                }
                i += 1
            }
            return nil
        }
    }

    /// What a Xing/Info, LAME or VBRI header in a stream's first frame says.
    struct InfoFrame {
        var frames: Int?
        var delay: Int?
        var padding: Int?
    }

    static func infoFrame(_ bytes: [UInt8], at offset: Int, _ h: MP3Header) -> InfoFrame? {
        func tag(_ at: Int, _ s: String) -> Bool {
            let u = Array(s.utf8)
            guard at >= 0, at + u.count <= bytes.count else { return false }
            for k in 0..<u.count where bytes[at + k] != u[k] { return false }
            return true
        }
        func be32(_ at: Int) -> Int? {
            guard at >= 0, at + 4 <= bytes.count else { return nil }
            return Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
        }
        let x = offset + 4 + (h.crc ? 2 : 0) + h.sideInfoBytes
        if tag(x, "Xing") || tag(x, "Info") {
            var info = InfoFrame()
            guard let flags = be32(x + 4) else { return info }
            var p = x + 8
            if flags & 1 != 0 { info.frames = be32(p); p += 4 }
            if flags & 2 != 0 { p += 4 }
            if flags & 4 != 0 { p += 100 }
            if flags & 8 != 0 { p += 4 }
            if (tag(p, "LAME") || tag(p, "Lavf") || tag(p, "Lavc") || tag(p, "L3.9")) && p + 24 <= bytes.count {
                info.delay = Int(bytes[p + 21]) << 4 | Int(bytes[p + 22]) >> 4
                info.padding = (Int(bytes[p + 22]) & 15) << 8 | Int(bytes[p + 23])
            }
            return info
        }
        if tag(offset + 36, "VBRI") {
            return InfoFrame(frames: be32(offset + 36 + 14), delay: nil, padding: nil)
        }
        return nil
    }
}

/// An MP3 file decoded frame by frame. Seeking is exact to the sample: it
/// restarts a few frames early to refill the bit reservoir and the filter
/// banks, and drops what those frames produce.
public final class MP3Source: AudioSource, @unchecked Sendable {
    public let format: AudioFormat
    public let frameCount: Int?
    public private(set) var position = 0
    public let bitsPerSample = 0
    public let metadata: AudioMetadata
    /// From the LAME tag; 0 without one.
    public let encoderDelay: Int
    public let encoderPadding: Int
    /// Layer III frames holding audio (an Xing/Info frame is not counted).
    public var mpegFrames: Int { frames.count }
    /// Average bits per second over the audio frames.
    public let bitrate: Int
    /// True when a LAME tag gave the exact length.
    public let isGapless: Bool

    let bytes: [UInt8]
    let dataEnd: Int
    let frames: [Int]
    let samplesPerFrame: Int
    /// Decoded samples dropped at the start.
    let skip: Int
    let decoder: MP3FrameDecoder
    let pcm: UnsafeMutablePointer<Float>
    var pcmStart = 0
    var pcmPos = 0
    var pcmCount = 0
    var nextFrame = 0

    public init(_ bytes: [UInt8]) throws(AudioError) {
        self.bytes = bytes
        var meta = AudioMetadata()
        var start = 0
        let hasID3v2 = bytes.count >= 10 && bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33
        if hasID3v2 {
            ID3v2.read(bytes, into: &meta)
            start = min(bytes.count, ID3v2.totalSize(bytes))
        }
        var end = bytes.count
        if end - start >= 128, bytes[end - 128] == 0x54, bytes[end - 127] == 0x41, bytes[end - 126] == 0x47 {
            if !hasID3v2 { ID3v1.read(bytes, into: &meta) }
            end -= 128
        }
        if end - start >= 32 {
            let f = end - 32
            if Array(bytes[f..<(f + 8)]) == Array("APETAGEX".utf8) {
                func le32(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24 }
                let total = le32(f + 12) + (le32(f + 20) & 0x8000_0000 != 0 ? 32 : 0)
                if total > 0, total <= end - start { end -= total }
            }
        }
        metadata = meta
        dataEnd = end

        guard let first = MP3.sync(bytes, from: start, end: end, limit: 1 << 20, kind: nil),
              let h0 = MP3.header(bytes, at: first) else {
            throw AudioError("no MPEG Layer III frame found in the first megabyte after the tags; the file may be Layer I/II, free-format or not MP3 at all")
        }
        var offsets: [Int] = []
        offsets.reserveCapacity((end - first) / max(1, h0.frameBytes) + 16)
        var pos = first
        while pos + 4 <= end {
            if let h = MP3.header(bytes, at: pos), h.kind == h0.kind {
                if pos + h.frameBytes > end { break }
                offsets.append(pos)
                pos += h.frameBytes
                continue
            }
            guard let next = MP3.sync(bytes, from: pos + 1, end: end, limit: 64 * 1024, kind: h0.kind) else { break }
            pos = next
        }
        var delay = 0, padding = 0, gapless = false
        if offsets.first == first, let info = MP3.infoFrame(bytes, at: first, h0) {
            offsets.removeFirst()
            if let d = info.delay, let p = info.padding {
                delay = d; padding = p; gapless = true
                if let f = info.frames, f != offsets.count { padding = 0 }
            }
        }
        guard !offsets.isEmpty else { throw AudioError("the MP3 stream has a header frame but no audio frames; the file is truncated") }
        frames = offsets
        samplesPerFrame = h0.samples
        format = AudioFormat(sampleRate: h0.sampleRate, channels: h0.channels)
        encoderDelay = delay
        encoderPadding = padding
        isGapless = gapless
        skip = gapless ? delay + 529 : 0
        frameCount = max(0, offsets.count * h0.samples - (gapless ? delay + padding : 0))
        let seconds = Double(offsets.count * h0.samples) / Double(h0.sampleRate)
        bitrate = seconds > 0 ? Int(Double(end - offsets[0]) * 8 / seconds) : 0
        decoder = MP3FrameDecoder()
        pcm = .allocate(capacity: 1152 * 2)
        pcm.initialize(repeating: 0, count: 1152 * 2)
    }

    deinit { pcm.deallocate() }

    public func read(into buffer: UnsafeMutablePointer<Float>, frames n: Int) -> Int {
        let ch = format.channels
        let total = frameCount ?? Int.max
        var done = 0
        while done < n, position < total {
            if pcmPos == pcmCount {
                if !decodeNext() { break }
                continue
            }
            let global = pcmStart + pcmPos
            if global < skip { pcmPos = min(pcmCount, pcmPos + skip - global); continue }
            let take = min(n - done, pcmCount - pcmPos, total - position)
            (buffer + done * ch).update(from: pcm + pcmPos * ch, count: take * ch)
            pcmPos += take; done += take; position += take
        }
        return done
    }

    public func seek(toFrame target: Int) throws(AudioError) {
        let t = min(max(0, target), frameCount ?? Int.max)
        let global = t + skip
        let k = global / samplesPerFrame
        decoder.reset()
        // Earlier frames refill the bit reservoir (up to 511 bytes) and warm the filter banks.
        var s = min(k, frames.count)
        var back = 0
        while s > 0, k - s < 2 || back < 512 {
            s -= 1
            back += (s + 1 < frames.count ? frames[s + 1] : dataEnd) - frames[s]
        }
        nextFrame = s
        while nextFrame < k { if !decodeNext() { break } }
        pcmCount = 0; pcmPos = 0
        if nextFrame == k, decodeNext() { pcmPos = min(pcmCount, global - k * samplesPerFrame) }
        position = t
    }

    /// Decodes frame `nextFrame` into `pcm`; past the last frame, drains the
    /// filter banks with silence while the gapless length still needs samples.
    func decodeNext() -> Bool {
        let k = nextFrame
        let channels: Int
        if k < frames.count {
            channels = bytes.withUnsafeBufferPointer { b in decoder.decode(b.baseAddress!, count: dataEnd, at: frames[k], silentChannels: format.channels, silentGranules: samplesPerFrame / 576) }
        } else if let total = frameCount, k * samplesPerFrame < skip + total {
            decoder.decodeSilence(channels: format.channels, granules: samplesPerFrame / 576)
            channels = format.channels
        } else { return false }
        let n = samplesPerFrame
        let out = format.channels
        let src = decoder.planar
        if channels == out {
            for c in 0..<out { for i in 0..<n { pcm[i * out + c] = src[c * 1152 + i] } }
        } else if channels == 1 {
            for i in 0..<n { let v = src[i]; for c in 0..<out { pcm[i * out + c] = v } }
        } else {
            for i in 0..<n { pcm[i] = (src[i] + src[1152 + i]) * 0.5 }
        }
        pcmStart = k * samplesPerFrame
        pcmPos = 0
        pcmCount = n
        nextFrame = k + 1
        return true
    }
}

/// Side information for one granule of one channel.
struct MP3Granule {
    var part23 = 0
    var bigValues = 0
    var globalGain = 0
    var scalefacCompress = 0
    var windowSwitching = false
    var blockType = 0
    var mixed = false
    var table0 = 0, table1 = 0, table2 = 0
    var gain0 = 0, gain1 = 0, gain2 = 0
    var region0 = 0
    var region1 = 0
    var preflag = 0
    var scalefacScale = 0
    var count1Table = 0

    /// Block type with window switching applied (0 without it).
    var block: Int { windowSwitching ? blockType : 0 }
    var isShort: Bool { windowSwitching && blockType == 2 }
}

/// The per-stream state of Layer III decoding: bit reservoir, scalefactors
/// kept across granules, IMDCT overlap and synthesis history. All buffers are
/// allocated once; decoding a frame allocates nothing.
final class MP3FrameDecoder {
    static let reservoirCapacity = 4096
    static let maxBands = 40

    let reservoir: UnsafeMutablePointer<UInt8>
    var reservoirCount = 0
    /// Huffman values and requantised spectrum, 576 per channel.
    let values: UnsafeMutablePointer<Int32>
    let spectrum: UnsafeMutablePointer<Float>
    let overlap: UnsafeMutablePointer<Float>
    let history: UnsafeMutablePointer<Float>
    var historyOffset = (0, 0)
    let time: UnsafeMutablePointer<Float>
    let scratch: UnsafeMutablePointer<Float>
    /// Decoded PCM of the last frame: channel c at c * 1152.
    let planar: UnsafeMutablePointer<Float>
    /// Scalefactors: long bands at ch * 22 + sfb, short at ch * 39 + sfb * 3 + window,
    /// with the largest value each band could hold (LSF intensity marks illegal positions with it).
    let scaleLong: UnsafeMutablePointer<Int>
    let scaleShort: UnsafeMutablePointer<Int>
    let maxLong: UnsafeMutablePointer<Int>
    let maxShort: UnsafeMutablePointer<Int>
    let flat: UnsafeMutablePointer<Int>
    let flatMax: UnsafeMutablePointer<Int>
    var scfsi = [Int](repeating: 0, count: 8)
    /// Band layout of the current granule per channel: start, width, sfb, window (-1 long).
    let bandStart: UnsafeMutablePointer<Int>
    let bandWidth: UnsafeMutablePointer<Int>
    let bandSfb: UnsafeMutablePointer<Int>
    let bandWindow: UnsafeMutablePointer<Int>
    var bandCount = (0, 0)
    var nonzero = (0, 0)
    var granules = [MP3Granule](repeating: MP3Granule(), count: 4)
    var intensityScale = 0

    static func buffer<T>(_ count: Int, _ zero: T) -> UnsafeMutablePointer<T> {
        let p = UnsafeMutablePointer<T>.allocate(capacity: count)
        p.initialize(repeating: zero, count: count)
        return p
    }

    init() {
        reservoir = Self.buffer(Self.reservoirCapacity, 0)
        values = Self.buffer(2 * 576, 0)
        spectrum = Self.buffer(2 * 576, 0)
        overlap = Self.buffer(2 * 576, 0)
        history = Self.buffer(2 * 1024, 0)
        time = Self.buffer(576, 0)
        scratch = Self.buffer(576, 0)
        planar = Self.buffer(2 * 1152, 0)
        scaleLong = Self.buffer(2 * 22, 0)
        scaleShort = Self.buffer(2 * 39, 0)
        maxLong = Self.buffer(2 * 22, 0)
        maxShort = Self.buffer(2 * 39, 0)
        flat = Self.buffer(48, 0)
        flatMax = Self.buffer(48, 0)
        bandStart = Self.buffer(2 * Self.maxBands, 0)
        bandWidth = Self.buffer(2 * Self.maxBands, 0)
        bandSfb = Self.buffer(2 * Self.maxBands, 0)
        bandWindow = Self.buffer(2 * Self.maxBands, 0)
    }

    deinit {
        reservoir.deallocate(); values.deallocate(); spectrum.deallocate(); overlap.deallocate()
        history.deallocate(); time.deallocate(); scratch.deallocate(); planar.deallocate()
        scaleLong.deallocate(); scaleShort.deallocate(); maxLong.deallocate(); maxShort.deallocate()
        flat.deallocate(); flatMax.deallocate()
        bandStart.deallocate(); bandWidth.deallocate(); bandSfb.deallocate(); bandWindow.deallocate()
    }

    /// Forgets everything carried between frames (after a seek).
    func reset() {
        reservoirCount = 0
        overlap.update(repeating: 0, count: 2 * 576)
        history.update(repeating: 0, count: 2 * 1024)
        historyOffset = (0, 0)
        scaleLong.update(repeating: 0, count: 2 * 22)
        scaleShort.update(repeating: 0, count: 2 * 39)
    }

    // MARK: Frame

    /// Decodes the frame at `offset` into `planar` and returns its channel
    /// count. A frame whose bit reservoir is missing (right after a seek) or
    /// whose header is damaged plays as silence through the filter banks.
    func decode(_ p: UnsafePointer<UInt8>, count: Int, at offset: Int, silentChannels: Int, silentGranules: Int) -> Int {
        guard let h = MP3.header(p, count: count, at: offset) else {
            decodeSilence(channels: silentChannels, granules: silentGranules)
            return silentChannels
        }
        let channels = h.channels
        let sideStart = offset + 4 + (h.crc ? 2 : 0)
        let sideEnd = sideStart + h.sideInfoBytes
        let frameEnd = min(offset + h.frameBytes, count)
        guard sideEnd <= frameEnd else {
            decodeSilence(channels: channels, granules: h.granules)
            return channels
        }
        var side = BitReader(p + sideStart, count: h.sideInfoBytes)
        let mainDataBegin = readSideInfo(&side, h)

        let keep = min(reservoirCount, 511)
        if keep > 0, keep < reservoirCount { reservoir.update(from: reservoir + (reservoirCount - keep), count: keep) }
        let length = min(frameEnd - sideEnd, Self.reservoirCapacity - keep)
        (reservoir + keep).update(from: p + sideEnd, count: length)
        reservoirCount = keep + length
        guard mainDataBegin <= keep else {
            decodeSilence(channels: channels, granules: h.granules)
            return channels
        }

        var main = BitReader(UnsafePointer(reservoir), count: reservoirCount, bitPosition: (keep - mainDataBegin) * 8)
        for gr in 0..<h.granules {
            for ch in 0..<channels {
                let index = gr * 2 + ch
                let start = main.position
                layout(ch, granules[index], h)
                if h.mpeg1 { readScalefactors(&main, gr: gr, ch: ch, h) } else { readScalefactorsLSF(&main, index: index, ch: ch, h) }
                let n = readHuffman(&main, ch: ch, granules[index], end: start + granules[index].part23)
                setNonzero(ch, n)
                main.position = start + granules[index].part23
                requantise(ch, granules[index])
            }
            if channels == 2, h.mode == 1, h.modeExtension != 0 { stereo(gr, h) }
            for ch in 0..<channels { hybrid(ch, granules[gr * 2 + ch], h, silent: false, out: planar + ch * 1152 + gr * 576) }
        }
        return channels
    }

    /// Runs the filter banks on an all-zero spectrum: drains the overlap and
    /// synthesis history (end of stream, undecodable frames).
    func decodeSilence(channels: Int, granules count: Int) {
        let h = MP3Header(mpeg1: true, rateIndex: 0, crc: false, bitrate: 0, sampleRate: 44100, padding: 0, mode: 0,
                          modeExtension: 0, frameBytes: 0, kind: 0)
        for gr in 0..<count {
            for ch in 0..<channels {
                (spectrum + ch * 576).update(repeating: 0, count: 576)
                hybrid(ch, MP3Granule(), h, silent: true, out: planar + ch * 1152 + gr * 576)
            }
        }
    }

    func setNonzero(_ ch: Int, _ n: Int) { if ch == 0 { nonzero.0 = n } else { nonzero.1 = n } }
    func nonzeroCount(_ ch: Int) -> Int { ch == 0 ? nonzero.0 : nonzero.1 }

    // MARK: Side information

    func readSideInfo(_ br: inout BitReader, _ h: MP3Header) -> Int {
        let channels = h.channels
        let mainDataBegin: Int
        if h.mpeg1 {
            mainDataBegin = Int(br.read(9))
            br.skip(channels == 1 ? 5 : 3)
            for ch in 0..<channels { for g in 0..<4 { scfsi[ch * 4 + g] = Int(br.read(1)) } }
        } else {
            mainDataBegin = Int(br.read(8))
            br.skip(channels == 1 ? 1 : 2)
        }
        for gr in 0..<h.granules {
            for ch in 0..<channels {
                var g = MP3Granule()
                g.part23 = Int(br.read(12))
                g.bigValues = min(288, Int(br.read(9)))
                g.globalGain = Int(br.read(8))
                g.scalefacCompress = Int(br.read(h.mpeg1 ? 4 : 9))
                g.windowSwitching = br.bit()
                if g.windowSwitching {
                    g.blockType = Int(br.read(2))
                    g.mixed = br.bit()
                    g.table0 = Int(br.read(5)); g.table1 = Int(br.read(5)); g.table2 = 0
                    g.gain0 = Int(br.read(3)); g.gain1 = Int(br.read(3)); g.gain2 = Int(br.read(3))
                    g.region0 = g.blockType == 2 && !g.mixed ? 8 : 7
                    g.region1 = 255
                } else {
                    g.table0 = Int(br.read(5)); g.table1 = Int(br.read(5)); g.table2 = Int(br.read(5))
                    g.region0 = Int(br.read(4))
                    g.region1 = Int(br.read(3))
                }
                if h.mpeg1 { g.preflag = Int(br.read(1)) }
                g.scalefacScale = Int(br.read(1))
                g.count1Table = Int(br.read(1))
                granules[gr * 2 + ch] = g
            }
        }
        return mainDataBegin
    }

    /// The scalefactor band layout of one granule, in the order the spectrum
    /// is coded (short blocks: band by band, each band's three windows in turn).
    func layout(_ ch: Int, _ g: MP3Granule, _ h: MP3Header) {
        let l = MP3Tables.longBands[h.rateIndex], s = MP3Tables.shortBands[h.rateIndex]
        let base = ch * Self.maxBands
        var n = 0
        func add(_ start: Int, _ width: Int, _ sfb: Int, _ window: Int) {
            bandStart[base + n] = start; bandWidth[base + n] = width; bandSfb[base + n] = sfb; bandWindow[base + n] = window
            n += 1
        }
        if g.isShort {
            var first = 0
            if g.mixed {
                for sfb in 0..<(h.mpeg1 ? 8 : 6) { add(l[sfb], l[sfb + 1] - l[sfb], sfb, -1) }
                first = 3
            }
            for sfb in first..<13 {
                let w = s[sfb + 1] - s[sfb]
                for window in 0..<3 { add(3 * s[sfb] + window * w, w, sfb, window) }
            }
        } else {
            for sfb in 0..<22 { add(l[sfb], l[sfb + 1] - l[sfb], sfb, -1) }
        }
        if ch == 0 { bandCount.0 = n } else { bandCount.1 = n }
    }

    func bands(_ ch: Int) -> Int { ch == 0 ? bandCount.0 : bandCount.1 }

    // MARK: Scalefactors

    func readScalefactors(_ br: inout BitReader, gr: Int, ch: Int, _ h: MP3Header) {
        let g = granules[gr * 2 + ch]
        let slen1 = MP3Tables.slen1[g.scalefacCompress], slen2 = MP3Tables.slen2[g.scalefacCompress]
        let sl = scaleLong + ch * 22, ss = scaleShort + ch * 39
        if g.isShort {
            var first = 0
            if g.mixed {
                for sfb in 0..<8 { sl[sfb] = Int(br.read(slen1)) }
                first = 3
            }
            for sfb in first..<12 {
                let bits = sfb < 6 ? slen1 : slen2
                for w in 0..<3 { ss[sfb * 3 + w] = Int(br.read(bits)) }
            }
            for w in 0..<3 { ss[36 + w] = 0 }
        } else {
            let groups = (0, 6, 11, 16, 21)
            for group in 0..<4 {
                let lo: Int, hi: Int
                switch group {
                case 0: (lo, hi) = (groups.0, groups.1)
                case 1: (lo, hi) = (groups.1, groups.2)
                case 2: (lo, hi) = (groups.2, groups.3)
                default: (lo, hi) = (groups.3, groups.4)
                }
                if gr == 1, scfsi[ch * 4 + group] != 0 { continue }
                let bits = group < 2 ? slen1 : slen2
                for sfb in lo..<hi { sl[sfb] = Int(br.read(bits)) }
            }
            sl[21] = 0
        }
    }

    func readScalefactorsLSF(_ br: inout BitReader, index: Int, ch: Int, _ h: MP3Header) {
        let g = granules[index]
        let sfc = g.scalefacCompress
        var s0 = 0, s1 = 0, s2 = 0, s3 = 0
        var table = 0
        var preflag = 0
        if h.mode == 1, h.modeExtension & 1 != 0, ch == 1 {
            let isc = sfc >> 1
            intensityScale = sfc & 1
            if isc < 180 { (s0, s1, s2, s3) = (isc / 36, (isc % 36) / 6, isc % 6, 0); table = 3 }
            else if isc < 244 { let t = isc - 180; (s0, s1, s2, s3) = ((t % 64) >> 4, (t % 16) >> 2, t % 4, 0); table = 4 }
            else { let t = isc - 244; (s0, s1, s2, s3) = (t / 3, t % 3, 0, 0); table = 5 }
        } else {
            if sfc < 400 { (s0, s1, s2, s3) = ((sfc >> 4) / 5, (sfc >> 4) % 5, (sfc & 15) >> 2, sfc & 3); table = 0 }
            else if sfc < 500 { let t = sfc - 400; (s0, s1, s2, s3) = ((t >> 2) / 5, (t >> 2) % 5, t & 3, 0); table = 1 }
            else { let t = sfc - 500; (s0, s1, s2, s3) = (t / 3, t % 3, 0, 0); table = 2; preflag = 1 }
        }
        granules[index].preflag = preflag
        let kind = g.isShort ? (g.mixed ? 2 : 1) : 0
        let counts = MP3Tables.lsfBandCounts[table][kind]
        var n = 0
        for part in 0..<4 {
            let bits: Int
            switch part {
            case 0: bits = s0
            case 1: bits = s1
            case 2: bits = s2
            default: bits = s3
            }
            for _ in 0..<counts[part] where n < 48 {
                flat[n] = Int(br.read(bits))
                flatMax[n] = (1 << bits) - 1
                n += 1
            }
        }
        for i in n..<48 { flat[i] = 0; flatMax[i] = 0 }
        let sl = scaleLong + ch * 22, ss = scaleShort + ch * 39
        let ml = maxLong + ch * 22, ms = maxShort + ch * 39
        switch kind {
        case 0:
            for i in 0..<21 { sl[i] = flat[i]; ml[i] = flatMax[i] }
            sl[21] = 0; ml[21] = 0
        case 1:
            for i in 0..<36 { ss[i] = flat[i]; ms[i] = flatMax[i] }
            for w in 0..<3 { ss[36 + w] = 0; ms[36 + w] = 0 }
        default:
            for i in 0..<6 { sl[i] = flat[i]; ml[i] = flatMax[i] }
            for sfb in 3..<12 {
                for w in 0..<3 { ss[sfb * 3 + w] = flat[6 + (sfb - 3) * 3 + w]; ms[sfb * 3 + w] = flatMax[6 + (sfb - 3) * 3 + w] }
            }
            for w in 0..<3 { ss[36 + w] = 0; ms[36 + w] = 0 }
        }
    }

    // MARK: Huffman

    /// Decodes the big-values and count1 regions; returns how many lines were coded.
    func readHuffman(_ br: inout BitReader, ch: Int, _ g: MP3Granule, end: Int) -> Int {
        let out = values + ch * 576
        let base = ch * Self.maxBands
        let count = bands(ch)
        let bigEnd = min(g.bigValues * 2, 576)
        let r1Index = g.region0 + 1, r2Index = g.region0 + g.region1 + 2
        let region1 = min(r1Index < count ? bandStart[base + r1Index] : 576, bigEnd)
        let region2 = min(g.region1 != 255 && r2Index < count ? bandStart[base + r2Index] : 576, bigEnd)
        var i = 0
        for region in 0..<3 {
            let hi = region == 0 ? region1 : region == 1 ? region2 : bigEnd
            let select = region == 0 ? g.table0 : region == 1 ? g.table1 : g.table2
            let (number, linbits) = MP3Tables.selection[select]
            guard number != 0, let table = MP3DSP.huffman[number] else {
                while i < hi { out[i] = 0; out[i + 1] = 0; i += 2 }
                continue
            }
            while i < hi {
                let v = table.decode(&br)
                var x = Int32(v >> 4), y = Int32(v & 15)
                if linbits > 0, x == 15 { x += Int32(br.read(linbits)) }
                if x != 0, br.bit() { x = -x }
                if linbits > 0, y == 15 { y += Int32(br.read(linbits)) }
                if y != 0, br.bit() { y = -y }
                out[i] = x; out[i + 1] = y
                i += 2
            }
        }
        let quad = MP3DSP.huffman[32]!
        while i <= 572, br.position < end {
            let q = g.count1Table == 0 ? quad.decode(&br) : Int(15 - br.read(4))
            var a = Int32(q >> 3 & 1), b = Int32(q >> 2 & 1), c = Int32(q >> 1 & 1), d = Int32(q & 1)
            if a != 0, br.bit() { a = -1 }
            if b != 0, br.bit() { b = -1 }
            if c != 0, br.bit() { c = -1 }
            if d != 0, br.bit() { d = -1 }
            if br.position > end { break }
            out[i] = a; out[i + 1] = b; out[i + 2] = c; out[i + 3] = d
            i += 4
        }
        return i
    }

    // MARK: Requantisation

    func requantise(_ ch: Int, _ g: MP3Granule) {
        let x = spectrum + ch * 576, v = values + ch * 576
        let n = nonzeroCount(ch)
        let gain = g.globalGain - 210
        let shift = g.scalefacScale != 0 ? 4 : 2
        let base = ch * Self.maxBands
        let sl = scaleLong + ch * 22, ss = scaleShort + ch * 39
        let pow43 = MP3DSP.pow43
        for e in 0..<bands(ch) {
            let start = bandStart[base + e]
            if start >= n { break }
            let end = min(start + bandWidth[base + e], n)
            let sfb = bandSfb[base + e], w = bandWindow[base + e]
            let q: Int
            if w < 0 {
                q = gain - shift * (sl[sfb] + (g.preflag != 0 ? MP3Tables.pretab[sfb] : 0))
            } else {
                let sub = w == 0 ? g.gain0 : w == 1 ? g.gain1 : g.gain2
                q = gain - 8 * sub - shift * ss[sfb * 3 + w]
            }
            let scale = Float(MP3DSP.pow2Quarter(q))
            for i in start..<end {
                let a = v[i]
                x[i] = a == 0 ? 0 : a > 0 ? pow43[Int(a)] * scale : -pow43[Int(-a)] * scale
            }
        }
        if n < 576 { (x + n).update(repeating: 0, count: 576 - n) }
    }

    // MARK: Stereo

    func stereo(_ gr: Int, _ h: MP3Header) {
        let l = spectrum, r = spectrum + 576
        let ms = h.modeExtension & 2 != 0
        let intensity = h.modeExtension & 1 != 0
        let n = max(nonzeroCount(0), nonzeroCount(1))
        let k = Float(0.7071067811865476)
        func midSide(_ lo: Int, _ hi: Int) {
            for i in lo..<hi { let m = l[i], s = r[i]; l[i] = (m + s) * k; r[i] = (m - s) * k }
        }
        guard intensity else {
            if ms { midSide(0, n) }
            setNonzero(0, n); setNonzero(1, n)
            return
        }
        // Intensity bands are those above the highest band with right-channel
        // values, per window for short blocks; their positions are the right
        // channel's scalefactors.
        let base = 1 * Self.maxBands
        let count = bands(1)
        var lastLong = -1, lastShort = (-1, -1, -1), anyShort = false
        for e in 0..<count {
            let start = bandStart[base + e], end = start + bandWidth[base + e]
            var nz = false
            for i in start..<end where r[i] != 0 { nz = true; break }
            guard nz else { continue }
            let sfb = bandSfb[base + e]
            switch bandWindow[base + e] {
            case -1: lastLong = max(lastLong, sfb)
            case 0: lastShort.0 = max(lastShort.0, sfb); anyShort = true
            case 1: lastShort.1 = max(lastShort.1, sfb); anyShort = true
            default: lastShort.2 = max(lastShort.2, sfb); anyShort = true
            }
        }
        for e in 0..<count {
            let start = bandStart[base + e], end = start + bandWidth[base + e]
            let sfb = bandSfb[base + e], w = bandWindow[base + e]
            let isIntensity: Bool
            switch w {
            case -1: isIntensity = !anyShort && sfb > lastLong
            case 0: isIntensity = sfb > lastShort.0
            case 1: isIntensity = sfb > lastShort.1
            default: isIntensity = sfb > lastShort.2
            }
            if isIntensity {
                let position: Int, illegal: Int
                if w < 0 {
                    let b = min(sfb, 20)
                    position = scaleLong[22 + b]; illegal = h.mpeg1 ? 7 : maxLong[22 + b]
                } else {
                    let b = min(sfb, 11)
                    position = scaleShort[39 + b * 3 + w]; illegal = h.mpeg1 ? 7 : maxShort[39 + b * 3 + w]
                }
                if position < illegal {
                    var kl: Float = 1, kr: Float = 1
                    if h.mpeg1 {
                        kl = MP3DSP.intensityLeft[position]; kr = MP3DSP.intensityRight[position]
                    } else if position > 0 {
                        let step = -(1 + intensityScale)
                        if position & 1 == 1 { kl = Float(MP3DSP.pow2Quarter(step * ((position + 1) / 2))) }
                        else { kr = Float(MP3DSP.pow2Quarter(step * (position / 2))) }
                    }
                    for i in start..<end { let v = l[i]; l[i] = v * kl; r[i] = v * kr }
                    continue
                }
            }
            if ms { midSide(start, end) }
        }
        setNonzero(0, 576); setNonzero(1, 576)
    }

    // MARK: Hybrid filter bank and synthesis

    func hybrid(_ ch: Int, _ g: MP3Granule, _ h: MP3Header, silent: Bool, out: UnsafeMutablePointer<Float>) {
        let x = spectrum + ch * 576
        let block = silent ? 0 : g.block
        let mixed = !silent && g.isShort && g.mixed
        if block == 2 {
            let s = MP3Tables.shortBands[h.rateIndex]
            for sfb in (mixed ? 3 : 0)..<13 {
                let w = s[sfb + 1] - s[sfb]
                let start = 3 * s[sfb]
                for j in 0..<w { for window in 0..<3 { scratch[3 * j + window] = x[start + window * w + j] } }
                (x + start).update(from: scratch, count: 3 * w)
            }
        }
        if block != 2 || mixed {
            let limit = block == 2 ? 1 : 31
            let cs = MP3DSP.aliasCS, ca = MP3DSP.aliasCA
            for sb in 1...limit {
                for i in 0..<8 {
                    let up = x[18 * sb - 1 - i], down = x[18 * sb + i]
                    x[18 * sb - 1 - i] = up * cs[i] - down * ca[i]
                    x[18 * sb + i] = down * cs[i] + up * ca[i]
                }
            }
        }
        let ov = overlap + ch * 576
        for sb in 0..<32 {
            let type = block == 2 ? (mixed && sb < 2 ? 0 : 2) : block
            MP3DSP.imdct(x + 18 * sb, type: type, overlap: ov + 18 * sb, out: time + 18 * sb)
            if sb & 1 == 1 { for t in stride(from: 1, to: 18, by: 2) { time[18 * sb + t] = -time[18 * sb + t] } }
        }
        let v = history + ch * 1024
        var offset = ch == 0 ? historyOffset.0 : historyOffset.1
        withUnsafeTemporaryAllocation(of: Float.self, capacity: 32) { sb in
            let s = sb.baseAddress!
            for t in 0..<18 {
                for k in 0..<32 { s[k] = time[18 * k + t] }
                MP3DSP.synthesize(s, v: v, offset: &offset, out: out + 32 * t)
            }
        }
        if ch == 0 { historyOffset.0 = offset } else { historyOffset.1 = offset }
    }
}
