import PolymerBase
import PolymerText

// MARK: - Synthetic OpenType binary builders (for headless unit checks)

private enum SyntheticOpenType {
    static func tag(_ s: String) -> UInt32 {
        let b = Array(s.utf8)
        return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }

    static func fixed16_16(_ v: Double) -> UInt32 {
        UInt32(bitPattern: Int32((v * 65536.0).rounded()))
    }

    static func f2dot14(_ v: Double) -> UInt16 {
        UInt16(bitPattern: Int16((v * 16384.0).rounded()))
    }

    /// Builds a minimal GDEF v1.2 binary table with Format-1 GlyphClassDef,
    /// Format-2 MarkAttachClassDef, and Format-1 MarkGlyphSetsDef.
    static func buildGDEF() -> [UInt8] {
        // Header (v1.2): 14 bytes
        // GlyphClassDef (Format 1) at 14: startGlyph=10, count=5 -> [1(base), 1(base), 2(lig), 3(mark), 3(mark)] (16 bytes -> ends at 30)
        // MarkAttachClassDef (Format 2) at 30: 2 ranges -> (13..13: class 1), (14..14: class 2) (16 bytes -> ends at 46)
        // MarkGlyphSetsDef (Format 1) at 46: 1 set, coverageOffset=8 -> Coverage Format 1 at 54 containing [13] (6 bytes -> ends at 60)
        var out: [UInt8] = []
        // Header
        out.append(u16: 1)    // majorVersion
        out.append(u16: 2)    // minorVersion
        out.append(u16: 14)   // glyphClassDefOffset
        out.append(u16: 0)    // attachListOffset
        out.append(u16: 0)    // ligCaretListOffset
        out.append(u16: 30)   // markAttachClassDefOffset
        out.append(u16: 46)   // markGlyphSetsDefOffset

        // GlyphClassDef Format 1 at offset 14
        out.append(u16: 1)    // classFormat = 1
        out.append(u16: 10)   // startGlyphID = 10
        out.append(u16: 5)    // glyphCount = 5
        out.append(u16: 1)    // glyph 10 -> base
        out.append(u16: 1)    // glyph 11 -> base
        out.append(u16: 2)    // glyph 12 -> ligature
        out.append(u16: 3)    // glyph 13 -> mark
        out.append(u16: 3)    // glyph 14 -> mark

        // MarkAttachClassDef Format 2 at offset 30
        out.append(u16: 2)    // classFormat = 2
        out.append(u16: 2)    // classRangeCount = 2
        out.append(u16: 13); out.append(u16: 13); out.append(u16: 1)
        out.append(u16: 14); out.append(u16: 14); out.append(u16: 2)

        // MarkGlyphSetsDef Format 1 at offset 46
        out.append(u16: 1)    // format = 1
        out.append(u16: 1)    // markGlyphSetCount = 1
        out.append(u32: 8)    // coverageOffset[0] relative to 46 -> 54
        // Coverage Format 1 at offset 54: glyph 13
        out.append(u16: 1)    // coverageFormat = 1
        out.append(u16: 1)    // glyphCount = 1
        out.append(u16: 13)   // glyphArray[0] = 13
        return out
    }

    /// Builds a minimal GSUB table with a single 'liga' feature containing one
    /// LigatureSubst lookup: `first + second -> ligature` with the specified `lookupFlag`
    /// and optional `markFilteringSet`.
    static func buildLigatureGSUB(
        first: GlyphID, second: GlyphID, ligature: GlyphID,
        lookupFlag: UInt16, markFilteringSet: UInt16? = nil
    ) -> [UInt8] {
        // Layout:
        //  0: GSUB header (10 bytes): major=1, minor=0, scriptList=10, featureList=30, lookupList=44
        // 10: ScriptList (20 bytes): 1 script 'DFLT' -> ScriptTable at +8 (18) -> DefaultLangSys at +4 (22) -> 1 feature [0]
        // 30: FeatureList (14 bytes): 1 feature 'liga' -> FeatureTable at +8 (38) -> 1 lookup [0]
        // 44: LookupList: 1 lookup at +4 (48)
        var out: [UInt8] = []
        // GSUB header (10 bytes)
        out.append(u16: 1); out.append(u16: 0)
        out.append(u16: 10); out.append(u16: 30); out.append(u16: 44)

        // ScriptList at 10 (20 bytes)
        out.append(u16: 1)             // scriptCount = 1
        out.append(u32: tag("DFLT"))   // scriptTag
        out.append(u16: 8)             // scriptOffset -> 18
        // ScriptTable at 18 (4 bytes)
        out.append(u16: 4)             // defaultLangSysOffset -> 22
        out.append(u16: 0)             // langSysCount = 0
        // LangSysTable at 22 (8 bytes)
        out.append(u16: 0)             // lookupOrderOffset
        out.append(u16: 0xFFFF)        // requiredFeatureIndex = none
        out.append(u16: 1)             // featureIndexCount = 1
        out.append(u16: 0)             // featureIndices[0] = 0

        // FeatureList at 30 (14 bytes)
        out.append(u16: 1)             // featureCount = 1
        out.append(u32: tag("liga"))   // featureTag
        out.append(u16: 8)             // featureOffset -> 38
        // FeatureTable at 38 (6 bytes)
        out.append(u16: 0)             // featureParamsOffset
        out.append(u16: 1)             // lookupIndexCount = 1
        out.append(u16: 0)             // lookupListIndices[0] = 0

        // LookupList at 44
        out.append(u16: 1)             // lookupCount = 1
        out.append(u16: 4)             // lookupOffsets[0] -> 48

        // LookupTable at 48
        let hasMarkSet = (lookupFlag & GDEFTable.LookupFlag.useMarkFilteringSet != 0)
        let subtableRel: UInt16 = hasMarkSet ? 10 : 8
        out.append(u16: 4)             // lookupType = 4 (Ligature)
        out.append(u16: lookupFlag)    // lookupFlag
        out.append(u16: 1)             // subTableCount = 1
        out.append(u16: subtableRel)   // subtableOffsets[0]
        if hasMarkSet {
            out.append(u16: markFilteringSet ?? 0)
        }

        // LigatureSubstFormat1 subtable:
        // +0: format=1, +2: coverageOffset=8, +4: ligSetCount=1, +6: ligSetOffsets[0]=14
        // +8: Coverage Format 1: format=1, glyphCount=1, glyph=first (6 bytes)
        // +14: LigatureSet: ligCount=1, ligOffset=4 (4 bytes)
        // +18: Ligature: ligGlyph, compCount=2, comp[0]=second (6 bytes)
        out.append(u16: 1)             // substFormat = 1
        out.append(u16: 8)             // coverageOffset
        out.append(u16: 1)             // ligatureSetCount = 1
        out.append(u16: 14)            // ligatureSetOffsets[0]
        // Coverage at +8
        out.append(u16: 1); out.append(u16: 1); out.append(u16: first)
        // LigatureSet at +14
        out.append(u16: 1); out.append(u16: 4)
        // Ligature at +18
        out.append(u16: ligature); out.append(u16: 2); out.append(u16: second)
        return out
    }

    /// Builds a GSUB table with a Chaining Context (type 6 format 3) lookup in 'calt'
    /// that replaces `target -> replacement` only when preceded by `back` and followed by `ahead`,
    /// using the given `lookupFlag`.
    static func buildChainingContextGSUB(
        back: GlyphID, target: GlyphID, ahead: GlyphID, replacement: GlyphID,
        lookupFlag: UInt16
    ) -> [UInt8] {
        var out: [UInt8] = []
        // GSUB header (10 bytes): scriptList=10, featureList=30, lookupList=44
        out.append(u16: 1); out.append(u16: 0)
        out.append(u16: 10); out.append(u16: 30); out.append(u16: 44)

        // ScriptList at 10 (20 bytes)
        out.append(u16: 1); out.append(u32: tag("DFLT")); out.append(u16: 8)
        out.append(u16: 4); out.append(u16: 0)
        out.append(u16: 0); out.append(u16: 0xFFFF); out.append(u16: 1); out.append(u16: 0)

        // FeatureList at 30 (14 bytes): 'calt' referencing lookup 0 only (lookup 1 is nested)
        out.append(u16: 1); out.append(u32: tag("calt")); out.append(u16: 8)
        out.append(u16: 0); out.append(u16: 1); out.append(u16: 0)

        // LookupList at 44: 2 lookups (lookup 0 = chaining context, lookup 1 = single subst)
        // LookupList header: 2 + 2*2 = 6 bytes -> lookup 0 at +6 (50)
        // Lookup 0 table: 8 bytes header + 38 bytes subtable = 46 bytes -> lookup 1 at +52 (96)
        out.append(u16: 2)
        out.append(u16: 6)    // lookup 0 -> 50
        out.append(u16: 52)   // lookup 1 -> 96

        // Lookup 0 (Type 6 Chaining Context) at 50
        out.append(u16: 6); out.append(u16: lookupFlag); out.append(u16: 1); out.append(u16: 8)
        // ChainingContext Format 3 subtable at 58 (38 bytes):
        // +0: format=3
        // +2: backCount=1, +4: backCov=20
        // +6: inputCount=1, +8: inputCov=26
        // +10: aheadCount=1, +12: aheadCov=32
        // +14: substCount=1, +16: seqIndex=0, +18: lookupListIndex=1
        // +20: backCov (6 bytes), +26: inputCov (6 bytes), +32: aheadCov (6 bytes) -> total 38 bytes
        out.append(u16: 3)
        out.append(u16: 1); out.append(u16: 20)
        out.append(u16: 1); out.append(u16: 26)
        out.append(u16: 1); out.append(u16: 32)
        out.append(u16: 1); out.append(u16: 0); out.append(u16: 1)
        out.append(u16: 1); out.append(u16: 1); out.append(u16: back)
        out.append(u16: 1); out.append(u16: 1); out.append(u16: target)
        out.append(u16: 1); out.append(u16: 1); out.append(u16: ahead)

        // Lookup 1 (Type 1 SingleSubst Format 2) at 96
        out.append(u16: 1); out.append(u16: 0); out.append(u16: 1); out.append(u16: 8)
        // SingleSubstFormat2 at 104: format=2, coverage=8, glyphCount=1, subst[0]=replacement, Coverage at +8
        out.append(u16: 2); out.append(u16: 8); out.append(u16: 1); out.append(u16: replacement)
        out.append(u16: 1); out.append(u16: 1); out.append(u16: target)
        return out
    }

    /// Builds a valid OpenType `fvar` binary table with `wght` (100..400..900) and
    /// `wdth` (75..100..125) axes plus two named instances (Regular, Bold).
    static func buildFvar() -> [UInt8] {
        var out: [UInt8] = []
        // Header (16 bytes)
        out.append(u16: 1)    // majorVersion
        out.append(u16: 0)    // minorVersion
        out.append(u16: 16)   // axesArrayOffset
        out.append(u16: 2)    // reserved
        out.append(u16: 2)    // axisCount
        out.append(u16: 20)   // axisSize
        out.append(u16: 2)    // instanceCount
        out.append(u16: 14)   // instanceSize = 4 + 2*4 + 2 (with postScriptNameID)

        // Axis 0: wght [100, 400, 900]
        out.append(u32: tag("wght"))
        out.append(u32: fixed16_16(100))
        out.append(u32: fixed16_16(400))
        out.append(u32: fixed16_16(900))
        out.append(u16: 0)    // flags
        out.append(u16: 256)  // axisNameID

        // Axis 1: wdth [75, 100, 125], hidden flag set for flag-parsing coverage
        out.append(u32: tag("wdth"))
        out.append(u32: fixed16_16(75))
        out.append(u32: fixed16_16(100))
        out.append(u32: fixed16_16(125))
        out.append(u16: 1)    // HIDDEN_AXIS
        out.append(u16: 257)  // axisNameID

        // Instance 0: Regular (400, 100)
        out.append(u16: 258); out.append(u16: 0)
        out.append(u32: fixed16_16(400)); out.append(u32: fixed16_16(100))
        out.append(u16: 260)

        // Instance 1: Bold (700, 100)
        out.append(u16: 259); out.append(u16: 0)
        out.append(u32: fixed16_16(700)); out.append(u32: fixed16_16(100))
        out.append(u16: 261)
        return out
    }

    /// Builds a valid OpenType `avar` binary table for 2 axes:
    /// Axis 0 (`wght`): (-1 -> -1), (0 -> 0), (0.5 -> 0.25), (1 -> 1)
    /// Axis 1 (`wdth`): (-1 -> -1), (0 -> 0), (1 -> 1)
    static func buildAvar() -> [UInt8] {
        var out: [UInt8] = []
        out.append(u16: 1); out.append(u16: 0)   // version 1.0
        out.append(u16: 0)                       // reserved
        out.append(u16: 2)                       // axisCount = 2

        // Axis 0 segment map (4 pairs)
        out.append(u16: 4)
        for (f, t) in [(-1.0, -1.0), (0.0, 0.0), (0.5, 0.25), (1.0, 1.0)] {
            out.append(u16: f2dot14(f)); out.append(u16: f2dot14(t))
        }

        // Axis 1 segment map (3 pairs)
        out.append(u16: 3)
        for (f, t) in [(-1.0, -1.0), (0.0, 0.0), (1.0, 1.0)] {
            out.append(u16: f2dot14(f)); out.append(u16: f2dot14(t))
        }
        return out
    }

    /// Builds a valid OpenType `gvar` binary table for 2 axes, 1 glyph (glyph 0),
    /// 1 shared tuple `[1.0, 0.0]`, and 1 sparse tuple variation touching points 0 and 2
    /// with deltas `(dx=0, dy=0)` and `(dx=20, dy=0)`.
    static func buildGvar() -> [UInt8] {
        // Header (20 bytes) + glyphVariationDataOffsets (2 * 4 = 8 bytes with longOffsets=1) -> 28 bytes
        // Shared tuples at 28: 1 tuple * 2 axes * 2 bytes = 4 bytes -> ends at 32
        // GlyphVariationDataArray at 32:
        //   GlyphVariationData header (4 bytes): tvCount=1, dataOffset=8 (after 1 TupleVariationHeader of 4 bytes)
        //   TupleVariationHeader (4 bytes): varDataSize=9, tupleIndex=0x2000 (PRIVATE_POINT_NUMBERS | sharedIndex 0)
        //   Serialized data (9 bytes):
        //     Packed point numbers: count=2, runHeader=0x01 (2 uint8s), delta0=0 (pt 0), delta1=2 (pt 2) -> 4 bytes
        //     Packed X deltas: runHeader=0x01 (2 int8s), 0, 20 -> 3 bytes
        //     Packed Y deltas: runHeader=0x81 (2 zeros) -> 1 byte
        //     Total serialized = 8 bytes
        var glyphData: [UInt8] = []
        // GlyphVariationData header
        glyphData.append(u16: 1)          // tupleVariationCount = 1 (no shared points)
        glyphData.append(u16: 8)          // dataOffset = 4 (header) + 4 (1 tuple header)
        // TupleVariationHeader
        glyphData.append(u16: 8)          // variationDataSize = 8 bytes
        glyphData.append(u16: 0x2000)     // PRIVATE_POINT_NUMBERS | shared tuple index 0
        // Serialized data (8 bytes)
        glyphData.append(2)               // total point count = 2
        glyphData.append(0x01)            // run of 2 uint8 point deltas
        glyphData.append(0)               // point 0
        glyphData.append(2)               // +2 => point 2
        glyphData.append(0x01)            // run of 2 int8 X deltas
        glyphData.append(0)               // dx[0] = 0
        glyphData.append(20)              // dx[2] = 20
        glyphData.append(0x81)            // DELTAS_ARE_ZERO, run of 2 Y deltas (0, 0)

        var out: [UInt8] = []
        out.append(u16: 1); out.append(u16: 0)            // version 1.0
        out.append(u16: 2)                                // axisCount = 2
        out.append(u16: 1)                                // sharedTupleCount = 1
        out.append(u32: 28)                               // sharedTuplesOffset
        out.append(u16: 1)                                // glyphCount = 1
        out.append(u16: 1)                                // flags = 1 (32-bit offsets)
        out.append(u32: 32)                               // glyphVariationDataArrayOffset
        // glyphVariationDataOffsets (glyphCount + 1 = 2 uint32s)
        out.append(u32: 0)
        out.append(u32: UInt32(glyphData.count))
        // Shared tuple 0: [1.0, 0.0]
        out.append(u16: f2dot14(1.0)); out.append(u16: f2dot14(0.0))
        // Glyph variation data array
        out.append(contentsOf: glyphData)
        return out
    }
}

// MARK: - Advanced Text Checks

@MainActor public let textAdvancedChecks: [Check] = [
    Check("text.gdef") { c in
        // 1. Parse real GDEF tables from bundled fonts.
        let inter = try TextReference.font(root: c.root, "Inter-Regular.otf")
        let geist = try TextReference.font(root: c.root, "Geist-Regular.otf")
        let mono = try TextReference.font(root: c.root, "JetBrainsMono-Regular.ttf")

        if let interGDEF = inter.gdef {
            c.expectEqual(interGDEF.majorVersion, 1, "Inter GDEF major version")
            c.expect(interGDEF.minorVersion >= 2, "Inter GDEF v1.2+ has mark glyph sets")
            c.expect(interGDEF.markGlyphSetCount > 0, "Inter GDEF markGlyphSetCount > 0")
            let gA = inter.glyph(for: "A")
            c.expectEqual(interGDEF.glyphClass(for: gA), .base, "Inter 'A' is a base glyph")
            let gAcute = inter.glyph(for: "\u{0301}")
            if gAcute != 0 {
                c.expectEqual(interGDEF.glyphClass(for: gAcute), .mark, "Inter combining acute is a mark")
            }
            c.note("Inter GDEF v\(interGDEF.majorVersion).\(interGDEF.minorVersion), markGlyphSets=\(interGDEF.markGlyphSetCount)")
        } else {
            c.fail("Inter-Regular.otf should have a GDEF table")
        }

        if let geistGDEF = geist.gdef {
            c.expect(geistGDEF.markGlyphSetCount > 0, "Geist GDEF markGlyphSetCount > 0")
            c.expectEqual(geistGDEF.glyphClass(for: geist.glyph(for: "H")), .base, "Geist 'H' is a base glyph")
        } else {
            c.fail("Geist-Regular.otf should have a GDEF table")
        }
        c.expect(mono.gdef != nil, "JetBrainsMono-Regular.ttf has a GDEF table")

        // 2. Binary GDEF v1.2 round-trip parse (ClassDef format 1 & 2, MarkGlyphSetsDef).
        let binGDEF = SyntheticOpenType.buildGDEF()
        if let parsed = GDEFTable(data: binGDEF) {
            c.expectEqual(parsed.majorVersion, 1, "binary GDEF major")
            c.expectEqual(parsed.minorVersion, 2, "binary GDEF minor")
            c.expectEqual(parsed.glyphClass(for: 10), .base, "glyph 10 base")
            c.expectEqual(parsed.glyphClass(for: 12), .ligature, "glyph 12 ligature")
            c.expectEqual(parsed.glyphClass(for: 13), .mark, "glyph 13 mark")
            c.expectEqual(parsed.glyphClass(for: 99), .unclassified, "unlisted glyph unclassified")
            c.expectEqual(parsed.markAttachmentClass(for: 13), 1, "glyph 13 mark attach class 1")
            c.expectEqual(parsed.markAttachmentClass(for: 14), 2, "glyph 14 mark attach class 2")
            c.expectEqual(parsed.markGlyphSetCount, 1, "markGlyphSetCount == 1")
            c.expect(parsed.isInMarkGlyphSet(13, setIndex: 0), "glyph 13 in mark set 0")
            c.expect(!parsed.isInMarkGlyphSet(14, setIndex: 0), "glyph 14 not in mark set 0")
        } else {
            c.fail("failed to parse synthetic binary GDEF")
        }

        // 3. Synthetic GDEFTable mark-skipping flags + real GSUB ligature/chaining-context execution.
        let gF: GlyphID = 10, gI: GlyphID = 11, gFI: GlyphID = 12
        let markA: GlyphID = 13, markB: GlyphID = 14
        let gA: GlyphID = 20, gB: GlyphID = 21, gC: GlyphID = 22, gBAlt: GlyphID = 23

        let gdef = GDEFTable(
            glyphClasses: [
                gF: .base, gI: .base, gFI: .ligature,
                markA: .mark, markB: .mark,
                gA: .base, gB: .base, gC: .base, gBAlt: .base,
            ],
            markAttachmentClasses: [markA: 1, markB: 2],
            markGlyphSets: [[markA]]
        )

        // Direct shouldSkip verification
        c.expect(gdef.shouldSkip(glyph: markA, lookupFlag: GDEFTable.LookupFlag.ignoreMarks), "ignoreMarks skips mark")
        c.expect(!gdef.shouldSkip(glyph: gF, lookupFlag: GDEFTable.LookupFlag.ignoreMarks), "ignoreMarks keeps base")
        c.expect(gdef.shouldSkip(glyph: gF, lookupFlag: GDEFTable.LookupFlag.ignoreBaseGlyphs), "ignoreBaseGlyphs skips base")
        c.expect(gdef.shouldSkip(glyph: gFI, lookupFlag: GDEFTable.LookupFlag.ignoreLigatures), "ignoreLigatures skips ligature")
        c.expect(!gdef.shouldSkip(glyph: markA, lookupFlag: 1 << 8), "markAttachType 1 keeps class-1 mark")
        c.expect(gdef.shouldSkip(glyph: markB, lookupFlag: 1 << 8), "markAttachType 1 skips class-2 mark")
        c.expect(!gdef.shouldSkip(glyph: markA, lookupFlag: GDEFTable.LookupFlag.useMarkFilteringSet, markFilteringSet: 0),
                 "markFilteringSet 0 keeps markA")
        c.expect(gdef.shouldSkip(glyph: markB, lookupFlag: GDEFTable.LookupFlag.useMarkFilteringSet, markFilteringSet: 0),
                 "markFilteringSet 0 skips markB")

        // GSUB ligature with ignoreMarks: [f, markA, i, markB] -> [fi, markA, markB]
        let gsubIgnoreMarks = SyntheticOpenType.buildLigatureGSUB(
            first: gF, second: gI, ligature: gFI, lookupFlag: GDEFTable.LookupFlag.ignoreMarks
        )
        if let sub = Substitution(data: gsubIgnoreMarks, gsub: 0, gdef: gdef) {
            var glyphs: [GlyphID] = [gF, markA, gI, markB]
            sub.apply(gsubIgnoreMarks, glyphs: &glyphs)
            c.expectEqual(glyphs, [gFI, markA, markB], "ignoreMarks ligature skips interleaved mark and preserves it")
        } else {
            c.fail("failed to build ignoreMarks GSUB")
        }

        // GSUB ligature with flag=0: interleaved mark blocks ligature
        let gsubNoSkip = SyntheticOpenType.buildLigatureGSUB(
            first: gF, second: gI, ligature: gFI, lookupFlag: 0
        )
        if let sub = Substitution(data: gsubNoSkip, gsub: 0, gdef: gdef) {
            var glyphs: [GlyphID] = [gF, markA, gI]
            sub.apply(gsubNoSkip, glyphs: &glyphs)
            c.expectEqual(glyphs, [gF, markA, gI], "flag=0 does not skip interleaved mark")
        } else {
            c.fail("failed to build flag=0 GSUB")
        }

        // GSUB ligature with markAttachmentType=1: skips markB (class 2), blocked by markA (class 1)
        let gsubAttach1 = SyntheticOpenType.buildLigatureGSUB(
            first: gF, second: gI, ligature: gFI, lookupFlag: 1 << 8
        )
        if let sub = Substitution(data: gsubAttach1, gsub: 0, gdef: gdef) {
            var withB: [GlyphID] = [gF, markB, gI]
            sub.apply(gsubAttach1, glyphs: &withB)
            c.expectEqual(withB, [gFI, markB], "markAttachmentType=1 skips class-2 markB")

            var withA: [GlyphID] = [gF, markA, gI]
            sub.apply(gsubAttach1, glyphs: &withA)
            c.expectEqual(withA, [gF, markA, gI], "markAttachmentType=1 does not skip class-1 markA")
        } else {
            c.fail("failed to build markAttachType GSUB")
        }

        // GSUB ligature with useMarkFilteringSet=0 ({markA}): skips markB, blocked by markA
        let gsubFilterSet = SyntheticOpenType.buildLigatureGSUB(
            first: gF, second: gI, ligature: gFI,
            lookupFlag: GDEFTable.LookupFlag.useMarkFilteringSet, markFilteringSet: 0
        )
        if let sub = Substitution(data: gsubFilterSet, gsub: 0, gdef: gdef) {
            var withB: [GlyphID] = [gF, markB, gI]
            sub.apply(gsubFilterSet, glyphs: &withB)
            c.expectEqual(withB, [gFI, markB], "useMarkFilteringSet skips markB not in set 0")

            var withA: [GlyphID] = [gF, markA, gI]
            sub.apply(gsubFilterSet, glyphs: &withA)
            c.expectEqual(withA, [gF, markA, gI], "useMarkFilteringSet does not skip markA in set 0")
        } else {
            c.fail("failed to build useMarkFilteringSet GSUB")
        }

        // GSUB chaining context with ignoreMarks: [gA, markA, gB, markB, gC] -> [gA, markA, gBAlt, markB, gC]
        let gsubChaining = SyntheticOpenType.buildChainingContextGSUB(
            back: gA, target: gB, ahead: gC, replacement: gBAlt,
            lookupFlag: GDEFTable.LookupFlag.ignoreMarks
        )
        if let sub = Substitution(data: gsubChaining, gsub: 0, gdef: gdef) {
            var glyphs: [GlyphID] = [gA, markA, gB, markB, gC]
            sub.apply(gsubChaining, glyphs: &glyphs)
            c.expectEqual(glyphs, [gA, markA, gBAlt, markB, gC],
                          "chaining context with ignoreMarks matches across marks and substitutes exact glyph")
        } else {
            c.fail("failed to build chaining context GSUB")
        }
    },

    Check("text.line-break") { c in
        func allowedSplits(_ s: String) -> [(String, UnicodeLineBreak.BreakOpportunity)] {
            UnicodeLineBreak.breaks(in: s)
                .filter { $0.index != s.endIndex && $0.kind != .prohibited }
                .map { (String(s[..<$0.index]), $0.kind) }
        }

        // 1. Mandatory breaks: \n, \r\n, \u{2028}, \u{2029}
        let nl = allowedSplits("a\nb")
        c.expectEqual(nl.count, 1, "one interior break in a\\nb")
        c.expectEqual(nl.first?.0, "a\n", "mandatory break right after \\n")
        c.expectEqual(nl.first?.1, .mandatory, "\\n break is mandatory")

        let crlf = allowedSplits("a\r\nb")
        c.expectEqual(crlf.count, 1, "CR+LF is a single mandatory break (no break between CR and LF)")
        c.expectEqual(crlf.first?.1, .mandatory, "CR+LF break is mandatory")

        let ls = allowedSplits("a\u{2028}b")
        c.expectEqual(ls.count, 1, "U+2028 line separator produces mandatory break")
        c.expectEqual(ls.first?.1, .mandatory, "U+2028 is mandatory")

        let ps = allowedSplits("a\u{2029}b")
        c.expectEqual(ps.count, 1, "U+2029 paragraph separator produces mandatory break")
        c.expectEqual(ps.first?.1, .mandatory, "U+2029 is mandatory")

        // 2. NBSP / NNBSP / Word Joiner prohibit breaks
        c.expect(allowedSplits("foo\u{00A0}bar").isEmpty, "NBSP prevents line break")
        c.expect(allowedSplits("foo\u{202F}bar").isEmpty, "narrow NBSP prevents line break")
        c.expect(allowedSplits("foo\u{2060}bar").isEmpty, "word joiner prevents line break")

        // 3. Hyphens: break words, keep negative numbers intact
        let hyp = allowedSplits("self-contained")
        c.expectEqual(hyp.map(\.0), ["self-"], "self-contained breaks after hyphen")
        c.expect(allowedSplits("-42").isEmpty, "-42 stays together")
        let neg = allowedSplits("temp -42")
        c.expectEqual(neg.map(\.0), ["temp "], "temp -42 breaks after space, not after minus")

        // 4. Em-dash, slash, zero-width space
        c.expectEqual(allowedSplits("alpha\u{2014}beta").map(\.0), ["alpha\u{2014}"], "em-dash allows break after")
        c.expectEqual(allowedSplits("src/text/break").map(\.0), ["src/", "src/text/"], "slash allows break after")
        c.expectEqual(allowedSplits("super\u{200B}long").map(\.0), ["super\u{200B}"], "ZWSP allows break after")

        // 5. Opening and closing punctuation stay attached
        let punct = allowedSplits("(hello), world!")
        c.expectEqual(punct.map(\.0), ["(hello), "], "opening '(' and closing '),!' stay attached to words")

        // 6. CJK / ideographic text breaks cleanly between characters and Latin boundaries
        let cjk = allowedSplits("日本語テスト")
        c.expectEqual(cjk.count, 5, "6 CJK characters have 5 interior break opportunities")
        let cjkQuoted = allowedSplits("「日本語」")
        c.expectEqual(cjkQuoted.map(\.0), ["「日", "「日本"], "opening 「 and closing 」 stay attached")
        let mixed = allowedSplits("Hello世界")
        c.expectEqual(mixed.map(\.0), ["Hello", "Hello世"], "breaks at Latin/CJK and CJK/CJK boundaries")

        // 7. TextLayout.lines integration with NBSP, negative numbers, ZWSP, and CJK
        let geist = try TextReference.font(root: c.root, "Geist-Regular.otf")
        let nbspStr = "hello foo\u{00A0}bar"
        let helloW = TextLayout.width(TextLayout.line("hello foo", font: geist, pixelSize: 13))
        let nbspLines = TextLayout.lines(nbspStr, font: geist, pixelSize: 13, maxWidth: helloW + 1)
        c.expectEqual(nbspLines.count, 2, "NBSP keeps foo\\u{00A0}bar together on second line")
        c.expectEqual(nbspLines[0].glyphs.count, 5, "first line is 'hello' (5 glyphs)")
        c.expectEqual(nbspLines[1].glyphs.count, 7, "second line is 'foo\\u{00A0}bar' (7 glyphs)")

        let negStr = "temp -42"
        let tempDashW = TextLayout.width(TextLayout.line("temp -", font: geist, pixelSize: 13))
        let negLines = TextLayout.lines(negStr, font: geist, pixelSize: 13, maxWidth: tempDashW + 1)
        c.expectEqual(negLines.count, 2, "negative number wraps as a unit")
        c.expectEqual(negLines[0].glyphs.count, 4, "first line is 'temp'")
        c.expectEqual(negLines[1].glyphs.count, 3, "second line is '-42'")

        let cjkStr = "日本語テスト"
        let singleCJKW = TextLayout.width(TextLayout.line("日", font: geist, pixelSize: 13))
        let cjkLines = TextLayout.lines(cjkStr, font: geist, pixelSize: 13, maxWidth: singleCJKW * 2.5)
        c.expectEqual(cjkLines.count, 3, "6 CJK chars at 2.5-char width wrap into 3 lines of 2")
        c.expect(cjkLines.allSatisfy { $0.glyphs.count == 2 }, "each CJK line has 2 glyphs")
    },

    Check("text.fallback") { c in
        let geist = try TextReference.font(root: c.root, "Geist-Regular.otf")
        let inter = try TextReference.font(root: c.root, "Inter-Regular.otf")
        let mono = try TextReference.font(root: c.root, "JetBrainsMono-Regular.ttf")

        // Verify fixture coverage assumptions before testing chain.
        c.expectEqual(geist.glyph(for: "\u{0114}"), 0, "Geist lacks U+0114 (Ĕ)")
        c.expect(inter.glyph(for: "\u{0114}") != 0, "Inter has U+0114 (Ĕ)")
        c.expectEqual(geist.glyph(for: "\u{211D}"), 0, "Geist lacks U+211D (ℝ)")
        c.expectEqual(inter.glyph(for: "\u{211D}"), 0, "Inter lacks U+211D (ℝ)")
        c.expect(mono.glyph(for: "\u{211D}") != 0, "JetBrainsMono has U+211D (ℝ)")

        let chain = FontFallbackChain([geist, inter, mono])

        // 1. Direct scalar resolution
        if let rA = chain.resolveIndex(scalar: "A") {
            c.expectEqual(rA.faceIndex, 0, "'A' resolves from primary Geist")
            c.expect(rA.glyphID != 0, "'A' has non-zero glyph")
        } else { c.fail("resolveIndex failed for 'A'") }

        if let rE = chain.resolveIndex(scalar: "\u{0114}") {
            c.expectEqual(rE.faceIndex, 1, "'Ĕ' resolves from fallback 1 (Inter)")
            c.expect(rE.glyphID != 0, "'Ĕ' has non-zero glyph")
        } else { c.fail("resolveIndex failed for 'Ĕ'") }

        if let rR = chain.resolveIndex(scalar: "\u{211D}") {
            c.expectEqual(rR.faceIndex, 2, "'ℝ' resolves from fallback 2 (JetBrainsMono)")
            c.expect(rR.glyphID != 0, "'ℝ' has non-zero glyph")
        } else { c.fail("resolveIndex failed for 'ℝ'") }

        if let rMissing = chain.resolve(scalar: "漢") {
            c.expect(rMissing.face === geist, "completely missing glyph falls back to primary face")
            c.expectEqual(rMissing.glyphID, 0, "missing glyph returns .notdef (0)")
        } else { c.fail("resolve returned nil on non-empty chain") }

        // 2. Contiguous shaped runs + monotonic continuous x-advance
        let sample = "Hi \u{0114}\u{211D} ok"
        let runs = chain.shape(sample, size: 14)
        c.expectEqual(runs.map(\.faceIndex), [0, 1, 2, 0], "minimal contiguous face runs")
        c.expectEqual(runs.map(\.text), ["Hi ", "\u{0114}", "\u{211D}", " ok"], "run text slices match")

        var prevEndX = 0.0
        var prevX = -1.0
        var clusters: [Int] = []
        for (idx, run) in runs.enumerated() {
            c.expect(!run.glyphs.isEmpty, "run \(idx) has glyphs")
            if let first = run.glyphs.first {
                c.expectClose(first.x, prevEndX, tolerance: 1e-6, "run \(idx) starts where previous run ended")
            }
            for g in run.glyphs {
                c.expect(g.x > prevX, "glyph x advances monotonically (\(g.x) > \(prevX))")
                prevX = g.x
                clusters.append(g.cluster)
            }
            if let last = run.glyphs.last {
                prevEndX = last.x + last.advance
            }
        }
        c.expectEqual(clusters, Array(0..<sample.unicodeScalars.count), "clusters map to original scalar indices")

        // 3. GSUB preserved within fallback runs (Inter raises colon between digits)
        let interChain = FontFallbackChain([inter, mono])
        let shaped = interChain.shape("3:42 \u{211D}", size: 13)
        c.expectEqual(shaped.count, 2, "two runs for '3:42 ℝ'")
        c.expectEqual(shaped[0].faceIndex, 0, "first run uses Inter")
        c.expectEqual(shaped[1].faceIndex, 1, "second run uses JetBrainsMono")
        c.expect(shaped[0].glyphs.count == 5 && shaped[0].glyphs[1].glyph != inter.glyph(for: ":"),
                 "GSUB contextual colon preserved inside primary run")
    },

    Check("text.variable-font") { c in
        let fvar = SyntheticOpenType.buildFvar()
        let avar = SyntheticOpenType.buildAvar()
        let gvar = SyntheticOpenType.buildGvar()

        guard let vf = VariableFontTable(fvarData: fvar, avarData: avar, gvarData: gvar) else {
            c.fail("failed to parse synthetic fvar/avar/gvar tables")
            return
        }

        // 1. fvar axes & named instances
        c.expectEqual(vf.axes.count, 2, "2 variation axes")
        c.expectEqual(vf.axes[0].tag, "wght", "axis 0 is wght")
        c.expectClose(vf.axes[0].minValue, 100, tolerance: 1e-6, "wght min")
        c.expectClose(vf.axes[0].defaultValue, 400, tolerance: 1e-6, "wght default")
        c.expectClose(vf.axes[0].maxValue, 900, tolerance: 1e-6, "wght max")
        c.expect(!vf.axes[0].isHidden, "wght is visible")

        c.expectEqual(vf.axes[1].tag, "wdth", "axis 1 is wdth")
        c.expectClose(vf.axes[1].minValue, 75, tolerance: 1e-6, "wdth min")
        c.expectClose(vf.axes[1].defaultValue, 100, tolerance: 1e-6, "wdth default")
        c.expectClose(vf.axes[1].maxValue, 125, tolerance: 1e-6, "wdth max")
        c.expect(vf.axes[1].isHidden, "wdth hidden flag parsed")

        c.expectEqual(vf.instances.count, 2, "2 named instances")
        c.expectEqual(vf.instances[1].coordinates, [700, 100], "Bold instance coordinates")
        c.expectEqual(vf.instances[1].postScriptNameID, 261, "Bold postScriptNameID")

        // 2. fvar + avar normalization
        let wght = vf.axes[0]
        c.expectClose(VariableFontTable.normalizeCoordinate(400, axis: wght), 0.0, tolerance: 1e-6, "default -> 0")
        c.expectClose(VariableFontTable.normalizeCoordinate(100, axis: wght), -1.0, tolerance: 1e-6, "min -> -1")
        c.expectClose(VariableFontTable.normalizeCoordinate(900, axis: wght), 1.0, tolerance: 1e-6, "max -> 1")
        c.expectClose(VariableFontTable.normalizeCoordinate(50, axis: wght), -1.0, tolerance: 1e-6, "clamped below min")
        c.expectClose(VariableFontTable.normalizeCoordinate(1200, axis: wght), 1.0, tolerance: 1e-6, "clamped above max")
        c.expectClose(VariableFontTable.normalizeCoordinate(650, axis: wght), 0.5, tolerance: 1e-6, "linear midpoint")

        // With avar piecewise-linear mapping: raw 0.5 -> 0.25, raw 0.75 -> 0.625
        let nMid = vf.normalize(VariationCoordinates(["wght": 650, "wdth": 112.5]))
        c.expectClose(nMid[0], 0.25, tolerance: 1e-4, "avar maps raw 0.5 -> 0.25")
        c.expectClose(nMid[1], 0.5, tolerance: 1e-4, "wdth identity map 112.5 -> 0.5")

        let nUpper = vf.normalize(VariationCoordinates(["wght": 775]))
        c.expectClose(nUpper[0], 0.625, tolerance: 1e-4, "avar interpolates raw 0.75 -> 0.625")
        c.expectClose(nUpper[1], 0.0, tolerance: 1e-6, "unspecified axis defaults to 0")

        // 3. Tuple scalar evaluation (simple peaks + intermediate regions + multi-axis)
        c.expectClose(VariableFontTable.tupleScalar(peak: [1.0, 0.0], coordinates: [0.5, 0.8]), 0.5, tolerance: 1e-6,
                      "simple positive peak scalar")
        c.expectClose(VariableFontTable.tupleScalar(peak: [1.0, 0.0], coordinates: [-0.5, 0.0]), 0.0, tolerance: 1e-6,
                      "opposite sign gives 0")
        c.expectClose(VariableFontTable.tupleScalar(peak: [-1.0], coordinates: [-0.4]), 0.4, tolerance: 1e-6,
                      "negative peak scalar")
        c.expectClose(VariableFontTable.tupleScalar(peak: [0.5], start: [0.0], end: [1.0], coordinates: [0.25]),
                      0.5, tolerance: 1e-6, "intermediate tent rising slope")
        c.expectClose(VariableFontTable.tupleScalar(peak: [0.5], start: [0.0], end: [1.0], coordinates: [0.5]),
                      1.0, tolerance: 1e-6, "intermediate tent peak")
        c.expectClose(VariableFontTable.tupleScalar(peak: [0.5], start: [0.0], end: [1.0], coordinates: [0.75]),
                      0.5, tolerance: 1e-6, "intermediate tent falling slope")
        c.expectClose(VariableFontTable.tupleScalar(peak: [1.0, 1.0], coordinates: [0.5, 0.5]), 0.25, tolerance: 1e-6,
                      "multi-axis tuple scalar product")

        // 4. Dense applyDeltas + IUP (Interpolation of Untouched Points) + binary gvar end-to-end
        // Contour of 4 points: p0=(0,0) touched(0,0), p1=(50,0) untouched, p2=(100,0) touched(20,0), p3=(120,100) untouched
        let pts = [
            Point(x: 0, y: 0),
            Point(x: 50, y: 0),
            Point(x: 100, y: 0),
            Point(x: 120, y: 100),
        ]
        // Evaluate directly through parsed binary gvar at wght=0.5 (scalar = 0.5):
        // p0: (0,0) + 0.5*(0,0) = (0,0)
        // p1: x=50 interpolates halfway between p0(0->0) and p2(100->20) => dx=10, scaled 0.5 => (55, 0)
        // p2: (100,0) + 0.5*(20,0) = (110, 0)
        // p3: x=120 >= max(0,100) clamps to p2's delta dx=20, scaled 0.5 => (130, 100)
        let varied = vf.applyGlyphVariations(glyphID: 0, to: pts, contourEndIndices: [3], normalizedCoordinates: [0.5, 0.0])
        c.expectClose(varied[0].x, 0, tolerance: 1e-6, "gvar touched p0.x")
        c.expectClose(varied[1].x, 55, tolerance: 1e-6, "gvar IUP interpolated p1.x")
        c.expectClose(varied[2].x, 110, tolerance: 1e-6, "gvar touched p2.x")
        c.expectClose(varied[3].x, 130, tolerance: 1e-6, "gvar IUP clamped p3.x")
        c.expectClose(varied[3].y, 100, tolerance: 1e-6, "gvar untouched p3.y unchanged")

        // Single touched point shifts entire contour uniformly.
        let shifted = VariableFontTable.applySparseDeltas(
            to: pts, contourEndIndices: [3], touchedDeltas: [0: (dx: 10, dy: -4)], scalar: 1.0
        )
        c.expectClose(shifted[2].x, 110, tolerance: 1e-6, "single-touched IUP shifts whole contour x")
        c.expectClose(shifted[2].y, -4, tolerance: 1e-6, "single-touched IUP shifts whole contour y")

        // Dense applyDeltas check
        let dense = VariableFontTable.applyDeltas(
            to: [Point(x: 10, y: 20)], deltas: [(dx: 8, dy: -4)], scalar: 0.25
        )
        c.expectClose(dense[0].x, 12, tolerance: 1e-6, "dense applyDeltas x")
        c.expectClose(dense[0].y, 19, tolerance: 1e-6, "dense applyDeltas y")
    },
]
