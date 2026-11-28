// Title casing, cleanup rules, artist spelling groups and album health.
// Ported from Meimei's Core/MetadataTools.swift. CaseStyle, FeatStyle and
// CleanupRules live in SettingsData.swift. Differences:
//  - the two NSRegularExpressions are a small backtracking matcher below
//    with ICU's meaning of \s, \d, \b and $ and its case-insensitive
//    matching of the (ASCII) pattern letters.
//  - ArtistSpellings.key folds case with stdlib lowercasing, accents with a
//    Latin-1 / Latin Extended-A table plus dropping combining marks, and
//    width for the fullwidth ASCII forms (Foundation's folding covers more).
//  - spelling groups sort with naturalCompare, then by key, so equal
//    suggestions never depend on dictionary order.
import PolymerBase

// MARK: - Capitalization

/// Music-aware capitalization. Leaves alone what was written on purpose:
/// acronyms and Roman numerals (DJ, NYC, II), mixed-case names (iPhone,
/// McCartney, deadmau5), and anything with digits. Small words stay lower
/// inside a title, but not first, last, or after a colon, dash, or bracket.
public enum TitleCaser {
    /// MusicBrainz's English capitalization standard's lowercase words.
    public static let smallWords: Set<String> = [
        "a", "an", "and", "as", "at", "but", "by", "en", "for", "if", "in", "nor", "n", "o",
        "of", "on", "or", "per", "the", "to", "v", "vs", "via",
    ]
    /// Always lowercase, even first in a bracket: "(feat. X)".
    public static let featWords: Set<String> = ["feat", "ft", "featuring"]
    public static let acronyms: Set<String> = [
        "dj", "mc", "ep", "lp", "uk", "us", "usa", "nyc", "la", "tv", "ok", "ufo", "rip", "mtv", "bbc", "edm", "r&b", "a&r",
        "ii", "iii", "iv", "vi", "vii", "viii", "ix", "xi", "xii", "xiii", "xiv", "xv", "xx", "id", "vip", "aka",
    ]

    public static func apply(_ text: String, style: CaseStyle) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        // An all-caps title says nothing about which words are acronyms.
        let letters = text.filter(\.isLetter)
        let shouting = letters.count > 3 && letters == letters.uppercased() && words.count > 1
        var out: [String] = []
        var startsPhrase = true
        // Featured names are names: kept as written up to the bracket's end.
        var inFeat = false
        for (i, word) in words.enumerated() {
            guard !word.isEmpty else { out.append(word); continue }
            if inFeat {
                out.append(word)
                if word.last.map({ ")]".contains($0) }) == true { inFeat = false }
                continue
            }
            let bare = TextTools.trimming(word, TextTools.isPunctuation).lowercased()
            if i > 0, featWords.contains(bare) {
                out.append(word.lowercased())
                inFeat = true
                continue
            }
            let isLast = i == words.count - 1
            out.append(caseWord(word, style: style, startsPhrase: startsPhrase, isLast: isLast, shouting: shouting))
            startsPhrase = word.last.map { ":-–—([{/".contains($0) } ?? false || word == "-" || word == "–" || word == "—"
            if word.first.map({ "([{".contains($0) }) == true, word.count == 1 { startsPhrase = true }
        }
        return out.joined(separator: " ")
    }

    private static func caseWord(_ word: String, style: CaseStyle, startsPhrase: Bool, isLast: Bool, shouting: Bool) -> String {
        // Opening punctuation starts a phrase of its own: "(remix)" -> "(Remix)".
        let lead = String(word.prefix { "([{\"'“‘".contains($0) })
        let core = String(word.dropFirst(lead.count))
        let opensPhrase = startsPhrase || lead.contains { "([{".contains($0) }
        guard !core.isEmpty else { return word }
        // Hyphenated words case each part.
        if core.contains("-"), core.count > 2 {
            let parts = core.split(separator: "-", omittingEmptySubsequences: false).enumerated().map { j, part in
                caseWord(String(part), style: style, startsPhrase: opensPhrase && j == 0, isLast: isLast, shouting: shouting)
            }
            return lead + parts.joined(separator: "-")
        }
        let bare = TextTools.trimming(core, TextTools.isPunctuation).lowercased()
        if keepsAsWritten(core, bare: bare, shouting: shouting) { return word }
        let lower = core.lowercased()
        let capital: Bool
        switch style {
        case .title: capital = opensPhrase || isLast || !smallWords.contains(bare)
        case .sentence: capital = opensPhrase || bare == "i" || bare.hasPrefix("i'")
        }
        if acronyms.contains(bare) { return lead + core.uppercased() }
        if featWords.contains(bare) { return lead + lower }
        return lead + (capital ? capitalizeFirstLetter(lower) : lower)
    }

    private static func keepsAsWritten(_ core: String, bare: String, shouting: Bool) -> Bool {
        if core.contains(where: \.isNumber) { return true }
        let letters = core.filter(\.isLetter)
        guard !letters.isEmpty else { return true }
        // Capitals after the first letter: iPhone, McCartney, DJ, NYC.
        let rest = letters.dropFirst()
        if !shouting, rest.contains(where: \.isUppercase),
           rest.contains(where: \.isLowercase) || letters.first?.isLowercase == true { return true }
        if !shouting, letters.count >= 2, letters == letters.uppercased() { return true }
        if core.contains("."), core.filter({ $0 == "." }).count >= 2 { return true } // A.D., U.S.A.
        return false
    }

    private static func capitalizeFirstLetter(_ s: String) -> String {
        guard let i = s.firstIndex(where: \.isLetter) else { return s }
        return String(s[..<i]) + s[i].uppercased() + String(s[s.index(after: i)...])
    }
}

// MARK: - Cleanup

public enum MetadataCleanup {
    /// A title (track or album) with the rules applied.
    public static func title(_ s: String, _ rules: CleanupRules) -> String {
        var t = s
        if rules.tidySpaces { t = tidy(t) }
        if rules.straightQuotes { t = straighten(t) }
        if rules.removeEditionTags { t = removingEditionTags(t) }
        if rules.feat != .asIs { t = featuring(t, rules.feat) }
        if let style = rules.caseStyle { t = TitleCaser.apply(t, style: style) }
        return t
    }

    /// A name (artist, album artist, composer): spaces and quotes only;
    /// names keep their own capitalization.
    public static func name(_ s: String, _ rules: CleanupRules) -> String {
        var t = s
        if rules.tidySpaces { t = tidy(t) }
        if rules.straightQuotes { t = straighten(t) }
        return t
    }

    public static func tidy(_ s: String) -> String {
        var t = TextTools.trimming(s, TextTools.isWhitespaceOrNewline)
        while TextTools.contains(t, "  ") { t = TextTools.replacing(t, "  ", with: " ") }
        for (a, b) in [("( ", "("), (" )", ")"), ("[ ", "["), (" ]", "]")] { t = TextTools.replacing(t, a, with: b) }
        return t
    }

    public static func straighten(_ s: String) -> String {
        var t = TextTools.replacing(s, "’", with: "'")
        t = TextTools.replacing(t, "‘", with: "'")
        t = TextTools.replacing(t, "“", with: "\"")
        return TextTools.replacing(t, "”", with: "\"")
    }

    /// Meimei's pattern, case-insensitive:
    /// \s*[\(\[](?:\d{4}\s+)?(?:digital(?:ly)?\s+)?(?:remaster(?:ed)?|explicit|clean|bonus track|
    /// deluxe(?: edition| version)?|expanded edition|album version)(?:\s+\d{4})?(?:\s+version)?[\)\]]
    private static let editionPattern: Rx = .seq([
        .star(.space), .oneOf("(["),
        .optional(.seq([.count(4, .digit), .plus(.space)])),
        .optional(.seq([.text("digital"), .optional(.text("ly")), .plus(.space)])),
        .alt([
            .seq([.text("remaster"), .optional(.text("ed"))]),
            .text("explicit"), .text("clean"), .text("bonus track"),
            .seq([.text("deluxe"), .optional(.alt([.text(" edition"), .text(" version")]))]),
            .text("expanded edition"), .text("album version"),
        ]),
        .optional(.seq([.plus(.space), .count(4, .digit)])),
        .optional(.seq([.plus(.space), .text("version")])),
        .oneOf(")]"),
    ])

    public static func removingEditionTags(_ s: String) -> String {
        let m = RxMatcher(s)
        var out = String.UnicodeScalarView()
        var kept = 0, from = 0
        while let hit = m.firstMatch(editionPattern, from: from) {
            let lo = hit.0, hi = hit.1
            out.append(contentsOf: m.u[kept..<lo])
            kept = hi
            from = hi > lo ? hi : hi + 1
        }
        if kept == 0 { return TextTools.trimming(s, TextTools.isWhitespace) }
        out.append(contentsOf: m.u[kept...])
        return TextTools.trimming(String(out), TextTools.isWhitespace)
    }

    /// Meimei's pattern, case-insensitive:
    /// \s*[\(\[]?\s*\b(?:feat\.?|ft\.?|featuring)\s+([^\)\]]+?)\s*[\)\]]?\s*$
    private static let featPattern: Rx = .seq([
        .star(.space), .optional(.oneOf("([")), .star(.space), .wordBoundary,
        .alt([
            .seq([.text("feat"), .optional(.oneOf("."))]),
            .seq([.text("ft"), .optional(.oneOf("."))]),
            .text("featuring"),
        ]),
        .plus(.space), .capture(.lazyPlus(.noneOf(")]"))),
        .star(.space), .optional(.oneOf(")]")), .star(.space), .end,
    ])

    /// "Song ft Someone", "Song [Featuring Someone]" -> "Song (feat. Someone)".
    public static func featuring(_ s: String, _ style: FeatStyle) -> String {
        let m = RxMatcher(s)
        guard let hit = m.firstMatch(featPattern, from: 0), let who = m.capture else { return s }
        let head = TextTools.string(m.u[0..<hit.0])
        guard !TextTools.trimming(head, TextTools.isWhitespace).isEmpty else { return s }
        let name = TextTools.trimming(TextTools.string(m.u[who.0..<who.1]), TextTools.isWhitespace)
        return style == .parentheses ? "\(head) (feat. \(name))" : "\(head) feat. \(name)"
    }
}

// MARK: - The pattern matcher

/// A regular expression as a tree; only what the two cleanup patterns use.
private indirect enum Rx: Sendable {
    /// Literal text, matched as ICU's case-insensitive mode does for ASCII letters.
    case text(String)
    case oneOf(String), noneOf(String)
    /// ICU \s and \d.
    case space, digit
    case seq([Rx]), alt([Rx])
    case optional(Rx), star(Rx), plus(Rx), lazyPlus(Rx), count(Int, Rx)
    /// Group 1.
    case capture(Rx)
    /// ICU \b (without UREGEX_UWORD) and $ (without multiline).
    case wordBoundary, end
}

/// Leftmost-first backtracking over the text's scalars (ICU reports UTF-16
/// offsets; the same matches fall out at scalar granularity here).
private final class RxMatcher {
    let u: [Unicode.Scalar]
    private(set) var capture: (Int, Int)?

    init(_ s: String) { u = Array(s.unicodeScalars) }

    /// The first match starting at or after `from`, as scalar offsets.
    func firstMatch(_ p: Rx, from: Int) -> (Int, Int)? {
        guard from <= u.count else { return nil }
        for start in from...u.count {
            capture = nil
            var end = -1
            if run(p, start, { j in end = j; return true }) { return (start, end) }
        }
        return nil
    }

    private func run(_ p: Rx, _ i: Int, _ k: (Int) -> Bool) -> Bool {
        switch p {
        case .text(let t):
            var j = i
            for c in t.unicodeScalars {
                guard j < u.count, Self.fold(u[j]) == c.value else { return false }
                j += 1
            }
            return k(j)
        case .oneOf(let set):
            guard i < u.count, set.unicodeScalars.contains(u[i]) else { return false }
            return k(i + 1)
        case .noneOf(let set):
            guard i < u.count, !set.unicodeScalars.contains(u[i]) else { return false }
            return k(i + 1)
        case .space:
            guard i < u.count, Self.isSpace(u[i]) else { return false }
            return k(i + 1)
        case .digit:
            guard i < u.count, u[i].properties.generalCategory == .decimalNumber else { return false }
            return k(i + 1)
        case .seq(let ps):
            return seq(ps[...], i, k)
        case .alt(let ps):
            for q in ps where run(q, i, k) { return true }
            return false
        case .optional(let q):
            return run(q, i, k) || k(i)
        case .star(let q):
            return star(q, i, k)
        case .plus(let q):
            return run(q, i) { j in self.star(q, j, k) }
        case .lazyPlus(let q):
            return run(q, i) { j in self.lazyStar(q, j, k) }
        case .count(let n, let q):
            return count(n, q, i, k)
        case .capture(let q):
            return run(q, i) { j in
                let before = self.capture
                self.capture = (i, j)
                if k(j) { return true }
                self.capture = before
                return false
            }
        case .wordBoundary:
            return isWordBoundary(i) && k(i)
        case .end:
            return isEnd(i) && k(i)
        }
    }

    private func seq(_ ps: ArraySlice<Rx>, _ i: Int, _ k: (Int) -> Bool) -> Bool {
        guard let first = ps.first else { return k(i) }
        return run(first, i) { j in self.seq(ps.dropFirst(), j, k) }
    }

    private func star(_ q: Rx, _ i: Int, _ k: (Int) -> Bool) -> Bool {
        if run(q, i, { j in j > i && self.star(q, j, k) }) { return true }
        return k(i)
    }

    private func lazyStar(_ q: Rx, _ i: Int, _ k: (Int) -> Bool) -> Bool {
        if k(i) { return true }
        return run(q, i) { j in j > i && self.lazyStar(q, j, k) }
    }

    private func count(_ n: Int, _ q: Rx, _ i: Int, _ k: (Int) -> Bool) -> Bool {
        if n == 0 { return k(i) }
        return run(q, i) { j in self.count(n - 1, q, j, k) }
    }

    /// $: at the end, or before a final line terminator (CRLF counts as one).
    private func isEnd(_ i: Int) -> Bool {
        let n = u.count
        if i == n { return true }
        if i == n - 1 && Self.isLineEnd(u[i]) { return !(u[i] == "\n" && i > 0 && u[i - 1] == "\r") }
        if i == n - 2 && u[i] == "\r" && u[i + 1] == "\n" { return true }
        return false
    }

    private func isWordBoundary(_ i: Int) -> Bool {
        var cur = false
        if i < u.count {
            if Self.isExtendOrFormat(u[i]) { return false }
            cur = Self.isWord(u[i])
        }
        var prev = false, j = i
        while j > 0 {
            j -= 1
            if !Self.isExtendOrFormat(u[j]) { prev = Self.isWord(u[j]); break }
        }
        return cur != prev
    }

    /// Simple case folding for what can equal a lowercase ASCII pattern letter.
    private static func fold(_ s: Unicode.Scalar) -> UInt32 {
        let v = s.value
        if v >= 65 && v <= 90 { return v + 32 }
        if v == 0x017F { return 0x73 }   // long s
        if v == 0x212A { return 0x6B }   // Kelvin sign
        return v
    }

    /// ICU \s: [\t\n\f\r\p{Z}].
    private static func isSpace(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x09, 0x0A, 0x0C, 0x0D: return true
        default:
            switch s.properties.generalCategory {
            case .spaceSeparator, .lineSeparator, .paragraphSeparator: return true
            default: return false
            }
        }
    }

    private static func isLineEnd(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        return (v >= 0x0A && v <= 0x0D) || v == 0x85 || v == 0x2028 || v == 0x2029
    }

    /// ICU \w: alphabetic, marks, decimal digits, connector punctuation, ZWNJ, ZWJ.
    private static func isWord(_ s: Unicode.Scalar) -> Bool {
        if s.value == 0x200C || s.value == 0x200D { return true }
        if s.properties.isAlphabetic { return true }
        switch s.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .connectorPunctuation: return true
        default: return false
        }
    }

    private static func isExtendOrFormat(_ s: Unicode.Scalar) -> Bool {
        s.properties.isGraphemeExtend || s.properties.generalCategory == .format
    }
}

// MARK: - Artist spellings

/// One artist written several ways ("Beyoncé", "Beyonce", "BEYONCÉ").
public struct ArtistSpellings: Identifiable, Equatable, Sendable {
    public var key: String
    /// Every spelling with how many tracks use it (as artist or album artist).
    public var variants: [(name: String, count: Int)]
    public var id: String { key }
    /// The spelling most tracks use.
    public var suggested: String { variants.first?.name ?? "" }

    public init(key: String, variants: [(name: String, count: Int)]) {
        self.key = key
        self.variants = variants
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.key == b.key && a.variants.map(\.name) == b.variants.map(\.name) && a.variants.map(\.count) == b.variants.map(\.count)
    }

    /// The comparison key: case, accents, punctuation, "&"/"and", and a
    /// leading "The" don't matter.
    public static func key(_ name: String) -> String {
        var folded = String.UnicodeScalarView()
        for s in name.lowercased().unicodeScalars {
            let v = s.value
            if s.properties.generalCategory == .nonspacingMark { continue }
            if v >= 0xFF01 && v <= 0xFF5E, let w = Unicode.Scalar(v - 0xFEE0) {
                folded.append(contentsOf: String(Character(w)).lowercased().unicodeScalars)
            } else if v == 0x3000 {
                folded.append(" ")
            } else if v >= 0xC0 && v <= 0x17F, let base = latinBase[Int(v - 0xC0)] {
                folded.append(base)
            } else {
                folded.append(s)
            }
        }
        var k = String(folded)
        k = TextTools.replacing(k, "&", with: " and ")
        k = TextTools.replacing(k, "+", with: " and ")
        if k.hasPrefix("the ") { k = String(k.dropFirst(4)) }
        return TextTools.string(k.unicodeScalars.filter(TextTools.isAlphanumeric))
    }

    /// Base letters of U+00C0...U+017F; nil where the letter has no accent to drop.
    private static let latinBase: [Unicode.Scalar?] = {
        let rows = [
            "AAAAAA_C", "EEEEIIII", "_NOOOOO_", "_UUUUY__", "aaaaaa_c", "eeeeiiii", "_nooooo_", "_uuuuy_y",
            "AaAaAaCc", "CcCcCcDd", "__EeEeEe", "EeEeGgGg", "GgGgHh__", "IiIiIiIi", "I___JjKk", "_LlLlLl_",
            "___NnNnN", "n___OoOo", "Oo__RrRr", "RrSsSsSs", "SsTtTt__", "UuUuUuUu", "UuUuWwYy", "YZzZzZz_",
        ]
        return rows.joined().unicodeScalars.map { $0 == "_" ? nil : $0 }
    }()

    /// Artists with more than one spelling across the library.
    public static func find(in tracks: [Track]) -> [ArtistSpellings] {
        var counts: [String: [String: Int]] = [:]
        for t in tracks {
            for name in Set([t.artist, t.albumArtist]) where !name.isEmpty {
                let k = key(name)
                guard !k.isEmpty else { continue }
                counts[k, default: [:]][name, default: 0] += 1
            }
        }
        return counts.compactMap { key, names -> ArtistSpellings? in
            guard names.count > 1 else { return nil }
            let variants = names.map { (name: $0.key, count: $0.value) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
            return ArtistSpellings(key: key, variants: variants)
        }
        .sorted {
            let c = $0.suggested.naturalCompare($1.suggested)
            return c != 0 ? c < 0 : $0.key < $1.key
        }
    }
}

// MARK: - Album health

/// What looks off about an album, for the "needs attention" list.
public struct AlbumIssues: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let noCover = AlbumIssues(rawValue: 1 << 0)
    public static let mixedAlbumArtist = AlbumIssues(rawValue: 1 << 1)
    public static let noYear = AlbumIssues(rawValue: 1 << 2)
    public static let trackNumbers = AlbumIssues(rawValue: 1 << 3)
    public static let formatting = AlbumIssues(rawValue: 1 << 4)
    public static let artistSpelling = AlbumIssues(rawValue: 1 << 5)
    public static let noGenre = AlbumIssues(rawValue: 1 << 6)
    public static let noLyrics = AlbumIssues(rawValue: 1 << 7)

    public var labels: [String] {
        var out: [String] = []
        if contains(.noCover) { out.append("no cover") }
        if contains(.artistSpelling) { out.append("artist spelling") }
        if contains(.mixedAlbumArtist) { out.append("mixed album artist") }
        if contains(.formatting) { out.append("formatting") }
        if contains(.trackNumbers) { out.append("track numbers") }
        if contains(.noYear) { out.append("no year") }
        if contains(.noGenre) { out.append("no genre") }
        if contains(.noLyrics) { out.append("no lyrics") }
        return out
    }

    public static func of(_ tracks: [Track], rules: CleanupRules, spellingKeys: Set<String>,
                          lyricsMissing: Bool = false) -> AlbumIssues {
        guard let first = tracks.first else { return [] }
        var issues: AlbumIssues = []
        if tracks.allSatisfy({ $0.artworkFilePath == nil }) { issues.insert(.noCover) }
        if lyricsMissing { issues.insert(.noLyrics) }
        if Set(tracks.map(\.albumArtist)).count > 1 { issues.insert(.mixedAlbumArtist) }
        if tracks.allSatisfy({ $0.year == nil }) { issues.insert(.noYear) }
        if tracks.allSatisfy({ $0.genre.isEmpty || $0.genre == "Unknown" }) { issues.insert(.noGenre) }
        let numbers = tracks.map { "\($0.discNumber ?? 1)-\($0.trackNumber ?? 0)" }
        if tracks.contains(where: { $0.trackNumber == nil }) || Set(numbers).count != numbers.count {
            issues.insert(.trackNumbers)
        }
        if MetadataCleanup.title(first.album, rules) != first.album
            || tracks.contains(where: { MetadataCleanup.title($0.title, rules) != $0.title }) {
            issues.insert(.formatting)
        }
        if tracks.contains(where: {
            spellingKeys.contains(ArtistSpellings.key($0.artist)) || spellingKeys.contains(ArtistSpellings.key($0.albumArtist))
        }) {
            issues.insert(.artistSpelling)
        }
        return issues
    }
}
