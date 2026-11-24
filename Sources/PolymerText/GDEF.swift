// OpenType Glyph Definition (GDEF) table: glyph classes (base, ligature, mark,
// component), mark attachment classes, mark glyph sets and lookup flag filtering.
import PolymerBase

/// Parsed OpenType `GDEF` table (versions 1.0, 1.2, and 1.3).
public struct GDEFTable: Equatable, Sendable {
    /// OpenType GDEF glyph class values.
    public enum GlyphClass: UInt16, Equatable, Hashable, Sendable {
        case unclassified = 0
        case base = 1
        case ligature = 2
        case mark = 3
        case component = 4
    }

    /// Standard OpenType GSUB/GPOS lookup flag bitmasks.
    public enum LookupFlag {
        public static let rightToLeft: UInt16 = 0x0001
        public static let ignoreBaseGlyphs: UInt16 = 0x0002
        public static let ignoreLigatures: UInt16 = 0x0004
        public static let ignoreMarks: UInt16 = 0x0008
        public static let useMarkFilteringSet: UInt16 = 0x0010
        public static let markAttachmentTypeMask: UInt16 = 0xFF00
    }

    enum ClassDef: Equatable, Sendable {
        case empty
        case format1(startGlyph: UInt16, values: [UInt16])
        case format2(ranges: [ClassRange])
        case explicit([UInt16: UInt16])

        struct ClassRange: Equatable, Sendable {
            let start: UInt16
            let end: UInt16
            let value: UInt16
        }

        func value(for glyph: UInt16) -> UInt16 {
            switch self {
            case .empty:
                return 0
            case .format1(let start, let values):
                guard glyph >= start else { return 0 }
                let idx = Int(glyph - start)
                return idx < values.count ? values[idx] : 0
            case .format2(let ranges):
                var lo = 0, hi = ranges.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    let r = ranges[mid]
                    if glyph < r.start {
                        hi = mid
                    } else if glyph > r.end {
                        lo = mid + 1
                    } else {
                        return r.value
                    }
                }
                return 0
            case .explicit(let map):
                return map[glyph] ?? 0
            }
        }

        static func parse(_ data: [UInt8], at offset: Int, limit: Int) -> ClassDef {
            guard offset >= 0, offset + 4 <= limit else { return .empty }
            let format = data.u16(at: offset)
            if format == 1 {
                guard offset + 6 <= limit else { return .empty }
                let startGlyph = data.u16(at: offset + 2)
                let count = Int(data.u16(at: offset + 4))
                let available = max(0, (limit - (offset + 6)) / 2)
                let n = min(count, available)
                var values: [UInt16] = []
                values.reserveCapacity(n)
                for i in 0..<n {
                    values.append(data.u16(at: offset + 6 + 2 * i))
                }
                return .format1(startGlyph: startGlyph, values: values)
            }
            if format == 2 {
                let count = Int(data.u16(at: offset + 2))
                let available = max(0, (limit - (offset + 4)) / 6)
                let n = min(count, available)
                var ranges: [ClassRange] = []
                ranges.reserveCapacity(n)
                for i in 0..<n {
                    let r = offset + 4 + 6 * i
                    let s = data.u16(at: r)
                    let e = data.u16(at: r + 2)
                    let v = data.u16(at: r + 4)
                    ranges.append(ClassRange(start: s, end: e, value: v))
                }
                return .format2(ranges: ranges)
            }
            return .empty
        }
    }

    enum CoverageSet: Equatable, Sendable {
        case empty
        case format1(glyphs: [UInt16])
        case format2(ranges: [CoverageRange])
        case explicit(Set<UInt16>)

        struct CoverageRange: Equatable, Sendable {
            let start: UInt16
            let end: UInt16
        }

        func contains(_ glyph: UInt16) -> Bool {
            switch self {
            case .empty:
                return false
            case .format1(let glyphs):
                var lo = 0, hi = glyphs.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    let v = glyphs[mid]
                    if v == glyph { return true }
                    if v < glyph { lo = mid + 1 } else { hi = mid }
                }
                return false
            case .format2(let ranges):
                var lo = 0, hi = ranges.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    let r = ranges[mid]
                    if glyph < r.start {
                        hi = mid
                    } else if glyph > r.end {
                        lo = mid + 1
                    } else {
                        return true
                    }
                }
                return false
            case .explicit(let set):
                return set.contains(glyph)
            }
        }

        static func parse(_ data: [UInt8], at offset: Int, limit: Int) -> CoverageSet {
            guard offset >= 0, offset + 4 <= limit else { return .empty }
            let format = data.u16(at: offset)
            let count = Int(data.u16(at: offset + 2))
            if format == 1 {
                let available = max(0, (limit - (offset + 4)) / 2)
                let n = min(count, available)
                var glyphs: [UInt16] = []
                glyphs.reserveCapacity(n)
                for i in 0..<n {
                    glyphs.append(data.u16(at: offset + 4 + 2 * i))
                }
                return .format1(glyphs: glyphs)
            }
            if format == 2 {
                let available = max(0, (limit - (offset + 4)) / 6)
                let n = min(count, available)
                var ranges: [CoverageRange] = []
                ranges.reserveCapacity(n)
                for i in 0..<n {
                    let r = offset + 4 + 6 * i
                    ranges.append(CoverageRange(start: data.u16(at: r), end: data.u16(at: r + 2)))
                }
                return .format2(ranges: ranges)
            }
            return .empty
        }
    }

    public let majorVersion: UInt16
    public let minorVersion: UInt16
    let glyphClassDef: ClassDef
    let markAttachClassDef: ClassDef
    let markGlyphSets: [CoverageSet]

    /// Number of mark glyph sets defined in `MarkGlyphSetsDef` (GDEF 1.2+).
    public var markGlyphSetCount: Int { markGlyphSets.count }

    /// Parses a binary OpenType `GDEF` table starting at `offset`.
    public init?(data: [UInt8], offset: Int = 0, length: Int? = nil) {
        let limit = min(data.count, length.map { offset + $0 } ?? data.count)
        guard offset >= 0, offset + 12 <= limit else { return nil }
        let major = data.u16(at: offset)
        let minor = data.u16(at: offset + 2)
        guard major == 1, minor == 0 || minor == 2 || minor == 3 else { return nil }

        let glyphClassOffset = Int(data.u16(at: offset + 4))
        let markAttachOffset = Int(data.u16(at: offset + 10))
        let markGlyphSetsOffset: Int
        if minor >= 2, offset + 14 <= limit {
            markGlyphSetsOffset = Int(data.u16(at: offset + 12))
        } else {
            markGlyphSetsOffset = 0
        }

        self.majorVersion = major
        self.minorVersion = minor
        self.glyphClassDef = glyphClassOffset != 0
            ? ClassDef.parse(data, at: offset + glyphClassOffset, limit: limit)
            : .empty
        self.markAttachClassDef = markAttachOffset != 0
            ? ClassDef.parse(data, at: offset + markAttachOffset, limit: limit)
            : .empty

        var sets: [CoverageSet] = []
        if markGlyphSetsOffset != 0 {
            let mgs = offset + markGlyphSetsOffset
            if mgs + 4 <= limit, data.u16(at: mgs) == 1 {
                let count = Int(data.u16(at: mgs + 2))
                let available = max(0, (limit - (mgs + 4)) / 4)
                let n = min(count, available)
                sets.reserveCapacity(n)
                for i in 0..<n {
                    let covRel = Int(data.u32(at: mgs + 4 + 4 * i))
                    if covRel != 0, mgs + covRel < limit {
                        sets.append(CoverageSet.parse(data, at: mgs + covRel, limit: limit))
                    } else {
                        sets.append(.empty)
                    }
                }
            }
        }
        self.markGlyphSets = sets
    }

    /// Creates a synthetic `GDEFTable` directly from maps and mark sets (useful for tests).
    public init(
        glyphClasses: [UInt16: GlyphClass] = [:],
        markAttachmentClasses: [UInt16: UInt16] = [:],
        markGlyphSets: [Set<UInt16>] = []
    ) {
        self.majorVersion = 1
        self.minorVersion = markGlyphSets.isEmpty ? 0 : 2
        if glyphClasses.isEmpty {
            self.glyphClassDef = .empty
        } else {
            var raw: [UInt16: UInt16] = [:]
            raw.reserveCapacity(glyphClasses.count)
            for (g, c) in glyphClasses { raw[g] = c.rawValue }
            self.glyphClassDef = .explicit(raw)
        }
        self.markAttachClassDef = markAttachmentClasses.isEmpty ? .empty : .explicit(markAttachmentClasses)
        self.markGlyphSets = markGlyphSets.map { .explicit($0) }
    }

    /// Returns the GDEF glyph class for `glyph` (`.unclassified` if not listed).
    public func glyphClass(for glyph: UInt16) -> GlyphClass {
        GlyphClass(rawValue: glyphClassDef.value(for: glyph)) ?? .unclassified
    }

    /// Returns the mark attachment class for `glyph` (0 if not listed).
    public func markAttachmentClass(for glyph: UInt16) -> UInt16 {
        markAttachClassDef.value(for: glyph)
    }

    /// Returns `true` when `glyph` belongs to the `setIndex`-th mark glyph set.
    public func isInMarkGlyphSet(_ glyph: UInt16, setIndex: Int) -> Bool {
        guard setIndex >= 0, setIndex < markGlyphSets.count else { return false }
        return markGlyphSets[setIndex].contains(glyph)
    }

    /// Evaluates OpenType lookup-flag filtering rules for `glyph`.
    /// Returns `true` when the lookup must skip `glyph`.
    public func shouldSkip(glyph: UInt16, lookupFlag: UInt16, markFilteringSet: UInt16? = nil) -> Bool {
        guard lookupFlag != 0 else { return false }
        let cls = glyphClass(for: glyph)
        if lookupFlag & LookupFlag.ignoreBaseGlyphs != 0, cls == .base { return true }
        if lookupFlag & LookupFlag.ignoreLigatures != 0, cls == .ligature { return true }
        if lookupFlag & LookupFlag.ignoreMarks != 0, cls == .mark { return true }

        if cls == .mark {
            let attachType = (lookupFlag & LookupFlag.markAttachmentTypeMask) >> 8
            if attachType != 0, markAttachmentClass(for: glyph) != attachType {
                return true
            }
            if lookupFlag & LookupFlag.useMarkFilteringSet != 0, let setIdx = markFilteringSet {
                if !isInMarkGlyphSet(glyph, setIndex: Int(setIdx)) {
                    return true
                }
            }
        }
        return false
    }
}

extension FontFace {
    /// Parsed OpenType `GDEF` table from this font face, if present.
    public var gdef: GDEFTable? {
        guard let t = table("GDEF") else { return nil }
        return GDEFTable(data: data, offset: t.offset, length: t.length)
    }
}
