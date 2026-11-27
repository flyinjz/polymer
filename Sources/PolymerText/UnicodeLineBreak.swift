// Pure-Swift UAX #14 Unicode Line Breaking engine.
// Determines mandatory, allowed, and prohibited line-break opportunities
// across scripts (Latin, punctuation, glue/joiners, hyphens, CJK/ideographic).

public enum UnicodeLineBreak {
    /// Whether a line break at a boundary is mandatory, allowed, or prohibited.
    public enum BreakOpportunity: Equatable, Hashable, Sendable {
        case mandatory
        case allowed
        case prohibited
    }

    /// Key UAX #14 line breaking classes.
    public enum LineBreakClass: Equatable, Hashable, Sendable {
        case BK   // Mandatory break (VT, FF, NEL, LS, PS)
        case CR   // Carriage return
        case LF   // Line feed
        case SP   // Space
        case GL   // Glue / non-breaking space (NBSP, NNBSP)
        case WJ   // Word joiner
        case ZW   // Zero-width space
        case BA   // Break after (tab, en/em dash, slash, soft hyphen)
        case HY   // Hyphen-minus '-'
        case OP   // Opening punctuation
        case CL   // Closing punctuation
        case CP   // Closing parenthesis / bracket
        case EX   // Exclamation / interrogation
        case NS   // Nonstarters (small kana, iteration marks)
        case ID   // Ideographic (CJK, Hiragana, Katakana, Hangul, fullwidth, emoji)
        case AL   // Alphabetic / ordinary characters
        case NU   // Numeric digits
        case PR   // Prefix numeric (currency, '+')
        case PO   // Postfix numeric ('%', degree)
        case CM   // Combining marks (attach to previous)
    }

    /// Classifies a single `Unicode.Scalar` into its `LineBreakClass`.
    public static func lineBreakClass(for scalar: Unicode.Scalar) -> LineBreakClass {
        let v = scalar.value
        switch v {
        // Mandatory breaks
        case 0x000A:
            return .LF
        case 0x000D:
            return .CR
        case 0x000B, 0x000C, 0x0085, 0x2028, 0x2029:
            return .BK

        // Spaces and joiners
        case 0x0020:
            return .SP
        case 0x200B:
            return .ZW
        case 0x2060, 0xFEFF:
            return .WJ
        case 0x00A0, 0x2007, 0x202F, 0x0F0C, 0x180E:
            return .GL

        // Hyphen-minus and break-after characters
        case 0x002D:
            return .HY
        case 0x0009, 0x002F, 0x007C, 0x00AD,
             0x2000...0x2006, 0x2008...0x200A,
             0x2010, 0x2012, 0x2013, 0x2014:
            return .BA

        // Opening punctuation
        case 0x0028, 0x005B, 0x007B,           // ( [ {
             0x00A1, 0x00AB, 0x00BF,           // ¡ « ¿
             0x2018, 0x201A, 0x201C, 0x201E,   // ‘ ‚ “ „
             0x2039,                           // ‹
             0x3008, 0x300A, 0x300C, 0x300E,   // 〈 《 「 『
             0x3010, 0x3014, 0x3016, 0x3018,   // 【 〔 〖 〘
             0x301A, 0x301D,                   // 〚 〝
             0xFF08, 0xFF3B, 0xFF5B, 0xFF5F, 0xFF62:
            return .OP

        // Closing parenthesis / bracket
        case 0x0029, 0x005D:                   // ) ]
            return .CP

        // Closing punctuation
        case 0x002C, 0x002E, 0x003A, 0x003B,   // , . : ;
             0x007D, 0x00BB,                   // } »
             0x2019, 0x201D, 0x203A,           // ’ ” ›
             0x3001, 0x3002,                   // 、 。
             0x3009, 0x300B, 0x300D, 0x300F,   // 〉 》 」 』
             0x3011, 0x3015, 0x3017, 0x3019,   // 】 〕 〗 〙
             0x301B, 0x301E, 0x301F,           // 〛 〞 〟
             0xFF09, 0xFF0C, 0xFF0E, 0xFF1A, 0xFF1B,
             0xFF3D, 0xFF5D, 0xFF60, 0xFF63:
            return .CL

        // Exclamation / interrogation
        case 0x0021, 0x003F,                   // ! ?
             0x203C, 0x203D, 0x2047...0x2049,
             0xFF01, 0xFF1F:
            return .EX

        // Nonstarters (small kana, iteration marks, prolonged sound mark)
        case 0x3005, 0x301C, 0x303B, 0x303C,
             0x3041, 0x3043, 0x3045, 0x3047, 0x3049, 0x3063,
             0x3083, 0x3085, 0x3087, 0x308E, 0x3095, 0x3096,
             0x309B...0x309E,
             0x30A1, 0x30A3, 0x30A5, 0x30A7, 0x30A9, 0x30C3,
             0x30E3, 0x30E5, 0x30E7, 0x30EE, 0x30F5, 0x30F6,
             0x30FB...0x30FE:
            return .NS

        // Prefix numeric
        case 0x0023, 0x0024, 0x002B, 0x005C,
             0x00A2, 0x00A3, 0x00A5, 0x00B1,
             0x20A0...0x20CF:
            return .PR

        // Postfix numeric
        case 0x0025, 0x00B0, 0x2030...0x2037:
            return .PO

        // Digits
        case 0x0030...0x0039:
            return .NU

        // Combining marks and variation selectors
        case 0x0300...0x036F, 0x1AB0...0x1AFF, 0x1DC0...0x1DFF,
             0x200D, 0x20D0...0x20FF, 0xFE00...0xFE0F,
             0xFE20...0xFE2F, 0xE0100...0xE01EF:
            return .CM

        // CJK, Kana, Hangul, fullwidth forms, emoji/pictographs
        case 0x2600...0x27BF,
             0x2E80...0x2FDF,
             0x3000...0x303F,
             0x3040...0x30FF,
             0x3100...0x33FF,
             0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xA000...0xA4CF,
             0xAC00...0xD7AF,
             0xF900...0xFAFF,
             0xFF00...0xFFEF,
             0x1F000...0x1FAFF,
             0x20000...0x2EBEF:
            return .ID

        default:
            return .AL
        }
    }

    /// Whether a break-after dash/hyphen stays glued to a following digit (e.g. `-42`, `–5`).
    @inline(__always)
    private static func isNumericGluedHyphen(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return v == 0x002D || v == 0x2010 || v == 0x2012 || v == 0x2013
    }

    /// Computes break opportunities before each scalar in `scalars`.
    /// Result has count `scalars.count`; index `0` is always `.prohibited` (LB2: never break at start of text),
    /// and index `k` (`1 <= k < scalars.count`) is the break opportunity between `scalars[k - 1]` and `scalars[k]`.
    public static func breakOpportunities(in scalars: [Unicode.Scalar]) -> [BreakOpportunity] {
        let n = scalars.count
        guard n > 0 else { return [] }
        var classes: [LineBreakClass] = []
        classes.reserveCapacity(n)
        for s in scalars { classes.append(lineBreakClass(for: s)) }

        var result = [BreakOpportunity](repeating: .prohibited, count: n)
        // Track effective previous class (absorbing CM per LB9) and last non-SP class (for OP SP* / ZW SP*).
        var prevEffective: LineBreakClass = classes[0] == .CM ? .AL : classes[0]
        var prevEffectiveScalar: Unicode.Scalar = scalars[0]
        var prevNonSP: LineBreakClass = classes[0] == .CM ? .AL : classes[0]

        for k in 1..<n {
            let prevRaw = classes[k - 1]
            let curr = classes[k]
            let opp: BreakOpportunity

            // LB4 / LB5: Mandatory breaks after BK, LF, CR (except CR x LF).
            if prevRaw == .BK || prevRaw == .LF {
                opp = .mandatory
            } else if prevRaw == .CR {
                opp = (curr == .LF) ? .prohibited : .mandatory
            }
            // LB6: Do not break before hard line breaks.
            else if curr == .BK || curr == .CR || curr == .LF {
                opp = .prohibited
            }
            // LB7: Do not break before spaces or zero-width space.
            else if curr == .SP || curr == .ZW {
                opp = .prohibited
            }
            // LB8: Break before any character following ZW (even with intervening spaces).
            else if prevRaw == .ZW || (prevRaw == .SP && prevNonSP == .ZW) {
                opp = .allowed
            }
            // LB9: Do not break a combining character sequence (except after break/space/ZW).
            else if curr == .CM && prevRaw != .SP {
                opp = .prohibited
            }
            // LB11: Do not break before or after Word Joiner.
            else if curr == .WJ || prevEffective == .WJ {
                opp = .prohibited
            }
            // LB12 / GL: Do not break before or after NBSP / glue.
            else if curr == .GL || prevEffective == .GL {
                opp = .prohibited
            }
            // LB13: Do not break before closing punctuation, exclamation, or nonstarters.
            else if curr == .CL || curr == .CP || curr == .EX || curr == .NS {
                opp = .prohibited
            }
            // LB14: Do not break after opening punctuation, even after spaces.
            else if prevEffective == .OP || (prevRaw == .SP && prevNonSP == .OP) {
                opp = .prohibited
            }
            // LB18: Break after spaces.
            else if prevRaw == .SP {
                opp = .allowed
            }
            // LB21: Do not break before HY or BA.
            else if curr == .HY || curr == .BA {
                opp = .prohibited
            }
            // LB21 / LB25: Break after HY or BA, except hyphen before digits (keeps -42 intact).
            else if prevEffective == .HY || prevEffective == .BA {
                if curr == .NU && isNumericGluedHyphen(prevEffectiveScalar) {
                    opp = .prohibited
                } else {
                    opp = .allowed
                }
            }
            // LB24 / LB25: Keep prefix/postfix attached to numbers/words.
            else if prevEffective == .PR && (curr == .NU || curr == .AL || curr == .OP) {
                opp = .prohibited
            } else if curr == .PO && (prevEffective == .NU || prevEffective == .AL) {
                opp = .prohibited
            }
            // Ideographic / CJK breaks: allow between ID and ID/AL/NU/OP/PR/CL/CP/EX/PO/NS.
            else if prevEffective == .ID || curr == .ID {
                opp = .allowed
            } else {
                opp = .prohibited
            }

            result[k] = opp

            // Update state for next boundary.
            if curr == .CM {
                // LB9: CM attaches transparently to previous non-break/space/ZW base.
                if prevRaw == .BK || prevRaw == .CR || prevRaw == .LF || prevRaw == .SP || prevRaw == .ZW {
                    prevEffective = .AL
                    prevEffectiveScalar = scalars[k]
                    prevNonSP = .AL
                }
            } else {
                prevEffective = curr
                prevEffectiveScalar = scalars[k]
                if curr != .SP {
                    prevNonSP = curr
                }
            }
        }
        return result
    }

    /// Returns all line-break opportunities in `text` at scalar boundaries and at `text.endIndex`.
    /// Each entry's `index` is the split point (`text[..<index]` before the break, `text[index...]` after).
    public static func breaks(in text: String) -> [(index: String.Index, kind: BreakOpportunity)] {
        let view = text.unicodeScalars
        let n = view.count
        guard n > 0 else { return [] }

        var scalars: [Unicode.Scalar] = []
        var indices: [String.Index] = []
        scalars.reserveCapacity(n)
        indices.reserveCapacity(n)
        var idx = view.startIndex
        while idx < view.endIndex {
            scalars.append(view[idx])
            indices.append(idx)
            idx = view.index(after: idx)
        }

        let opps = breakOpportunities(in: scalars)
        var out: [(index: String.Index, kind: BreakOpportunity)] = []
        out.reserveCapacity(n)
        for k in 1..<n {
            out.append((index: indices[k], kind: opps[k]))
        }
        // LB3: Always break at the end of text.
        out.append((index: text.endIndex, kind: .mandatory))
        return out
    }
}
