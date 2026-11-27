// Checks for the text extras: GDEF mark-skipping in GSUB, UAX #14 line
// breaking, the font fallback chain, variable-font tables (fvar/avar/gvar
// with IUP) and COLR/CPAL v0 color glyphs. Binary tables are built here so
// the parsers are exercised without extra fixtures.
import PolymerBase
import PolymerText

// MARK: - Synthetic OpenType binary builders

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

    /// A minimal GDEF v1.2 table: format-1 GlyphClassDef, format-2
    /// MarkAttachClassDef and a format-1 MarkGlyphSetsDef with one set.
    static func buildGDEF() -> [UInt8] {
        var out: [UInt8] = []
        // Header (14 bytes).
        out.append(u16: 1)    // majorVersion
        out.append(u16: 2)    // minorVersion
        out.append(u16: 14)   // glyphClassDefOffset
        out.append(u16: 0)    // attachListOffset
        out.append(u16: 0)    // ligCaretListOffset
        out.append(u16: 30)   // markAttachClassDefOffset
        out.append(u16: 46)   // markGlyphSetsDefOffset

        // GlyphClassDef, format 1, at 14: glyphs 10..<15.
        out.append(u16: 1)
        out.append(u16: 10)
        out.append(u16: 5)
        out.append(u16: 1)    // 10 base
        out.append(u16: 1)    // 11 base
        out.append(u16: 2)    // 12 ligature
        out.append(u16: 3)    // 13 mark
        out.append(u16: 3)    // 14 mark

        // MarkAttachClassDef, format 2, at 30.
        out.append(u16: 2)
        out.append(u16: 2)
        out.append(u16: 13); out.append(u16: 13); out.append(u16: 1)
        out.append(u16: 14); out.append(u16: 14); out.append(u16: 2)

        // MarkGlyphSetsDef at 46: one set, coverage at +8.
        out.append(u16: 1)
        out.append(u16: 1)
        out.append(u32: 8)
        // Coverage, format 1: glyph 13.
        out.append(u16: 1)
        out.append(u16: 1)
        out.append(u16: 13)
        return out
    }

    /// GSUB with one 'liga' LigatureSubst lookup: `first + second -> ligature`,
    /// carrying the given lookup flag (and mark filtering set when asked for).
    static func buildLigatureGSUB(
        first: GlyphID, second: GlyphID, ligature: GlyphID,
        lookupFlag: UInt16, markFilteringSet: UInt16? = nil
    ) -> [UInt8] {
        var out: [UInt8] = []
        // GSUB header.
        out.append(u16: 1); out.append(u16: 0)
        out.append(u16: 10); out.append(u16: 30); out.append(u16: 44)

        // ScriptList at 10.
        out.append(u16: 1)
        out.append(u32: tag("DFLT"))
        out.append(u16: 8)
        out.append(u16: 4)             // defaultLangSysOffset -> 22
        out.append(u16: 0)             // langSysCount
        out.append(u16: 0)             // lookupOrderOffset
        out.append(u16: 0xFFFF)        // requiredFeatureIndex
        out.append(u16: 1)             // featureIndexCount
        out.append(u16: 0)

        // FeatureList at 30.
        out.append(u16: 1)
        out.append(u32: tag("liga"))
        out.append(u16: 8)
        out.append(u16: 0)
        out.append(u16: 1)
        out.append(u16: 0)

        // LookupList at 44.
        out.append(u16: 1)
        out.append(u16: 4)

        // LookupTable at 48.
        let hasMarkSet = (lookupFlag & GDEFTable.LookupFlag.useMarkFilteringSet != 0)
        out.append(u16: 4)             // lookupType = ligature
        out.append(u16: lookupFlag)
        out.append(u16: 1)             // subTableCount
        out.append(u16: hasMarkSet ? 10 : 8)
        if hasMarkSet {
            out.append(u16: markFilteringSet ?? 0)
        }

        // LigatureSubst format 1.
        out.append(u16: 1)
        out.append(u16: 8)             // coverageOffset
        out.append(u16: 1)             // ligatureSetCount
        out.append(u16: 14)            // ligatureSetOffsets[0]
        out.append(u16: 1); out.append(u16: 1); out.append(u16: first)
        out.append(u16: 1); out.append(u16: 4)
        out.append(u16: ligature); out.append(u16: 2); out.append(u16: second)
        return out
    }

    /// GSUB with a chaining-context (type 6, format 3) lookup in 'calt' that
    /// replaces `target` with `replacement` when preceded by `back` and
    /// followed by `ahead`, plus a nested single substitution.
    static func buildChainingContextGSUB(
        back: GlyphID, target: GlyphID, ahead: GlyphID, replacement: GlyphID,
        lookupFlag: UInt16
    ) -> [UInt8] {
        var out: [UInt8] = []
        out.append(u16: 1); out.append(u16: 0)
        out.append(u16: 10); out.append(u16: 30); out.append(u16: 44)

        out.append(u16: 1); out.append(u32: tag("DFLT")); out.append(u16: 8)
        out.append(u16: 4); out.append(u16: 0)
        out.append(u16: 0); out.append(u16: 0xFFFF); out.append(u16: 1); out.append(u16: 0)

        out.append(u16: 1); out.append(u32: tag("calt")); out.append(u16: 8)
        out.append(u16: 0); out.append(u16: 1); out.append(u16: 0)

        // Two lookups: 0 = chaining context, 1 = single substitution.
        out.append(u16: 2)
        out.append(u16: 6)    // lookup 0 -> 50
        out.append(u16: 52)   // lookup 1 -> 96

        out.append(u16: 6); out.append(u16: lookupFlag); out.append(u16: 1); out.append(u16: 8)

        // ChainingContext format 3 at 58.
        out.append(u16: 3)
        out.append(u16: 1); out.append(u16: 20)
        out.append(u16: 1); out.append(u16: 26)
        out.append(u16: 1); out.append(u16: 32)
        out.append(u16: 1); out.append(u16: 0); out.append(u16: 1)
        out.append(u16: 1); out.append(u16: 1); out.append(u16: back)
        out.append(u16: 1); out.append(u16: 1); out.append(u16: target)
        out.append(u16: 1); out.append(u16: 1); out.append(u16: ahead)

        // Lookup 1: SingleSubst format 2 at 96.
        out.append(u16: 1); out.append(u16: 0); out.append(u16: 1); out.append(u16: 8)
        out.append(u16: 2); out.append(u16: 8); out.append(u16: 1); out.append(u16: replacement)
        out.append(u16: 1); out.append(u16: 1); out.append(u16: target)
        return out
    }

    /// `fvar` with `wght` (100..400..900) and `wdth` (75..100..125, hidden).
    static func buildFvar() -> [UInt8] {
        var out: [UInt8] = []
        out.append(u16: 1)    // majorVersion
        out.append(u16: 0)    // minorVersion
        out.append(u16: 16)   // axesArrayOffset
        out.append(u16: 2)    // reserved
        out.append(u16: 2)    // axisCount
        out.append(u16: 20)   // axisSize
        out.append(u16: 2)    // instanceCount
        out.append(u16: 14)   // instanceSize

        out.append(u32: tag("wght"))
        out.append(u32: fixed16_16(100))
        out.append(u32: fixed16_16(400))
        out.append(u32: fixed16_16(900))
        out.append(u16: 0)
        out.append(u16: 256)

        out.append(u32: tag("wdth"))
        out.append(u32: fixed16_16(75))
        out.append(u32: fixed16_16(100))
        out.append(u32: fixed16_16(125))
        out.append(u16: 1)
        out.append(u16: 257)

        out.append(u16: 258); out.append(u16: 0)
        out.append(u32: fixed16_16(400)); out.append(u32: fixed16_16(100))
        out.append(u16: 260)

        out.append(u16: 259); out.append(u16: 0)
        out.append(u32: fixed16_16(700)); out.append(u32: fixed16_16(100))
        out.append(u16: 261)
        return out
    }

    /// `avar` for two axes: `wght` maps 0.5 -> 0.25, `wdth` is the identity.
    static func buildAvar() -> [UInt8] {
        var out: [UInt8] = []
        out.append(u16: 1); out.append(u16: 0)
        out.append(u16: 0)
        out.append(u16: 2)

        out.append(u16: 4)
        for (f, t) in [(-1.0, -1.0), (0.0, 0.0), (0.5, 0.25), (1.0, 1.0)] {
            out.append(u16: f2dot14(f)); out.append(u16: f2dot14(t))
        }

        out.append(u16: 3)
        for (f, t) in [(-1.0, -1.0), (0.0, 0.0), (1.0, 1.0)] {
            out.append(u16: f2dot14(f)); out.append(u16: f2dot14(t))
        }
        return out
    }

    /// `gvar` with two axes, one glyph, one shared tuple `[1, 0]` and one
    /// private-point tuple touching points 0 and 2 with x deltas 0 and 20.
    static func buildGvar() -> [UInt8] {
        var glyphData: [UInt8] = []
        glyphData.append(u16: 1)          // tupleVariationCount
        glyphData.append(u16: 8)          // dataOffset
        glyphData.append(u16: 8)          // variationDataSize
        glyphData.append(u16: 0x2000)     // private points | shared tuple 0
        glyphData.append(2)               // two points
        glyphData.append(0x01)            // run of two uint8 point deltas
        glyphData.append(0)               // point 0
        glyphData.append(2)               // +2 => point 2
        glyphData.append(0x01)            // run of two int8 x deltas
        glyphData.append(0)
        glyphData.append(20)
        glyphData.append(0x81)            // two zero y deltas

        var out: [UInt8] = []
        out.append(u16: 1); out.append(u16: 0)
        out.append(u16: 2)                // axisCount
        out.append(u16: 1)                // sharedTupleCount
        out.append(u32: 28)               // sharedTuplesOffset
        out.append(u16: 1)                // glyphCount
        out.append(u16: 1)                // flags: 32-bit offsets
        out.append(u32: 32)               // glyphVariationDataArrayOffset
        out.append(u32: 0)
        out.append(u32: UInt32(glyphData.count))
        out.append(u16: f2dot14(1.0)); out.append(u16: f2dot14(0.0))
        out.append(contentsOf: glyphData)
        return out
    }
}

// MARK: - Checks

@MainActor let textExtrasChecks: [Check] = [
    Check("text.gdef") { c in
        // Real GDEF tables from the bundled fonts.
        let inter = try TextReference.font(root: c.root, "Inter-Regular.otf")
        let geist = try TextReference.font(root: c.root, "Geist-Regular.otf")
        let mono = try TextReference.font(root: c.root, "JetBrainsMono-Regular.ttf")

        if let interGDEF = inter.gdef {
            c.expectEqual(interGDEF.majorVersion, 1, "Inter GDEF major version")
            c.expect(interGDEF.minorVersion >= 2, "Inter GDEF v1.2+ has mark glyph sets")
            c.expect(interGDEF.markGlyphSetCount > 0, "Inter GDEF markGlyphSetCount > 0")
            c.expectEqual(interGDEF.glyphClass(for: inter.glyph(for: "A")), .base, "Inter 'A' is a base glyph")
            let acute = inter.glyph(for: "\u{0301}")
            if acute != 0 { c.expectEqual(interGDEF.glyphClass(for: acute), .mark, "Inter combining acute is a mark") }
            c.note("Inter GDEF v\(interGDEF.majorVersion).\(interGDEF.minorVersion), markGlyphSets=\(interGDEF.markGlyphSetCount)")
        } else {
            c.fail("Inter-Regular.otf should have a GDEF table")
        }

        if let geistGDEF = geist.gdef {
            c.expectEqual(geistGDEF.glyphClass(for: geist.glyph(for: "H")), .base, "Geist 'H' is a base glyph")
        } else {
            c.fail("Geist-Regular.otf should have a GDEF table")
        }
        c.expect(mono.gdef != nil, "JetBrainsMono-Regular.ttf has a GDEF table")

        // Binary GDEF v1.2: class formats 1 and 2, mark attach classes, mark sets.
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

        let gF: GlyphID = 10, gI: GlyphID = 11, gFI: GlyphID = 12
        let markA: GlyphID = 13, markB: GlyphID = 14
        let gA: GlyphID = 20, gB: GlyphID = 21, gC: GlyphID = 22, gBAlt: GlyphID = 23

        let gdef = GDEFTable(
            glyphClasses: [
                gF: .base, gI: .base, gFI: .ligature, markA: .mark, markB: .mark,
                gA: .base, gB: .base, gC: .base, gBAlt: .base,
            ],
            markAttachmentClasses: [markA: 1, markB: 2],
            markGlyphSets: [[markA]]
        )

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

        // Ligature with ignoreMarks: [f, markA, i, markB] -> [fi, markA, markB].
        let gsubIgnoreMarks = SyntheticOpenType.buildLigatureGSUB(
            first: gF, second: gI, ligature: gFI, lookupFlag: GDEFTable.LookupFlag.ignoreMarks
        )
        if let sub = Substitution(data: gsubIgnoreMarks, gsub: 0, gdef: gdef) {
            var glyphs: [GlyphID] = [gF, markA, gI, markB]
            sub.apply(gsubIgnoreMarks, glyphs: &glyphs)
            c.expectEqual(glyphs, [gFI, markA, markB], "ignoreMarks ligature skips the interleaved mark and keeps it")
        } else {
            c.fail("failed to build ignoreMarks GSUB")
        }

        // Flag 0: the interleaved mark blocks the ligature.
        let gsubNoSkip = SyntheticOpenType.buildLigatureGSUB(first: gF, second: gI, ligature: gFI, lookupFlag: 0)
        if let sub = Substitution(data: gsubNoSkip, gsub: 0, gdef: gdef) {
            var glyphs: [GlyphID] = [gF, markA, gI]
            sub.apply(gsubNoSkip, glyphs: &glyphs)
            c.expectEqual(glyphs, [gF, markA, gI], "flag 0 does not skip the interleaved mark")
        } else {
            c.fail("failed to build flag-0 GSUB")
        }

        // Mark attachment type 1: skips class-2 markB, blocked by class-1 markA.
        let gsubAttach1 = SyntheticOpenType.buildLigatureGSUB(first: gF, second: gI, ligature: gFI, lookupFlag: 1 << 8)
        if let sub = Substitution(data: gsubAttach1, gsub: 0, gdef: gdef) {
            var withB: [GlyphID] = [gF, markB, gI]
            sub.apply(gsubAttach1, glyphs: &withB)
            c.expectEqual(withB, [gFI, markB], "markAttachmentType 1 skips class-2 markB")
            var withA: [GlyphID] = [gF, markA, gI]
            sub.apply(gsubAttach1, glyphs: &withA)
            c.expectEqual(withA, [gF, markA, gI], "markAttachmentType 1 does not skip class-1 markA")
        } else {
            c.fail("failed to build markAttachType GSUB")
        }

        // Mark filtering set 0 ({markA}): skips markB, blocked by markA.
        let gsubFilterSet = SyntheticOpenType.buildLigatureGSUB(
            first: gF, second: gI, ligature: gFI,
            lookupFlag: GDEFTable.LookupFlag.useMarkFilteringSet, markFilteringSet: 0
        )
        if let sub = Substitution(data: gsubFilterSet, gsub: 0, gdef: gdef) {
            var withB: [GlyphID] = [gF, markB, gI]
            sub.apply(gsubFilterSet, glyphs: &withB)
            c.expectEqual(withB, [gFI, markB], "useMarkFilteringSet skips markB, which is not in set 0")
            var withA: [GlyphID] = [gF, markA, gI]
            sub.apply(gsubFilterSet, glyphs: &withA)
            c.expectEqual(withA, [gF, markA, gI], "useMarkFilteringSet keeps markA, which is in set 0")
        } else {
            c.fail("failed to build useMarkFilteringSet GSUB")
        }

        // Chaining context with ignoreMarks: matches across marks.
        let gsubChaining = SyntheticOpenType.buildChainingContextGSUB(
            back: gA, target: gB, ahead: gC, replacement: gBAlt,
            lookupFlag: GDEFTable.LookupFlag.ignoreMarks
        )
        if let sub = Substitution(data: gsubChaining, gsub: 0, gdef: gdef) {
            var glyphs: [GlyphID] = [gA, markA, gB, markB, gC]
            sub.apply(gsubChaining, glyphs: &glyphs)
            c.expectEqual(glyphs, [gA, markA, gBAlt, markB, gC],
                          "chaining context with ignoreMarks matches across marks and substitutes in place")
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

        let nl = allowedSplits("a\nb")
        c.expectEqual(nl.count, 1, "one interior break in a\\nb")
        c.expectEqual(nl.first?.0, "a\n", "mandatory break right after \\n")
        c.expectEqual(nl.first?.1, .mandatory, "\\n break is mandatory")

        let crlf = allowedSplits("a\r\nb")
        c.expectEqual(crlf.count, 1, "CR+LF is a single mandatory break")
        c.expectEqual(crlf.first?.1, .mandatory, "CR+LF break is mandatory")

        c.expectEqual(allowedSplits("a\u{2028}b").count, 1, "U+2028 line separator produces a break")
        c.expectEqual(allowedSplits("a\u{2028}b").first?.1, .mandatory, "U+2028 is mandatory")
        c.expectEqual(allowedSplits("a\u{2029}b").count, 1, "U+2029 paragraph separator produces a break")
        c.expectEqual(allowedSplits("a\u{2029}b").first?.1, .mandatory, "U+2029 is mandatory")

        c.expect(allowedSplits("foo\u{00A0}bar").isEmpty, "NBSP prevents a line break")
        c.expect(allowedSplits("foo\u{202F}bar").isEmpty, "narrow NBSP prevents a line break")
        c.expect(allowedSplits("foo\u{2060}bar").isEmpty, "word joiner prevents a line break")

        c.expectEqual(allowedSplits("self-contained").map(\.0), ["self-"], "self-contained breaks after the hyphen")
        c.expect(allowedSplits("-42").isEmpty, "-42 stays together")
        c.expectEqual(allowedSplits("temp -42").map(\.0), ["temp "], "temp -42 breaks after the space, not after the minus")

        c.expectEqual(allowedSplits("alpha\u{2014}beta").map(\.0), ["alpha\u{2014}"], "em dash allows a break after")
        c.expectEqual(allowedSplits("src/text/break").map(\.0), ["src/", "src/text/"], "slash allows a break after")
        c.expectEqual(allowedSplits("super\u{200B}long").map(\.0), ["super\u{200B}"], "zero-width space allows a break after")

        c.expectEqual(allowedSplits("(hello), world!").map(\.0), ["(hello), "],
                      "opening '(' and closing '),!' stay attached to the word")

        c.expectEqual(allowedSplits("日本語テスト").count, 5, "6 CJK characters have 5 interior break opportunities")
        c.expectEqual(allowedSplits("「日本語」").map(\.0), ["「日", "「日本"], "opening 「 and closing 」 stay attached")
        c.expectEqual(allowedSplits("Hello世界").map(\.0), ["Hello", "Hello世"], "breaks at Latin/CJK and CJK/CJK")

        // TextLayout.lines follows those rules.
        let geist = try TextReference.font(root: c.root, "Geist-Regular.otf")

        let helloW = TextLayout.width(TextLayout.line("hello foo", font: geist, pixelSize: 13))
        let nbspLines = TextLayout.lines("hello foo\u{00A0}bar", font: geist, pixelSize: 13, maxWidth: helloW + 1)
        c.expectEqual(nbspLines.count, 2, "NBSP keeps foo\\u{00A0}bar together on the second line")
        c.expectEqual(nbspLines[0].glyphs.count, 5, "first line is 'hello' (5 glyphs)")
        c.expectEqual(nbspLines[1].glyphs.count, 7, "second line is 'foo\\u{00A0}bar' (7 glyphs)")

        let tempDashW = TextLayout.width(TextLayout.line("temp -", font: geist, pixelSize: 13))
        let negLines = TextLayout.lines("temp -42", font: geist, pixelSize: 13, maxWidth: tempDashW + 1)
        c.expectEqual(negLines.count, 2, "a negative number wraps as a unit")
        c.expectEqual(negLines[0].glyphs.count, 4, "first line is 'temp'")
        c.expectEqual(negLines[1].glyphs.count, 3, "second line is '-42'")

        let singleCJKW = TextLayout.width(TextLayout.line("日", font: geist, pixelSize: 13))
        let cjkLines = TextLayout.lines("日本語テスト", font: geist, pixelSize: 13, maxWidth: singleCJKW * 2.5)
        c.expectEqual(cjkLines.count, 3, "6 CJK characters at 2.5 characters wide wrap into 3 lines of 2")
        c.expect(cjkLines.allSatisfy { $0.glyphs.count == 2 }, "each CJK line holds 2 glyphs")

        // Existing behaviours: explicit breaks, hyphen breaks, ellipsis.
        c.expectEqual(TextLayout.lines("one\ntwo\n", font: geist, pixelSize: 13).count, 3,
                      "explicit line breaks, with an empty last line")
        c.expectEqual(TextLayout.lines("well-known fact", font: geist, pixelSize: 13, maxWidth: 40).first?.glyphs.count, 5,
                      "well-known breaks after the hyphen")
        let limited = TextLayout.lines("Incomprehensibilities", font: geist, pixelSize: 13, maxWidth: 40, lineLimit: 2)
        c.expectEqual(limited.count, 2, "lineLimit 2 keeps two lines")
        c.expect(limited.last?.truncated == true, "the last limited line ends in an ellipsis")
    },

    Check("text.fallback") { c in
        let geist = try TextReference.font(root: c.root, "Geist-Regular.otf")
        let inter = try TextReference.font(root: c.root, "Inter-Regular.otf")
        let mono = try TextReference.font(root: c.root, "JetBrainsMono-Regular.ttf")

        // Assumptions about the fixtures, checked before relying on them.
        c.expectEqual(geist.glyph(for: "\u{0114}"), 0, "Geist lacks U+0114")
        c.expect(inter.glyph(for: "\u{0114}") != 0, "Inter has U+0114")
        c.expectEqual(geist.glyph(for: "\u{211D}"), 0, "Geist lacks U+211D")
        c.expectEqual(inter.glyph(for: "\u{211D}"), 0, "Inter lacks U+211D")
        c.expect(mono.glyph(for: "\u{211D}") != 0, "JetBrainsMono has U+211D")

        let chain = FontFallbackChain([geist, inter, mono])

        if let r = chain.resolveIndex(scalar: "A") {
            c.expectEqual(r.faceIndex, 0, "'A' resolves from the primary face")
            c.expect(r.glyphID != 0, "'A' has a non-zero glyph")
        } else {
            c.fail("resolveIndex failed for 'A'")
        }
        if let r = chain.resolveIndex(scalar: "\u{0114}") {
            c.expectEqual(r.faceIndex, 1, "'Ĕ' resolves from fallback 1")
        } else {
            c.fail("resolveIndex failed for 'Ĕ'")
        }
        if let r = chain.resolveIndex(scalar: "\u{211D}") {
            c.expectEqual(r.faceIndex, 2, "'ℝ' resolves from fallback 2")
        } else {
            c.fail("resolveIndex failed for 'ℝ'")
        }
        if let r = chain.resolve(scalar: "\u{6F22}") {
            c.expect(r.face === geist, "a glyph no face has falls back to the primary face")
            c.expectEqual(r.glyphID, 0, "a missing glyph is .notdef (0)")
        } else {
            c.fail("resolve returned nil on a non-empty chain")
        }
        c.expect(FontFallbackChain([]).resolveIndex(scalar: "A") == nil, "an empty chain resolves nothing")

        // Contiguous runs with continuous advances and original clusters.
        let sample = "Hi \u{0114}\u{211D} ok"
        let runs = chain.shape(sample, size: 14)
        c.expectEqual(runs.map(\.faceIndex), [0, 1, 2, 0], "minimal contiguous face runs")
        c.expectEqual(runs.map(\.text), ["Hi ", "\u{0114}", "\u{211D}", " ok"], "run text slices")

        var prevEndX = 0.0
        var prevX = -1.0
        var clusters: [Int] = []
        for (idx, run) in runs.enumerated() {
            c.expect(!run.glyphs.isEmpty, "run \(idx) has glyphs")
            if let first = run.glyphs.first {
                c.expectClose(first.x, prevEndX, tolerance: 1e-6, "run \(idx) starts where the previous one ended")
            }
            for g in run.glyphs {
                c.expect(g.x > prevX, "glyph x advances monotonically (\(g.x) > \(prevX))")
                prevX = g.x
                clusters.append(g.cluster)
            }
            if let last = run.glyphs.last { prevEndX = last.x + last.advance }
        }
        c.expectEqual(clusters, Array(0..<sample.unicodeScalars.count), "clusters are original scalar indices")

        // GSUB inside a run (Inter raises the colon between digits).
        let interChain = FontFallbackChain([inter, mono])
        let shaped = interChain.shape("3:42 \u{211D}", size: 13)
        c.expectEqual(shaped.count, 2, "two runs for '3:42 ℝ'")
        c.expectEqual(shaped[0].faceIndex, 0, "the first run uses Inter")
        c.expectEqual(shaped[1].faceIndex, 1, "the second run uses JetBrainsMono")
        c.expect(shaped[0].glyphs.count == 5 && shaped[0].glyphs[1].glyph != inter.glyph(for: ":"),
                 "the contextual colon is preserved inside the primary run")
    },

    Check("text.variable-font") { c in
        let fvar = SyntheticOpenType.buildFvar()
        let avar = SyntheticOpenType.buildAvar()
        let gvar = SyntheticOpenType.buildGvar()

        guard let vf = VariableFontTable(fvarData: fvar, avarData: avar, gvarData: gvar) else {
            c.fail("failed to parse synthetic fvar/avar/gvar tables")
            return
        }

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
        c.expect(vf.axes[1].isHidden, "the hidden-axis flag is parsed")

        c.expectEqual(vf.instances.count, 2, "2 named instances")
        c.expectEqual(vf.instances[1].coordinates, [700, 100], "Bold instance coordinates")
        c.expectEqual(vf.instances[1].postScriptNameID, 261, "Bold postScriptNameID")

        let wght = vf.axes[0]
        c.expectClose(VariableFontTable.normalizeCoordinate(400, axis: wght), 0, tolerance: 1e-6, "default -> 0")
        c.expectClose(VariableFontTable.normalizeCoordinate(100, axis: wght), -1, tolerance: 1e-6, "min -> -1")
        c.expectClose(VariableFontTable.normalizeCoordinate(900, axis: wght), 1, tolerance: 1e-6, "max -> 1")
        c.expectClose(VariableFontTable.normalizeCoordinate(50, axis: wght), -1, tolerance: 1e-6, "clamped below min")
        c.expectClose(VariableFontTable.normalizeCoordinate(1200, axis: wght), 1, tolerance: 1e-6, "clamped above max")
        c.expectClose(VariableFontTable.normalizeCoordinate(650, axis: wght), 0.5, tolerance: 1e-6, "linear midpoint")

        let nMid = vf.normalize(VariationCoordinates(["wght": 650, "wdth": 112.5]))
        c.expectClose(nMid[0], 0.25, tolerance: 1e-4, "avar maps raw 0.5 -> 0.25")
        c.expectClose(nMid[1], 0.5, tolerance: 1e-4, "the wdth identity map keeps 112.5 -> 0.5")

        let nUpper = vf.normalize(VariationCoordinates(["wght": 775]))
        c.expectClose(nUpper[0], 0.625, tolerance: 1e-4, "avar interpolates raw 0.75 -> 0.625")
        c.expectClose(nUpper[1], 0, tolerance: 1e-6, "an unspecified axis defaults to 0")

        c.expectClose(VariableFontTable.tupleScalar(peak: [1, 0], coordinates: [0.5, 0.8]), 0.5, tolerance: 1e-6,
                      "simple positive peak scalar")
        c.expectClose(VariableFontTable.tupleScalar(peak: [1, 0], coordinates: [-0.5, 0]), 0, tolerance: 1e-6,
                      "opposite sign gives 0")
        c.expectClose(VariableFontTable.tupleScalar(peak: [-1], coordinates: [-0.4]), 0.4, tolerance: 1e-6,
                      "negative peak scalar")
        c.expectClose(VariableFontTable.tupleScalar(peak: [0.5], start: [0], end: [1], coordinates: [0.25]),
                      0.5, tolerance: 1e-6, "intermediate region rising slope")
        c.expectClose(VariableFontTable.tupleScalar(peak: [0.5], start: [0], end: [1], coordinates: [0.5]),
                      1, tolerance: 1e-6, "intermediate region peak")
        c.expectClose(VariableFontTable.tupleScalar(peak: [0.5], start: [0], end: [1], coordinates: [0.75]),
                      0.5, tolerance: 1e-6, "intermediate region falling slope")
        c.expectClose(VariableFontTable.tupleScalar(peak: [1, 1], coordinates: [0.5, 0.5]), 0.25, tolerance: 1e-6,
                      "multi-axis tuple scalar is a product")

        // One contour: p0 and p2 touched (dx 0 and 20), p1 and p3 interpolated.
        let pts = [
            Point(x: 0, y: 0),
            Point(x: 50, y: 0),
            Point(x: 100, y: 0),
            Point(x: 120, y: 100),
        ]
        let varied = vf.applyGlyphVariations(glyphID: 0, to: pts, contourEndIndices: [3], normalizedCoordinates: [0.5, 0])
        c.expectClose(varied[0].x, 0, tolerance: 1e-6, "gvar touched p0.x")
        c.expectClose(varied[1].x, 55, tolerance: 1e-6, "gvar IUP interpolated p1.x")
        c.expectClose(varied[2].x, 110, tolerance: 1e-6, "gvar touched p2.x")
        c.expectClose(varied[3].x, 130, tolerance: 1e-6, "gvar IUP clamped p3.x")
        c.expectClose(varied[3].y, 100, tolerance: 1e-6, "gvar untouched p3.y is unchanged")

        let shifted = VariableFontTable.applySparseDeltas(
            to: pts, contourEndIndices: [3], touchedDeltas: [0: (dx: 10, dy: -4)], scalar: 1
        )
        c.expectClose(shifted[2].x, 110, tolerance: 1e-6, "one touched point shifts the whole contour in x")
        c.expectClose(shifted[2].y, -4, tolerance: 1e-6, "one touched point shifts the whole contour in y")

        let dense = VariableFontTable.applyDeltas(to: [Point(x: 10, y: 20)], deltas: [(dx: 8, dy: -4)], scalar: 0.25)
        c.expectClose(dense[0].x, 12, tolerance: 1e-6, "dense applyDeltas x")
        c.expectClose(dense[0].y, 19, tolerance: 1e-6, "dense applyDeltas y")

        // Malformed data parses to nil rather than crashing.
        c.expect(VariableFontTable(fvarData: [0, 1, 2, 3]) == nil, "a truncated fvar parses to nil")
        c.expect(GVARTable(data: [1, 0, 2]) == nil, "a truncated gvar parses to nil")

        // A face without fvar has no variable-font table.
        let geist = try TextReference.font(root: c.root, "Geist-Regular.otf")
        c.expect(geist.variableFont == nil, "a static face has no fvar")
    },

    Check("text.color-emoji") { c in
        let red = Color(hex: 0xE63946)
        let gold = Color(hex: 0xFFB703)
        let blue = Color(hex: 0x219EBC)
        let greenHalf = Color(hex: 0x2A9D8F, opacity: 0.5)
        let teal = Color(hex: 0x00B4D8)
        let amber = Color(hex: 0xF77F00)
        let slate = Color(hex: 0x4A5759)
        let crimson = Color(hex: 0xD62828)

        let palettes: [[Color]] = [
            [red, gold, blue, greenHalf],
            [teal, amber, slate, crimson],
        ]
        // Out of order on purpose: the builder sorts, the lookup binary-searches.
        let glyphSpecs: [(baseGlyphID: UInt16, layers: [ColorGlyphLayer])] = [
            (300, [
                ColorGlyphLayer(glyphID: 301, paletteEntryIndex: 2),
                ColorGlyphLayer(glyphID: 302, paletteEntryIndex: CPALTable.foregroundEntryIndex),
            ]),
            (100, [
                ColorGlyphLayer(glyphID: 101, paletteEntryIndex: 0),
                ColorGlyphLayer(glyphID: 102, paletteEntryIndex: 1),
                ColorGlyphLayer(glyphID: 103, paletteEntryIndex: CPALTable.foregroundEntryIndex),
            ]),
            (200, [
                ColorGlyphLayer(glyphID: 201, paletteEntryIndex: 0),
                ColorGlyphLayer(glyphID: 202, paletteEntryIndex: 1),
                ColorGlyphLayer(glyphID: 203, paletteEntryIndex: 2),
                ColorGlyphLayer(glyphID: 204, paletteEntryIndex: 3),
            ]),
        ]

        let tables = ColorGlyphTable.buildSyntheticTables(palettes: palettes, glyphs: glyphSpecs)
        guard let colorTable = ColorGlyphTable(colrData: tables.colr, cpalData: tables.cpal) else {
            c.fail("failed to parse synthetic COLR/CPAL tables")
            return
        }

        let cpal = colorTable.cpal
        c.expectEqual(cpal.version, 0, "CPAL version 0")
        c.expectEqual(cpal.numPalettes, 2, "CPAL palette count")
        c.expectEqual(cpal.numPaletteEntries, 4, "CPAL entries per palette")
        c.expectEqual(cpal.numColorRecords, 8, "CPAL total color records")

        if let p0e0 = cpal.color(paletteIndex: 0, entryIndex: 0) {
            c.expectClose(p0e0.red, red.red, tolerance: 1.0 / 255.0, "palette 0 entry 0 red")
            c.expectClose(p0e0.green, red.green, tolerance: 1.0 / 255.0, "palette 0 entry 0 green")
            c.expectClose(p0e0.blue, red.blue, tolerance: 1.0 / 255.0, "palette 0 entry 0 blue")
            c.expectClose(p0e0.opacity, 1, tolerance: 1.0 / 255.0, "palette 0 entry 0 alpha")
        } else {
            c.fail("palette 0 entry 0 missing")
        }
        if let p0e3 = cpal.color(paletteIndex: 0, entryIndex: 3) {
            c.expectClose(p0e3.opacity, 0.5, tolerance: 1.0 / 255.0, "a semi-transparent BGRA alpha is preserved")
        } else {
            c.fail("palette 0 entry 3 missing")
        }
        if let p1e1 = cpal.color(paletteIndex: 1, entryIndex: 1) {
            c.expectClose(p1e1.red, amber.red, tolerance: 1.0 / 255.0, "palette 1 entry 1 red")
            c.expectClose(p1e1.green, amber.green, tolerance: 1.0 / 255.0, "palette 1 entry 1 green")
            c.expectClose(p1e1.blue, amber.blue, tolerance: 1.0 / 255.0, "palette 1 entry 1 blue")
        } else {
            c.fail("palette 1 entry 1 missing")
        }

        c.expectEqual(cpal.color(paletteIndex: 0, entryIndex: 0xFFFF), nil, "0xFFFF is not a palette color")
        c.expectEqual(cpal.color(paletteIndex: 2, entryIndex: 0), nil, "an out-of-range palette gives nil")
        c.expectEqual(cpal.color(paletteIndex: 0, entryIndex: 4), nil, "an out-of-range entry gives nil")

        let customFG = Color(hex: 0x00FF88)
        c.expectEqual(cpal.resolveColor(paletteIndex: 0, entryIndex: CPALTable.foregroundEntryIndex, foreground: customFG),
                      customFG, "0xFFFF resolves to the foreground color")

        let colr = colorTable.colr
        c.expectEqual(colr.version, 0, "COLR version 0")
        c.expectEqual(colr.numBaseGlyphRecords, 3, "COLR base glyph count")
        c.expectEqual(colr.numLayerRecords, 9, "COLR total layer count")
        c.expectEqual(colr.baseGlyphRecords.map(\.glyphID), [100, 200, 300], "base glyph records are sorted")

        c.expectEqual(colr.layers(for: 50), nil, "a glyph below the range has no layers")
        c.expectEqual(colr.layers(for: 150), nil, "a glyph inside the range but absent has no layers")
        c.expectEqual(colr.layers(for: 999), nil, "a glyph above the range has no layers")

        c.expectEqual(colr.layers(for: 100)?.count, 3, "glyph 100 has 3 layers")
        c.expectEqual(colr.layers(for: 100)?.last?.usesForegroundColor, true, "the top layer of glyph 100 uses the foreground")
        c.expectEqual(colr.layers(for: 200)?.count, 4, "glyph 200 has 4 layers")
        c.expectEqual(colr.layers(for: 300)?.count, 2, "glyph 300 has 2 layers")

        guard let p0 = colorTable.resolvedLayers(for: 100, palette: 0, foreground: customFG),
              let p1 = colorTable.resolvedLayers(for: 100, palette: 1, foreground: .white) else {
            c.fail("resolvedLayers failed for base glyph 100")
            return
        }
        c.expectEqual(p0.count, 3, "resolved palette 0 layer count")
        c.expectEqual(p0[2].color, customFG, "the foreground layer uses the custom color")
        c.expectEqual(p1[2].color, .white, "the foreground layer follows the requested foreground")
        c.expect(p0[0].color != p1[0].color, "switching palette changes the base layer color")

        // Malformed tables parse to nil.
        c.expect(CPALTable(data: [0, 0, 0]) == nil, "a truncated CPAL parses to nil")
        c.expect(COLRTable(data: [0, 0]) == nil, "a truncated COLR parses to nil")

        // A face without COLR/CPAL has no color glyph table.
        let geist = try TextReference.font(root: c.root, "Geist-Regular.otf")
        c.expect(geist.colorGlyphTable == nil, "a plain face has no color glyph table")
    },
]
