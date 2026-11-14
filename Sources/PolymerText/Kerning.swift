// Pair kerning: GPOS 'kern' feature (pair adjustment, lookup type 2, also
// through extension lookups), falling back to the legacy 'kern' table.
import PolymerBase

struct Kerning: Sendable {
    /// Absolute offsets of PairPos subtables, in lookup order, grouped per lookup.
    let lookups: [[Int]]
    /// Legacy kern format 0 subtable: (pairs offset, count), or nil.
    let legacy: (offset: Int, count: Int)?

    init(data d: [UInt8], gpos: Int?, kern: Int?) {
        var lookups: [[Int]] = []
        if let g = gpos {
            // Each lookup once, even when the feature lists it twice (Inter does).
            for lookup in OpenTypeLayout.lookups(d, table: g, features: [FontFace.tag("kern")]) {
                let type = d.u16(at: lookup)
                let n = Int(d.u16(at: lookup + 4))
                var subs: [Int] = []
                for k in 0..<n {
                    var sub = lookup + Int(d.u16(at: lookup + 6 + 2 * k))
                    var t = type
                    if t == 9 { t = d.u16(at: sub + 2); sub += Int(d.u32(at: sub + 4)) }
                    if t == 2 { subs.append(sub) }
                }
                if !subs.isEmpty { lookups.append(subs) }
            }
        }
        self.lookups = lookups
        if lookups.isEmpty, let k = kern, d.u16(at: k) == 0, d.u16(at: k + 2) > 0 {
            let sub = k + 4
            if d.u16(at: sub + 4) & 0xFF00 == 0, d.u16(at: sub + 4) & 1 == 1 {   // format 0, horizontal
                legacy = (sub + 14, Int(d.u16(at: sub + 6)))
            } else { legacy = nil }
        } else { legacy = nil }
    }

    func adjustment(_ d: [UInt8], _ left: GlyphID, _ right: GlyphID) -> Int {
        if !lookups.isEmpty {
            var total = 0
            for subs in lookups {
                for sub in subs {
                    if let v = Kerning.pairPos(d, sub, left, right) { total += v; break }
                }
            }
            return total
        }
        if let l = legacy {
            let key = UInt32(left) << 16 | UInt32(right)
            var lo = 0, hi = l.count
            while lo < hi {
                let mid = (lo + hi) / 2
                let k = d.u32(at: l.offset + mid * 6)
                if k == key { return Int(d.i16(at: l.offset + mid * 6 + 4)) }
                if k < key { lo = mid + 1 } else { hi = mid }
            }
        }
        return 0
    }

    static func valueSize(_ format: UInt16) -> Int { format.nonzeroBitCount * 2 }

    /// X advance of the first value record (XPlacement is folded in as well).
    static func xAdvance(_ d: [UInt8], _ at: Int, _ format: UInt16) -> Int {
        var p = at, v = 0
        if format & 1 != 0 { v += Int(d.i16(at: p)); p += 2 }    // XPlacement
        if format & 2 != 0 { p += 2 }                            // YPlacement
        if format & 4 != 0 { v += Int(d.i16(at: p)) }           // XAdvance
        return v
    }

    static func coverage(_ d: [UInt8], _ c: Int, _ g: GlyphID) -> Int? {
        let format = d.u16(at: c), n = Int(d.u16(at: c + 2))
        var lo = 0, hi = n
        if format == 1 {
            while lo < hi {
                let mid = (lo + hi) / 2, v = d.u16(at: c + 4 + 2 * mid)
                if v == g { return mid }
                if v < g { lo = mid + 1 } else { hi = mid }
            }
        } else if format == 2 {
            while lo < hi {
                let mid = (lo + hi) / 2, r = c + 4 + 6 * mid
                if g < d.u16(at: r) { hi = mid } else if g > d.u16(at: r + 2) { lo = mid + 1 }
                else { return Int(d.u16(at: r + 4)) + Int(g - d.u16(at: r)) }
            }
        }
        return nil
    }

    static func classOf(_ d: [UInt8], _ c: Int, _ g: GlyphID) -> Int {
        let format = d.u16(at: c)
        if format == 1 {
            let start = d.u16(at: c + 2), n = Int(d.u16(at: c + 4))
            guard g >= start, Int(g - start) < n else { return 0 }
            return Int(d.u16(at: c + 6 + 2 * Int(g - start)))
        }
        if format == 2 {
            var lo = 0, hi = Int(d.u16(at: c + 2))
            while lo < hi {
                let mid = (lo + hi) / 2, r = c + 4 + 6 * mid
                if g < d.u16(at: r) { hi = mid } else if g > d.u16(at: r + 2) { lo = mid + 1 }
                else { return Int(d.u16(at: r + 4)) }
            }
        }
        return 0
    }

    static func pairPos(_ d: [UInt8], _ s: Int, _ left: GlyphID, _ right: GlyphID) -> Int? {
        let format = d.u16(at: s)
        guard let ci = coverage(d, s + Int(d.u16(at: s + 2)), left) else { return nil }
        let vf1 = d.u16(at: s + 4), vf2 = d.u16(at: s + 6)
        let size1 = valueSize(vf1), size2 = valueSize(vf2)
        if format == 1 {
            let set = s + Int(d.u16(at: s + 10 + 2 * ci))
            let n = Int(d.u16(at: set))
            let rec = 2 + size1 + size2
            var lo = 0, hi = n
            while lo < hi {
                let mid = (lo + hi) / 2, r = set + 2 + rec * mid
                let g = d.u16(at: r)
                if g == right { return xAdvance(d, r + 2, vf1) }
                if g < right { lo = mid + 1 } else { hi = mid }
            }
            return nil
        }
        if format == 2 {
            let c1 = classOf(d, s + Int(d.u16(at: s + 8)), left)
            let c2 = classOf(d, s + Int(d.u16(at: s + 10)), right)
            let n1 = Int(d.u16(at: s + 12)), n2 = Int(d.u16(at: s + 14))
            guard c1 < n1, c2 < n2 else { return nil }
            let r = s + 16 + (c1 * n2 + c2) * (size1 + size2)
            return xAdvance(d, r, vf1)
        }
        return nil
    }
}
