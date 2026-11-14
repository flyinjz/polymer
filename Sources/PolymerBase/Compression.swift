// zlib (RFC 1950) and DEFLATE (RFC 1951): our own inflate and deflate,
// plus CRC-32 and Adler-32. Used by PNG.

public enum Checksum {
    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// CRC-32 (ISO 3309), continuing from `crc` (start with 0).
    public static func crc32(_ bytes: some Collection<UInt8>, continuing crc: UInt32 = 0) -> UInt32 {
        var c = ~crc
        crcTable.withUnsafeBufferPointer { t in
            for b in bytes { c = t[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return ~c
    }

    public static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        var i = 0
        bytes.withUnsafeBufferPointer { p in
            while i < p.count {
                let end = min(i + 5552, p.count)
                while i < end { a &+= UInt32(p[i]); b &+= a; i += 1 }
                a %= 65521; b %= 65521
            }
        }
        return b << 16 | a
    }
}

public struct CompressionError: Error, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { "compressed data: \(message)" }
}

public enum Zlib {
    /// Decompresses a zlib stream.
    public static func decompress(_ data: [UInt8]) throws(CompressionError) -> [UInt8] {
        guard data.count >= 6 else { throw CompressionError("zlib stream too short") }
        let cmf = data[0], flg = data[1]
        guard cmf & 0x0F == 8, (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0 else {
            throw CompressionError("not a zlib stream (bad header)")
        }
        guard flg & 0x20 == 0 else { throw CompressionError("preset dictionaries are not supported") }
        var inflater = Inflater(data, start: 2)
        let out = try inflater.run()
        let p = inflater.bytePosition
        let expected = data.u32(at: p)
        guard p + 4 <= data.count, Checksum.adler32(out) == expected else {
            throw CompressionError("Adler-32 checksum mismatch")
        }
        return out
    }

    /// Compresses into a zlib stream (DEFLATE with LZ77 and fixed Huffman codes).
    public static func compress(_ data: [UInt8]) -> [UInt8] {
        var w = BitWriter()
        w.bytes = [0x78, 0x01]
        Deflater.encode(data, into: &w)
        w.flush()
        w.bytes.append(u32: Checksum.adler32(data))
        return w.bytes
    }
}

// MARK: - Inflate

struct Huffman {
    var counts = [UInt16](repeating: 0, count: 16)
    var symbols: [UInt16]

    init(lengths: ArraySlice<UInt8>) throws(CompressionError) {
        symbols = [UInt16](repeating: 0, count: lengths.count)
        for l in lengths { counts[Int(l)] += 1 }
        counts[0] = 0
        var left = 1
        for len in 1..<16 {
            left <<= 1
            left -= Int(counts[len])
            if left < 0 { throw CompressionError("over-subscribed Huffman code") }
        }
        var offs = [Int](repeating: 0, count: 16)
        for len in 1..<15 { offs[len + 1] = offs[len] + Int(counts[len]) }
        for (k, l) in lengths.enumerated() where l != 0 {
            symbols[offs[Int(l)]] = UInt16(k)
            offs[Int(l)] += 1
        }
    }
}

struct Inflater {
    let src: [UInt8]
    var pos: Int
    var bitBuf: UInt32 = 0
    var bitCount = 0
    var out: [UInt8] = []

    init(_ src: [UInt8], start: Int) { self.src = src; pos = start; out.reserveCapacity(src.count * 4) }

    /// Byte position after the last fully consumed byte (for the trailer).
    var bytePosition: Int { pos - bitCount / 8 }

    @inline(__always) mutating func bits(_ n: Int) throws(CompressionError) -> Int {
        while bitCount < n {
            guard pos < src.count else { throw CompressionError("data ended early") }
            bitBuf |= UInt32(src[pos]) << UInt32(bitCount)
            pos += 1
            bitCount += 8
        }
        let v = Int(bitBuf & ((1 << UInt32(n)) - 1))
        bitBuf >>= UInt32(n)
        bitCount -= n
        return v
    }

    @inline(__always) mutating func decode(_ h: Huffman) throws(CompressionError) -> Int {
        var code = 0, first = 0, index = 0
        for len in 1..<16 {
            code |= try bits(1)
            let count = Int(h.counts[len])
            if code - count < first { return Int(h.symbols[index + (code - first)]) }
            index += count
            first += count
            first <<= 1
            code <<= 1
        }
        throw CompressionError("invalid Huffman code")
    }

    static let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    static let distExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    static let fixedLit: Huffman = {
        var l = [UInt8](repeating: 8, count: 288)
        for k in 144..<256 { l[k] = 9 }
        for k in 256..<280 { l[k] = 7 }
        return try! Huffman(lengths: l[...])
    }()
    static let fixedDist: Huffman = try! Huffman(lengths: [UInt8](repeating: 5, count: 30)[...])

    mutating func run() throws(CompressionError) -> [UInt8] {
        var last = 0
        repeat {
            last = try bits(1)
            switch try bits(2) {
            case 0: try stored()
            case 1: try codes(Inflater.fixedLit, Inflater.fixedDist)
            case 2: try dynamic()
            default: throw CompressionError("invalid block type")
            }
        } while last == 0
        return out
    }

    mutating func stored() throws(CompressionError) {
        bitBuf = 0; bitCount = 0
        guard pos + 4 <= src.count else { throw CompressionError("data ended early") }
        let len = Int(src[pos]) | Int(src[pos + 1]) << 8
        let nlen = Int(src[pos + 2]) | Int(src[pos + 3]) << 8
        guard len == ~nlen & 0xFFFF else { throw CompressionError("stored block length mismatch") }
        pos += 4
        guard pos + len <= src.count else { throw CompressionError("data ended early") }
        out.append(contentsOf: src[pos..<pos + len])
        pos += len
    }

    mutating func dynamic() throws(CompressionError) {
        let nlen = try bits(5) + 257, ndist = try bits(5) + 1, ncode = try bits(4) + 4
        guard nlen <= 286, ndist <= 30 else { throw CompressionError("bad code counts") }
        let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var lengths = [UInt8](repeating: 0, count: 320)
        for k in 0..<ncode { lengths[order[k]] = UInt8(try bits(3)) }
        let lencode = try Huffman(lengths: lengths[0..<19])
        var index = 0
        while index < nlen + ndist {
            var sym = try decode(lencode)
            if sym < 16 { lengths[index] = UInt8(sym); index += 1; continue }
            var len: UInt8 = 0
            if sym == 16 {
                guard index > 0 else { throw CompressionError("repeat with no previous length") }
                len = lengths[index - 1]
                sym = 3 + (try bits(2))
            } else if sym == 17 {
                sym = 3 + (try bits(3))
            } else {
                sym = 11 + (try bits(7))
            }
            guard index + sym <= nlen + ndist else { throw CompressionError("too many lengths") }
            for _ in 0..<sym { lengths[index] = len; index += 1 }
        }
        guard lengths[256] != 0 else { throw CompressionError("no end-of-block code") }
        let lit = try Huffman(lengths: lengths[0..<nlen])
        let dist = try Huffman(lengths: lengths[nlen..<nlen + ndist])
        try codes(lit, dist)
    }

    mutating func codes(_ lit: Huffman, _ dist: Huffman) throws(CompressionError) {
        while true {
            var sym = try decode(lit)
            if sym < 256 { out.append(UInt8(sym)); continue }
            if sym == 256 { return }
            sym -= 257
            guard sym < 29 else { throw CompressionError("bad length symbol") }
            let len = Inflater.lengthBase[sym] + (try bits(Inflater.lengthExtra[sym]))
            let ds = try decode(dist)
            guard ds < 30 else { throw CompressionError("bad distance symbol") }
            let d = Inflater.distBase[ds] + (try bits(Inflater.distExtra[ds]))
            guard d <= out.count else { throw CompressionError("distance too far back") }
            let start = out.count - d
            for k in 0..<len { out.append(out[start + k]) }
        }
    }
}

// MARK: - Deflate

struct BitWriter {
    var bytes: [UInt8] = []
    var buf: UInt64 = 0
    var count = 0

    @inline(__always) mutating func write(_ value: UInt32, _ n: Int) {
        buf |= UInt64(value) << UInt64(count)
        count += n
        while count >= 8 { bytes.append(UInt8(truncatingIfNeeded: buf)); buf >>= 8; count -= 8 }
    }
    /// Huffman codes are sent most significant bit first.
    @inline(__always) mutating func writeReversed(_ code: UInt32, _ n: Int) {
        var r: UInt32 = 0, c = code
        for _ in 0..<n { r = r << 1 | (c & 1); c >>= 1 }
        write(r, n)
    }
    mutating func flush() {
        if count > 0 { bytes.append(UInt8(truncatingIfNeeded: buf)); buf = 0; count = 0 }
    }
}

enum Deflater {
    static func fixedLiteral(_ sym: Int, _ w: inout BitWriter) {
        switch sym {
        case 0..<144: w.writeReversed(UInt32(0x30 + sym), 8)
        case 144..<256: w.writeReversed(UInt32(0x190 + sym - 144), 9)
        case 256..<280: w.writeReversed(UInt32(sym - 256), 7)
        default: w.writeReversed(UInt32(0xC0 + sym - 280), 8)
        }
    }

    static func encode(_ data: [UInt8], into w: inout BitWriter) {
        w.write(1, 1)        // final block
        w.write(1, 2)        // fixed Huffman
        let n = data.count
        let hashSize = 1 << 15, window = 32768, maxChain = 48
        var head = [Int32](repeating: -1, count: hashSize)
        var prev = [Int32](repeating: -1, count: window)
        data.withUnsafeBufferPointer { d in
            @inline(__always) func hash(_ i: Int) -> Int {
                Int((UInt32(d[i]) << 10 ^ UInt32(d[i + 1]) << 5 ^ UInt32(d[i + 2])) & UInt32(hashSize - 1))
            }
            @inline(__always) func insert(_ i: Int) {
                guard i + 2 < n else { return }
                let h = hash(i)
                prev[i & (window - 1)] = head[h]
                head[h] = Int32(i)
            }
            var i = 0
            while i < n {
                var bestLen = 0, bestDist = 0
                if i + 2 < n {
                    var cand = Int(head[hash(i)])
                    var chain = maxChain
                    let maxLen = min(258, n - i)
                    while cand >= 0, i - cand <= window - 1, chain > 0 {
                        if d[cand + bestLen] == d[i + bestLen] || bestLen == 0 {
                            var l = 0
                            while l < maxLen, d[cand + l] == d[i + l] { l += 1 }
                            if l > bestLen { bestLen = l; bestDist = i - cand; if l == maxLen { break } }
                        }
                        let p = Int(prev[cand & (window - 1)])
                        if p >= cand { break }
                        cand = p
                        chain -= 1
                    }
                }
                if bestLen >= 3 {
                    var ls = 0
                    while ls < 28, Inflater.lengthBase[ls + 1] <= bestLen { ls += 1 }
                    fixedLiteral(257 + ls, &w)
                    if Inflater.lengthExtra[ls] > 0 { w.write(UInt32(bestLen - Inflater.lengthBase[ls]), Inflater.lengthExtra[ls]) }
                    var ds = 0
                    while ds < 29, Inflater.distBase[ds + 1] <= bestDist { ds += 1 }
                    w.writeReversed(UInt32(ds), 5)
                    if Inflater.distExtra[ds] > 0 { w.write(UInt32(bestDist - Inflater.distBase[ds]), Inflater.distExtra[ds]) }
                    for k in 0..<bestLen { insert(i + k) }
                    i += bestLen
                } else {
                    fixedLiteral(Int(d[i]), &w)
                    insert(i)
                    i += 1
                }
            }
        }
        fixedLiteral(256, &w)
    }
}
