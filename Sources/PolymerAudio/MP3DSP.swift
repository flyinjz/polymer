// The Layer III building blocks that do not depend on stream state: Huffman
// lookup tables built from the code tables, the IMDCT with its windows, and
// the polyphase synthesis filter bank. `MP3Diagnostics` exposes their
// self-tests to the checks.
import PolymerBase

// MARK: Huffman lookup

/// A two-level lookup table for one Huffman code table. Each entry is a
/// UInt32. A leaf holds the value in bits 0-7 and the code length in bits 8-15
/// (0: no code here). A pointer to a subtable has bit 31 set, the subtable
/// offset in bits 0-19 and the subtable's index width in bits 24-28; a leaf in
/// a subtable stores the length remaining after the primary bits.
struct MP3Huffman: Sendable {
    let number: Int
    let primaryBits: Int
    let entries: [UInt32]
    /// Defects found while building: empty for a correct table.
    let problems: [String]

    init(_ s: MP3HuffmanSource) {
        number = s.number
        var problems: [String] = []
        let quad = s.number == 32
        let n = s.lengths.count
        func label(_ i: Int) -> String { quad ? "index \(i)" : "(\(i / s.dimension), \(i % s.dimension))" }
        func value(_ i: Int) -> UInt32 { quad ? UInt32(i) : UInt32((i / s.dimension) << 4 | (i % s.dimension)) }

        var maxLen = 0
        for l in s.lengths { maxLen = max(maxLen, Int(l)) }
        let pb = min(8, maxLen)
        primaryBits = pb

        var kraft: UInt64 = 0
        for i in 0..<n {
            let l = Int(s.lengths[i])
            guard l > 0 else { continue }
            kraft += UInt64(1) << UInt64(maxLen - l)
            if Int(s.codes[i]) >= 1 << l {
                problems.append("table \(s.number): code \(s.codes[i]) for \(label(i)) does not fit in \(l) bits")
            }
        }
        let full = UInt64(1) << UInt64(maxLen)
        if kraft != full {
            problems.append("table \(s.number): Kraft sum is \(kraft)/\(full), not 1, so "
                + (kraft < full ? "some bit patterns decode to nothing (MP3Diagnostics.unusedCodes lists them)" : "codes overlap"))
        }
        var seen: [Int: Int] = [:]
        for i in 0..<n where s.lengths[i] > 0 {
            let key = Int(s.lengths[i]) << 32 | Int(s.codes[i])
            if let j = seen[key] {
                problems.append("table \(s.number): \(label(j)) and \(label(i)) share the code \(MP3Huffman.bits(Int(s.codes[i]), Int(s.lengths[i])))")
            } else { seen[key] = i }
        }

        var e = [UInt32](repeating: 0, count: 1 << pb)
        var owner = [Int](repeating: -1, count: 1 << pb)
        var reported = Set<Int>()
        func conflict(_ a: Int, _ b: Int) {
            guard a >= 0, a != b, reported.insert(min(a, b) << 16 | max(a, b)).inserted else { return }
            problems.append("table \(s.number): the codes of \(label(a)) (\(MP3Huffman.bits(Int(s.codes[a]), Int(s.lengths[a])))) and \(label(b)) (\(MP3Huffman.bits(Int(s.codes[b]), Int(s.lengths[b])))) are not prefix free")
        }
        for i in 0..<n {
            let l = Int(s.lengths[i])
            guard l > 0, l <= pb else { continue }
            let base = (Int(s.codes[i]) & ((1 << l) - 1)) << (pb - l)
            for k in 0..<(1 << (pb - l)) {
                let slot = base + k
                if e[slot] != 0 { conflict(owner[slot], i); continue }
                e[slot] = value(i) | UInt32(l) << 8
                owner[slot] = i
            }
        }
        var groupBits = [Int](repeating: 0, count: 1 << pb)
        for i in 0..<n where Int(s.lengths[i]) > pb {
            let l = Int(s.lengths[i])
            let prefix = (Int(s.codes[i]) >> (l - pb)) & ((1 << pb) - 1)
            groupBits[prefix] = max(groupBits[prefix], l - pb)
            if e[prefix] != 0 { conflict(owner[prefix], i) }
        }
        for prefix in 0..<(1 << pb) where groupBits[prefix] > 0 && e[prefix] == 0 {
            let offset = e.count
            e.append(contentsOf: repeatElement(0, count: 1 << groupBits[prefix]))
            e[prefix] = 0x8000_0000 | UInt32(groupBits[prefix]) << 24 | UInt32(offset)
        }
        var subOwner: [Int: Int] = [:]
        for i in 0..<n where Int(s.lengths[i]) > pb {
            let l = Int(s.lengths[i])
            let code = Int(s.codes[i])
            let prefix = (code >> (l - pb)) & ((1 << pb) - 1)
            let pointer = e[prefix]
            guard pointer & 0x8000_0000 != 0 else { continue }
            let sub = Int(pointer >> 24 & 0x1F)
            let offset = Int(pointer & 0xF_FFFF)
            let rest = l - pb
            let base = offset + (code & ((1 << rest) - 1)) << (sub - rest)
            for k in 0..<(1 << (sub - rest)) {
                let slot = base + k
                if e[slot] != 0 { conflict(subOwner[slot] ?? -1, i); continue }
                e[slot] = value(i) | UInt32(rest) << 8
                subOwner[slot] = i
            }
        }
        entries = e
        self.problems = problems
    }

    /// Decodes one value. A bit pattern with no code consumes one bit and gives 0.
    @inline(__always) func decode(_ br: inout BitReader) -> Int {
        var e = entries[Int(br.peek(primaryBits))]
        if e & 0x8000_0000 != 0 {
            br.skip(primaryBits)
            e = entries[Int(e & 0xF_FFFF) + Int(br.peek(Int(e >> 24 & 0x1F)))]
        }
        let length = Int(e >> 8 & 0xFF)
        if length == 0 { br.skip(1); return 0 }
        br.skip(length)
        return Int(e & 0xFF)
    }

    static func bits(_ code: Int, _ length: Int) -> String {
        var s = ""
        for b in stride(from: length - 1, through: 0, by: -1) { s += (code >> b) & 1 == 1 ? "1" : "0" }
        return s
    }

    /// The shortest bit patterns that start no code of the table.
    static func unusedCodes(_ s: MP3HuffmanSource, limit: Int = 64) -> [String] {
        var codes = Set<Int>()
        var prefixes = Set<Int>()
        for i in 0..<s.lengths.count where s.lengths[i] > 0 {
            let l = Int(s.lengths[i]), c = Int(s.codes[i])
            codes.insert(l << 32 | c)
            for d in 1..<max(1, l) { prefixes.insert(d << 32 | c >> (l - d)) }
        }
        var out: [String] = []
        func walk(_ d: Int, _ p: Int) {
            if out.count >= limit { return }
            if d > 0 {
                if codes.contains(d << 32 | p) { return }
                if !prefixes.contains(d << 32 | p) { out.append(bits(p, d)); return }
            }
            if d >= 24 { return }
            walk(d + 1, p << 1)
            walk(d + 1, p << 1 | 1)
        }
        walk(0, 0)
        return out
    }
}

// MARK: Filter banks

enum MP3DSP {
    /// Lookup tables by table number (1...24 for big values, 32 for count1 table A).
    static let huffman: [MP3Huffman?] = {
        var t = [MP3Huffman?](repeating: nil, count: 33)
        for s in MP3Tables.pairs { t[s.number] = MP3Huffman(s) }
        t[32] = MP3Huffman(MP3Tables.quadA)
        return t
    }()

    static func table(_ count: Int, _ f: (Int) -> Double) -> UnsafePointer<Float> {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: count)
        for i in 0..<count { (p + i).initialize(to: Float(f(i))) }
        return UnsafePointer(p)
    }

    /// |i|^(4/3) for the largest Huffman value plus linbits (15 + 8191).
    nonisolated(unsafe) static let pow43 = table(8207) { i in i == 0 ? 0 : pow(base: Double(i), 4.0 / 3.0) }

    /// 2^(q/4) built exactly from a power of two and one of four fractions.
    @inline(__always) static func pow2Quarter(_ q: Int) -> Double {
        let f: Double
        switch q & 3 {
        case 0: f = 1
        case 1: f = 1.189207115002721
        case 2: f = 1.4142135623730951
        default: f = 1.681792830507429
        }
        return Double(sign: .plus, exponent: q >> 2, significand: f)
    }

    nonisolated(unsafe) static let cosLong = table(36 * 18) { n in
        let i = Double(n / 18), k = Double(n % 18)
        return Math.cos(Double.pi / 72 * (2 * i + 1 + 18) * (2 * k + 1))
    }
    nonisolated(unsafe) static let cosShort = table(12 * 6) { n in
        let i = Double(n / 6), k = Double(n % 6)
        return Math.cos(Double.pi / 24 * (2 * i + 1 + 6) * (2 * k + 1))
    }

    /// Window for block type t (0 normal, 1 start, 3 stop; 2 is unused here) at 36 * t + i.
    nonisolated(unsafe) static let longWindows = table(4 * 36) { n in
        let t = n / 36, i = n % 36
        let sine = Math.sin(Double.pi / 36 * (Double(i) + 0.5))
        switch t {
        case 0: return sine
        case 1:
            if i < 18 { return sine }
            if i < 24 { return 1 }
            if i < 30 { return Math.sin(Double.pi / 12 * (Double(i - 18) + 0.5)) }
            return 0
        case 3:
            if i < 6 { return 0 }
            if i < 12 { return Math.sin(Double.pi / 12 * (Double(i - 6) + 0.5)) }
            if i < 18 { return 1 }
            return sine
        default: return 0
        }
    }
    nonisolated(unsafe) static let shortWindow = table(12) { i in Math.sin(Double.pi / 12 * (Double(i) + 0.5)) }

    nonisolated(unsafe) static let synthN = table(64 * 32) { n in
        let i = Double(n / 32), k = Double(n % 32)
        return Math.cos((16 + i) * (2 * k + 1) * Double.pi / 64)
    }
    nonisolated(unsafe) static let synthD = table(512) { MP3Tables.window[$0] }

    nonisolated(unsafe) static let aliasCS = table(8) { 1 / (1 + MP3Tables.aliasCoefficients[$0] * MP3Tables.aliasCoefficients[$0]).squareRoot() }
    nonisolated(unsafe) static let aliasCA = table(8) {
        let c = MP3Tables.aliasCoefficients[$0]
        return c / (1 + c * c).squareRoot()
    }

    /// MPEG-1 intensity stereo: left and right factors for is_pos 0...6.
    nonisolated(unsafe) static let intensityLeft = table(7) { p in
        let a = Double(p) * Double.pi / 12
        return Math.sin(a) / (Math.sin(a) + Math.cos(a))
    }
    nonisolated(unsafe) static let intensityRight = table(7) { p in
        let a = Double(p) * Double.pi / 12
        return Math.cos(a) / (Math.sin(a) + Math.cos(a))
    }

    /// One subband's IMDCT, window and overlap-add: 18 coefficients in, 18 time samples out.
    /// For type 2 the coefficients are in reordered short-block order (3k + window).
    static func imdct(_ x: UnsafePointer<Float>, type: Int, overlap: UnsafeMutablePointer<Float>, out: UnsafeMutablePointer<Float>) {
        withUnsafeTemporaryAllocation(of: Float.self, capacity: 36) { zb in
            let z = zb.baseAddress!
            if type == 2 {
                z.initialize(repeating: 0, count: 36)
                for w in 0..<3 {
                    for i in 0..<12 {
                        var s: Float = 0
                        let row = cosShort + i * 6
                        for k in 0..<6 { s += x[3 * k + w] * row[k] }
                        z[6 + 6 * w + i] += s * shortWindow[i]
                    }
                }
            } else {
                let win = longWindows + type * 36
                for i in 0..<36 {
                    var s: Float = 0
                    let row = cosLong + i * 18
                    for k in 0..<18 { s += x[k] * row[k] }
                    z[i] = s * win[i]
                }
            }
            for t in 0..<18 {
                out[t] = z[t] + overlap[t]
                overlap[t] = z[18 + t]
            }
        }
    }

    /// One step of the polyphase synthesis: 32 subband samples in, 32 PCM samples out.
    /// `v` is the channel's 1024-sample history and `offset` its rotating start.
    static func synthesize(_ s: UnsafePointer<Float>, v: UnsafeMutablePointer<Float>, offset: inout Int, out: UnsafeMutablePointer<Float>) {
        offset = (offset - 64) & 1023
        let o = offset
        for i in 0..<64 {
            var a: Float = 0
            let row = synthN + i * 32
            for k in 0..<32 { a += row[k] * s[k] }
            v[(o + i) & 1023] = a
        }
        let d = synthD
        for j in 0..<32 {
            var a: Float = 0
            for i in 0..<8 {
                a += d[j + 64 * i] * v[(o + 128 * i + j) & 1023]
                a += d[j + 64 * i + 32] * v[(o + 128 * i + 96 + j) & 1023]
            }
            out[j] = a
        }
    }
}

// MARK: Self-tests

/// Self-tests of the hand-transcribed tables and the filter banks, for the checks.
public enum MP3Diagnostics {
    /// Every defect in the Huffman tables (gaps, overlaps, duplicate codes); empty when all are sound.
    public static func huffmanProblems() -> [String] {
        MP3DSP.huffman.compactMap { $0 }.flatMap { $0.problems }
    }

    /// Bit patterns that begin no code of table `number` (1...24, or 32 for count1 table A).
    public static func unusedCodes(table number: Int) -> [String] {
        if number == 32 { return MP3Huffman.unusedCodes(MP3Tables.quadA) }
        guard let s = MP3Tables.pairs.first(where: { $0.number == number }) else { return ["no table \(number)"] }
        return MP3Huffman.unusedCodes(s)
    }

    /// Encodes every code of every table and decodes it through the lookup tables;
    /// lists each code that does not come back as its own value and length.
    public static func huffmanRoundTripFailures() -> [String] {
        var failures: [String] = []
        for s in MP3Tables.pairs + [MP3Tables.quadA] {
            guard let t = MP3DSP.huffman[s.number] else { failures.append("table \(s.number) was not built"); continue }
            for i in 0..<s.lengths.count where s.lengths[i] > 0 {
                let l = Int(s.lengths[i])
                let word = UInt64(s.codes[i]) << UInt64(64 - l)
                var buf = [UInt8](repeating: 0, count: 8)
                for b in 0..<8 { buf[b] = UInt8(truncatingIfNeeded: word >> UInt64(56 - 8 * b)) }
                let (v, used) = buf.withUnsafeBufferPointer { p -> (Int, Int) in
                    var br = BitReader(p.baseAddress!, count: 8)
                    let v = t.decode(&br)
                    return (v, br.position)
                }
                let expected = s.number == 32 ? i : (i / s.dimension) << 4 | (i % s.dimension)
                if v != expected || used != l {
                    failures.append("table \(s.number) entry \(i): decoded value \(v >> 4),\(v & 15) in \(used) bits, expected \(expected >> 4),\(expected & 15) in \(l)")
                }
            }
        }
        return failures
    }

    /// Defects in the scalefactor band and scalefactor tables.
    public static func bandProblems() -> [String] {
        var p: [String] = []
        let rates = MP3Tables.sampleRates
        for r in 0..<9 {
            let l = MP3Tables.longBands[r], s = MP3Tables.shortBands[r]
            if l.count != 23 || l.first != 0 || l.last != 576 { p.append("long bands at \(rates[r]) Hz: need 23 boundaries from 0 to 576") }
            if s.count != 14 || s.first != 0 || s.last != 192 { p.append("short bands at \(rates[r]) Hz: need 14 boundaries from 0 to 192") }
            for i in 1..<l.count where l[i] <= l[i - 1] { p.append("long bands at \(rates[r]) Hz do not rise at \(i)") }
            for i in 1..<s.count where s[i] <= s[i - 1] { p.append("short bands at \(rates[r]) Hz do not rise at \(i)") }
            let longPart = r < 3 ? 8 : 6
            if l.count > longPart, s.count > 3, l[longPart] != 3 * s[3] {
                p.append("mixed blocks at \(rates[r]) Hz: long part ends at \(l[longPart]), short part starts at \(3 * s[3])")
            }
        }
        for (t, kinds) in MP3Tables.lsfBandCounts.enumerated() {
            let sums = kinds.map { $0.reduce(0, +) }
            if sums != [21, 36, 33] { p.append("LSF scalefactor counts \(t) sum to \(sums), expected [21, 36, 33]") }
        }
        if MP3Tables.pretab.count != 22 { p.append("pretab has \(MP3Tables.pretab.count) entries, expected 22") }
        if MP3Tables.slen1.count != 16 || MP3Tables.slen2.count != 16 { p.append("slen tables need 16 entries") }
        return p
    }

    /// Synthesis window values that are not multiples of 1/65536 (a transcription error).
    public static func windowProblems() -> [String] {
        var p: [String] = []
        if MP3Tables.windowHalf.count != 257 { p.append("synthesis window has \(MP3Tables.windowHalf.count) values, expected 257") }
        for (i, d) in MP3Tables.windowHalf.enumerated() {
            let units = d * 65536
            let nearest = (units + (units < 0 ? -0.5 : 0.5)).rounded(.towardZero)
            if abs(units - nearest) > 0.001 { p.append("D[\(i)] = \(d) is \(units) / 65536, not a whole number of 1/65536") }
        }
        return p
    }

    /// Runs a test signal through the standard's analysis filter bank (window D / 32)
    /// and Polymer's synthesis. Returns the reconstruction SNR in dB, the delay in
    /// samples and the gain (1 when correct).
    public static func filterbankRoundTrip(sampleRate: Double = 44100) -> (snr: Double, delay: Int, gain: Double) {
        let blocks = 300
        let n = blocks * 32
        var x = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            x[i] = 0.4 * Math.sin(2 * Double.pi * 997 * t) + 0.3 * Math.sin(2 * Double.pi * 6007 * t) + 0.1 * Math.sin(2 * Double.pi * 15013 * t)
        }
        var fifo = [Double](repeating: 0, count: 512)
        var m = [Double](repeating: 0, count: 32 * 64)
        for i in 0..<32 { for k in 0..<64 { m[i * 64 + k] = Math.cos(Double(2 * i + 1) * Double(k - 16) * Double.pi / 64) } }
        let c = MP3Tables.window.map { $0 / 32 }
        var out = [Float](repeating: 0, count: n)
        let v = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
        v.initialize(repeating: 0, count: 1024)
        defer { v.deallocate() }
        var offset = 0
        var sub = [Float](repeating: 0, count: 32)
        var y = [Double](repeating: 0, count: 64)
        for b in 0..<blocks {
            for i in stride(from: 511, through: 32, by: -1) { fifo[i] = fifo[i - 32] }
            for i in 0..<32 { fifo[31 - i] = x[b * 32 + i] }
            for k in 0..<64 {
                var a = 0.0
                for j in 0..<8 { a += c[k + 64 * j] * fifo[k + 64 * j] }
                y[k] = a
            }
            for i in 0..<32 {
                var a = 0.0
                for k in 0..<64 { a += m[i * 64 + k] * y[k] }
                sub[i] = Float(a)
            }
            sub.withUnsafeBufferPointer { s in
                out.withUnsafeMutableBufferPointer { o in
                    MP3DSP.synthesize(s.baseAddress!, v: v, offset: &offset, out: o.baseAddress! + b * 32)
                }
            }
        }
        let span = n - 1100
        var best = 0, bestCorrelation = -Double.infinity
        for d in 0..<1024 {
            var a = 0.0
            for i in 0..<span { a += Double(out[i + d]) * x[i] }
            if a > bestCorrelation { bestCorrelation = a; best = d }
        }
        var energy = 0.0, error = 0.0
        for i in 0..<span { energy += x[i] * x[i] }
        let gain = bestCorrelation / energy
        for i in 0..<span { let e = Double(out[i + best]) - x[i]; error += e * e }
        let snr = error > 0 ? 10 * Math.log(energy / error) / Math.log(10) : 200
        return (snr, best, gain)
    }

    /// Forward MDCT (scaled to match) then Polymer's IMDCT over a run of block
    /// types covering every transition; returns the largest reconstruction error.
    public static func imdctRoundTripError() -> Double {
        let types = [0, 0, 1, 2, 2, 3, 0, 1, 3, 0, 0]
        let n = 18 * (types.count + 1)
        var x = [Float](repeating: 0, count: n)
        var seed: UInt32 = 12345
        for i in 0..<n {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            x[i] = Float(Double(seed >> 8) / 16_777_216 - 0.5)
        }
        var y = [Float](repeating: 0, count: n)
        var coefficients = [Float](repeating: 0, count: 18)
        var overlap = [Float](repeating: 0, count: 18)
        for (b, type) in types.enumerated() {
            for k in 0..<18 { coefficients[k] = 0 }
            if type == 2 {
                for w in 0..<3 {
                    for k in 0..<6 {
                        var a = 0.0
                        for i in 0..<12 {
                            let z = Double(x[18 * b + 6 + 6 * w + i]) * Double(MP3DSP.shortWindow[i])
                            a += z * Math.cos(Double.pi / 24 * Double(2 * i + 1 + 6) * Double(2 * k + 1))
                        }
                        coefficients[3 * k + w] = Float(a / 3)
                    }
                }
            } else {
                for k in 0..<18 {
                    var a = 0.0
                    for i in 0..<36 {
                        let z = Double(x[18 * b + i]) * Double(MP3DSP.longWindows[type * 36 + i])
                        a += z * Math.cos(Double.pi / 72 * Double(2 * i + 1 + 18) * Double(2 * k + 1))
                    }
                    coefficients[k] = Float(a / 9)
                }
            }
            coefficients.withUnsafeBufferPointer { c in
                overlap.withUnsafeMutableBufferPointer { o in
                    y.withUnsafeMutableBufferPointer { out in
                        MP3DSP.imdct(c.baseAddress!, type: type, overlap: o.baseAddress!, out: out.baseAddress! + 18 * b)
                    }
                }
            }
        }
        var worst = 0.0
        for i in 18..<(18 * types.count) { worst = max(worst, Double(abs(y[i] - x[i]))) }
        return worst
    }
}
