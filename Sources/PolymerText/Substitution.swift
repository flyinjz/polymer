// Glyph substitution (GSUB): ligatures and contextual forms, the features
// text renderers apply by default. Covers single, multiple, ligature,
// context and chaining-context lookups, through extension lookups too.
//
// Not yet: lookup flags that skip marks (needs GDEF), alternates, reverse
// chaining, language-specific forms. Complex scripts go through HarfBuzz
// later (Docs/DESIGN.md D5).
import PolymerBase

/// A glyph with the index of the character it came from.
struct ShapedGlyph {
    var glyph: GlyphID
    var cluster: Int
}

enum OpenTypeLayout {
    /// Lookup tables (absolute offsets) used by `features` in the default
    /// language system of 'DFLT', else 'latn', else the first script, in
    /// lookup-list order, each once.
    static func lookups(_ d: [UInt8], table g: Int, features wanted: [UInt32]) -> [Int] {
        let scripts = g + Int(d.u16(at: g + 4)), features = g + Int(d.u16(at: g + 6)), lookupList = g + Int(d.u16(at: g + 8))
        var langSys = -1
        let nScripts = Int(d.u16(at: scripts))
        var pick = -1
        for k in 0..<nScripts {
            let tag = d.u32(at: scripts + 2 + 6 * k)
            if tag == FontFace.tag("DFLT") { pick = k; break }
            if tag == FontFace.tag("latn") { pick = k }
        }
        if pick < 0, nScripts > 0 { pick = 0 }
        if pick >= 0 {
            let script = scripts + Int(d.u16(at: scripts + 2 + 6 * pick + 4))
            let def = Int(d.u16(at: script))
            if def != 0 { langSys = script + def }
        }
        guard langSys >= 0 else { return [] }
        var indices = Set<Int>()
        let n = Int(d.u16(at: langSys + 4))
        for k in 0..<n {
            let fi = Int(d.u16(at: langSys + 6 + 2 * k))
            let rec = features + 2 + 6 * fi
            guard wanted.contains(d.u32(at: rec)) else { continue }
            let feature = features + Int(d.u16(at: rec + 4))
            let count = Int(d.u16(at: feature + 2))
            for j in 0..<count { indices.insert(Int(d.u16(at: feature + 4 + 2 * j))) }
        }
        let lookupCount = Int(d.u16(at: lookupList))
        return indices.sorted().compactMap { $0 < lookupCount ? lookupList + Int(d.u16(at: lookupList + 2 + 2 * $0)) : nil }
    }
}

struct Substitution: Sendable {
    /// Lookups of the default features, in the order they apply.
    let lookups: [Int]
    let lookupList: Int
    let lookupCount: Int

    /// Features on by default for horizontal text, as in CoreText and HarfBuzz.
    static let defaultFeatures: [UInt32] = [
        FontFace.tag("ccmp"), FontFace.tag("locl"), FontFace.tag("rlig"), FontFace.tag("liga"),
        FontFace.tag("clig"), FontFace.tag("calt"), FontFace.tag("rclt"),
    ]

    init?(data d: [UInt8], gsub g: Int?) {
        guard let g else { return nil }
        lookups = OpenTypeLayout.lookups(d, table: g, features: Substitution.defaultFeatures)
        if lookups.isEmpty { return nil }
        lookupList = g + Int(d.u16(at: g + 8))
        lookupCount = Int(d.u16(at: lookupList))
    }

    func apply(_ d: [UInt8], _ g: inout [ShapedGlyph]) {
        for lookup in lookups {
            var i = 0
            while i < g.count {
                // A match moves past what it produced; a deletion stays in place.
                if let advance = applyLookup(d, lookup, &g, i, depth: 0) { i += advance } else { i += 1 }
            }
        }
    }

    /// Tries the lookup at position `i`. Returns the number of glyphs to move past, or nil when nothing matched.
    func applyLookup(_ d: [UInt8], _ lookup: Int, _ g: inout [ShapedGlyph], _ i: Int, depth: Int) -> Int? {
        guard depth < 6, i < g.count else { return nil }
        let type = d.u16(at: lookup), n = Int(d.u16(at: lookup + 4))
        for k in 0..<n {
            var sub = lookup + Int(d.u16(at: lookup + 6 + 2 * k))
            var t = type
            if t == 7 { t = d.u16(at: sub + 2); sub += Int(d.u32(at: sub + 4)) }
            let r: Int? = switch t {
            case 1: single(d, sub, &g, i)
            case 2: multiple(d, sub, &g, i)
            case 4: ligature(d, sub, &g, i)
            case 5, 6: context(d, sub, chaining: t == 6, &g, i, depth: depth)
            default: nil
            }
            if let r { return r }
        }
        return nil
    }

    func single(_ d: [UInt8], _ s: Int, _ g: inout [ShapedGlyph], _ i: Int) -> Int? {
        guard let ci = Kerning.coverage(d, s + Int(d.u16(at: s + 2)), g[i].glyph) else { return nil }
        switch d.u16(at: s) {
        case 1: g[i].glyph = g[i].glyph &+ d.u16(at: s + 4)
        case 2:
            guard ci < Int(d.u16(at: s + 4)) else { return nil }
            g[i].glyph = d.u16(at: s + 6 + 2 * ci)
        default: return nil
        }
        return 1
    }

    func multiple(_ d: [UInt8], _ s: Int, _ g: inout [ShapedGlyph], _ i: Int) -> Int? {
        guard d.u16(at: s) == 1, let ci = Kerning.coverage(d, s + Int(d.u16(at: s + 2)), g[i].glyph),
              ci < Int(d.u16(at: s + 4)) else { return nil }
        let seq = s + Int(d.u16(at: s + 6 + 2 * ci))
        let n = Int(d.u16(at: seq))
        let cluster = g[i].cluster
        g.replaceSubrange(i...i, with: (0..<n).map { ShapedGlyph(glyph: d.u16(at: seq + 2 + 2 * $0), cluster: cluster) })
        return n
    }

    func ligature(_ d: [UInt8], _ s: Int, _ g: inout [ShapedGlyph], _ i: Int) -> Int? {
        guard d.u16(at: s) == 1, let ci = Kerning.coverage(d, s + Int(d.u16(at: s + 2)), g[i].glyph),
              ci < Int(d.u16(at: s + 4)) else { return nil }
        let set = s + Int(d.u16(at: s + 6 + 2 * ci))
        let n = Int(d.u16(at: set))
        next: for j in 0..<n {
            let l = set + Int(d.u16(at: set + 2 + 2 * j))
            let count = Int(d.u16(at: l + 2))
            guard count >= 1, i + count <= g.count else { continue }
            for m in 1..<count where g[i + m].glyph != d.u16(at: l + 4 + 2 * (m - 1)) { continue next }
            g[i].glyph = d.u16(at: l)
            g.removeSubrange((i + 1)..<(i + count))
            return 1
        }
        return nil
    }

    /// Context (type 5) and chaining context (type 6) substitution, formats 1 to 3.
    func context(_ d: [UInt8], _ s: Int, chaining: Bool, _ g: inout [ShapedGlyph], _ i: Int, depth: Int) -> Int? {
        let format = d.u16(at: s)
        if format == 3 {
            // One rule, each position described by a coverage table.
            var p = s + 2
            var backCount = 0, back = 0
            if chaining { backCount = Int(d.u16(at: p)); back = p + 2; p += 2 + 2 * backCount }
            let inputCount = Int(d.u16(at: p))
            var substCount = 0
            if !chaining { substCount = Int(d.u16(at: p + 2)); p += 2 }
            let input = p + 2
            p += 2 + 2 * inputCount
            var aheadCount = 0, ahead = 0
            if chaining {
                aheadCount = Int(d.u16(at: p)); ahead = p + 2; p += 2 + 2 * aheadCount
                substCount = Int(d.u16(at: p)); p += 2
            }
            guard inputCount >= 1, i + inputCount + aheadCount <= g.count, i >= backCount else { return nil }
            func covers(_ table: Int, _ k: Int, _ glyph: GlyphID) -> Bool {
                Kerning.coverage(d, s + Int(d.u16(at: table + 2 * k)), glyph) != nil
            }
            for k in 0..<inputCount where !covers(input, k, g[i + k].glyph) { return nil }
            for k in 0..<backCount where !covers(back, k, g[i - 1 - k].glyph) { return nil }
            for k in 0..<aheadCount where !covers(ahead, k, g[i + inputCount + k].glyph) { return nil }
            return substitute(d, records: p, count: substCount, inputCount: inputCount, &g, i, depth: depth)
        }
        guard format == 1 || format == 2 else { return nil }
        // Rule sets chosen by the first glyph (format 1) or its class (format 2).
        guard let ci = Kerning.coverage(d, s + Int(d.u16(at: s + 2)), g[i].glyph) else { return nil }
        var backClasses = 0, inputClasses = 0, aheadClasses = 0
        let setCount: Int, sets: Int, setIndex: Int
        if format == 1 {
            setCount = Int(d.u16(at: s + 4)); sets = s + 6; setIndex = ci
        } else if chaining {
            backClasses = s + Int(d.u16(at: s + 4)); inputClasses = s + Int(d.u16(at: s + 6)); aheadClasses = s + Int(d.u16(at: s + 8))
            setCount = Int(d.u16(at: s + 10)); sets = s + 12
            setIndex = Kerning.classOf(d, inputClasses, g[i].glyph)
        } else {
            inputClasses = s + Int(d.u16(at: s + 4))
            setCount = Int(d.u16(at: s + 6)); sets = s + 8
            setIndex = Kerning.classOf(d, inputClasses, g[i].glyph)
        }
        guard setIndex < setCount else { return nil }
        let setOffset = Int(d.u16(at: sets + 2 * setIndex))
        guard setOffset != 0 else { return nil }
        let set = s + setOffset
        func matches(_ classes: Int, _ value: UInt16, _ glyph: GlyphID) -> Bool {
            format == 1 ? glyph == value : Kerning.classOf(d, classes, glyph) == Int(value)
        }
        let ruleCount = Int(d.u16(at: set))
        next: for r in 0..<ruleCount {
            var p = set + Int(d.u16(at: set + 2 + 2 * r))
            var backCount = 0, back = 0, aheadCount = 0, ahead = 0, substCount = 0
            if chaining { backCount = Int(d.u16(at: p)); back = p + 2; p += 2 + 2 * backCount }
            let inputCount = Int(d.u16(at: p))
            if !chaining { substCount = Int(d.u16(at: p + 2)); p += 2 }
            let input = p + 2   // values for positions 1..<inputCount
            p += 2 + 2 * max(0, inputCount - 1)
            if chaining {
                aheadCount = Int(d.u16(at: p)); ahead = p + 2; p += 2 + 2 * aheadCount
                substCount = Int(d.u16(at: p)); p += 2
            }
            guard inputCount >= 1, i + inputCount + aheadCount <= g.count, i >= backCount else { continue }
            for k in 1..<max(1, inputCount) where !matches(inputClasses, d.u16(at: input + 2 * (k - 1)), g[i + k].glyph) { continue next }
            for k in 0..<backCount where !matches(backClasses, d.u16(at: back + 2 * k), g[i - 1 - k].glyph) { continue next }
            for k in 0..<aheadCount where !matches(aheadClasses, d.u16(at: ahead + 2 * k), g[i + inputCount + k].glyph) { continue next }
            return substitute(d, records: p, count: substCount, inputCount: inputCount, &g, i, depth: depth)
        }
        return nil
    }

    /// Applies a matched rule's nested lookups; returns how far to move past the matched input.
    func substitute(_ d: [UInt8], records: Int, count: Int, inputCount: Int, _ g: inout [ShapedGlyph], _ i: Int, depth: Int) -> Int {
        let before = g.count
        for k in 0..<count {
            let at = i + Int(d.u16(at: records + 4 * k))
            let index = Int(d.u16(at: records + 4 * k + 2))
            guard index < lookupCount else { continue }
            _ = applyLookup(d, lookupList + Int(d.u16(at: lookupList + 2 + 2 * index)), &g, at, depth: depth + 1)
        }
        return max(1, inputCount + g.count - before)
    }
}
