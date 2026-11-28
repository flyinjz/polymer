// What the library shows and how it is filtered: ported from Meimei's
// LibraryRow, LibraryRules and Playlist (smart-playlist rules are kept as
// raw JSON until the smart-playlist editor is ported).
import PolymerBase

public enum TableGroupMode: String, CaseIterable, Sendable {
    case none, album, albumArtist, genre, year
    public var label: String {
        switch self {
        case .none: return "No grouping"
        case .album: return "Album"
        case .albumArtist: return "Album Artist"
        case .genre: return "Genre"
        case .year: return "Year"
        }
    }
}

/// One row of the library table: a group header or a track.
public enum LibraryRow: Sendable {
    case header(title: String, detail: String)
    case track(Track, stripe: Bool)

    public var track: Track? { if case .track(let t, _) = self { return t }; return nil }
    public var isHeader: Bool { if case .header = self { return true }; return false }

    /// Tracks keep their incoming order within each group; groups are sorted
    /// by title (years newest first). `stripe` alternates per track, restarting in each group.
    public static func build(from tracks: [Track], groupBy: TableGroupMode) -> [LibraryRow] {
        guard groupBy != .none else {
            return tracks.enumerated().map { .track($1, stripe: $0 % 2 == 1) }
        }
        func key(_ t: Track) -> String {
            switch groupBy {
            case .none: return ""
            case .album: return t.album.isEmpty ? "Unknown Album" : t.album
            case .albumArtist: return t.albumArtist.isEmpty ? "Unknown Artist" : t.albumArtist
            case .genre: return t.genre.isEmpty ? "Unknown" : t.genre
            case .year: return t.year.map(String.init) ?? "Unknown Year"
            }
        }
        var order: [String] = []
        var groups: [String: [Track]] = [:]
        for track in tracks {
            let k = key(track)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(track)
        }
        if groupBy == .year { order.sort { $0.naturalCompare($1) > 0 } }
        else { order.sort { $0.naturalCompare($1) < 0 } }
        var rows: [LibraryRow] = []
        rows.reserveCapacity(tracks.count + order.count)
        for k in order {
            let members = groups[k] ?? []
            let total = members.reduce(0) { $0 + $1.duration }
            let count = members.count == 1 ? "1 track" : "\(members.count) tracks"
            rows.append(.header(title: k, detail: "\(count) · \(formatClock(seconds: total))"))
            rows.append(contentsOf: members.enumerated().map { .track($1, stripe: $0 % 2 == 1) })
        }
        return rows
    }
}

public enum LibrarySource: Hashable, Sendable {
    case all, albums, artists
    case artist(String), genre(String)
    case liked, recentlyAdded, recentlyPlayed, mostPlayed
    case playlist(String)
    case profile

    public var key: String {
        switch self {
        case .all: return "all"
        case .albums: return "albums"
        case .artists: return "artists"
        case .artist(let a): return "artist:" + a
        case .genre(let g): return "genre:" + g
        case .liked: return "liked"
        case .recentlyAdded: return "recentlyAdded"
        case .recentlyPlayed: return "recentlyPlayed"
        case .mostPlayed: return "mostPlayed"
        case .playlist(let id): return "playlist:" + id
        case .profile: return "profile"
        }
    }

    public var isGrid: Bool { self == .albums || self == .artists }

    public init?(key: String) {
        func rest(_ p: String) -> String? { key.hasPrefix(p) ? String(key.dropFirst(p.count)) : nil }
        switch key {
        case "all": self = .all
        case "albums": self = .albums
        case "artists": self = .artists
        case "liked": self = .liked
        case "recentlyAdded": self = .recentlyAdded
        case "recentlyPlayed": self = .recentlyPlayed
        case "mostPlayed": self = .mostPlayed
        case "profile": self = .profile
        default:
            if let a = rest("artist:") { self = .artist(a) }
            else if let g = rest("genre:") { self = .genre(g) }
            else if let p = rest("playlist:") { self = .playlist(p) }
            else { return nil }
        }
    }
}

public struct Playlist: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var trackIDs: [String]
    public var isLibraryView = false
    public var isSmart = false
    public var matchAll = true
    public var isBuiltIn = false
    /// Smart rules, kept verbatim so saving never loses them.
    public var rulesJSON: JSON = .array([])
    public var smartOrder: String = "library"
    public var smartLimit: Int?

    public init(id: String, name: String, trackIDs: [String] = []) {
        self.id = id; self.name = name; self.trackIDs = trackIDs
    }

    public init?(json j: JSON) {
        guard let id = j["id"]?.string, let name = j["name"]?.string else { return nil }
        self.init(id: id, name: name, trackIDs: j["trackIDs"]?.array?.compactMap { $0.string } ?? [])
        isLibraryView = j["isLibraryView"]?.bool ?? false
        isSmart = j["isSmart"]?.bool ?? false
        matchAll = j["matchAll"]?.bool ?? true
        isBuiltIn = j["isBuiltIn"]?.bool ?? false
        rulesJSON = j["rules"] ?? .array([])
        smartOrder = j["smartOrder"]?.string ?? "library"
        smartLimit = j["smartLimit"]?.int
    }

    public var json: JSON {
        var o: [String: JSON] = [
            "id": .string(id), "name": .string(name), "trackIDs": .array(trackIDs.map { .string($0) }),
            "isLibraryView": .bool(isLibraryView), "isSmart": .bool(isSmart), "matchAll": .bool(matchAll),
            "isBuiltIn": .bool(isBuiltIn), "rules": rulesJSON, "smartOrder": .string(smartOrder),
        ]
        if let smartLimit { o["smartLimit"] = .number(Double(smartLimit)) }
        return .object(o)
    }
}

public enum LibraryRules {
    /// The tracks a source shows before the filter. `now` is seconds since 2001-01-01.
    public static func base(for source: LibrarySource, tracks: [Track], now: Double,
                            playlist: (String) -> Playlist?) -> [Track] {
        switch source {
        case .all, .albums, .artists, .profile: return tracks
        case .artist(let a): return tracks.filter { $0.displayArtist == a || $0.artist == a }
        case .genre(let g): return tracks.filter { $0.genre == g }
        case .liked: return tracks.filter(\.liked)
        case .recentlyAdded:
            let cutoff = now - 60 * 86_400
            let list = tracks.filter { $0.dateAdded > cutoff }.sorted { $0.dateAdded > $1.dateAdded }
            return list.count < 25 ? Array(tracks.sorted { $0.dateAdded > $1.dateAdded }.prefix(100)) : list
        case .recentlyPlayed:
            let list = tracks.filter { $0.lastPlayedAt != nil }.sorted { ($0.lastPlayedAt ?? 0) > ($1.lastPlayedAt ?? 0) }
            return Array(list.prefix(200))
        case .mostPlayed:
            return Array(tracks.filter { $0.playCount > 0 }.sorted { $0.playCount > $1.playCount }.prefix(100))
        case .playlist(let id):
            guard let p = playlist(id) else { return [] }
            if p.isSmart { return p.resolveSmart(from: tracks, now: now) }
            let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return p.trackIDs.compactMap { byID[$0] }
        }
    }

    public static func searchWords(_ text: String) -> [String] {
        text.split(separator: " ").map { String($0).asciiLowercased }
    }

    public static func searchHaystack(_ t: Track) -> String {
        [t.title, t.artist, t.album, t.albumArtist, t.genre, t.composer].joined(separator: " ").asciiLowercased
    }

    /// Tracks whose text holds every word.
    public static func filter(_ list: [Track], by text: String) -> [Track] {
        let words = searchWords(text)
        guard !words.isEmpty else { return list }
        return list.filter { t in
            let hay = searchHaystack(t)
            return words.allSatisfy { hay.contains($0) }
        }
    }
}

/// The library file (library.json): tracks and playlists.
public struct LibraryFile: Sendable {
    public var tracks: [Track]
    public var playlists: [Playlist]
    public init(tracks: [Track] = [], playlists: [Playlist] = []) { self.tracks = tracks; self.playlists = playlists }

    /// Reads the file as the app does: play counts in it are ignored (they come from
    /// the listening history), tracks in library order, built-in views dropped.
    public static func read(_ text: String) throws -> LibraryFile {
        let root = try JSON.parse(text)
        var tracks = (root["tracks"]?.array ?? []).compactMap { Track(json: $0) }
        for i in tracks.indices { tracks[i].playCount = 0; tracks[i].lastPlayedAt = nil }
        tracks.sort(by: Track.libraryOrder)
        let lists = (root["playlists"]?.array ?? []).compactMap { Playlist(json: $0) }.filter { !$0.isLibraryView }
        return LibraryFile(tracks: tracks, playlists: lists)
    }

    public func encoded() -> String {
        JSON.object(["tracks": .array(tracks.map(\.json)), "playlists": .array(playlists.map(\.json))]).serialized
    }
}

/// The track table's column sort.
public enum TrackSort {
    public static func textOrder(_ key: String, _ a: Track, _ b: Track, _ asc: Bool) -> Bool {
        func text(_ x: String, _ y: String) -> Bool { asc ? x.naturalCompare(y) < 0 : x.naturalCompare(y) > 0 }
        switch key {
        case "title": return text(a.title, b.title)
        case "artist": return a.artist == b.artist ? Track.libraryOrder(a, b) : text(a.artist, b.artist)
        case "album": return a.album == b.album ? Track.albumOrder(a, b) : text(a.album, b.album)
        case "genre": return text(a.genre, b.genre)
        case "format": return text(a.fileFormat, b.fileFormat)
        default: return false
        }
    }

    public static func sorted(_ tracks: [Track], key: String, ascending asc: Bool) -> [Track] {
        func num<T: Comparable>(_ keys: [T]) -> [Track] {
            keys.indices.sorted { asc ? keys[$0] < keys[$1] : keys[$0] > keys[$1] }.map { tracks[$0] }
        }
        switch key {
        case "track": return num(tracks.map { $0.trackNumber ?? 0 })
        case "year": return num(tracks.map { $0.year ?? 0 })
        case "time": return num(tracks.map(\.duration))
        case "plays": return num(tracks.map(\.playCount))
        case "quality": return num(tracks.map { $0.sampleRate * 100 + Double($0.bitDepth) })
        case "title", "artist", "album", "genre", "format":
            return tracks.sorted { textOrder(key, $0, $1, asc) }
        default: return tracks
        }
    }
}
