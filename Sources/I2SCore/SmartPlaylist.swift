// Smart playlist rules, ordering and resolution: ported from Meimei's SmartPlaylist.
// Text matching folds ASCII case only (Polymer's shared rule).
import PolymerBase

public enum SmartField: String, CaseIterable, Sendable {
    case title, artist, albumArtist, album, genre, composer, format
    case year, playCount, duration, sampleRate, bitDepth
    case addedDaysAgo, playedDaysAgo
    case liked, hiRes, lossless

    public enum Kind: Sendable { case text, number, flag }

    public var label: String {
        switch self {
        case .title: return "Title"
        case .artist: return "Artist"
        case .albumArtist: return "Album artist"
        case .album: return "Album"
        case .genre: return "Genre"
        case .composer: return "Composer"
        case .format: return "Format"
        case .year: return "Year"
        case .playCount: return "Play count"
        case .duration: return "Length (min)"
        case .sampleRate: return "Sample rate (kHz)"
        case .bitDepth: return "Bit depth"
        case .addedDaysAgo: return "Days since added"
        case .playedDaysAgo: return "Days since played"
        case .liked: return "Liked"
        case .hiRes: return "Hi-Res"
        case .lossless: return "Lossless"
        }
    }

    public var kind: Kind {
        switch self {
        case .title, .artist, .albumArtist, .album, .genre, .composer, .format: return .text
        case .year, .playCount, .duration, .sampleRate, .bitDepth, .addedDaysAgo, .playedDaysAgo: return .number
        case .liked, .hiRes, .lossless: return .flag
        }
    }
}

public enum SmartOp: String, CaseIterable, Sendable {
    case contains, equals, notContains, gte, lte, isTrue, isFalse

    public var label: String {
        switch self {
        case .contains: return "contains"
        case .equals: return "is"
        case .notContains: return "does not contain"
        case .gte: return "at least"
        case .lte: return "at most"
        case .isTrue: return "is yes"
        case .isFalse: return "is no"
        }
    }

    public static func ops(for field: SmartField) -> [SmartOp] {
        switch field.kind {
        case .flag: return [.isTrue, .isFalse]
        case .number: return [.equals, .gte, .lte]
        case .text: return [.contains, .equals, .notContains]
        }
    }
}

public struct SmartRule: Hashable, Sendable {
    public var id: String
    public var field: SmartField = .genre
    public var op: SmartOp = .contains
    public var value: String = ""

    public init(id: String, field: SmartField = .genre, op: SmartOp = .contains, value: String = "") {
        self.id = id; self.field = field; self.op = op; self.value = value
    }

    public init?(json j: JSON) {
        guard let id = j["id"]?.string, let f = j["field"]?.string.flatMap(SmartField.init(rawValue:)),
              let o = j["op"]?.string.flatMap(SmartOp.init(rawValue:)) else { return nil }
        self.init(id: id, field: f, op: o, value: j["value"]?.string ?? "")
    }

    public var json: JSON {
        .object(["id": .string(id), "field": .string(field.rawValue), "op": .string(op.rawValue), "value": .string(value)])
    }

    /// `now` is seconds since 2001-01-01.
    public func matches(_ t: Track, now: Double) -> Bool {
        switch field {
        case .liked: return flag(t.liked)
        case .hiRes: return flag(t.isHiRes)
        case .lossless: return flag(t.isLossless)
        case .year: return t.year.map { number(Double($0)) } ?? false
        case .playCount: return number(Double(t.playCount))
        case .duration: return number(t.duration / 60)
        case .sampleRate: return number(t.sampleRate / 1000)
        case .bitDepth: return number(Double(t.bitDepth))
        case .addedDaysAgo: return number((now - t.dateAdded) / 86_400)
        case .playedDaysAgo:
            guard let p = t.lastPlayedAt else { return false }
            return number((now - p) / 86_400)
        case .title: return text(t.title)
        case .artist: return text(t.artist)
        case .albumArtist: return text(t.albumArtist)
        case .album: return text(t.album)
        case .genre: return text(t.genre)
        case .composer: return text(t.composer)
        case .format: return text(t.fileFormat)
        }
    }

    private func flag(_ v: Bool) -> Bool { op == .isFalse ? !v : v }

    private func text(_ raw: String) -> Bool {
        let needle = value.trimmingSpaces.asciiLowercased
        let hay = raw.asciiLowercased
        let found = needle.isEmpty || hay.contains(needle)
        switch op {
        case .contains: return found
        case .notContains: return !found || needle.isEmpty
        default: return hay == needle
        }
    }

    private func number(_ n: Double) -> Bool {
        guard let target = Double(value.trimmingSpaces) else { return false }
        switch op {
        case .gte: return n >= target
        case .lte: return n <= target
        // Whole-number comparison so "length is 3" matches a 3:20 song.
        default: return n.rounded(.down) == target.rounded(.down)
        }
    }
}

public enum SmartOrder: String, CaseIterable, Sendable {
    case library, recentlyAdded, mostPlayed, recentlyPlayed, title, random

    public var label: String {
        switch self {
        case .library: return "Album order"
        case .recentlyAdded: return "Recently added"
        case .mostPlayed: return "Most played"
        case .recentlyPlayed: return "Recently played"
        case .title: return "Title"
        case .random: return "Random"
        }
    }

    /// `day` (whole days since the epoch) seeds Random so it holds still for a day.
    public func sort(_ tracks: inout [Track], day: UInt64) {
        switch self {
        case .library: tracks.sort(by: Track.libraryOrder)
        case .recentlyAdded: tracks.sort { $0.dateAdded > $1.dateAdded }
        case .mostPlayed:
            tracks.sort { $0.playCount != $1.playCount ? $0.playCount > $1.playCount : Track.libraryOrder($0, $1) }
        case .recentlyPlayed: tracks.sort { ($0.lastPlayedAt ?? -.infinity) > ($1.lastPlayedAt ?? -.infinity) }
        case .title: tracks.sort { $0.title.naturallyPrecedes($1.title) }
        case .random: tracks.sort { Self.mix($0.id, day) < Self.mix($1.id, day) }
        }
    }

    static func mix(_ id: String, _ seed: UInt64) -> UInt64 {
        var x = seed
        for b in id.utf8 { x = (x ^ UInt64(b)) &* 0x100000001B3 }
        return x
    }
}

extension String {
    var trimmingSpaces: String {
        var s = Substring(self)
        while s.first == " " || s.first == "\t" { s.removeFirst() }
        while s.last == " " || s.last == "\t" { s.removeLast() }
        return String(s)
    }
}

extension Playlist {
    public var rules: [SmartRule] { (rulesJSON.array ?? []).compactMap { SmartRule(json: $0) } }
    public mutating func setRules(_ r: [SmartRule]) { rulesJSON = .array(r.map(\.json)) }

    public func matches(_ t: Track, now: Double) -> Bool {
        let rs = rules
        guard isSmart, !rs.isEmpty else { return false }
        return matchAll ? rs.allSatisfy { $0.matches(t, now: now) } : rs.contains { $0.matches(t, now: now) }
    }

    /// Smart playlist contents: matching tracks, ordered and capped.
    public func resolveSmart(from tracks: [Track], now: Double) -> [Track] {
        var out = tracks.filter { matches($0, now: now) }
        (SmartOrder(rawValue: smartOrder) ?? .library).sort(&out, day: UInt64(max(0, now) / 86_400))
        if let smartLimit, smartLimit > 0, out.count > smartLimit { out = Array(out.prefix(smartLimit)) }
        return out
    }
}
