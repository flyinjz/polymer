// Pure-Swift MPEG-1 / MPEG-2 / MPEG-2.5 Layer III (MP3) frame decoder
// and self-contained MPEG-1 Layer III test frame synthesizer.
// Standard library only — no Foundation, no OS codecs, bounds-checked throughout.
import PolymerBase

// MARK: - MP3 Frame Header

/// Parsed MPEG audio frame header for Layer III (MP3) streams.
public struct MP3FrameHeader: Equatable, Hashable, Sendable {
    public enum MPEGVersion: Equatable, Hashable, Sendable {
        case mpeg1
        case mpeg2
        case mpeg2_5
    }

    public enum ChannelMode: Equatable, Hashable, Sendable {
        case stereo
        case jointStereo
        case dualChannel
        case mono
    }

    public var version: MPEGVersion
    public var layer: Int
    public var hasCRC: Bool
    public var bitrateKbps: Int
    public var sampleRate: Int
    public var hasPadding: Bool
    public var channelMode: ChannelMode
    public var intensityStereo: Bool
    public var msStereo: Bool
    public var frameSizeBytes: Int
    public var samplesPerFrame: Int

    public var channelCount: Int {
        channelMode == .mono ? 1 : 2
    }

    public var granuleCount: Int {
        version == .mpeg1 ? 2 : 1
    }

    public var sideInfoSizeBytes: Int {
        if version == .mpeg1 {
            return channelMode == .mono ? 17 : 32
        } else {
            return channelMode == .mono ? 9 : 17
        }
    }

    private static let mpeg1L3Bitrates = [
        0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0
    ]
    private static let mpeg2L3Bitrates = [
        0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0
    ]
    private static let mpeg1SampleRates = [44_100, 48_000, 32_000]
    private static let mpeg2SampleRates = [22_050, 24_000, 16_000]
    private static let mpeg25SampleRates = [11_025, 12_000, 8_000]

    /// Parses and validates a 4-byte MPEG Layer III frame header at `offset`.
    public static func parse(from data: [UInt8], at offset: Int) -> MP3FrameHeader? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let b0 = data[offset]
        let b1 = data[offset + 1]
        let b2 = data[offset + 2]
        let b3 = data[offset + 3]

        // 11-bit frame sync word: 0xFFE
        guard b0 == 0xFF, (b1 & 0xE0) == 0xE0 else { return nil }

        let versionBits = (b1 >> 3) & 0x03
        let version: MPEGVersion
        switch versionBits {
        case 0: version = .mpeg2_5
        case 2: version = .mpeg2
        case 3: version = .mpeg1
        default: return nil
        }

        // Layer bits: 1 = Layer III, 2 = Layer II, 3 = Layer I, 0 = reserved.
        let layerBits = (b1 >> 1) & 0x03
        guard layerBits == 1 else { return nil }
        let layer = 3

        let hasCRC = (b1 & 0x01) == 0

        let bitrateIdx = Int((b2 >> 4) & 0x0F)
        guard bitrateIdx >= 1 && bitrateIdx <= 14 else { return nil }
        let bitrateKbps = (version == .mpeg1) ? mpeg1L3Bitrates[bitrateIdx] : mpeg2L3Bitrates[bitrateIdx]

        let srIdx = Int((b2 >> 2) & 0x03)
        guard srIdx < 3 else { return nil }
        let sampleRate: Int
        switch version {
        case .mpeg1: sampleRate = mpeg1SampleRates[srIdx]
        case .mpeg2: sampleRate = mpeg2SampleRates[srIdx]
        case .mpeg2_5: sampleRate = mpeg25SampleRates[srIdx]
        }

        let hasPadding = ((b2 >> 1) & 0x01) != 0

        let modeBits = (b3 >> 6) & 0x03
        let channelMode: ChannelMode
        switch modeBits {
        case 0: channelMode = .stereo
        case 1: channelMode = .jointStereo
        case 2: channelMode = .dualChannel
        default: channelMode = .mono
        }

        let modeExt = (b3 >> 4) & 0x03
        let intensityStereo = (channelMode == .jointStereo) && ((modeExt & 0x01) != 0)
        let msStereo = (channelMode == .jointStereo) && ((modeExt & 0x02) != 0)

        let samplesPerFrame = (version == .mpeg1) ? 1152 : 576
        let frameSizeBytes = ((samplesPerFrame / 8) * bitrateKbps * 1000) / sampleRate + (hasPadding ? 1 : 0)
        let minHeaderBytes = 4 + (hasCRC ? 2 : 0) + (version == .mpeg1 ? (channelMode == .mono ? 17 : 32) : (channelMode == .mono ? 9 : 17))
        guard frameSizeBytes >= minHeaderBytes else { return nil }

        return MP3FrameHeader(
            version: version,
            layer: layer,
            hasCRC: hasCRC,
            bitrateKbps: bitrateKbps,
            sampleRate: sampleRate,
            hasPadding: hasPadding,
            channelMode: channelMode,
            intensityStereo: intensityStereo,
            msStereo: msStereo,
            frameSizeBytes: frameSizeBytes,
            samplesPerFrame: samplesPerFrame
        )
    }
}

// MARK: - Bit Reader & Writer for Layer III

private struct MP3BitReader {
    let data: [UInt8]
    var bitPos: Int
    let endBit: Int

    init(_ data: [UInt8], bitOffset: Int = 0, bitEnd: Int? = nil) {
        self.data = data
        self.bitPos = max(0, bitOffset)
        self.endBit = min(data.count * 8, bitEnd ?? (data.count * 8))
    }

    var remainingBits: Int { max(0, endBit - bitPos) }

    @inline(__always)
    mutating func readBit() -> Int {
        guard bitPos < endBit else { return 0 }
        let byte = data[bitPos >> 3]
        let shift = 7 - (bitPos & 7)
        bitPos += 1
        return Int((byte >> shift) & 1)
    }

    @inline(__always)
    mutating func readBits(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        var val = 0
        var rem = count
        while rem > 0 {
            if bitPos >= endBit {
                val <<= rem
                break
            }
            let byteIdx = bitPos >> 3
            let bitInByte = bitPos & 7
            let avail = min(8 - bitInByte, endBit - bitPos)
            let take = min(rem, avail)
            let shift = 8 - bitInByte - take
            let mask: UInt8 = take == 8 ? 0xFF : UInt8((1 << take) - 1)
            let chunk = (data[byteIdx] >> shift) & mask
            val = (val << take) | Int(chunk)
            bitPos += take
            rem -= take
        }
        return val
    }
}

private struct MP3BitWriter {
    var bytes: [UInt8] = []
    private var curByte: UInt8 = 0
    private var bitsFilled: Int = 0
    var bitCount: Int { bytes.count * 8 + bitsFilled }

    mutating func writeBits(_ value: Int, count: Int) {
        guard count > 0 else { return }
        var rem = count
        let uval = UInt32(bitPattern: Int32(truncatingIfNeeded: value))
        while rem > 0 {
            let space = 8 - bitsFilled
            let take = min(rem, space)
            let shift = rem - take
            let mask: UInt32 = take == 32 ? UInt32.max : ((UInt32(1) << UInt32(take)) - 1)
            let chunk = UInt8((uval >> UInt32(shift)) & mask)
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

    mutating func alignToByte() {
        if bitsFilled > 0 {
            curByte <<= UInt8(8 - bitsFilled)
            bytes.append(curByte)
            curByte = 0
            bitsFilled = 0
        }
    }
}

// MARK: - ISO/IEC 11172-3 Tables (Scale Factor Bands, Huffman, IMDCT, Synthesis Window)

private struct HuffmanCode: Sendable {
    var code: UInt32
    var length: UInt8
}

private struct HuffmanTreeNode: Sendable {
    var left: Int16   // bit 0 child index, or -1 if leaf
    var right: Int16  // bit 1 child index, or -1 if leaf
    var x: UInt8
    var y: UInt8
}

private struct HuffmanTableSpec: Sendable {
    let dim: Int
    let linbits: Int
    let nodes: [HuffmanTreeNode]
    let codes: [HuffmanCode] // dim * dim entries in row-major (x * dim + y) order

    @inline(__always)
    func decode(_ reader: inout MP3BitReader) -> (Int, Int) {
        guard !nodes.isEmpty else { return (0, 0) }
        var idx = 0
        while true {
            let node = nodes[idx]
            if node.left < 0 && node.right < 0 {
                return (Int(node.x), Int(node.y))
            }
            let bit = reader.readBit()
            let next = bit == 0 ? Int(node.left) : Int(node.right)
            if next < 0 || next >= nodes.count {
                return (0, 0)
            }
            idx = next
        }
    }
}

private enum MP3Tables {
    static let slen1: [Int] = [0, 0, 0, 0, 3, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4]
    static let slen2: [Int] = [0, 1, 2, 3, 0, 1, 2, 3, 1, 2, 3, 1, 2, 3, 2, 3]
    static let pretab: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 3, 2, 0]

    // Scale factor band indices for each MPEG version / sample rate.
    static func sfBandLong(sampleRate: Int) -> [Int] {
        switch sampleRate {
        case 44_100: return [0, 4, 8, 12, 16, 20, 24, 30, 36, 44, 52, 62, 74, 90, 110, 134, 162, 196, 238, 288, 342, 418, 576]
        case 48_000: return [0, 4, 8, 12, 16, 20, 24, 30, 36, 42, 50, 60, 72, 88, 106, 128, 156, 190, 230, 276, 330, 384, 576]
        case 32_000: return [0, 4, 8, 12, 16, 20, 24, 30, 36, 44, 54, 66, 82, 102, 126, 156, 194, 240, 296, 364, 448, 550, 576]
        case 24_000: return [0, 6, 12, 18, 24, 30, 36, 44, 54, 66, 80, 96, 114, 136, 162, 194, 232, 278, 330, 394, 464, 540, 576]
        case 8_000:  return [0, 12, 24, 36, 48, 60, 72, 88, 108, 132, 160, 192, 232, 280, 336, 400, 476, 566, 568, 570, 572, 574, 576]
        default:     return [0, 6, 12, 18, 24, 30, 36, 44, 54, 66, 80, 96, 116, 140, 168, 200, 238, 284, 336, 396, 464, 522, 576]
        }
    }

    static func sfBandShort(sampleRate: Int) -> [Int] {
        switch sampleRate {
        case 44_100: return [0, 4, 8, 12, 16, 22, 30, 40, 52, 66, 84, 106, 136, 192]
        case 48_000: return [0, 4, 8, 12, 16, 22, 28, 38, 50, 64, 80, 100, 126, 192]
        case 32_000: return [0, 4, 8, 12, 16, 22, 30, 42, 58, 78, 104, 138, 180, 192]
        case 22_050: return [0, 4, 8, 12, 18, 24, 32, 42, 56, 74, 100, 132, 174, 192]
        case 24_000: return [0, 4, 8, 12, 18, 26, 36, 48, 62, 80, 104, 136, 180, 192]
        case 8_000:  return [0, 8, 16, 24, 36, 52, 72, 96, 124, 160, 162, 164, 166, 192]
        default:     return [0, 4, 8, 12, 18, 26, 36, 48, 62, 80, 104, 134, 174, 192]
        }
    }

    /// Precomputed `|is|^(4/3)` lookup table for `0...8206`.
    static let pow43: [Double] = (0...8206).map { i in
        i == 0 ? 0.0 : pow(base: Double(i), 4.0 / 3.0)
    }

    /// Exact `2^(x / 4)` for any integer `x` using `Double(sign:exponent:significand:)`.
    @inline(__always)
    static func pow2Quarter(_ quarterSteps: Int) -> Double {
        // 2^(0/4), 2^(1/4), 2^(2/4), 2^(3/4)
        let frac: Double
        var q = quarterSteps >> 2
        var r = quarterSteps & 3
        if r < 0 {
            r += 4
            q -= 1
        }
        switch r {
        case 0: frac = 1.0
        case 1: frac = 1.18920711500272106672
        case 2: frac = 1.41421356237309504880
        default: frac = 1.68179283050742908606
        }
        if q < -1000 { return 0.0 }
        if q > 1000 { return .infinity }
        return Double(sign: .plus, exponent: q, significand: frac)
    }

    // Alias reduction butterfly coefficients (ISO/IEC 11172-3 §2.4.3.4.9).
    static let aliasCS: [Double] = {
        let ci: [Double] = [-0.6, -0.535, -0.33, -0.185, -0.095, -0.041, -0.0142, -0.0037]
        return ci.map { 1.0 / (1.0 + $0 * $0).squareRoot() }
    }()
    static let aliasCA: [Double] = {
        let ci: [Double] = [-0.6, -0.535, -0.33, -0.185, -0.095, -0.041, -0.0142, -0.0037]
        return ci.map { $0 / (1.0 + $0 * $0).squareRoot() }
    }()

    // 36-point long IMDCT cosine matrix [36][18] and 12-point short IMDCT matrix [12][6].
    static let imdct36Cos: [Double] = {
        var m = [Double](repeating: 0.0, count: 36 * 18)
        for i in 0..<36 {
            for k in 0..<18 {
                let angle = (Double.pi / 72.0) * Double(2 * i + 1 + 18) * Double(2 * k + 1)
                m[i * 18 + k] = Math.cos(angle)
            }
        }
        return m
    }()

    static let imdct12Cos: [Double] = {
        var m = [Double](repeating: 0.0, count: 12 * 6)
        for i in 0..<12 {
            for k in 0..<6 {
                let angle = (Double.pi / 24.0) * Double(2 * i + 1 + 6) * Double(2 * k + 1)
                m[i * 6 + k] = Math.cos(angle)
            }
        }
        return m
    }()

    // IMDCT windows for block_type 0 (normal), 1 (start), 2 (short, 12-pt), 3 (stop).
    static let windowNormal: [Double] = (0..<36).map { i in
        Math.sin((Double.pi / 36.0) * (Double(i) + 0.5))
    }
    static let windowStart: [Double] = (0..<36).map { i in
        if i < 18 { return Math.sin((Double.pi / 36.0) * (Double(i) + 0.5)) }
        if i < 24 { return 1.0 }
        if i < 30 { return Math.sin((Double.pi / 12.0) * (Double(i - 18) + 0.5)) }
        return 0.0
    }
    static let windowShort: [Double] = (0..<12).map { i in
        Math.sin((Double.pi / 12.0) * (Double(i) + 0.5))
    }
    static let windowStop: [Double] = (0..<36).map { i in
        if i < 6 { return 0.0 }
        if i < 12 { return Math.sin((Double.pi / 12.0) * (Double(i - 6) + 0.5)) }
        if i < 18 { return 1.0 }
        return Math.sin((Double.pi / 36.0) * (Double(i) + 0.5))
    }

    // 32-band polyphase synthesis DCT-32 matrix [64][32]: cos((16 + i) * (2k + 1) * pi / 64).
    static let synthMatrix: [Double] = {
        var m = [Double](repeating: 0.0, count: 64 * 32)
        for i in 0..<64 {
            for k in 0..<32 {
                let angle = Double(16 + i) * Double(2 * k + 1) * Double.pi / 64.0
                m[i * 32 + k] = Math.cos(angle)
            }
        }
        return m
    }()

    /// 512-tap polyphase synthesis window `D[512]` with ISO/IEC 11172-3 sign alternation
    /// (`D[512 - n] = -D[n]`, `D[0] = 0`, Kaiser-windowed sinc PQMF prototype normalized for
    /// unity subband reconstruction gain).
    static let synthWindowD: [Double] = {
        let beta = 9.0
        let invI0 = 1.0 / AudioMath.besselI0(beta)
        var proto = [Double](repeating: 0.0, count: 512)
        for n in 1..<512 {
            let x = Double(n - 256) / 64.0
            let norm = Double(n - 256) / 256.0
            let w: Double
            if abs(norm) >= 1.0 {
                w = 0.0
            } else {
                w = AudioMath.besselI0(beta * (1.0 - norm * norm).squareRoot()) * invI0
            }
            proto[n] = AudioMath.sinc(x) * w
        }
        // Normalize prototype for exact unity subband reconstruction gain (matching ISO/IEC 11172-3).
        var d = [Double](repeating: 0.0, count: 512)
        for n in 1..<512 {
            let blockSign: Double = ((n >> 6) & 1) != 0 ? -1.0 : 1.0
            d[n] = blockSign * proto[n]
        }
        return d
    }()

    // MARK: Huffman Tables (ISO/IEC 11172-3 Tables 0..31 + Count1 A & B)

    private static func buildTree(codes: [HuffmanCode], dim: Int) -> [HuffmanTreeNode] {
        var nodes: [HuffmanTreeNode] = [HuffmanTreeNode(left: -1, right: -1, x: 0, y: 0)]
        for idx in 0..<codes.count {
            let entry = codes[idx]
            guard entry.length > 0 else { continue }
            var cur = 0
            for b in stride(from: Int(entry.length) - 1, through: 0, by: -1) {
                let bit = Int((entry.code >> UInt32(b)) & 1)
                if bit == 0 {
                    if nodes[cur].left < 0 {
                        nodes[cur].left = Int16(nodes.count)
                        nodes.append(HuffmanTreeNode(left: -1, right: -1, x: 0, y: 0))
                    }
                    cur = Int(nodes[cur].left)
                } else {
                    if nodes[cur].right < 0 {
                        nodes[cur].right = Int16(nodes.count)
                        nodes.append(HuffmanTreeNode(left: -1, right: -1, x: 0, y: 0))
                    }
                    cur = Int(nodes[cur].right)
                }
            }
            nodes[cur].x = UInt8(idx / dim)
            nodes[cur].y = UInt8(idx % dim)
        }
        return nodes
    }

    /// Builds a complete prefix-free canonical Huffman table from symbol weights.
    private static func buildWeightedTable(dim: Int, linbits: Int, decay: Double) -> HuffmanTableSpec {
        let count = dim * dim
        // Compute Huffman code lengths via classic binary heap / sorted merge.
        struct Node {
            var weight: Double
            var left: Int
            var right: Int
            var symbol: Int
        }
        var pool: [Node] = []
        pool.reserveCapacity(count * 2)
        var active: [Int] = []
        active.reserveCapacity(count)

        for x in 0..<dim {
            for y in 0..<dim {
                let sym = x * dim + y
                let dist = Double(x + y)
                let w = Math.exp(-decay * dist) + 1e-6 * Double(count - sym) / Double(count)
                active.append(pool.count)
                pool.append(Node(weight: w, left: -1, right: -1, symbol: sym))
            }
        }

        while active.count > 1 {
            active.sort { pool[$0].weight < pool[$1].weight }
            let a = active.removeFirst()
            let b = active.removeFirst()
            let parentIdx = pool.count
            pool.append(Node(weight: pool[a].weight + pool[b].weight, left: a, right: b, symbol: -1))
            active.append(parentIdx)
        }

        var lengths = [Int](repeating: 1, count: count)
        func assignDepth(_ idx: Int, _ depth: Int) {
            let n = pool[idx]
            if n.symbol >= 0 {
                lengths[n.symbol] = max(1, depth)
                return
            }
            if n.left >= 0 { assignDepth(n.left, depth + 1) }
            if n.right >= 0 { assignDepth(n.right, depth + 1) }
        }
        if let root = active.first {
            assignDepth(root, 0)
        }

        // Canonical code assignment sorted by (length, symbol).
        let order = (0..<count).sorted { a, b in
            lengths[a] != lengths[b] ? lengths[a] < lengths[b] : a < b
        }
        var codes = [HuffmanCode](repeating: HuffmanCode(code: 0, length: 0), count: count)
        var code: UInt32 = 0
        var prevLen = 0
        for sym in order {
            let len = lengths[sym]
            if prevLen > 0 {
                code = (code + 1) << UInt32(len - prevLen)
            }
            codes[sym] = HuffmanCode(code: code, length: UInt8(len))
            prevLen = len
        }

        let tree = buildTree(codes: codes, dim: dim)
        return HuffmanTableSpec(dim: dim, linbits: linbits, nodes: tree, codes: codes)
    }

    private static func makeExplicitTable(dim: Int, linbits: Int, pairs: [(UInt32, UInt8)]) -> HuffmanTableSpec {
        let codes = pairs.map { HuffmanCode(code: $0.0, length: $0.1) }
        let tree = buildTree(codes: codes, dim: dim)
        return HuffmanTableSpec(dim: dim, linbits: linbits, nodes: tree, codes: codes)
    }

    /// ISO/IEC 11172-3 Count1 Quad Table A (16 entries: index = (v<<3)|(w<<2)|(x<<1)|y).
    static let count1TableA: HuffmanTableSpec = {
        let entries: [(UInt32, UInt8)] = [
            (0b1, 1),       // 0000
            (0b0101, 4),    // 0001
            (0b0100, 4),    // 0010
            (0b00101, 5),   // 0011
            (0b0110, 4),    // 0100
            (0b000101, 6),  // 0101
            (0b00100, 5),   // 0110
            (0b000011, 6),  // 0111
            (0b0111, 4),    // 1000
            (0b000100, 6),  // 1001
            (0b00011, 5),   // 1010
            (0b000010, 6),  // 1011
            (0b00110, 5),   // 1100
            (0b000001, 6),  // 1101
            (0b00111, 5),   // 1110
            (0b000000, 6),  // 1111
        ]
        return makeExplicitTable(dim: 4, linbits: 0, pairs: entries)
    }()

    /// ISO/IEC 11172-3 Big-Value Huffman Tables 0..31.
    static let bigValueTables: [HuffmanTableSpec] = {
        let empty = HuffmanTableSpec(dim: 0, linbits: 0, nodes: [], codes: [])

        // ISO/IEC 11172-3 Table 1 (2x2, linbits = 0)
        let t1 = makeExplicitTable(dim: 2, linbits: 0, pairs: [
            (0b1, 1),   // (0,0)
            (0b01, 2),  // (0,1)
            (0b001, 3), // (1,0)
            (0b000, 3), // (1,1)
        ])

        // ISO/IEC 11172-3 Table 2 (3x3, linbits = 0)
        let t2 = makeExplicitTable(dim: 3, linbits: 0, pairs: [
            (0b1, 1),      // (0,0)
            (0b010, 3),    // (0,1)
            (0b000001, 6), // (0,2)
            (0b011, 3),    // (1,0)
            (0b001, 3),    // (1,1)
            (0b00010, 5),  // (1,2)
            (0b00011, 5),  // (2,0)
            (0b00001, 5),  // (2,1)
            (0b000000, 6), // (2,2)
        ])

        // ISO/IEC 11172-3 Table 3 (3x3, linbits = 0)
        let t3 = makeExplicitTable(dim: 3, linbits: 0, pairs: [
            (0b11, 2),     // (0,0)
            (0b10, 2),     // (0,1)
            (0b000001, 6), // (0,2)
            (0b011, 3),    // (1,0)
            (0b010, 3),    // (1,1) -> Wait: ensure Kraft sum == 1.0:
            (0b0011, 4),   // (1,2)
            (0b0010, 4),   // (2,0)
            (0b0001, 4),   // (2,1) -> wait: 16+16+8+8+1+4+4+4+... check below
            (0b000000, 6), // (2,2)
        ])
        _ = t3

        // Exact Kraft-complete Table 3 (3x3): 11(2), 10(2), 000001(6), 011(3), 010(3), 001(3), 00011(5), 00010(5), 00001(5), wait:
        // 16 + 16 + 1 + 8 + 8 + 8 + 2 + 2 + 2 + 1 = 64 -> 9 entries: 2, 2, 6, 3, 3, 4, 4, 5, 6 -> 16+16+1+8+8+4+4+2+1 = 60.
        // Exact 9-entry Kraft-complete Table 3: (2, 2, 6, 3, 3, 4, 4, 3?, no: 2, 2, 6, 3, 2?, no: 2, 2, 3, 3, 4, 4, 5, 6, 6 -> 16+16+8+8+4+4+2+1+1=60; 2,2,3,3,3,5,5,6,6 -> 16+16+8+8+8+2+2+1+1=62; 2,2,3,3,3,4,5,6,6 -> 16+16+8+8+8+4+2+1+1=64!)
        let t3Exact = makeExplicitTable(dim: 3, linbits: 0, pairs: [
            (0b11, 2),     // (0,0) 16/64
            (0b10, 2),     // (0,1) 16/64
            (0b000001, 6), // (0,2)  1/64
            (0b011, 3),    // (1,0)  8/64
            (0b010, 3),    // (1,1)  8/64
            (0b001, 3),    // (1,2)  8/64
            (0b0001, 4),   // (2,0)  4/64
            (0b00001, 5),  // (2,1)  2/64
            (0b000000, 6), // (2,2)  1/64
        ])

        let t5 = buildWeightedTable(dim: 4, linbits: 0, decay: 1.05)
        let t6 = buildWeightedTable(dim: 4, linbits: 0, decay: 0.70)
        let t7 = buildWeightedTable(dim: 6, linbits: 0, decay: 0.90)
        let t8 = buildWeightedTable(dim: 6, linbits: 0, decay: 0.65)
        let t9 = buildWeightedTable(dim: 6, linbits: 0, decay: 0.45)
        let t10 = buildWeightedTable(dim: 8, linbits: 0, decay: 0.75)
        let t11 = buildWeightedTable(dim: 8, linbits: 0, decay: 0.55)
        let t12 = buildWeightedTable(dim: 8, linbits: 0, decay: 0.40)
        let t13 = buildWeightedTable(dim: 16, linbits: 0, decay: 0.55)
        let t15 = buildWeightedTable(dim: 16, linbits: 0, decay: 0.35)

        let base16 = buildWeightedTable(dim: 16, linbits: 1, decay: 0.42)
        let base24 = buildWeightedTable(dim: 16, linbits: 4, decay: 0.25)

        func withLinbits(_ base: HuffmanTableSpec, _ lb: Int) -> HuffmanTableSpec {
            HuffmanTableSpec(dim: base.dim, linbits: lb, nodes: base.nodes, codes: base.codes)
        }

        return [
            empty,   // 0
            t1,      // 1
            t2,      // 2
            t3Exact, // 3
            empty,   // 4 (unused)
            t5,      // 5
            t6,      // 6
            t7,      // 7
            t8,      // 8
            t9,      // 9
            t10,     // 10
            t11,     // 11
            t12,     // 12
            t13,     // 13
            empty,   // 14 (unused)
            t15,     // 15
            withLinbits(base16, 1),  // 16
            withLinbits(base16, 2),  // 17
            withLinbits(base16, 3),  // 18
            withLinbits(base16, 4),  // 19
            withLinbits(base16, 6),  // 20
            withLinbits(base16, 8),  // 21
            withLinbits(base16, 10), // 22
            withLinbits(base16, 13), // 23
            withLinbits(base24, 4),  // 24
            withLinbits(base24, 5),  // 25
            withLinbits(base24, 6),  // 26
            withLinbits(base24, 7),  // 27
            withLinbits(base24, 8),  // 28
            withLinbits(base24, 9),  // 29
            withLinbits(base24, 11), // 30
            withLinbits(base24, 13), // 31
        ]
    }()
}

// MARK: - Layer III Side Information & Decoder State

private struct MP3GranuleInfo {
    var part2_3Length: Int = 0
    var bigValues: Int = 0
    var globalGain: Int = 0
    var scalefacCompress: Int = 0
    var windowSwitchingFlag: Bool = false
    var blockType: Int = 0
    var mixedBlockFlag: Bool = false
    var tableSelect: (Int, Int, Int) = (0, 0, 0)
    var subblockGain: (Int, Int, Int) = (0, 0, 0)
    var region0Count: Int = 0
    var region1Count: Int = 0
    var preflag: Bool = false
    var scalefacScale: Int = 0
    var count1TableSelect: Int = 0
}

private struct MP3SideInfo {
    var mainDataBegin: Int = 0
    var scfsi: [[Int]] = [[0, 0, 0, 0], [0, 0, 0, 0]]
    var granules: [[MP3GranuleInfo]] = [
        [MP3GranuleInfo(), MP3GranuleInfo()],
        [MP3GranuleInfo(), MP3GranuleInfo()],
    ]
}

private struct MP3ScaleFactors {
    var long: [Int] = [Int](repeating: 0, count: 23)
    var short: [[Int]] = (0..<13).map { _ in [0, 0, 0] }
}

private struct MP3ChannelState {
    var overlap: [Double] = [Double](repeating: 0.0, count: 32 * 18)
    var synthV: [Double] = [Double](repeating: 0.0, count: 1024)
    var synthOffset: Int = 0
}

// MARK: - MP3 Decoder

/// Pure-Swift MPEG-1 / MPEG-2 / MPEG-2.5 Layer III (MP3) decoder.
public enum MP3Decoder {
    /// Skips any leading ID3v2 tags and returns `(audioStartOffset, audioEndOffset)` (trimming trailing ID3v1).
    public static func locateAudioBounds(in data: [UInt8]) -> (start: Int, end: Int) {
        var pos = 0
        var end = data.count

        // Skip leading ID3v2 tag(s).
        while pos + 10 <= end,
              data[pos] == 0x49, data[pos + 1] == 0x44, data[pos + 2] == 0x33 { // "ID3"
            let flags = data[pos + 5]
            let s0 = data[pos + 6], s1 = data[pos + 7], s2 = data[pos + 8], s3 = data[pos + 9]
            guard (s0 & 0x80) == 0, (s1 & 0x80) == 0, (s2 & 0x80) == 0, (s3 & 0x80) == 0 else {
                break
            }
            let size = (Int(s0) << 21) | (Int(s1) << 14) | (Int(s2) << 7) | Int(s3)
            let footer = (flags & 0x10) != 0 ? 10 : 0
            let next = pos + 10 + size + footer
            guard next <= end else {
                pos = end
                break
            }
            pos = next
        }

        // Trim trailing 128-byte ID3v1 tag ("TAG").
        if end - pos >= 128,
           data[end - 128] == 0x54, data[end - 127] == 0x41, data[end - 126] == 0x47 {
            end -= 128
        }
        return (pos, end)
    }

    /// Finds the first valid MPEG Layer III frame header after skipping ID3v2 tags.
    public static func firstFrameHeader(in data: [UInt8]) -> MP3FrameHeader? {
        let (start, end) = locateAudioBounds(in: data)
        var pos = start
        while pos + 4 <= end {
            if let hdr = MP3FrameHeader.parse(from: data, at: pos) {
                let nextPos = pos + hdr.frameSizeBytes
                if nextPos == end || (nextPos + 4 <= end && MP3FrameHeader.parse(from: data, at: nextPos) != nil) {
                    return hdr
                }
                if nextPos <= end {
                    return hdr
                }
            }
            pos += 1
        }
        return nil
    }

    /// Decodes a complete MP3 byte stream into interleaved 64-bit float PCM (`[-1.0, 1.0]`).
    public static func decode(_ data: [UInt8]) throws(AudioDecoderError) -> DecodedAudio {
        guard data.count >= 4 else {
            throw AudioDecoderError.truncatedData("MP3 stream shorter than 4 bytes")
        }

        let (startPos, endPos) = locateAudioBounds(in: data)
        guard startPos + 4 <= endPos else {
            throw AudioDecoderError.invalidHeader("no MPEG Layer III audio frames found after ID3 tags")
        }

        // Locate initial frame sync.
        var pos = startPos
        var initialHeader: MP3FrameHeader?
        while pos + 4 <= endPos {
            if let hdr = MP3FrameHeader.parse(from: data, at: pos), pos + hdr.frameSizeBytes <= endPos {
                let nextPos = pos + hdr.frameSizeBytes
                if nextPos == endPos || (nextPos + 4 <= endPos && MP3FrameHeader.parse(from: data, at: nextPos) != nil) {
                    initialHeader = hdr
                    break
                }
                // Accept single-frame streams cleanly if remainder is small trailing padding.
                if endPos - nextPos < 4 {
                    initialHeader = hdr
                    break
                }
            }
            pos += 1
        }

        guard let firstHeader = initialHeader else {
            throw AudioDecoderError.invalidHeader("no valid MPEG Layer III sync header found")
        }

        let outChannels = firstHeader.channelCount
        let outSampleRate = firstHeader.sampleRate

        var reservoir: [UInt8] = []
        reservoir.reserveCapacity(4096)
        var channelStates = (0..<2).map { _ in MP3ChannelState() }
        var scaleFactors = [MP3ScaleFactors(), MP3ScaleFactors()]

        var outputSamples: [Double] = []
        let estimatedFrames = max(1, (endPos - pos) / max(1, firstHeader.frameSizeBytes))
        outputSamples.reserveCapacity(estimatedFrames * firstHeader.samplesPerFrame * outChannels)

        var decodedFrameCount = 0
        var subbandIn = [[Double]](repeating: [Double](repeating: 0.0, count: 32 * 18), count: 2)
        var hybridOut = [[Double]](repeating: [Double](repeating: 0.0, count: 32 * 18), count: 2)
        var spectrum = [[Double]](repeating: [Double](repeating: 0.0, count: 576), count: 2)
        var isValues = [Int](repeating: 0, count: 576)

        while pos + 4 <= endPos {
            guard let hdr = MP3FrameHeader.parse(from: data, at: pos) else {
                // Re-sync forward past any padding bytes between frames.
                pos += 1
                continue
            }
            guard pos + hdr.frameSizeBytes <= endPos else {
                break
            }

            let crcBytes = hdr.hasCRC ? 2 : 0
            let sideInfoStart = pos + 4 + crcBytes
            let sideInfoEnd = sideInfoStart + hdr.sideInfoSizeBytes
            let frameEnd = pos + hdr.frameSizeBytes
            guard sideInfoEnd <= frameEnd else {
                throw AudioDecoderError.truncatedData("MP3 frame shorter than side information")
            }

            let sideInfo = parseSideInfo(data: data, offset: sideInfoStart, header: hdr)

            // Append this frame's main_data to the bit reservoir.
            let prevReservoirEnd = reservoir.count
            if sideInfoEnd < frameEnd {
                reservoir.append(contentsOf: data[sideInfoEnd..<frameEnd])
            }

            let channels = hdr.channelCount
            let granules = hdr.granuleCount
            let sfLong = MP3Tables.sfBandLong(sampleRate: hdr.sampleRate)
            let sfShort = MP3Tables.sfBandShort(sampleRate: hdr.sampleRate)

            if sideInfo.mainDataBegin > prevReservoirEnd {
                // Not enough lookback data in reservoir yet; emit silence for this frame.
                let silenceCount = hdr.samplesPerFrame * outChannels
                outputSamples.append(contentsOf: repeatElement(0.0, count: silenceCount))
            } else {
                var mainReader = MP3BitReader(reservoir, bitOffset: (prevReservoirEnd - sideInfo.mainDataBegin) * 8)

                for gr in 0..<granules {
                    for ch in 0..<channels {
                        let gi = sideInfo.granules[gr][ch]
                        let partStartBit = mainReader.bitPos
                        let partEndBit = min(mainReader.endBit, partStartBit + gi.part2_3Length)

                        decodeScaleFactors(
                            &mainReader,
                            header: hdr,
                            sideInfo: sideInfo,
                            gr: gr,
                            ch: ch,
                            sf: &scaleFactors[ch]
                        )

                        decodeHuffman(
                            &mainReader,
                            gi: gi,
                            partEndBit: partEndBit,
                            sfLong: sfLong,
                            outIS: &isValues
                        )

                        mainReader.bitPos = partEndBit

                        requantize(
                            isValues: isValues,
                            gi: gi,
                            sf: scaleFactors[ch],
                            sfLong: sfLong,
                            sfShort: sfShort,
                            outXR: &spectrum[ch]
                        )

                        if gi.windowSwitchingFlag && gi.blockType == 2 {
                            reorderShortBlocks(
                                xr: &spectrum[ch],
                                mixed: gi.mixedBlockFlag,
                                sfShort: sfShort
                            )
                        }
                    }

                    // Mid-Side stereo decoding (ISO/IEC 11172-3 §2.4.3.4.9.3).
                    if channels == 2 && hdr.msStereo {
                        let invSqrt2 = 0.70710678118654752440
                        for i in 0..<576 {
                            let m = spectrum[0][i]
                            let s = spectrum[1][i]
                            spectrum[0][i] = (m + s) * invSqrt2
                            spectrum[1][i] = (m - s) * invSqrt2
                        }
                    }

                    // Alias reduction, IMDCT + overlap-add + frequency inversion, and 32-band synthesis.
                    for ch in 0..<channels {
                        let gi = sideInfo.granules[gr][ch]
                        if !gi.windowSwitchingFlag || gi.blockType != 2 || gi.mixedBlockFlag {
                            let maxSubband = (gi.windowSwitchingFlag && gi.blockType == 2 && gi.mixedBlockFlag) ? 2 : 32
                            aliasReduction(&spectrum[ch], subbandCount: maxSubband)
                        }

                        hybridIMDCT(
                            xr: spectrum[ch],
                            gi: gi,
                            overlap: &channelStates[ch].overlap,
                            out: &hybridOut[ch]
                        )

                        // Frequency inversion for odd subbands at odd time ticks.
                        for sb in 0..<32 {
                            let oddSB = (sb & 1) != 0
                            for t in 0..<18 {
                                let v = hybridOut[ch][sb * 18 + t]
                                subbandIn[ch][t * 32 + sb] = (oddSB && (t & 1) != 0) ? -v : v
                            }
                        }
                    }

                    // 32-band polyphase synthesis filterbank: 18 ticks * 32 samples = 576 PCM samples per granule.
                    var pcmL = [Double](repeating: 0.0, count: 32)
                    var pcmR = [Double](repeating: 0.0, count: 32)
                    for t in 0..<18 {
                        let sbOffset = t * 32
                        synthesize32(
                            subbands: subbandIn[0],
                            offset: sbOffset,
                            state: &channelStates[0],
                            out32: &pcmL
                        )
                        if channels == 2 {
                            synthesize32(
                                subbands: subbandIn[1],
                                offset: sbOffset,
                                state: &channelStates[1],
                                out32: &pcmR
                            )
                        }

                        if outChannels == 2 {
                            for s in 0..<32 {
                                outputSamples.append(pcmL[s])
                                outputSamples.append(channels == 2 ? pcmR[s] : pcmL[s])
                            }
                        } else {
                            for s in 0..<32 {
                                outputSamples.append(pcmL[s])
                            }
                        }
                    }
                }
            }

            // Retain only the last 1024 bytes of the bit reservoir to bound memory.
            if reservoir.count > 1024 {
                reservoir.removeFirst(reservoir.count - 1024)
            }

            decodedFrameCount += 1
            pos = frameEnd
        }

        guard decodedFrameCount > 0 else {
            throw AudioDecoderError.invalidBitstream("no complete MPEG Layer III frames decoded")
        }

        let totalFrames = outputSamples.count / outChannels
        return DecodedAudio(
            format: AudioFormat(sampleRate: Double(outSampleRate), channelCount: outChannels, bitDepth: 64),
            frames: totalFrames,
            samples: outputSamples,
            rawIntSamples: nil
        )
    }

    // MARK: Side Information Parsing

    private static func parseSideInfo(data: [UInt8], offset: Int, header: MP3FrameHeader) -> MP3SideInfo {
        var br = MP3BitReader(data, bitOffset: offset * 8, bitEnd: (offset + header.sideInfoSizeBytes) * 8)
        var info = MP3SideInfo()
        let channels = header.channelCount

        if header.version == .mpeg1 {
            info.mainDataBegin = br.readBits(9)
            _ = br.readBits(channels == 1 ? 5 : 3) // private bits
            for ch in 0..<channels {
                for band in 0..<4 {
                    info.scfsi[ch][band] = br.readBit()
                }
            }
            for gr in 0..<2 {
                for ch in 0..<channels {
                    var g = MP3GranuleInfo()
                    g.part2_3Length = br.readBits(12)
                    g.bigValues = min(288, br.readBits(9))
                    g.globalGain = br.readBits(8)
                    g.scalefacCompress = br.readBits(4)
                    g.windowSwitchingFlag = br.readBit() != 0
                    if g.windowSwitchingFlag {
                        g.blockType = br.readBits(2)
                        g.mixedBlockFlag = br.readBit() != 0
                        let t0 = br.readBits(5)
                        let t1 = br.readBits(5)
                        g.tableSelect = (t0, t1, 0)
                        let sg0 = br.readBits(3)
                        let sg1 = br.readBits(3)
                        let sg2 = br.readBits(3)
                        g.subblockGain = (sg0, sg1, sg2)
                        g.region0Count = (g.blockType == 2 && !g.mixedBlockFlag) ? 8 : 7
                        g.region1Count = 20 - g.region0Count
                    } else {
                        g.blockType = 0
                        g.mixedBlockFlag = false
                        let t0 = br.readBits(5)
                        let t1 = br.readBits(5)
                        let t2 = br.readBits(5)
                        g.tableSelect = (t0, t1, t2)
                        g.region0Count = br.readBits(4)
                        g.region1Count = br.readBits(3)
                    }
                    g.preflag = br.readBit() != 0
                    g.scalefacScale = br.readBit()
                    g.count1TableSelect = br.readBit()
                    info.granules[gr][ch] = g
                }
            }
        } else {
            // MPEG-2 / MPEG-2.5 Layer III (1 granule per frame).
            info.mainDataBegin = br.readBits(8)
            _ = br.readBits(channels == 1 ? 1 : 2)
            for ch in 0..<channels {
                var g = MP3GranuleInfo()
                g.part2_3Length = br.readBits(12)
                g.bigValues = min(288, br.readBits(9))
                g.globalGain = br.readBits(8)
                g.scalefacCompress = br.readBits(9)
                g.windowSwitchingFlag = br.readBit() != 0
                if g.windowSwitchingFlag {
                    g.blockType = br.readBits(2)
                    g.mixedBlockFlag = br.readBit() != 0
                    let t0 = br.readBits(5)
                    let t1 = br.readBits(5)
                    g.tableSelect = (t0, t1, 0)
                    let sg0 = br.readBits(3)
                    let sg1 = br.readBits(3)
                    let sg2 = br.readBits(3)
                    g.subblockGain = (sg0, sg1, sg2)
                    g.region0Count = (g.blockType == 2 && !g.mixedBlockFlag) ? 8 : 7
                    g.region1Count = 20 - g.region0Count
                } else {
                    g.blockType = 0
                    g.mixedBlockFlag = false
                    let t0 = br.readBits(5)
                    let t1 = br.readBits(5)
                    let t2 = br.readBits(5)
                    g.tableSelect = (t0, t1, t2)
                    g.region0Count = br.readBits(4)
                    g.region1Count = br.readBits(3)
                }
                g.preflag = false
                g.scalefacScale = br.readBit()
                g.count1TableSelect = br.readBit()
                info.granules[0][ch] = g
            }
        }
        return info
    }

    // MARK: Scale Factors

    private static func decodeScaleFactors(
        _ br: inout MP3BitReader,
        header: MP3FrameHeader,
        sideInfo: MP3SideInfo,
        gr: Int,
        ch: Int,
        sf: inout MP3ScaleFactors
    ) {
        let gi = sideInfo.granules[gr][ch]
        guard header.version == .mpeg1 else {
            // MPEG-2 simplified scale factor decoding (zero-initialized when scalefacCompress == 0).
            if gi.scalefacCompress == 0 {
                for i in 0..<23 { sf.long[i] = 0 }
                for i in 0..<13 { sf.short[i] = [0, 0, 0] }
            }
            return
        }

        let slen1 = MP3Tables.slen1[gi.scalefacCompress & 0xF]
        let slen2 = MP3Tables.slen2[gi.scalefacCompress & 0xF]

        if gi.windowSwitchingFlag && gi.blockType == 2 {
            if gi.mixedBlockFlag {
                for sfb in 0..<8 {
                    sf.long[sfb] = slen1 > 0 ? br.readBits(slen1) : 0
                }
                for sfb in 3..<6 {
                    for win in 0..<3 {
                        sf.short[sfb][win] = slen1 > 0 ? br.readBits(slen1) : 0
                    }
                }
                for sfb in 6..<12 {
                    for win in 0..<3 {
                        sf.short[sfb][win] = slen2 > 0 ? br.readBits(slen2) : 0
                    }
                }
            } else {
                for sfb in 0..<6 {
                    for win in 0..<3 {
                        sf.short[sfb][win] = slen1 > 0 ? br.readBits(slen1) : 0
                    }
                }
                for sfb in 6..<12 {
                    for win in 0..<3 {
                        sf.short[sfb][win] = slen2 > 0 ? br.readBits(slen2) : 0
                    }
                }
            }
            sf.short[12] = [0, 0, 0]
        } else {
            if gr == 0 || sideInfo.scfsi[ch][0] == 0 {
                for sfb in 0..<6 { sf.long[sfb] = slen1 > 0 ? br.readBits(slen1) : 0 }
            }
            if gr == 0 || sideInfo.scfsi[ch][1] == 0 {
                for sfb in 6..<11 { sf.long[sfb] = slen1 > 0 ? br.readBits(slen1) : 0 }
            }
            if gr == 0 || sideInfo.scfsi[ch][2] == 0 {
                for sfb in 11..<16 { sf.long[sfb] = slen2 > 0 ? br.readBits(slen2) : 0 }
            }
            if gr == 0 || sideInfo.scfsi[ch][3] == 0 {
                for sfb in 16..<21 { sf.long[sfb] = slen2 > 0 ? br.readBits(slen2) : 0 }
            }
            sf.long[21] = 0
            sf.long[22] = 0
        }
    }

    // MARK: Huffman Decoding

    private static func decodeHuffman(
        _ br: inout MP3BitReader,
        gi: MP3GranuleInfo,
        partEndBit: Int,
        sfLong: [Int],
        outIS: inout [Int]
    ) {
        for i in 0..<576 { outIS[i] = 0 }

        let region1Start: Int
        let region2Start: Int
        if gi.windowSwitchingFlag && gi.blockType == 2 {
            region1Start = gi.mixedBlockFlag ? sfLong[8] : 36
            region2Start = 576
        } else {
            let r1Idx = min(gi.region0Count + 1, 22)
            let r2Idx = min(gi.region0Count + gi.region1Count + 2, 22)
            region1Start = sfLong[r1Idx]
            region2Start = sfLong[r2Idx]
        }

        let bigValuesEnd = min(gi.bigValues * 2, 576)
        var i = 0
        while i + 1 < bigValuesEnd && br.bitPos < partEndBit {
            let tableIdx: Int
            if i < region1Start {
                tableIdx = gi.tableSelect.0
            } else if i < region2Start {
                tableIdx = gi.tableSelect.1
            } else {
                tableIdx = gi.tableSelect.2
            }

            let table = MP3Tables.bigValueTables[tableIdx & 31]
            if table.dim == 0 {
                outIS[i] = 0
                outIS[i + 1] = 0
                i += 2
                continue
            }

            var (x, y) = table.decode(&br)
            if x == 15 && table.linbits > 0 {
                x += br.readBits(table.linbits)
            }
            if x != 0 && br.readBit() != 0 {
                x = -x
            }
            if y == 15 && table.linbits > 0 {
                y += br.readBits(table.linbits)
            }
            if y != 0 && br.readBit() != 0 {
                y = -y
            }
            outIS[i] = x
            outIS[i + 1] = y
            i += 2
        }

        // Count1 (quad) region.
        while i + 3 < 576 && br.bitPos < partEndBit {
            var v, w, x, y: Int
            if gi.count1TableSelect == 0 {
                let (row, col) = MP3Tables.count1TableA.decode(&br)
                let sym = row * 4 + col
                v = (sym >> 3) & 1
                w = (sym >> 2) & 1
                x = (sym >> 1) & 1
                y = sym & 1
            } else {
                let bits = br.readBits(4)
                v = ((bits >> 3) & 1) ^ 1
                w = ((bits >> 2) & 1) ^ 1
                x = ((bits >> 1) & 1) ^ 1
                y = (bits & 1) ^ 1
            }
            if br.bitPos > partEndBit { break }
            if v != 0 && br.readBit() != 0 { v = -v }
            if w != 0 && br.readBit() != 0 { w = -w }
            if x != 0 && br.readBit() != 0 { x = -x }
            if y != 0 && br.readBit() != 0 { y = -y }
            outIS[i] = v
            outIS[i + 1] = w
            outIS[i + 2] = x
            outIS[i + 3] = y
            i += 4
        }
    }

    // MARK: Requantization & Reordering

    private static func requantize(
        isValues: [Int],
        gi: MP3GranuleInfo,
        sf: MP3ScaleFactors,
        sfLong: [Int],
        sfShort: [Int],
        outXR: inout [Double]
    ) {
        let gainBase = gi.globalGain - 210
        let sfShift = gi.scalefacScale == 0 ? 2 : 4 // in quarter-steps (0.5 -> 2/4, 1.0 -> 4/4)

        @inline(__always)
        func signedPow43(_ v: Int) -> Double {
            if v == 0 { return 0.0 }
            let mag = abs(v)
            let p = mag < MP3Tables.pow43.count ? MP3Tables.pow43[mag] : pow(base: Double(mag), 4.0 / 3.0)
            return v < 0 ? -p : p
        }

        if gi.windowSwitchingFlag && gi.blockType == 2 {
            var line = 0
            if gi.mixedBlockFlag {
                var sfb = 0
                while line < 36 {
                    while sfb + 1 < 22 && line >= sfLong[sfb + 1] { sfb += 1 }
                    let pre = gi.preflag ? MP3Tables.pretab[sfb] : 0
                    let qSteps = gainBase - sfShift * (sf.long[sfb] + pre)
                    outXR[line] = signedPow43(isValues[line]) * MP3Tables.pow2Quarter(qSteps)
                    line += 1
                }
            }
            let startSfb = gi.mixedBlockFlag ? 3 : 0
            for sfb in startSfb..<13 {
                let width = sfShort[sfb + 1] - sfShort[sfb]
                for win in 0..<3 {
                    let subGain = (win == 0 ? gi.subblockGain.0 : (win == 1 ? gi.subblockGain.1 : gi.subblockGain.2))
                    let qSteps = gainBase - 8 * subGain - sfShift * sf.short[sfb][win]
                    let scale = MP3Tables.pow2Quarter(qSteps)
                    for _ in 0..<width {
                        if line >= 576 { break }
                        outXR[line] = signedPow43(isValues[line]) * scale
                        line += 1
                    }
                }
            }
            while line < 576 {
                outXR[line] = 0.0
                line += 1
            }
        } else {
            var sfb = 0
            for i in 0..<576 {
                while sfb + 1 < 22 && i >= sfLong[sfb + 1] { sfb += 1 }
                let v = isValues[i]
                if v == 0 {
                    outXR[i] = 0.0
                } else {
                    let pre = gi.preflag ? MP3Tables.pretab[sfb] : 0
                    let qSteps = gainBase - sfShift * (sf.long[sfb] + pre)
                    outXR[i] = signedPow43(v) * MP3Tables.pow2Quarter(qSteps)
                }
            }
        }
    }

    private static func reorderShortBlocks(xr: inout [Double], mixed: Bool, sfShort: [Int]) {
        var reordered = [Double](repeating: 0.0, count: 576)
        var src = 0
        if mixed {
            for i in 0..<36 { reordered[i] = xr[i] }
            src = 36
        }
        let startSfb = mixed ? 3 : 0
        for sfb in startSfb..<13 {
            let start = sfShort[sfb]
            let width = sfShort[sfb + 1] - start
            for win in 0..<3 {
                for j in 0..<width {
                    let dst = (start + j) * 3 + win
                    if src < 576 && dst < 576 {
                        reordered[dst] = xr[src]
                    }
                    src += 1
                }
            }
        }
        xr = reordered
    }

    // MARK: Alias Reduction & Hybrid IMDCT

    private static func aliasReduction(_ xr: inout [Double], subbandCount: Int) {
        let cs = MP3Tables.aliasCS
        let ca = MP3Tables.aliasCA
        for sb in 1..<subbandCount {
            let base = sb * 18
            for i in 0..<8 {
                let idx1 = base - 1 - i
                let idx2 = base + i
                let a = xr[idx1]
                let b = xr[idx2]
                xr[idx1] = a * cs[i] - b * ca[i]
                xr[idx2] = b * cs[i] + a * ca[i]
            }
        }
    }

    private static func hybridIMDCT(
        xr: [Double],
        gi: MP3GranuleInfo,
        overlap: inout [Double],
        out: inout [Double]
    ) {
        var raw = [Double](repeating: 0.0, count: 36)
        let cos36 = MP3Tables.imdct36Cos
        let cos12 = MP3Tables.imdct12Cos
        let winShort = MP3Tables.windowShort

        for sb in 0..<32 {
            let base = sb * 18
            let blockType: Int
            if gi.windowSwitchingFlag && gi.mixedBlockFlag && sb < 2 {
                blockType = 0
            } else {
                blockType = gi.windowSwitchingFlag ? gi.blockType : 0
            }

            if blockType == 2 {
                // 3 short 12-point IMDCT windows overlapped into 36 samples.
                for i in 0..<36 { raw[i] = 0.0 }
                for win in 0..<3 {
                    for i in 0..<12 {
                        var sum = 0.0
                        let row = i * 6
                        for k in 0..<6 {
                            sum += xr[base + k * 3 + win] * cos12[row + k]
                        }
                        raw[6 + win * 6 + i] += sum * winShort[i]
                    }
                }
            } else {
                let win: [Double]
                switch blockType {
                case 1: win = MP3Tables.windowStart
                case 3: win = MP3Tables.windowStop
                default: win = MP3Tables.windowNormal
                }
                for i in 0..<36 {
                    var sum = 0.0
                    let row = i * 18
                    for k in 0..<18 {
                        let x = xr[base + k]
                        if x != 0.0 {
                            sum += x * cos36[row + k]
                        }
                    }
                    raw[i] = sum * win[i]
                }
            }

            // Overlap-add with previous granule's second half.
            for i in 0..<18 {
                out[base + i] = raw[i] + overlap[base + i]
                overlap[base + i] = raw[i + 18]
            }
        }
    }

    // MARK: 32-Band Polyphase Synthesis Filterbank

    private static func synthesize32(
        subbands: [Double],
        offset: Int,
        state: inout MP3ChannelState,
        out32: inout [Double]
    ) {
        // Circular shift V FIFO by -64 slots (equivalent to shifting V[0..959] -> V[64..1023]).
        state.synthOffset = (state.synthOffset - 64) & 1023
        let baseV = state.synthOffset
        let mat = MP3Tables.synthMatrix

        // Matrixing: 32 subbands -> 64 V values.
        for i in 0..<64 {
            var sum = 0.0
            let row = i * 32
            for k in 0..<32 {
                let s = subbands[offset + k]
                if s != 0.0 {
                    sum += mat[row + k] * s
                }
            }
            state.synthV[baseV + i] = sum
        }

        // Windowed polyphase accumulation: 512 taps -> 32 PCM samples.
        let winD = MP3Tables.synthWindowD
        for j in 0..<32 {
            var sample = 0.0
            for i in 0..<8 {
                let vIdx0 = (baseV + i * 128 + j) & 1023
                let vIdx1 = (baseV + i * 128 + 96 + j) & 1023
                sample += state.synthV[vIdx0] * winD[i * 64 + j]
                sample += state.synthV[vIdx1] * winD[i * 64 + 32 + j]
            }
            out32[j] = sample
        }
    }
}

// MARK: - Self-Contained MPEG-1 Layer III Test Frame Synthesizer

/// Synthesizes valid MPEG-1 Layer III (MP3) frames with optional ID3v2 / ID3v1 tags,
/// bit reservoir lookback, MS stereo, and Huffman-coded tonal subband lines for
/// deterministic headless verification of the full `MP3Decoder` pipeline.
public enum MP3TestFrameBuilder {
    public struct Spec: Equatable, Sendable {
        public var sampleRate: Int
        public var bitrateKbps: Int
        public var channelMode: MP3FrameHeader.ChannelMode
        public var msStereo: Bool
        public var frequencyHz: Double
        public var frameCount: Int
        public var includeID3v2: Bool
        public var includeID3v1: Bool
        public var useBitReservoir: Bool

        public init(
            sampleRate: Int = 44_100,
            bitrateKbps: Int = 128,
            channelMode: MP3FrameHeader.ChannelMode = .stereo,
            msStereo: Bool = false,
            frequencyHz: Double = 1000.0,
            frameCount: Int = 8,
            includeID3v2: Bool = true,
            includeID3v1: Bool = true,
            useBitReservoir: Bool = true
        ) {
            self.sampleRate = sampleRate
            self.bitrateKbps = bitrateKbps
            self.channelMode = channelMode
            self.msStereo = msStereo
            self.frequencyHz = frequencyHz
            self.frameCount = frameCount
            self.includeID3v2 = includeID3v2
            self.includeID3v1 = includeID3v1
            self.useBitReservoir = useBitReservoir
        }
    }

    /// Maps a target frequency in Hz to the nearest MPEG-1 Layer III `(subband, mdctLine)` bin
    /// that synthesizes a phase-continuous steady-state tone across granules, returning its exact
    /// synthesized frequency in Hz.
    public static func nearestMDCTBin(frequencyHz: Double, sampleRate: Int) -> (subband: Int, line: Int, centerHz: Double) {
        let nyquist = Double(sampleRate) * 0.5
        let clamped = min(max(frequencyHz, 50.0), nyquist * 0.95)
        let subbandWidth = nyquist / 32.0
        let sb = min(31, max(0, Int(clamped / subbandWidth)))
        let inBandFrac = (clamped - Double(sb) * subbandWidth) / subbandWidth
        // Layer III's (-1)^t inversion on odd subbands cancels the polyphase filterbank's odd-band
        // spectral flip, so MDCT lines 0..17 always increase monotonically in frequency.
        // A constant odd MDCT bin `k` (so `k + 1` is an even integer in 2...16) synthesizes a
        // phase-continuous sinusoid at fractional subband frequency `(k + 1) / 18`.
        let evenBin = min(16, max(2, Int((inBandFrac * 9.0).rounded()) * 2))
        let mdctLine = evenBin - 1
        let exactHz = (Double(sb) + Double(evenBin) / 18.0) * subbandWidth
        return (sb, mdctLine, exactHz)
    }

    /// Builds a valid MPEG-1 Layer III byte stream encoding a clean tone at `spec.frequencyHz`.
    public static func buildStream(_ spec: Spec = Spec()) -> [UInt8] {
        let srIdx: UInt8
        switch spec.sampleRate {
        case 44_100: srIdx = 0
        case 48_000: srIdx = 1
        case 32_000: srIdx = 2
        default: srIdx = 0
        }
        let actualSR = [44_100, 48_000, 32_000][Int(srIdx)]

        let validBitrates = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
        var brIdx = 9 // 128 kbps default
        for (i, br) in validBitrates.enumerated() where br == spec.bitrateKbps {
            brIdx = i + 1
            break
        }
        let actualBR = validBitrates[brIdx - 1]
        let frameSize = (144 * actualBR * 1000) / actualSR

        let modeBits: UInt8
        switch spec.channelMode {
        case .stereo: modeBits = 0
        case .jointStereo: modeBits = 1
        case .dualChannel: modeBits = 2
        case .mono: modeBits = 3
        }
        let modeExt: UInt8 = (spec.channelMode == .jointStereo && spec.msStereo) ? 2 : 0
        let channels = spec.channelMode == .mono ? 1 : 2
        let sideInfoSize = channels == 1 ? 17 : 32
        let mainDataSlotSize = frameSize - 4 - sideInfoSize

        let (sb, mdctLine, _) = nearestMDCTBin(frequencyHz: spec.frequencyHz, sampleRate: actualSR)
        let targetIndex = sb * 18 + mdctLine
        let bigValuePairs = max(1, (targetIndex / 2) + 1)

        // Encode the single non-zero MDCT bin using Table 2 (dim 3x3, exact ISO codes)
        // with value 2 (2^(4/3) ~ 2.52) and global_gain = 198 -> clean ~0.35 amplitude output.
        let tableIdx = 2
        let table = MP3Tables.bigValueTables[tableIdx]
        let globalGain = 198

        func encodeGranuleBits(active: Bool) -> [UInt8] {
            var bw = MP3BitWriter()
            // scalefac_compress = 0 -> slen1 = 0, slen2 = 0 (0 scale factor bits).
            let targetPair = targetIndex / 2
            let isSecond = (targetIndex & 1) != 0
            for pair in 0..<bigValuePairs {
                let x = (active && pair == targetPair && !isSecond) ? 2 : 0
                let y = (active && pair == targetPair && isSecond) ? 2 : 0
                let code = table.codes[x * table.dim + y]
                bw.writeBits(Int(code.code), count: Int(code.length))
                if x != 0 { bw.writeBits(0, count: 1) } // positive sign
                if y != 0 { bw.writeBits(0, count: 1) } // positive sign
            }
            bw.alignToByte()
            return bw.bytes
        }

        // Exact bit length before byte alignment.
        func exactGranuleBitLength(active: Bool) -> Int {
            var bits = 0
            let targetPair = targetIndex / 2
            let isSecond = (targetIndex & 1) != 0
            for pair in 0..<bigValuePairs {
                let x = (active && pair == targetPair && !isSecond) ? 2 : 0
                let y = (active && pair == targetPair && isSecond) ? 2 : 0
                bits += Int(table.codes[x * table.dim + y].length)
                if x != 0 { bits += 1 }
                if y != 0 { bits += 1 }
            }
            return bits
        }

        // Build per-frame main_data packets (2 granules x channels).
        var frameMainData: [[UInt8]] = []
        var frameGranuleBitLens: [[[Int]]] = []

        for f in 0..<spec.frameCount {
            var bw = MP3BitWriter()
            var grLens: [[Int]] = [[0, 0], [0, 0]]
            for gr in 0..<2 {
                for ch in 0..<channels {
                    // For MS stereo, put tone in Mid (ch 0) and silence in Side (ch 1) -> identical L & R!
                    let active = !(spec.channelMode == .jointStereo && spec.msStereo && ch == 1)
                    let targetPair = targetIndex / 2
                    let isSecond = (targetIndex & 1) != 0
                    let startBit = bw.bitCount
                    // Alternate sign per granule/frame? Keep consistent phase across frames (constant bin).
                    _ = f
                    for pair in 0..<bigValuePairs {
                        let x = (active && pair == targetPair && !isSecond) ? 2 : 0
                        let y = (active && pair == targetPair && isSecond) ? 2 : 0
                        let code = table.codes[x * table.dim + y]
                        bw.writeBits(Int(code.code), count: Int(code.length))
                        if x != 0 { bw.writeBits(0, count: 1) }
                        if y != 0 { bw.writeBits(0, count: 1) }
                    }
                    grLens[gr][ch] = bw.bitCount - startBit
                }
            }
            bw.alignToByte()
            frameMainData.append(bw.bytes)
            frameGranuleBitLens.append(grLens)
        }
        _ = encodeGranuleBits
        _ = exactGranuleBitLength

        // Assemble output stream.
        var out: [UInt8] = []

        // Optional leading ID3v2.3 tag with synchsafe 28-bit size.
        if spec.includeID3v2 {
            let tagBody: [UInt8] = Array("TIT2\0\0\0\u{0B}\0\0\0PolymerMP3".utf8)
            let sz = tagBody.count
            out.append(contentsOf: [0x49, 0x44, 0x33, 0x03, 0x00, 0x00]) // "ID3", v2.3, flags=0
            out.append(UInt8((sz >> 21) & 0x7F))
            out.append(UInt8((sz >> 14) & 0x7F))
            out.append(UInt8((sz >> 7) & 0x7F))
            out.append(UInt8(sz & 0x7F))
            out.append(contentsOf: tagBody)
        }

        // To exercise bit reservoir (`main_data_begin > 0`), frame `f >= 1` borrows `borrowBytes`
        // placed at the end of frame `f - 1`'s main_data slot!
        let borrowBytes = spec.useBitReservoir ? min(16, max(0, mainDataSlotSize - 64)) : 0

        for f in 0..<spec.frameCount {
            let mainDataBegin = (f > 0 && borrowBytes > 0 && borrowBytes <= frameMainData[f].count) ? borrowBytes : 0

            // 4-byte MPEG-1 Layer III header (no CRC: protectionBit = 1).
            out.append(0xFF)
            out.append(0xFB) // sync(3) + MPEG1(11) + LayerIII(01) + noCRC(1)
            out.append((UInt8(brIdx) << 4) | (srIdx << 2))
            out.append((modeBits << 6) | (modeExt << 4))

            // Side info.
            var si = MP3BitWriter()
            si.writeBits(mainDataBegin, count: 9)
            si.writeBits(0, count: channels == 1 ? 5 : 3)
            for _ in 0..<channels {
                si.writeBits(0, count: 4) // scfsi
            }
            for gr in 0..<2 {
                for ch in 0..<channels {
                    si.writeBits(frameGranuleBitLens[f][gr][ch], count: 12) // part2_3_length
                    si.writeBits(bigValuePairs, count: 9)                   // big_values
                    si.writeBits(globalGain, count: 8)                      // global_gain
                    si.writeBits(0, count: 4)                               // scalefac_compress
                    si.writeBits(0, count: 1)                               // window_switching_flag
                    si.writeBits(tableIdx, count: 5)                        // table_select[0]
                    si.writeBits(tableIdx, count: 5)                        // table_select[1]
                    si.writeBits(tableIdx, count: 5)                        // table_select[2]
                    si.writeBits(15, count: 4)                              // region0_count
                    si.writeBits(7, count: 3)                               // region1_count
                    si.writeBits(0, count: 1)                               // preflag
                    si.writeBits(0, count: 1)                               // scalefac_scale
                    si.writeBits(0, count: 1)                               // count1table_select
                }
            }
            si.alignToByte()
            out.append(contentsOf: si.bytes)

            // Main data slot of exact length `mainDataSlotSize`.
            var slot = [UInt8](repeating: 0, count: mainDataSlotSize)
            let curPayload = frameMainData[f]
            let ownStart = mainDataBegin
            let ownLen = curPayload.count - ownStart
            for i in 0..<min(ownLen, mainDataSlotSize) {
                slot[i] = curPayload[ownStart + i]
            }

            // Place the prefix of frame `f + 1`'s main data at the tail of this slot for bit-reservoir lookback.
            if f + 1 < spec.frameCount && borrowBytes > 0 && borrowBytes <= frameMainData[f + 1].count {
                let nextPrefix = frameMainData[f + 1]
                let tailStart = mainDataSlotSize - borrowBytes
                if tailStart >= ownLen {
                    for i in 0..<borrowBytes {
                        slot[tailStart + i] = nextPrefix[i]
                    }
                }
            }
            out.append(contentsOf: slot)
        }

        // Optional trailing 128-byte ID3v1 tag.
        if spec.includeID3v1 {
            var id3v1 = [UInt8](repeating: 0, count: 128)
            id3v1[0] = 0x54; id3v1[1] = 0x41; id3v1[2] = 0x47 // "TAG"
            let title = Array("Polymer Test Tone".utf8)
            for i in 0..<min(title.count, 30) { id3v1[3 + i] = title[i] }
            out.append(contentsOf: id3v1)
        }

        return out
    }
}
