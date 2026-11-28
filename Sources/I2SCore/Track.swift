// One song in the library. Same fields, same JSON keys and same defaults as
// Meimei's Core/Track.swift so existing library files load unchanged. Differences:
//  - `id` is the UUID string as written in the file (no UUID type without Foundation).
//  - `dateAdded` / `lastPlayedAt` are seconds since 2001-01-01 UTC (what Swift's JSONEncoder writes for Date).
import PolymerBase

public struct Track: Hashable, Sendable, Identifiable {
    public var id: String
    public var filePath: String
    public var title: String
    public var artist: String
    public var album: String
    public var albumArtist: String
    public var genre: String
    public var composer: String
    public var year: Int?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var duration: Double
    public var sampleRate: Double
    public var bitDepth: Int
    public var channelCount: Int
    public var estimatedBitrateKbps: Int
    public var fileFormat: String
    public var artworkFilePath: String?
    public var dateAdded: Double
    public var playCount: Int
    public var lastPlayedAt: Double?
    public var liked: Bool

    public init(
        id: String, filePath: String, title: String, artist: String, album: String,
        albumArtist: String = "", genre: String = "Unknown", composer: String = "",
        year: Int? = nil, trackNumber: Int? = nil, discNumber: Int? = nil,
        duration: Double, sampleRate: Double, bitDepth: Int, channelCount: Int,
        estimatedBitrateKbps: Int, fileFormat: String, artworkFilePath: String? = nil,
        dateAdded: Double = 0, playCount: Int = 0, lastPlayedAt: Double? = nil, liked: Bool = false
    ) {
        self.id = id; self.filePath = filePath; self.title = title; self.artist = artist; self.album = album
        self.albumArtist = albumArtist.isEmpty ? artist : albumArtist
        self.genre = genre; self.composer = composer; self.year = year
        self.trackNumber = trackNumber; self.discNumber = discNumber
        self.duration = duration; self.sampleRate = sampleRate; self.bitDepth = bitDepth
        self.channelCount = channelCount; self.estimatedBitrateKbps = estimatedBitrateKbps
        self.fileFormat = fileFormat; self.artworkFilePath = artworkFilePath
        self.dateAdded = dateAdded; self.playCount = playCount; self.lastPlayedAt = lastPlayedAt; self.liked = liked
    }

    /// More than CD resolution in either sample rate or word length.
    public var isHiRes: Bool { sampleRate > 44_100 || bitDepth > 16 }

    public var isLossless: Bool {
        switch fileFormat.asciiLowercased {
        case "flac", "alac", "wav", "aiff", "pcm": return true
        default: return false
        }
    }

    /// Who the artist views file this track under.
    public var displayArtist: String {
        let a = albumArtist.isEmpty ? artist : albumArtist
        return a.isEmpty ? "Unknown Artist" : a
    }

    public var albumKey: String { albumArtist.asciiLowercased + "::" + album.asciiLowercased }

    public var formattedDuration: String { formatClock(seconds: duration) }

    /// "44.1 kHz · 24-bit" for lossless, "320 kbps · 44.1 kHz" for lossy.
    public var qualitySummary: String {
        let rate = formatSampleRate(sampleRate)
        if isLossless { return "\(rate) · \(bitDepth)-bit" }
        if estimatedBitrateKbps > 0 { return "\(estimatedBitrateKbps) kbps · \(rate)" }
        return rate
    }

    /// Disc, then track number, then title: the order a record plays in.
    public static func albumOrder(_ l: Track, _ r: Track) -> Bool {
        let ld = l.discNumber ?? 0, rd = r.discNumber ?? 0
        if ld != rd { return ld < rd }
        let lt = l.trackNumber ?? Int.max, rt = r.trackNumber ?? Int.max
        if lt != rt { return lt < rt }
        return l.title.naturallyPrecedes(r.title)
    }

    /// Album artist, album, then album order: the library's natural order.
    public static func libraryOrder(_ l: Track, _ r: Track) -> Bool {
        if l.albumArtist != r.albumArtist { return l.albumArtist.naturallyPrecedes(r.albumArtist) }
        if l.album != r.album { return l.album.naturallyPrecedes(r.album) }
        return albumOrder(l, r)
    }
}

// MARK: JSON (the library file format)

extension Track {
    /// Nil only when a required field is missing; fields added after the first release default.
    public init?(json j: JSON) {
        guard let id = j["id"]?.string, let filePath = j["filePath"]?.string, let title = j["title"]?.string,
              let artist = j["artist"]?.string, let album = j["album"]?.string,
              let albumArtist = j["albumArtist"]?.string, let genre = j["genre"]?.string,
              let duration = j["duration"]?.double, let sampleRate = j["sampleRate"]?.double,
              let bitDepth = j["bitDepth"]?.int, let channelCount = j["channelCount"]?.int,
              let kbps = j["estimatedBitrateKbps"]?.int, let format = j["fileFormat"]?.string
        else { return nil }
        self.init(
            id: id, filePath: filePath, title: title, artist: artist, album: album,
            albumArtist: albumArtist, genre: genre, composer: j["composer"]?.string ?? "",
            year: j["year"]?.int, trackNumber: j["trackNumber"]?.int, discNumber: j["discNumber"]?.int,
            duration: duration, sampleRate: sampleRate, bitDepth: bitDepth, channelCount: channelCount,
            estimatedBitrateKbps: kbps, fileFormat: format, artworkFilePath: j["artworkFilePath"]?.string,
            dateAdded: j["dateAdded"]?.double ?? 0, playCount: j["playCount"]?.int ?? 0,
            lastPlayedAt: j["lastPlayedAt"]?.double, liked: j["liked"]?.bool ?? false)
        self.albumArtist = albumArtist // exactly what the file says, as Meimei's decoder does
    }

    /// Same keys as Meimei writes; nil values are left out.
    public var json: JSON {
        var o: [String: JSON] = [
            "id": .string(id), "filePath": .string(filePath), "title": .string(title),
            "artist": .string(artist), "album": .string(album), "albumArtist": .string(albumArtist),
            "genre": .string(genre), "composer": .string(composer),
            "duration": .number(duration), "sampleRate": .number(sampleRate),
            "bitDepth": .number(Double(bitDepth)), "channelCount": .number(Double(channelCount)),
            "estimatedBitrateKbps": .number(Double(estimatedBitrateKbps)), "fileFormat": .string(fileFormat),
            "dateAdded": .number(dateAdded), "playCount": .number(Double(playCount)), "liked": .bool(liked),
        ]
        if let year { o["year"] = .number(Double(year)) }
        if let trackNumber { o["trackNumber"] = .number(Double(trackNumber)) }
        if let discNumber { o["discNumber"] = .number(Double(discNumber)) }
        if let artworkFilePath { o["artworkFilePath"] = .string(artworkFilePath) }
        if let lastPlayedAt { o["lastPlayedAt"] = .number(lastPlayedAt) }
        return .object(o)
    }
}

// MARK: Albums

/// One record in the library, derived from its tracks.
public struct AlbumGroup: Hashable, Sendable, Identifiable {
    public var id: String { key }
    public let key: String
    public let title: String
    public let artist: String
    public let year: Int?
    public let artworkFilePath: String?
    public let trackCount: Int
    public let duration: Double

    /// Groups tracks by album and sorts the albums by title.
    public static func groups(from tracks: [Track]) -> [AlbumGroup] {
        var byAlbum: [String: [Track]] = [:]
        for t in tracks { byAlbum[t.albumKey, default: []].append(t) }
        var out: [AlbumGroup] = []
        for (_, var members) in byAlbum {
            members.sort(by: Track.albumOrder)
            let first = members[0]
            out.append(AlbumGroup(
                key: first.albumKey,
                title: first.album.isEmpty ? "Unknown Album" : first.album,
                artist: first.albumArtist,
                year: members.lazy.compactMap(\.year).first,
                artworkFilePath: members.first { $0.artworkFilePath != nil }?.artworkFilePath,
                trackCount: members.count,
                duration: members.reduce(0) { $0 + $1.duration }))
        }
        // Title, then key, so equal titles never depend on dictionary order.
        return out.sorted {
            let c = $0.title.naturalCompare($1.title)
            return c != 0 ? c < 0 : $0.key < $1.key
        }
    }
}
