// The i2s app state: the library, what is shown, what plays.
import PolymerBase
import PolymerUI
import I2SCore

@Observable
@MainActor
public final class I2SModel {
    public var tracks: [Track]
    public var playlists: [Playlist] = []
    public var source: LibrarySource = .albums
    public var filter = ""
    public var groupBy: TableGroupMode = .album
    public var sortKey = ""
    public var sortAscending = true
    public var selectedAlbumKey: String?
    public var nowPlayingID: String?
    public var isPlaying = false
    public var progress = 0.0
    public var volume = 0.8
    public var showsLyrics = true
    public var showsProfile = true

    public init(tracks: [Track]) {
        self.tracks = tracks
        selectedAlbumKey = AlbumGroup.groups(from: tracks).first?.key
    }

    public var albums: [AlbumGroup] { AlbumGroup.groups(from: tracks) }
    public var artistCount: Int { Set(tracks.map(\.displayArtist)).count }
    public var likedCount: Int { tracks.filter(\.liked).count }
    public var nowPlaying: Track? { tracks.first { $0.id == nowPlayingID } }
    public var totalDuration: Double { tracks.reduce(0) { $0 + $1.duration } }

    public var selectedAlbum: AlbumGroup? { albums.first { $0.key == selectedAlbumKey } }
    public func tracks(of album: AlbumGroup) -> [Track] {
        tracks.filter { $0.albumKey == album.key }.sorted(by: Track.albumOrder)
    }

    /// The rows of the track table for the current source, filter and sort.
    public var visibleTracks: [Track] {
        var list = LibraryRules.base(for: source, tracks: tracks, now: 0) { id in self.playlists.first { $0.id == id } }
        list = LibraryRules.filter(list, by: filter)
        if !sortKey.isEmpty { list = TrackSort.sorted(list, key: sortKey, ascending: sortAscending) }
        return list
    }
    public var rows: [LibraryRow] { LibraryRow.build(from: visibleTracks, groupBy: groupBy) }

    public func play(_ t: Track) { nowPlayingID = t.id; isPlaying = true; progress = 0 }
    public func togglePlay() { if nowPlaying == nil, let t = visibleTracks.first { play(t) } else { isPlaying.toggle() } }
    public func toggleLike(_ t: Track) {
        if let i = tracks.firstIndex(where: { $0.id == t.id }) { tracks[i].liked.toggle() }
    }
    public func step(_ d: Int) {
        let list = visibleTracks
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.id == nowPlayingID } ?? (d > 0 ? -1 : list.count)
        play(list[(i + d + list.count) % list.count])
    }
}

/// A repeatable sample library for screens and checks (the owner's real library is never read).
public enum I2SSample {
    static let artists = ["North Arcade", "Quiet Harbor", "Velvet Static", "Low Gardens", "Hollow Maps", "Paper Orbit"]
    static let genres = ["Electronic", "Jazz", "Ambient", "Rock", "Classical", "Folk"]
    static let words = ["Afterglow", "Late Bloom", "Kite", "Interlude", "Ember", "Ninth Floor", "Halfway", "Signal",
                        "Tide", "Lantern", "Drift", "Meridian", "Cinder", "Glass Hour"]
    static let albums = ["Static Hours", "Low Gardens", "Hollow Maps", "Salt Lines", "Night Shift", "Paper Moons",
                         "Understory", "Fieldwork"]

    public static func tracks() -> [Track] {
        var out: [Track] = []
        for (a, album) in albums.enumerated() {
            let count = 8 + (a * 3) % 6
            for n in 1...count {
                let w = words[(a * 5 + n * 3) % words.count]
                let title = n % 4 == 0 ? "\(w) (Part \(n / 4 + 1))" : w
                let hi = a % 3 == 0
                out.append(Track(
                    id: "S\(a)-\(n)", filePath: "C:/Music/\(album)/\(n).flac", title: title,
                    artist: artists[a % artists.count], album: album, albumArtist: artists[a % artists.count],
                    genre: genres[a % genres.count], year: 1990 + a * 4, trackNumber: n,
                    duration: Double(95 + (a * 37 + n * 53) % 330), sampleRate: hi ? 96_000 : 44_100,
                    bitDepth: hi ? 24 : 16, channelCount: 2, estimatedBitrateKbps: hi ? 2800 : 900,
                    fileFormat: "FLAC", dateAdded: Double(700_000_000 + a * 86_400 * 9 + n), liked: (a + n) % 11 == 0))
            }
        }
        return out.sorted(by: Track.libraryOrder)
    }
}
