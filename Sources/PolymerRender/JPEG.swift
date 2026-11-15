// JPEG, our own decoder: baseline and progressive Huffman-coded files with
// any sampling factors, restart intervals, greyscale, YCbCr, RGB, CMYK and
// YCCK. Pixels match libjpeg-turbo's default output exactly: the same
// integer IDCT ("islow"), the same fancy upsampling for 2x1, 2x2 and 1x2
// chroma, and the same colour conversion tables. Checked against images
// decoded by djpeg in `Tests/Fixtures/Images`.
import PolymerBase

public enum JPEG {
    /// Decodes a JPEG file to RGBA. Arithmetic-coded, lossless and 12-bit
    /// files are refused with an error that says so. Entropy-coded data that
    /// ends early decodes as zeros, as in libjpeg (a partial image, not an error).
    ///
    /// `scale` decodes directly at 1/2, 1/4 or 1/8 of the size with libjpeg's
    /// scaled inverse DCTs (pixels identical to `djpeg -scale`), far faster than
    /// decoding whole and shrinking: for thumbnails. The EXIF orientation is
    /// applied unless `applyOrientation` is false (`orientation(of:)` reads it).
    public static func decode(_ data: [UInt8], scale: JPEGScale = .full, applyOrientation: Bool = true) throws(ImageError) -> Bitmap {
        var d = JPEGDecoder(data: data)
        d.idctSize = scale.rawValue
        let b = try d.decode()
        return applyOrientation ? b.applyingOrientation(d.orientation) : b
    }

    /// The EXIF orientation (1 to 8; 1 when there is none), without decoding the image.
    public static func orientation(of data: [UInt8]) -> Int {
        var d = JPEGDecoder(data: data)
        d.headerOnly = true
        _ = try? d.decode()
        return d.orientation
    }

    /// The largest reduction whose image still covers `width` x `height` pixels, for an image `imageWidth` x `imageHeight`.
    public static func scale(imageWidth: Int, imageHeight: Int, covering width: Int, _ height: Int) -> JPEGScale {
        for s in [JPEGScale.eighth, .quarter, .half] where (imageWidth * s.rawValue + 7) / 8 >= width && (imageHeight * s.rawValue + 7) / 8 >= height {
            return s
        }
        return .full
    }

    /// True when `data` starts like a JPEG file.
    public static func matches(_ data: [UInt8]) -> Bool { data.count > 3 && data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF }
}

/// Sizes a JPEG decodes at directly: the raw value is the inverse DCT's size (8 is whole).
public enum JPEGScale: Int, Sendable, CaseIterable {
    case full = 8, half = 4, quarter = 2, eighth = 1
}

/// Zigzag position → natural (row-major) position; extra entries absorb corrupt run lengths.
private let naturalOrder: [Int] = [
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63,
]

struct HuffmanTable {
    /// Codes up to `lookupBits` long: (length << 8) | value; 0 for longer codes.
    var lookup = [UInt16](repeating: 0, count: 1 << HuffmanTable.lookupBits)
    var maxcode = [Int32](repeating: -1, count: 18)
    var valptr = [Int32](repeating: 0, count: 17)
    var mincode = [Int32](repeating: 0, count: 17)
    var values: [UInt8] = []
    static let lookupBits = 9

    init() {}

    init(counts: [Int], values: [UInt8]) throws(ImageError) {
        self.values = values
        var code: Int32 = 0, k: Int32 = 0
        for len in 1...16 {
            let n = Int32(counts[len])
            valptr[len] = k
            mincode[len] = code
            code += n
            k += n
            maxcode[len] = n > 0 ? code - 1 : -1
            guard code <= (1 << len) else { throw ImageError("JPEG Huffman table has more codes than its lengths allow") }
            if n > 0, len <= HuffmanTable.lookupBits {
                for i in 0..<n {
                    let c = Int(mincode[len] + i), shift = HuffmanTable.lookupBits - len
                    let entry = UInt16(len << 8) | UInt16(values[Int(valptr[len] + i)])
                    for j in (c << shift)..<((c + 1) << shift) { lookup[j] = entry }
                }
            }
            code <<= 1
        }
        maxcode[17] = Int32.max   // ends the slow search
    }
}

struct JPEGComponent {
    var id = 0, h = 1, v = 1, tq = 0
    /// Blocks per line and per column, padded to whole MCUs.
    var blocksPerLine = 0, blocksPerColumn = 0
    /// Samples per line and lines in the image, before upsampling (libjpeg's downsampled_width/height).
    var width = 0, height = 0
    var coefficients: [Int16] = []
    var quant: [Int32]? = nil
    var dcTable = 0, acTable = 0
    var dcPred = 0
}

struct JPEGDecoder {
    let data: [UInt8]
    var pos = 0
    // Tables.
    var quant = [[Int32]](repeating: [Int32](repeating: 1, count: 64), count: 4)
    /// Huffman tables, flat: slots 0 to 3 are DC tables, 4 to 7 AC tables.
    var hLookup = [UInt16](repeating: 0, count: 8 << HuffmanTable.lookupBits)
    var hMaxcode: [Int32] = (0..<(8 * 18)).map { $0 % 18 == 17 ? Int32.max : -1 }
    var hValptr = [Int32](repeating: 0, count: 8 * 17)
    var hMincode = [Int32](repeating: 0, count: 8 * 17)
    var hValues = [UInt8](repeating: 0, count: 8 * 256)
    // Frame.
    var width = 0, height = 0
    var progressive = false
    var components: [JPEGComponent] = []
    var hmax = 1, vmax = 1, mcusX = 0, mcusY = 0
    var restartInterval = 0
    var sawJFIF = false, adobeTransform: Int? = nil
    /// Output scale: the smallest inverse DCT size (8, 4, 2 or 1), as libjpeg's `min_DCT_scaled_size`.
    var idctSize = 8
    /// EXIF orientation, 1 when absent.
    var orientation = 1
    /// Stop at the first frame header (for `JPEG.orientation`).
    var headerOnly = false
    // Entropy decoding.
    var acc: UInt64 = 0, accBits = 0, atMarker = false
    var eobrun = 0

    init(data: [UInt8]) { self.data = data }

    func u16(_ p: Int) -> Int { Int(data[p]) << 8 | Int(data[p + 1]) }

    mutating func decode() throws(ImageError) -> Bitmap {
        guard JPEG.matches(data) else { throw ImageError("not a JPEG file (no start-of-image marker)") }
        pos = 2
        var frameSeen = false
        while true {
            // The next marker: 0xFF (fill bytes allowed) and then a byte other
            // than 0, which would be a stuffed 0xFF inside entropy-coded data.
            while pos + 1 < data.count, !(data[pos] == 0xFF && data[pos + 1] != 0 && data[pos + 1] != 0xFF) { pos += 1 }
            pos += 1
            guard pos < data.count else {
                if frameSeen { break }
                throw ImageError("JPEG file ends before any image data")
            }
            let marker = data[pos]
            pos += 1
            switch marker {
            case 0xD8, 0x01, 0xD0...0xD7: continue   // SOI, TEM, stray restart markers: no length
            case 0xD9: break                          // EOI
            default:
                guard pos + 2 <= data.count else { throw ImageError("JPEG segment header cut off") }
                let length = u16(pos)
                guard length >= 2, pos + length <= data.count else { throw ImageError("JPEG segment runs past the end of the file") }
                let body = pos + 2, end = pos + length
                switch marker {
                case 0xC0, 0xC1, 0xC2:
                    guard !frameSeen else { throw ImageError("JPEG file has more than one frame") }
                    try readFrame(body, end, progressive: marker == 0xC2)
                    frameSeen = true
                    if headerOnly { return Bitmap(width: 0, height: 0) }
                case 0xC3, 0xC5, 0xC6, 0xC7, 0xCB, 0xCD, 0xCE, 0xCF:
                    throw ImageError("lossless and hierarchical JPEG are not supported")
                case 0xC9, 0xCA:
                    throw ImageError("arithmetic-coded JPEG is not supported (rare; re-encode with Huffman coding)")
                case 0xC4: try readHuffman(body, end)
                case 0xDB: try readQuant(body, end)
                case 0xDD:
                    guard length >= 4 else { throw ImageError("JPEG restart interval segment too short") }
                    restartInterval = u16(body)
                case 0xDA:
                    guard frameSeen else { throw ImageError("JPEG scan before its frame header") }
                    pos = end
                    try readScan(body, end)
                    continue
                case 0xE0:
                    if length >= 7, data[body] == 0x4A, data[body + 1] == 0x46, data[body + 2] == 0x49, data[body + 3] == 0x46 { sawJFIF = true }
                case 0xE1: readExif(body, end)
                case 0xEE:
                    if length >= 14, data[body] == 0x41, data[body + 1] == 0x64, data[body + 2] == 0x6F, data[body + 3] == 0x62 {
                        adobeTransform = Int(data[body + 11])
                    }
                case 0xDC: throw ImageError("JPEG files with a DNL marker are not supported")
                default: break   // APPn, COM and others: skipped
                }
                pos = end
                continue
            }
            break
        }
        guard frameSeen else { throw ImageError("JPEG file has no frame header") }
        return output()
    }

    // MARK: Segments

    mutating func readFrame(_ body: Int, _ end: Int, progressive: Bool) throws(ImageError) {
        guard end - body >= 6 else { throw ImageError("JPEG frame header too short") }
        guard data[body] == 8 else { throw ImageError("\(data[body])-bit JPEG is not supported (only 8-bit samples)") }
        height = u16(body + 1); width = u16(body + 3)
        let n = Int(data[body + 5])
        guard width > 0, height > 0 else { throw ImageError("JPEG with zero width or height (or a DNL marker) is not supported") }
        guard [1, 3, 4].contains(n), end - body >= 6 + 3 * n else { throw ImageError("JPEG with \(n) components is not supported") }
        self.progressive = progressive
        for i in 0..<n {
            let p = body + 6 + 3 * i
            var c = JPEGComponent()
            c.id = Int(data[p]); c.h = Int(data[p + 1] >> 4); c.v = Int(data[p + 1] & 15); c.tq = Int(data[p + 2])
            guard (1...4).contains(c.h), (1...4).contains(c.v), c.tq < 4 else { throw ImageError("JPEG component has invalid sampling factors or table") }
            components.append(c)
        }
        hmax = components.map(\.h).max()!; vmax = components.map(\.v).max()!
        mcusX = (width + 8 * hmax - 1) / (8 * hmax)
        mcusY = (height + 8 * vmax - 1) / (8 * vmax)
        guard mcusX * mcusY * hmax * vmax <= 1 << 22 else { throw ImageError("JPEG is too large (\(width)x\(height))") }
        for i in components.indices {
            let c = components[i]
            guard hmax % c.h == 0, vmax % c.v == 0 else { throw ImageError("JPEG sampling factors that are not whole ratios are not supported") }
            components[i].blocksPerLine = mcusX * c.h
            components[i].blocksPerColumn = mcusY * c.v
            components[i].width = (width * c.h + hmax - 1) / hmax
            components[i].height = (height * c.v + vmax - 1) / vmax
            components[i].coefficients = [Int16](repeating: 0, count: components[i].blocksPerLine * components[i].blocksPerColumn * 64)
        }
    }

    mutating func readHuffman(_ body: Int, _ end: Int) throws(ImageError) {
        var p = body
        while p < end {
            guard p + 17 <= end else { throw ImageError("JPEG Huffman table cut off") }
            let tc = Int(data[p] >> 4), th = Int(data[p] & 15)
            guard tc < 2, th < 4 else { throw ImageError("JPEG Huffman table has an invalid class or slot") }
            var counts = [Int](repeating: 0, count: 17)
            var total = 0
            for i in 1...16 { counts[i] = Int(data[p + i]); total += counts[i] }
            guard total <= 256, p + 17 + total <= end else { throw ImageError("JPEG Huffman table cut off") }
            let table = try HuffmanTable(counts: counts, values: Array(data[(p + 17)..<(p + 17 + total)]))
            install(table, slot: tc * 4 + th)
            p += 17 + total
        }
    }

    mutating func readQuant(_ body: Int, _ end: Int) throws(ImageError) {
        var p = body
        while p < end {
            let pq = Int(data[p] >> 4), tq = Int(data[p] & 15)
            guard pq < 2, tq < 4, p + 1 + 64 * (pq + 1) <= end else { throw ImageError("JPEG quantisation table is invalid or cut off") }
            var t = [Int32](repeating: 0, count: 64)
            for k in 0..<64 {
                t[naturalOrder[k]] = pq == 0 ? Int32(data[p + 1 + k]) : Int32(u16(p + 1 + 2 * k))
            }
            quant[tq] = t
            p += 1 + 64 * (pq + 1)
        }
    }

    /// Reads the orientation from an EXIF segment (APP1): a TIFF header and its first directory.
    mutating func readExif(_ body: Int, _ end: Int) {
        guard end - body >= 14, Array(data[body..<(body + 6)]) == [0x45, 0x78, 0x69, 0x66, 0, 0] else { return }
        let t = body + 6
        let little: Bool
        switch (data[t], data[t + 1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: return
        }
        func u16(_ p: Int) -> Int? {
            guard p >= t, p + 2 <= end else { return nil }
            return little ? Int(data[p]) | Int(data[p + 1]) << 8 : Int(data[p]) << 8 | Int(data[p + 1])
        }
        func u32(_ p: Int) -> Int? {
            guard let a = u16(p), let b = u16(p + 2) else { return nil }
            return little ? a | b << 16 : a << 16 | b
        }
        guard let ifd = u32(t + 4), let count = u16(t + ifd) else { return }
        for i in 0..<min(count, 512) {
            let e = t + ifd + 2 + 12 * i
            guard let tag = u16(e), let type = u16(e + 2) else { return }
            if tag == 0x0112, type == 3, let v = u16(e + 8), (1...8).contains(v) { orientation = v; return }
        }
    }

    // MARK: Entropy-coded data

    /// Keeps at least 57 bits in the accumulator. At a marker (or the end of
    /// the file) zeros are fed in, as libjpeg does with truncated data.
    @inline(__always) mutating func fill() {
        while accBits <= 56 {
            var byte: UInt8 = 0
            if !atMarker, pos < data.count {
                byte = data[pos]
                if byte == 0xFF {
                    let next = pos + 1 < data.count ? data[pos + 1] : 0xD9
                    if next == 0 { pos += 2 } else { atMarker = true; byte = 0 }
                } else {
                    pos += 1
                }
            }
            acc |= UInt64(byte) << UInt64(56 - accBits)
            accBits += 8
        }
    }

    @inline(__always) mutating func bits(_ n: Int) -> Int {
        guard n > 0 else { return 0 }
        if accBits < n { fill() }
        let v = Int(acc >> UInt64(64 - n))
        acc <<= UInt64(n); accBits -= n
        return v
    }

    @inline(__always) mutating func bit() -> Bool { bits(1) != 0 }

    /// `n` bits as a signed value (JPEG's "receive and extend").
    @inline(__always) mutating func receiveExtend(_ n: Int) -> Int {
        guard n > 0 else { return 0 }
        let v = bits(n)
        return v < 1 << (n - 1) ? v - (1 << n) + 1 : v
    }

    /// Copies a table into its slot of the flat arrays.
    mutating func install(_ t: HuffmanTable, slot: Int) {
        let n = 1 << HuffmanTable.lookupBits
        for i in 0..<n { hLookup[slot * n + i] = t.lookup[i] }
        for i in 0..<18 { hMaxcode[slot * 18 + i] = t.maxcode[i] }
        for i in 0..<17 { hValptr[slot * 17 + i] = t.valptr[i]; hMincode[slot * 17 + i] = t.mincode[i] }
        for i in 0..<256 { hValues[slot * 256 + i] = i < t.values.count ? t.values[i] : 0 }
    }

    /// One Huffman-coded value with the table in `slot`.
    @inline(__always) mutating func decodeHuffman(_ slot: Int) -> Int {
        if accBits < 17 { fill() }
        let e = Int(hLookup[slot << HuffmanTable.lookupBits | Int(acc >> UInt64(64 - HuffmanTable.lookupBits))])
        if e != 0 {
            let len = e >> 8
            acc <<= UInt64(len); accBits -= len
            return e & 0xFF
        }
        var len = HuffmanTable.lookupBits + 1
        var code = Int32(acc >> UInt64(64 - len))
        while code > hMaxcode[slot * 18 + len] { len += 1; code = Int32(acc >> UInt64(64 - len)) }
        acc <<= UInt64(len); accBits -= len
        guard len <= 16 else { return 0 }   // corrupt data: libjpeg also carries on with zero
        let i = Int(hValptr[slot * 17 + len] + code - hMincode[slot * 17 + len])
        return (0..<256).contains(i) ? Int(hValues[slot * 256 + i]) : 0
    }

    /// Skips the restart marker that should come next and resets the predictions.
    mutating func restart() {
        acc = 0; accBits = 0
        // Find the marker (it may be preceded by fill bytes).
        while pos + 1 < data.count, !(data[pos] == 0xFF && (0xD0...0xD7).contains(data[pos + 1])) {
            if data[pos] == 0xFF, data[pos + 1] != 0, data[pos + 1] != 0xFF { break }   // another marker: leave it for the parser
            pos += 1
        }
        if pos + 1 < data.count, data[pos] == 0xFF, (0xD0...0xD7).contains(data[pos + 1]) { pos += 2 }
        atMarker = false
        eobrun = 0
        for i in components.indices { components[i].dcPred = 0 }
    }

    mutating func readScan(_ body: Int, _ end: Int) throws(ImageError) {
        let n = Int(data[body])
        guard (1...4).contains(n), end - body >= 1 + 2 * n + 3 else { throw ImageError("JPEG scan header is invalid") }
        var scan: [Int] = []
        for i in 0..<n {
            let id = Int(data[body + 1 + 2 * i]), tables = data[body + 2 + 2 * i]
            guard let c = components.firstIndex(where: { $0.id == id }) else { throw ImageError("JPEG scan names a component the frame doesn't have") }
            components[c].dcTable = Int(tables >> 4) & 3
            components[c].acTable = Int(tables & 15) & 3
            if components[c].quant == nil { components[c].quant = quant[components[c].tq] }   // latched, as libjpeg
            scan.append(c)
        }
        let p = body + 1 + 2 * n
        let ss = Int(data[p]), se = Int(data[p + 1]), ah = Int(data[p + 2] >> 4), al = Int(data[p + 2] & 15)
        if progressive {
            guard ss <= se, se < 64, (ss == 0) == (se == 0), ss == 0 || n == 1, al < 14 else {
                throw ImageError("JPEG progressive scan has invalid parameters")
            }
        }
        acc = 0; accBits = 0; atMarker = false; eobrun = 0
        for c in scan { components[c].dcPred = 0 }

        enum Kind { case baseline, dcFirst, dcRefine, acFirst, acRefine }
        let kind: Kind = !progressive ? .baseline : ss == 0 ? (ah == 0 ? .dcFirst : .dcRefine) : (ah == 0 ? .acFirst : .acRefine)

        func decodeBlock(_ d: inout JPEGDecoder, _ c: Int, _ offset: Int) {
            switch kind {
            case .baseline: d.decodeBaseline(c, offset)
            case .dcFirst: d.decodeDCFirst(c, offset, al)
            case .dcRefine: if d.bit() { d.components[c].coefficients[offset] |= Int16(1 << al) }
            case .acFirst: d.decodeACFirst(c, offset, ss, se, al)
            case .acRefine: d.decodeACRefine(c, offset, ss, se, al)
            }
        }

        var unitsToRestart = restartInterval
        func countUnit(_ d: inout JPEGDecoder) {
            guard d.restartInterval > 0 else { return }
            unitsToRestart -= 1
            if unitsToRestart == 0 { d.restart(); unitsToRestart = d.restartInterval }
        }

        if scan.count == 1 {
            // One component: its own blocks, row by row, only those covering the image.
            let c = scan[0], comp = components[c]
            let bw = (comp.width + 7) / 8, bh = (comp.height + 7) / 8
            for by in 0..<bh {
                for bx in 0..<bw {
                    decodeBlock(&self, c, (by * comp.blocksPerLine + bx) * 64)
                    countUnit(&self)
                }
            }
        } else {
            for my in 0..<mcusY {
                for mx in 0..<mcusX {
                    for c in scan {
                        let comp = components[c]
                        for v in 0..<comp.v {
                            for h in 0..<comp.h {
                                let row = my * comp.v + v, col = mx * comp.h + h
                                decodeBlock(&self, c, (row * comp.blocksPerLine + col) * 64)
                            }
                        }
                    }
                    countUnit(&self)
                }
            }
        }
    }

    mutating func decodeBaseline(_ c: Int, _ offset: Int) {
        let t = decodeHuffman(components[c].dcTable)
        components[c].dcPred += receiveExtend(t)
        components[c].coefficients[offset] = Int16(truncatingIfNeeded: components[c].dcPred)
        let ac = components[c].acTable
        var k = 1
        while k < 64 {
            let rs = decodeHuffman(4 + ac)
            let r = rs >> 4, s = rs & 15
            if s == 0 {
                if r != 15 { break }
                k += 16
                continue
            }
            k += r
            let v = receiveExtend(s)
            components[c].coefficients[offset + naturalOrder[min(k, 64)]] = Int16(truncatingIfNeeded: v)
            k += 1
        }
    }

    mutating func decodeDCFirst(_ c: Int, _ offset: Int, _ al: Int) {
        let t = decodeHuffman(components[c].dcTable)
        components[c].dcPred += receiveExtend(t)
        components[c].coefficients[offset] = Int16(truncatingIfNeeded: components[c].dcPred << al)
    }

    mutating func decodeACFirst(_ c: Int, _ offset: Int, _ ss: Int, _ se: Int, _ al: Int) {
        if eobrun > 0 { eobrun -= 1; return }
        let ac = components[c].acTable
        var k = ss
        while k <= se {
            let rs = decodeHuffman(4 + ac)
            let r = rs >> 4, s = rs & 15
            if s == 0 {
                if r < 15 {
                    eobrun = (1 << r) - 1
                    if r > 0 { eobrun += bits(r) }
                    break
                }
                k += 16
                continue
            }
            k += r
            let v = receiveExtend(s) * (1 << al)
            components[c].coefficients[offset + naturalOrder[min(k, 64)]] = Int16(truncatingIfNeeded: v)
            k += 1
        }
    }

    /// Successive approximation of AC coefficients, following libjpeg's decode_mcu_AC_refine.
    mutating func decodeACRefine(_ c: Int, _ offset: Int, _ ss: Int, _ se: Int, _ al: Int) {
        let p1 = Int16(1 << al), m1 = Int16(truncatingIfNeeded: -1 << al)
        let ac = components[c].acTable
        var k = ss
        @inline(__always) func refine(_ d: inout JPEGDecoder, _ i: Int) {
            let v = d.components[c].coefficients[i]
            if d.bit(), v & p1 == 0 { d.components[c].coefficients[i] = v >= 0 ? v &+ p1 : v &+ m1 }
        }
        if eobrun == 0 {
            outer: while k <= se {
                let rs = decodeHuffman(4 + ac)
                var r = rs >> 4
                let s = rs & 15
                var value: Int16 = 0
                if s != 0 {
                    value = bit() ? p1 : m1   // s is always 1 here
                } else if r != 15 {
                    eobrun = 1 << r
                    if r > 0 { eobrun += bits(r) }
                    break outer
                }
                while k <= se {
                    let i = offset + naturalOrder[k]
                    if components[c].coefficients[i] != 0 {
                        refine(&self, i)
                    } else {
                        r -= 1
                        if r < 0 { break }
                    }
                    k += 1
                }
                if value != 0, k <= 63 { components[c].coefficients[offset + naturalOrder[k]] = value }
                k += 1
            }
        }
        if eobrun > 0 {
            while k <= se {
                let i = offset + naturalOrder[k]
                if components[c].coefficients[i] != 0 { refine(&self, i) }
                k += 1
            }
            eobrun -= 1
        }
    }

    // MARK: Output

    /// A component's inverse DCT size: libjpeg-turbo doubles it from the
    /// output scale while that keeps whole upsampling ratios, so subsampled
    /// chroma often needs no upsampling at reduced scales (jdmaster.c).
    func dctSize(_ c: JPEGComponent) -> Int {
        var s = idctSize
        while s < 8, (hmax * idctSize) % (c.h * s * 2) == 0, (vmax * idctSize) % (c.v * s * 2) == 0 { s *= 2 }
        return s
    }

    /// Each component's samples after the inverse DCT, `s` x `s` per block
    /// (padded to whole blocks).
    func plane(_ c: JPEGComponent, _ s: Int) -> [UInt8] {
        let stride = c.blocksPerLine * s
        var out = [UInt8](repeating: 0, count: stride * c.blocksPerColumn * s)
        let q = c.quant ?? quant[c.tq]
        // Only the blocks that cover the image are needed.
        let bw = min(c.blocksPerLine, (c.width + 7) / 8), bh = min(c.blocksPerColumn, (c.height + 7) / 8)
        c.coefficients.withUnsafeBufferPointer { coef in
            q.withUnsafeBufferPointer { q in
                out.withUnsafeMutableBufferPointer { out in
                    var ws = [Int32](repeating: 0, count: 64)
                    ws.withUnsafeMutableBufferPointer { ws in
                        for by in 0..<bh {
                            for bx in 0..<bw {
                                let block = (by * c.blocksPerLine + bx) * 64, o = (by * s) * stride + bx * s
                                switch s {
                                case 8: idctIslow(coef, block, q, ws, out, o, stride)
                                case 4: idct4x4(coef, block, q, ws, out, o, stride)
                                case 2: idct2x2(coef, block, q, ws, out, o, stride)
                                default: idct1x1(coef, block, q, out, o)
                                }
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    func output() -> Bitmap {
        // Output size (libjpeg's output_width and output_height).
        let ow = (width * idctSize + 7) / 8, oh = (height * idctSize + 7) / 8
        // Planes at the output size (upsampled where needed).
        var planes: [[UInt8]] = []
        for c in components {
            let s = dctSize(c)
            let p = plane(c, s)
            let stride = c.blocksPerLine * s
            let hr = hmax * idctSize / (c.h * s), vr = vmax * idctSize / (c.v * s)
            if hr == 1, vr == 1 {
                planes.append(crop(p, stride, ow, oh))
            } else {
                // The component's size at this scale (libjpeg's downsampled_width and height).
                let cw = (width * c.h * s + hmax * 8 - 1) / (hmax * 8), ch = (height * c.v * s + vmax * 8 - 1) / (vmax * 8)
                planes.append(upsample(p, stride, cw, ch, hr, vr, ow, oh))
            }
        }
        var px = [UInt8](repeating: 255, count: ow * oh * 4)
        let n = ow * oh
        switch components.count {
        case 1:
            for i in 0..<n { let y = planes[0][i]; px[4 * i] = y; px[4 * i + 1] = y; px[4 * i + 2] = y }
        case 3:
            let ids = components.map(\.id)
            let rgb = sawJFIF ? false : adobeTransform.map { $0 == 0 } ?? (ids == [82, 71, 66])
            if rgb {
                for i in 0..<n { px[4 * i] = planes[0][i]; px[4 * i + 1] = planes[1][i]; px[4 * i + 2] = planes[2][i] }
            } else {
                let t = YCC.tables
                for i in 0..<n {
                    let (r, g, b) = t.rgb(planes[0][i], planes[1][i], planes[2][i])
                    px[4 * i] = r; px[4 * i + 1] = g; px[4 * i + 2] = b
                }
            }
        default:
            // Adobe stores CMYK inverted (255 = no ink); YCCK is that CMY behind a YCC transform.
            let ycck = adobeTransform == 2, t = YCC.tables
            @inline(__always) func mul(_ x: Int, _ y: Int) -> UInt8 { let v = x * y + 128; return UInt8((v + (v >> 8)) >> 8) }
            for i in 0..<n {
                let k = Int(planes[3][i])
                var c = (Int(planes[0][i]), Int(planes[1][i]), Int(planes[2][i]))
                if ycck {
                    let (r, g, b) = t.rgb(planes[0][i], planes[1][i], planes[2][i])
                    c = (255 - Int(r), 255 - Int(g), 255 - Int(b))
                }
                px[4 * i] = mul(c.0, k); px[4 * i + 1] = mul(c.1, k); px[4 * i + 2] = mul(c.2, k)
            }
        }
        return Bitmap(width: ow, height: oh, pixels: px)
    }

    func crop(_ p: [UInt8], _ stride: Int, _ width: Int, _ height: Int) -> [UInt8] {
        if stride == width { return Array(p[0..<(width * height)]) }
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { out[y * width + x] = p[y * stride + x] } }
        return out
    }

    /// Upsamples a component (`cw` x `ch` samples) by `hr` x `vr` to `width` x `height`
    /// as libjpeg-turbo does: triangle ("fancy") filters for 2x1, 2x2 and 1x2, replication otherwise.
    func upsample(_ p: [UInt8], _ stride: Int, _ cw: Int, _ ch: Int, _ hr: Int, _ vr: Int, _ width: Int, _ height: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height)
        @inline(__always) func at(_ x: Int, _ y: Int) -> Int { Int(p[y * stride + x]) }
        // One output row from input row `y` (and its neighbour `y2` for vertical filters).
        var row = [Int](repeating: 0, count: cw * hr + 2)
        // libjpeg-turbo filters only above 1/8 scale (jdsample.c: min_DCT_scaled_size > 1).
        let fancy = idctSize > 1
        if fancy, hr == 2, vr == 1, cw > 2 {
            for y in 0..<height {
                let iy = y
                row[0] = at(0, iy)
                row[1] = (at(0, iy) * 3 + at(1, iy) + 2) >> 2
                for x in 1..<(cw - 1) {
                    let v = at(x, iy) * 3
                    row[2 * x] = (v + at(x - 1, iy) + 1) >> 2
                    row[2 * x + 1] = (v + at(x + 1, iy) + 2) >> 2
                }
                row[2 * cw - 2] = (at(cw - 1, iy) * 3 + at(cw - 2, iy) + 1) >> 2
                row[2 * cw - 1] = at(cw - 1, iy)
                for x in 0..<width { out[y * width + x] = UInt8(row[x]) }
            }
        } else if fancy, hr == 2, vr == 2, cw > 2 {
            for y in 0..<height {
                let iy = y / 2
                let ny = y % 2 == 0 ? max(iy - 1, 0) : min(iy + 1, ch - 1)
                @inline(__always) func col(_ x: Int) -> Int { at(x, iy) * 3 + at(x, ny) }
                var this = col(0), next = col(1), last = this
                row[0] = (this * 4 + 8) >> 4
                row[1] = (this * 3 + next + 7) >> 4
                last = this; this = next
                for x in 1..<(cw - 1) {
                    next = col(x + 1)
                    row[2 * x] = (this * 3 + last + 8) >> 4
                    row[2 * x + 1] = (this * 3 + next + 7) >> 4
                    last = this; this = next
                }
                row[2 * cw - 2] = (this * 3 + last + 8) >> 4
                row[2 * cw - 1] = (this * 4 + 7) >> 4
                for x in 0..<width { out[y * width + x] = UInt8(row[x]) }
            }
        } else if fancy, hr == 1, vr == 2 {
            for y in 0..<height {
                let iy = y / 2
                let upper = y % 2 == 0
                let ny = upper ? max(iy - 1, 0) : min(iy + 1, ch - 1)
                let bias = upper ? 1 : 2
                for x in 0..<width { out[y * width + x] = UInt8((at(x, iy) * 3 + at(x, ny) + bias) >> 2) }
            }
        } else {
            for y in 0..<height { for x in 0..<width { out[y * width + x] = p[(y / vr) * stride + x / hr] } }
        }
        return out
    }
}

/// libjpeg's YCbCr → RGB tables (jdcolor.c), so colours match it exactly.
struct YCC {
    var crR = [Int](repeating: 0, count: 256), cbB = [Int](repeating: 0, count: 256)
    var crG = [Int](repeating: 0, count: 256), cbG = [Int](repeating: 0, count: 256)

    static let tables = YCC()

    init() {
        func fix(_ x: Double) -> Int { Int(x * Double(1 << 16) + 0.5) }
        let half = 1 << 15
        for i in 0..<256 {
            let x = i - 128
            crR[i] = (fix(1.40200) * x + half) >> 16
            cbB[i] = (fix(1.77200) * x + half) >> 16
            crG[i] = -fix(0.71414) * x
            cbG[i] = -fix(0.34414) * x + half
        }
    }

    @inline(__always) func rgb(_ y: UInt8, _ cb: UInt8, _ cr: UInt8) -> (UInt8, UInt8, UInt8) {
        let y = Int(y), cb = Int(cb), cr = Int(cr)
        @inline(__always) func clamp(_ v: Int) -> UInt8 { UInt8(min(max(v, 0), 255)) }
        return (clamp(y + crR[cr]), clamp(y + ((cbG[cb] + crG[cr]) >> 16)), clamp(y + cbB[cb]))
    }
}

/// libjpeg's accurate integer inverse DCT (jidctint.c, "islow"), with its range limiting.
@inline(__always)
private func idctIslow(_ coef: UnsafeBufferPointer<Int16>, _ offset: Int, _ q: UnsafeBufferPointer<Int32>,
                       _ ws: UnsafeMutableBufferPointer<Int32>, _ out: UnsafeMutableBufferPointer<UInt8>,
                       _ outOffset: Int, _ stride: Int) {
    let constBits: Int32 = 13, pass1Bits: Int32 = 2
    let f0298: Int32 = 2446, f0390: Int32 = 3196, f0541: Int32 = 4433, f0765: Int32 = 6270
    let f0899: Int32 = 7373, f1175: Int32 = 9633, f1501: Int32 = 12299, f1847: Int32 = 15137
    let f1961: Int32 = 16069, f2053: Int32 = 16819, f2562: Int32 = 20995, f3072: Int32 = 25172
    @inline(__always) func deq(_ i: Int) -> Int32 { Int32(coef[offset + i]) &* q[i] }
    @inline(__always) func descale(_ x: Int32, _ n: Int32) -> Int32 { (x &+ (1 << (n - 1))) >> n }

    // Pass 1: columns into the workspace.
    for col in 0..<8 {
        if coef[offset + 8 + col] == 0, coef[offset + 16 + col] == 0, coef[offset + 24 + col] == 0, coef[offset + 32 + col] == 0,
           coef[offset + 40 + col] == 0, coef[offset + 48 + col] == 0, coef[offset + 56 + col] == 0 {
            let dc = deq(col) << pass1Bits
            for r in 0..<8 { ws[r * 8 + col] = dc }
            continue
        }
        var z2 = deq(16 + col), z3 = deq(48 + col)
        var z1 = (z2 &+ z3) &* f0541
        var tmp2 = z1 &+ z3 &* -f1847
        var tmp3 = z1 &+ z2 &* f0765
        z2 = deq(col); z3 = deq(32 + col)
        var tmp0 = (z2 &+ z3) << constBits
        var tmp1 = (z2 &- z3) << constBits
        let tmp10 = tmp0 &+ tmp3, tmp13 = tmp0 &- tmp3, tmp11 = tmp1 &+ tmp2, tmp12 = tmp1 &- tmp2
        tmp0 = deq(56 + col); tmp1 = deq(40 + col); tmp2 = deq(24 + col); tmp3 = deq(8 + col)
        z1 = tmp0 &+ tmp3; z2 = tmp1 &+ tmp2; z3 = tmp0 &+ tmp2
        var z4 = tmp1 &+ tmp3
        let z5 = (z3 &+ z4) &* f1175
        tmp0 = tmp0 &* f0298; tmp1 = tmp1 &* f2053; tmp2 = tmp2 &* f3072; tmp3 = tmp3 &* f1501
        z1 = z1 &* -f0899; z2 = z2 &* -f2562; z3 = z3 &* -f1961; z4 = z4 &* -f0390
        z3 = z3 &+ z5; z4 = z4 &+ z5
        tmp0 = tmp0 &+ z1 &+ z3; tmp1 = tmp1 &+ z2 &+ z4; tmp2 = tmp2 &+ z2 &+ z3; tmp3 = tmp3 &+ z1 &+ z4
        let n = constBits - pass1Bits
        ws[col] = descale(tmp10 &+ tmp3, n); ws[56 + col] = descale(tmp10 &- tmp3, n)
        ws[8 + col] = descale(tmp11 &+ tmp2, n); ws[48 + col] = descale(tmp11 &- tmp2, n)
        ws[16 + col] = descale(tmp12 &+ tmp1, n); ws[40 + col] = descale(tmp12 &- tmp1, n)
        ws[24 + col] = descale(tmp13 &+ tmp0, n); ws[32 + col] = descale(tmp13 &- tmp0, n)
    }

    // Range limit as libjpeg's table: the low 10 bits, read as signed, plus 128, clamped.
    @inline(__always) func limit(_ x: Int32) -> UInt8 {
        var v = Int(x) & 1023
        if v >= 512 { v -= 1024 }
        return UInt8(min(max(v + 128, 0), 255))
    }

    // Pass 2: rows from the workspace into the output.
    let shift = constBits + pass1Bits + 3
    for row in 0..<8 {
        let w = row * 8, o = outOffset + row * stride
        if ws[w + 1] == 0, ws[w + 2] == 0, ws[w + 3] == 0, ws[w + 4] == 0, ws[w + 5] == 0, ws[w + 6] == 0, ws[w + 7] == 0 {
            let v = limit(descale(ws[w], pass1Bits + 3))
            for i in 0..<8 { out[o + i] = v }
            continue
        }
        var z2 = ws[w + 2], z3 = ws[w + 6]
        var z1 = (z2 &+ z3) &* f0541
        var tmp2 = z1 &+ z3 &* -f1847
        var tmp3 = z1 &+ z2 &* f0765
        var tmp0 = (ws[w] &+ ws[w + 4]) << constBits
        var tmp1 = (ws[w] &- ws[w + 4]) << constBits
        let tmp10 = tmp0 &+ tmp3, tmp13 = tmp0 &- tmp3, tmp11 = tmp1 &+ tmp2, tmp12 = tmp1 &- tmp2
        tmp0 = ws[w + 7]; tmp1 = ws[w + 5]; tmp2 = ws[w + 3]; tmp3 = ws[w + 1]
        z1 = tmp0 &+ tmp3; z2 = tmp1 &+ tmp2; z3 = tmp0 &+ tmp2
        var z4 = tmp1 &+ tmp3
        let z5 = (z3 &+ z4) &* f1175
        tmp0 = tmp0 &* f0298; tmp1 = tmp1 &* f2053; tmp2 = tmp2 &* f3072; tmp3 = tmp3 &* f1501
        z1 = z1 &* -f0899; z2 = z2 &* -f2562; z3 = z3 &* -f1961; z4 = z4 &* -f0390
        z3 = z3 &+ z5; z4 = z4 &+ z5
        tmp0 = tmp0 &+ z1 &+ z3; tmp1 = tmp1 &+ z2 &+ z4; tmp2 = tmp2 &+ z2 &+ z3; tmp3 = tmp3 &+ z1 &+ z4
        out[o] = limit(descale(tmp10 &+ tmp3, shift)); out[o + 7] = limit(descale(tmp10 &- tmp3, shift))
        out[o + 1] = limit(descale(tmp11 &+ tmp2, shift)); out[o + 6] = limit(descale(tmp11 &- tmp2, shift))
        out[o + 2] = limit(descale(tmp12 &+ tmp1, shift)); out[o + 5] = limit(descale(tmp12 &- tmp1, shift))
        out[o + 3] = limit(descale(tmp13 &+ tmp0, shift)); out[o + 4] = limit(descale(tmp13 &- tmp0, shift))
    }
}

/// libjpeg's 4x4 inverse DCT for output at 1/2 size (jidctred.c), the same arithmetic.
private func idct4x4(_ coef: UnsafeBufferPointer<Int16>, _ offset: Int, _ q: UnsafeBufferPointer<Int32>,
                     _ ws: UnsafeMutableBufferPointer<Int32>, _ out: UnsafeMutableBufferPointer<UInt8>,
                     _ outOffset: Int, _ stride: Int) {
    let constBits: Int32 = 13, pass1Bits: Int32 = 2
    let f0211: Int32 = 1730, f0509: Int32 = 4176, f0601: Int32 = 4926, f0765: Int32 = 6270, f0899: Int32 = 7373
    let f1061: Int32 = 8697, f1451: Int32 = 11893, f1847: Int32 = 15137, f2172: Int32 = 17799, f2562: Int32 = 20995
    @inline(__always) func deq(_ i: Int) -> Int32 { Int32(coef[offset + i]) &* q[i] }
    @inline(__always) func descale(_ x: Int32, _ n: Int32) -> Int32 { (x &+ (1 << (n - 1))) >> n }
    for col in 0..<8 where col != 4 {   // column 4 is not needed for 4x4 output
        if coef[offset + 8 + col] == 0, coef[offset + 16 + col] == 0, coef[offset + 24 + col] == 0,
           coef[offset + 40 + col] == 0, coef[offset + 48 + col] == 0, coef[offset + 56 + col] == 0 {
            let dc = deq(col) << pass1Bits
            for r in 0..<4 { ws[r * 8 + col] = dc }
            continue
        }
        let even0 = deq(col) << (constBits + 1)
        let even2 = deq(16 + col) &* f1847 &+ deq(48 + col) &* -f0765
        let tmp10 = even0 &+ even2, tmp12 = even0 &- even2
        let z1 = deq(56 + col), z2 = deq(40 + col), z3 = deq(24 + col), z4 = deq(8 + col)
        let tmp0 = z1 &* -f0211 &+ z2 &* f1451 &+ z3 &* -f2172 &+ z4 &* f1061
        let tmp2 = z1 &* -f0509 &+ z2 &* -f0601 &+ z3 &* f0899 &+ z4 &* f2562
        let n = constBits - pass1Bits + 1
        ws[col] = descale(tmp10 &+ tmp2, n); ws[24 + col] = descale(tmp10 &- tmp2, n)
        ws[8 + col] = descale(tmp12 &+ tmp0, n); ws[16 + col] = descale(tmp12 &- tmp0, n)
    }
    for row in 0..<4 {
        let w = row * 8, o = outOffset + row * stride
        if ws[w + 1] == 0, ws[w + 2] == 0, ws[w + 3] == 0, ws[w + 5] == 0, ws[w + 6] == 0, ws[w + 7] == 0 {
            let v = jpegLimit(descale(ws[w], pass1Bits + 3))
            for i in 0..<4 { out[o + i] = v }
            continue
        }
        let even0 = ws[w] << (constBits + 1)
        let even2 = ws[w + 2] &* f1847 &+ ws[w + 6] &* -f0765
        let tmp10 = even0 &+ even2, tmp12 = even0 &- even2
        let z1 = ws[w + 7], z2 = ws[w + 5], z3 = ws[w + 3], z4 = ws[w + 1]
        let tmp0 = z1 &* -f0211 &+ z2 &* f1451 &+ z3 &* -f2172 &+ z4 &* f1061
        let tmp2 = z1 &* -f0509 &+ z2 &* -f0601 &+ z3 &* f0899 &+ z4 &* f2562
        let n = constBits + pass1Bits + 3 + 1
        out[o] = jpegLimit(descale(tmp10 &+ tmp2, n)); out[o + 3] = jpegLimit(descale(tmp10 &- tmp2, n))
        out[o + 1] = jpegLimit(descale(tmp12 &+ tmp0, n)); out[o + 2] = jpegLimit(descale(tmp12 &- tmp0, n))
    }
}

/// libjpeg's 2x2 inverse DCT for output at 1/4 size (jidctred.c).
private func idct2x2(_ coef: UnsafeBufferPointer<Int16>, _ offset: Int, _ q: UnsafeBufferPointer<Int32>,
                     _ ws: UnsafeMutableBufferPointer<Int32>, _ out: UnsafeMutableBufferPointer<UInt8>,
                     _ outOffset: Int, _ stride: Int) {
    let constBits: Int32 = 13, pass1Bits: Int32 = 2
    let f0720: Int32 = 5906, f0850: Int32 = 6967, f1272: Int32 = 10426, f3624: Int32 = 29692
    @inline(__always) func deq(_ i: Int) -> Int32 { Int32(coef[offset + i]) &* q[i] }
    @inline(__always) func descale(_ x: Int32, _ n: Int32) -> Int32 { (x &+ (1 << (n - 1))) >> n }
    for col in [0, 1, 3, 5, 7] {   // columns 2, 4 and 6 are not needed for 2x2 output
        if coef[offset + 8 + col] == 0, coef[offset + 24 + col] == 0, coef[offset + 40 + col] == 0, coef[offset + 56 + col] == 0 {
            let dc = deq(col) << pass1Bits
            ws[col] = dc; ws[8 + col] = dc
            continue
        }
        let tmp10 = deq(col) << (constBits + 2)
        let tmp0 = deq(56 + col) &* -f0720 &+ deq(40 + col) &* f0850 &+ deq(24 + col) &* -f1272 &+ deq(8 + col) &* f3624
        let n = constBits - pass1Bits + 2
        ws[col] = descale(tmp10 &+ tmp0, n); ws[8 + col] = descale(tmp10 &- tmp0, n)
    }
    for row in 0..<2 {
        let w = row * 8, o = outOffset + row * stride
        if ws[w + 1] == 0, ws[w + 3] == 0, ws[w + 5] == 0, ws[w + 7] == 0 {
            let v = jpegLimit(descale(ws[w], pass1Bits + 3))
            out[o] = v; out[o + 1] = v
            continue
        }
        let tmp10 = ws[w] << (constBits + 2)
        let tmp0 = ws[w + 7] &* -f0720 &+ ws[w + 5] &* f0850 &+ ws[w + 3] &* -f1272 &+ ws[w + 1] &* f3624
        let n = constBits + pass1Bits + 3 + 2
        out[o] = jpegLimit(descale(tmp10 &+ tmp0, n)); out[o + 1] = jpegLimit(descale(tmp10 &- tmp0, n))
    }
}

/// libjpeg's 1x1 inverse DCT for output at 1/8 size: the block's mean.
private func idct1x1(_ coef: UnsafeBufferPointer<Int16>, _ offset: Int, _ q: UnsafeBufferPointer<Int32>,
                     _ out: UnsafeMutableBufferPointer<UInt8>, _ outOffset: Int) {
    let dc = Int32(coef[offset]) &* q[0]
    out[outOffset] = jpegLimit((dc &+ 4) >> 3)
}

/// libjpeg's range limit: the low 10 bits, read as signed, plus 128, clamped.
@inline(__always) private func jpegLimit(_ x: Int32) -> UInt8 {
    var v = Int(x) & 1023
    if v >= 512 { v -= 1024 }
    return UInt8(min(max(v + 128, 0), 255))
}

extension Bitmap {
    /// The image turned as an EXIF orientation (1 to 8) says it should be shown.
    public func applyingOrientation(_ orientation: Int) -> Bitmap {
        guard (2...8).contains(orientation) else { return self }
        let swap = orientation >= 5
        let ow = swap ? height : width, oh = swap ? width : height
        var out = [UInt8](repeating: 0, count: pixels.count)
        for y in 0..<oh {
            for x in 0..<ow {
                let (sx, sy): (Int, Int) = switch orientation {
                case 2: (ow - 1 - x, y)
                case 3: (ow - 1 - x, oh - 1 - y)
                case 4: (x, oh - 1 - y)
                case 5: (y, x)
                case 6: (y, ow - 1 - x)
                case 7: (oh - 1 - y, ow - 1 - x)
                default: (oh - 1 - y, x)
                }
                let s = (sy * width + sx) * 4, d = (y * ow + x) * 4
                out[d] = pixels[s]; out[d + 1] = pixels[s + 1]; out[d + 2] = pixels[s + 2]; out[d + 3] = pixels[s + 3]
            }
        }
        return Bitmap(width: ow, height: oh, pixels: out)
    }
}
