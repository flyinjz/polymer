// OpenType fonts: the table directory, metrics, character map, kerning and
// outlines (TrueType `glyf` and CFF). Our own parser; reads are bounds-
// checked so a damaged font draws nothing instead of crashing.
import PolymerBase

public typealias GlyphID = UInt16

public struct FontError: Error, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ m: String) { message = m }
    public var description: String { "font: \(message)" }
}

public final class FontFace: Sendable {
    public let data: [UInt8]
    let tables: [UInt32: (offset: Int, length: Int)]

    public let unitsPerEm: Int
    public let glyphCount: Int
    /// hhea metrics in font units (ascender positive up, descender negative).
    public let ascender: Int
    public let descender: Int
    public let lineGap: Int
    public let xHeight: Int
    public let capHeight: Int
    public let familyName: String

    let indexToLocFormat: Int
    let hmtxCount: Int
    let cmapSubtable: Int   // absolute offset, or -1
    let cmapFormat: Int
    let cff: CFF?
    let kerning: Kerning
    let substitution: Substitution?

    public var hasCFF: Bool { cff != nil }

    public convenience init(data: [UInt8]) throws(FontError) {
        try self.init(data: data, index: 0)
    }

    /// `index` picks a face inside a collection (.ttc/.otc).
    public init(data: [UInt8], index: Int) throws(FontError) {
        self.data = data
        var base = 0
        let tag = data.u32(at: 0)
        if tag == FontFace.tag("ttcf") {
            let n = Int(data.u32(at: 8))
            guard index < n else { throw FontError("collection has \(n) faces; index \(index) is out of range") }
            base = Int(data.u32(at: 12 + 4 * index))
        }
        let version = data.u32(at: base)
        guard version == 0x00010000 || version == FontFace.tag("OTTO") || version == FontFace.tag("true") else {
            throw FontError("not an OpenType or TrueType font (WOFF and WOFF2 are not supported yet)")
        }
        let numTables = Int(data.u16(at: base + 4))
        var t: [UInt32: (Int, Int)] = [:]
        for k in 0..<numTables {
            let r = base + 12 + 16 * k
            let off = Int(data.u32(at: r + 8)), len = Int(data.u32(at: r + 12))
            guard off + len <= data.count else { throw FontError("table directory points past the end of the file") }
            t[data.u32(at: r)] = (off, len)
        }
        tables = t
        guard let head = t[FontFace.tag("head")], let hhea = t[FontFace.tag("hhea")], let maxp = t[FontFace.tag("maxp")],
              t[FontFace.tag("hmtx")] != nil, t[FontFace.tag("cmap")] != nil else {
            throw FontError("missing a required table (head, hhea, maxp, hmtx or cmap)")
        }
        unitsPerEm = Int(data.u16(at: head.0 + 18))
        guard unitsPerEm >= 16 else { throw FontError("unitsPerEm \(unitsPerEm) is invalid") }
        indexToLocFormat = Int(data.i16(at: head.0 + 50))
        glyphCount = Int(data.u16(at: maxp.0 + 4))
        ascender = Int(data.i16(at: hhea.0 + 4))
        descender = Int(data.i16(at: hhea.0 + 6))
        lineGap = Int(data.i16(at: hhea.0 + 8))
        hmtxCount = max(1, Int(data.u16(at: hhea.0 + 34)))
        if let os2 = t[FontFace.tag("OS/2")], data.u16(at: os2.0) >= 2 {
            xHeight = Int(data.i16(at: os2.0 + 86)); capHeight = Int(data.i16(at: os2.0 + 88))
        } else {
            xHeight = 0; capHeight = 0
        }
        (cmapSubtable, cmapFormat) = FontFace.pickCmap(data, t[FontFace.tag("cmap")]!.0)
        if let c = t[FontFace.tag("CFF ")] {
            cff = try CFF(data: data, offset: c.0, length: c.1)
        } else {
            guard t[FontFace.tag("glyf")] != nil, t[FontFace.tag("loca")] != nil else {
                throw FontError("no outlines: neither a glyf nor a CFF table (CFF2 variable fonts are not supported yet)")
            }
            cff = nil
        }
        familyName = FontFace.readName(data, t[FontFace.tag("name")]?.0, id: 1)
        kerning = Kerning(data: data, gpos: t[FontFace.tag("GPOS")]?.0, kern: t[FontFace.tag("kern")]?.0)
        substitution = Substitution(data: data, gsub: t[FontFace.tag("GSUB")]?.0)
    }

    /// Glyphs for a run of characters: the character map, then the font's
    /// default substitutions (ligatures, contextual forms).
    func shape(_ scalars: ArraySlice<Unicode.Scalar>) -> [ShapedGlyph] {
        var glyphs: [ShapedGlyph] = []
        glyphs.reserveCapacity(scalars.count)
        for (k, s) in scalars.enumerated() { glyphs.append(ShapedGlyph(glyph: glyph(for: s), cluster: k)) }
        substitution?.apply(data, &glyphs)
        return glyphs
    }

    @inlinable static func tag(_ s: StaticString) -> UInt32 {
        let p = s.utf8Start
        return UInt32(p[0]) << 24 | UInt32(p[1]) << 16 | UInt32(p[2]) << 8 | UInt32(p[3])
    }

    func table(_ name: StaticString) -> (offset: Int, length: Int)? { tables[FontFace.tag(name)] }

    // MARK: Character map

    static func pickCmap(_ d: [UInt8], _ cmap: Int) -> (Int, Int) {
        let n = Int(d.u16(at: cmap + 2))
        var best = -1, bestScore = -1, bestFormat = 0
        for k in 0..<n {
            let r = cmap + 4 + 8 * k
            let pid = d.u16(at: r), eid = d.u16(at: r + 2)
            let off = cmap + Int(d.u32(at: r + 4))
            let format = Int(d.u16(at: off))
            var score = -1
            if format == 12, (pid == 3 && eid == 10) || pid == 0 { score = 3 }
            else if format == 4, (pid == 3 && eid == 1) || pid == 0 { score = 2 }
            if score > bestScore { best = off; bestScore = score; bestFormat = format }
        }
        return (best, bestFormat)
    }

    /// The glyph for a character, or 0 (.notdef).
    public func glyph(for scalar: Unicode.Scalar) -> GlyphID {
        let c = scalar.value
        let d = data, s = cmapSubtable
        guard s >= 0 else { return 0 }
        if cmapFormat == 4 {
            guard c <= 0xFFFF else { return 0 }
            let segX2 = Int(d.u16(at: s + 6))
            let ends = s + 14, starts = ends + segX2 + 2, deltas = starts + segX2, ranges = deltas + segX2
            // Binary search on end codes.
            var lo = 0, hi = segX2 / 2
            while lo < hi {
                let mid = (lo + hi) / 2
                if UInt32(d.u16(at: ends + mid * 2)) < c { lo = mid + 1 } else { hi = mid }
            }
            guard lo < segX2 / 2 else { return 0 }
            let start = UInt32(d.u16(at: starts + lo * 2))
            guard c >= start else { return 0 }
            let delta = d.u16(at: deltas + lo * 2)
            let ro = Int(d.u16(at: ranges + lo * 2))
            if ro == 0 { return GlyphID(truncatingIfNeeded: UInt16(c) &+ delta) }
            let g = d.u16(at: ranges + lo * 2 + ro + Int(c - start) * 2)
            return g == 0 ? 0 : g &+ delta
        }
        if cmapFormat == 12 {
            let n = Int(d.u32(at: s + 12))
            var lo = 0, hi = n
            while lo < hi {
                let mid = (lo + hi) / 2
                let r = s + 16 + mid * 12
                if d.u32(at: r + 4) < c { lo = mid + 1 } else { hi = mid }
            }
            guard lo < n else { return 0 }
            let r = s + 16 + lo * 12
            let start = d.u32(at: r)
            guard c >= start else { return 0 }
            return GlyphID(truncatingIfNeeded: d.u32(at: r + 8) + (c - start))
        }
        return 0
    }

    // MARK: Metrics

    /// Advance width in font units.
    public func advance(_ g: GlyphID) -> Int {
        guard let h = table("hmtx") else { return 0 }
        let i = min(Int(g), hmtxCount - 1)
        return Int(data.u16(at: h.offset + 4 * i))
    }

    /// Horizontal kerning adjustment between two glyphs, in font units.
    public func kern(_ left: GlyphID, _ right: GlyphID) -> Int {
        kerning.adjustment(data, left, right)
    }

    // MARK: Outlines

    /// The glyph outline in font units, y up.
    public func outline(_ g: GlyphID) -> Path {
        guard Int(g) < glyphCount else { return Path() }
        var path = Path()
        if let cff {
            cff.outline(data, Int(g), into: &path)
        } else {
            glyfOutline(Int(g), transform: .identity, depth: 0, into: &path)
        }
        return path
    }

    func glyphRange(_ g: Int) -> Range<Int>? {
        guard let loca = table("loca"), let glyf = table("glyf") else { return nil }
        let a: Int, b: Int
        if indexToLocFormat == 0 {
            a = Int(data.u16(at: loca.offset + 2 * g)) * 2; b = Int(data.u16(at: loca.offset + 2 * g + 2)) * 2
        } else {
            a = Int(data.u32(at: loca.offset + 4 * g)); b = Int(data.u32(at: loca.offset + 4 * g + 4))
        }
        guard b > a, b <= glyf.length else { return nil }
        return glyf.offset + a..<glyf.offset + b
    }

    func glyfOutline(_ g: Int, transform t: AffineTransform, depth: Int, into path: inout Path) {
        guard depth < 8, let r = glyphRange(g) else { return }
        let d = data
        let contours = Int(d.i16(at: r.lowerBound))
        if contours >= 0 {
            simpleGlyph(r.lowerBound, contours: contours, end: r.upperBound, t, into: &path)
            return
        }
        // Composite glyph.
        var p = r.lowerBound + 10
        while p < r.upperBound {
            let flags = d.u16(at: p), child = Int(d.u16(at: p + 2))
            p += 4
            var dx = 0.0, dy = 0.0
            if flags & 0x0001 != 0 {
                dx = Double(d.i16(at: p)); dy = Double(d.i16(at: p + 2)); p += 4
            } else {
                dx = Double(Int8(bitPattern: d.u8(at: p))); dy = Double(Int8(bitPattern: d.u8(at: p + 1))); p += 2
            }
            var a = 1.0, b = 0.0, c = 0.0, e = 1.0
            func f2dot14(_ o: Int) -> Double { Double(d.i16(at: o)) / 16384 }
            if flags & 0x0008 != 0 { a = f2dot14(p); e = a; p += 2 }
            else if flags & 0x0040 != 0 { a = f2dot14(p); e = f2dot14(p + 2); p += 4 }
            else if flags & 0x0080 != 0 { a = f2dot14(p); b = f2dot14(p + 2); c = f2dot14(p + 4); e = f2dot14(p + 6); p += 8 }
            // ARGS_ARE_XY_VALUES assumed; point matching (rare) is treated as zero offset.
            if flags & 0x0002 == 0 { dx = 0; dy = 0 }
            let local = AffineTransform(a: a, b: b, c: c, d: e, tx: dx, ty: dy)
            glyfOutline(child, transform: local.concatenating(t), depth: depth + 1, into: &path)
            if flags & 0x0020 == 0 { break }
        }
    }

    func simpleGlyph(_ start: Int, contours: Int, end: Int, _ t: AffineTransform, into path: inout Path) {
        let d = data
        guard contours > 0 else { return }
        var endPts: [Int] = []
        endPts.reserveCapacity(contours)
        for k in 0..<contours { endPts.append(Int(d.u16(at: start + 10 + 2 * k))) }
        let n = endPts.last! + 1
        guard n < 65536 else { return }
        let instrLen = Int(d.u16(at: start + 10 + 2 * contours))
        var p = start + 12 + 2 * contours + instrLen
        var flags = [UInt8](repeating: 0, count: n)
        var k = 0
        while k < n, p < end {
            let f = d.u8(at: p); p += 1
            flags[k] = f; k += 1
            if f & 8 != 0 {
                var rep = Int(d.u8(at: p)); p += 1
                while rep > 0, k < n { flags[k] = f; k += 1; rep -= 1 }
            }
        }
        var xs = [Double](repeating: 0, count: n), ys = [Double](repeating: 0, count: n)
        var v = 0
        for i in 0..<n {
            let f = flags[i]
            if f & 2 != 0 { let dx = Int(d.u8(at: p)); p += 1; v += f & 16 != 0 ? dx : -dx }
            else if f & 16 == 0 { v += Int(d.i16(at: p)); p += 2 }
            xs[i] = Double(v)
        }
        v = 0
        for i in 0..<n {
            let f = flags[i]
            if f & 4 != 0 { let dy = Int(d.u8(at: p)); p += 1; v += f & 32 != 0 ? dy : -dy }
            else if f & 32 == 0 { v += Int(d.i16(at: p)); p += 2 }
            ys[i] = Double(v)
        }
        var s = 0
        for e in endPts {
            guard e >= s, e < n else { break }
            let count = e - s + 1
            func pt(_ i: Int) -> Point { t.apply(Point(x: xs[s + i], y: ys[s + i])) }
            func on(_ i: Int) -> Bool { flags[s + i] & 1 != 0 }
            // Start from an on-curve point (or the midpoint of two off-curve points).
            var first = 0
            while first < count, !on(first) { first += 1 }
            let startPt: Point
            if first == count {
                startPt = (pt(0) + pt(1 % count)) * 0.5; first = 0
                path.move(to: startPt)
                for i in 0..<count {
                    let c = pt(i), next = pt((i + 1) % count)
                    path.quad(to: (c + next) * 0.5, control: c)
                }
                path.close(); s = e + 1; continue
            }
            startPt = pt(first)
            path.move(to: startPt)
            var control: Point? = nil
            for j in 1...count {
                let i = (first + j) % count
                let q = pt(i)
                if on(i) {
                    if let c = control { path.quad(to: q, control: c); control = nil } else { path.line(to: q) }
                } else {
                    if let c = control { path.quad(to: (c + q) * 0.5, control: c) }
                    control = q
                }
            }
            path.close()
            s = e + 1
        }
    }

    // MARK: Names

    static func readName(_ d: [UInt8], _ name: Int?, id: UInt16) -> String {
        guard let name else { return "" }
        let n = Int(d.u16(at: name + 2)), strings = name + Int(d.u16(at: name + 4))
        var fallback = ""
        for k in 0..<n {
            let r = name + 6 + 12 * k
            guard d.u16(at: r + 6) == id else { continue }
            let pid = d.u16(at: r), len = Int(d.u16(at: r + 8)), off = strings + Int(d.u16(at: r + 10))
            guard off + len <= d.count else { continue }
            if pid == 3 || pid == 0 {
                var units: [UInt16] = []
                for i in stride(from: 0, to: len - 1, by: 2) { units.append(d.u16(at: off + i)) }
                return String(decoding: units, as: UTF16.self)
            }
            if pid == 1 { fallback = String(decoding: d[off..<off + len], as: UTF8.self) }
        }
        return fallback
    }
}
