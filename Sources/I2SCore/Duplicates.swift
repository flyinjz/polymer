// Duplicate detection: ported from Meimei's Duplicates (ASCII folding, punctuation to spaces).

public struct DuplicateGroup: Hashable, Sendable {
    public enum Kind: Sendable { case songs, albums }
    public let id: String
    public let kind: Kind
    public let title: String
    public let subtitle: String
    public var tracks: [Track]
}

public enum DuplicateIdentity {
    /// The ignored-duplicates list is keyed on this.
    public static func normalize(_ raw: String) -> String {
        var out = "", pendingSpace = false
        for ch in raw.unicodeScalars {
            let v = ch.value
            let isWord = (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || v > 127
            if isWord {
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.unicodeScalars.append(v >= 65 && v <= 90 ? Unicode.Scalar(v + 32)! : ch)
            } else { pendingSpace = true }
        }
        return out
    }
}

extension Track {
    public var looseAlbumKey: String { DuplicateIdentity.normalize(albumArtist) + "::" + DuplicateIdentity.normalize(album) }
    /// Same song regardless of file: artist, title, and length to the nearest two seconds.
    public var duplicateSongKey: String {
        let seconds = Int((duration / 2).rounded()) * 2
        return DuplicateIdentity.normalize(artist) + "|" + DuplicateIdentity.normalize(title) + "|\(seconds)"
    }
}

public enum DuplicateFinder {
    public static func groups(in tracks: [Track]) -> [DuplicateGroup] {
        var songs: [String: [Track]] = [:], albums: [String: [Track]] = [:]
        var songOrder: [String] = [], albumOrder: [String] = []
        for t in tracks {
            let sk = t.duplicateSongKey, ak = t.looseAlbumKey
            if songs[sk] == nil { songOrder.append(sk) }
            if albums[ak] == nil { albumOrder.append(ak) }
            songs[sk, default: []].append(t); albums[ak, default: []].append(t)
        }
        var groups: [DuplicateGroup] = []
        for key in songOrder {
            let members = songs[key] ?? []
            guard members.count > 1, let s = members.first, !DuplicateIdentity.normalize(s.title).isEmpty else { continue }
            groups.append(DuplicateGroup(id: "song:" + key, kind: .songs, title: s.title,
                                         subtitle: "\(s.artist) · \(members.count) copies",
                                         tracks: members.sorted { $0.dateAdded > $1.dateAdded }))
        }
        for key in albumOrder {
            let members = albums[key] ?? []
            let keys = Set(members.map(\.albumKey))
            guard keys.count > 1, let s = members.first, !DuplicateIdentity.normalize(s.album).isEmpty else { continue }
            groups.append(DuplicateGroup(id: "album:" + key, kind: .albums, title: s.album,
                                         subtitle: "\(s.albumArtist) · \(keys.count) matching albums",
                                         tracks: members.sorted(by: Track.albumOrder)))
        }
        return groups.sorted { $0.title.naturallyPrecedes($1.title) }
    }
}
