// The i2s main window: sidebar, top bar, library pages, now playing and player bar.
import PolymerBase
import PolymerText
import PolymerRender
import PolymerUI
import PolymerDesign
import I2SCore

/// A boxed region with a mono caption: the i2s panel look (solid surface, 1px line).
struct IPanel<Content: View>: View {
    let title: String
    let trailing: String?
    let content: Content
    @Environment(\.theme) var t
    init(_ title: String, trailing: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.trailing = trailing; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).textStyle(.label, t.gray.secondaryText, theme: t)
                Spacer(minLength: 0)
                if let trailing { Text(trailing).textStyle(.mono, t.gray.tertiaryText, theme: t) }
            }
            .padding(horizontal: t.space.m, vertical: t.space.s)
            .overlay(VStack(spacing: 0) { Spacer(minLength: 0); Rectangle().fill(t.gray.line).frame(height: t.line) })
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Rectangle().fill(t.gray.surface))
        .border(t.gray.line, width: t.line)
    }
}

/// Square cover art made from the album name (no artwork files are read here).
struct CoverArt: View {
    let key: String
    @Environment(\.theme) var t
    var body: some View {
        var h: UInt32 = 2166136261
        for b in key.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        let g = 0.14 + Double(h % 17) / 100
        let bar = Double((h >> 8) % 70) / 100 + 0.2
        return ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Color(white: g))
            Rectangle().fill(t.accent.opacity(0.85)).frame(width: 3, height: 1).frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Rectangle().fill(Color(white: g + 0.12)).frame(height: 1)
                Rectangle().fill(Color(white: g + 0.05)).frame(maxWidth: .infinity, minHeight: 0, maxHeight: 40 * bar)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .border(t.gray.line, width: t.line)
    }
}

struct I2SSidebar: View {
    let model: I2SModel
    @Environment(\.theme) var t

    func row(_ title: String, _ detail: String?, _ source: LibrarySource) -> some View {
        PListRow(title, detail: detail, isSelected: model.source == source) { model.source = source }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("i2s").textStyle(.title, t.gray.text, theme: t)
                .padding(horizontal: t.space.m, vertical: t.space.m)
            PSectionHeader("Library")
            row("Albums", "\(model.albums.count)", .albums)
            row("Artists", "\(model.artistCount)", .artists)
            row("All Music", "\(model.tracks.count)", .all)
            row("Liked", "\(model.likedCount)", .liked)
            PSectionHeader("Collections")
            row("Recently Added", nil, .recentlyAdded)
            row("Recently Played", nil, .recentlyPlayed)
            row("Most Played", nil, .mostPlayed)
            if !model.playlists.isEmpty {
                PSectionHeader("Playlists")
                ForEach(model.playlists) { p in row(p.name, "\(p.trackIDs.count)", .playlist(p.id)) }
            }
            Spacer(minLength: 0)
            row("Profile", nil, .profile)
        }
    }
}

struct I2STopBar: View {
    let model: I2SModel
    @Environment(\.theme) var t
    var body: some View {
        @Bindable var m = model
        HStack(spacing: t.space.m) {
            Text(title).textStyle(.title, t.gray.text, theme: t)
            Spacer(minLength: 0)
            PTextField("Search", text: $m.filter).frame(width: 260 * t.scale)
        }
        .padding(horizontal: t.space.l, vertical: 0)
        .frame(maxWidth: .infinity, minHeight: t.size.toolbar, maxHeight: t.size.toolbar)
        .overlay(VStack(spacing: 0) { Spacer(minLength: 0); Rectangle().fill(t.gray.line).frame(height: t.line) })
    }
    var title: String {
        switch model.source {
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .all: return "All Music"
        case .liked: return "Liked"
        case .recentlyAdded: return "Recently Added"
        case .recentlyPlayed: return "Recently Played"
        case .mostPlayed: return "Most Played"
        case .profile: return "Profile"
        case .artist(let a): return a
        case .genre(let g): return g
        case .playlist(let id): return model.playlists.first { $0.id == id }?.name ?? "Playlist"
        }
    }
}

struct AlbumGrid: View {
    let model: I2SModel
    @Environment(\.theme) var t
    var body: some View {
        let words = LibraryRules.searchWords(model.filter)
        let albums = model.albums.filter { a in
            words.allSatisfy { (a.title + " " + a.artist).asciiLowercased.contains($0) }
        }
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150 * t.scale), spacing: t.space.l)], spacing: t.space.l) {
                ForEach(albums, id: \.key) { a in
                    Button { model.selectedAlbumKey = a.key } label: {
                        VStack(alignment: .leading, spacing: t.space.xs) {
                            CoverArt(key: a.key)
                            Text(a.title).textStyle(.body, t.gray.text, theme: t).lineLimit(1)
                            Text("\(a.artist) · \(a.year.map(String.init) ?? "")")
                                .textStyle(.caption, t.gray.secondaryText, theme: t).lineLimit(1)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(t.space.l)
        }
    }
}

struct AlbumHero: View {
    let model: I2SModel
    let album: AlbumGroup
    @Environment(\.theme) var t
    var body: some View {
        let list = model.tracks(of: album)
        HStack(alignment: .top, spacing: t.space.l) {
            CoverArt(key: album.key).frame(width: 168 * t.scale, height: 168 * t.scale)
            VStack(alignment: .leading, spacing: t.space.s) {
                Text(album.title).textStyle(.largeTitle, t.gray.text, theme: t).lineLimit(1)
                Text(album.artist).textStyle(.body, t.gray.secondaryText, theme: t)
                Text("\(album.year.map(String.init) ?? "") · \(list.count) tracks · \(formatClock(seconds: album.duration))")
                    .textStyle(.mono, t.gray.tertiaryText, theme: t)
                if let q = list.first?.qualitySummary { Text(q).textStyle(.mono, t.gray.tertiaryText, theme: t) }
                Spacer(minLength: 0)
                PButton("Play", kind: .primary) { if let f = list.first { model.play(f) } }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(t.space.l)
    }
}

struct TrackRowView: View {
    let model: I2SModel
    let track: Track
    let stripe: Bool
    @Environment(\.theme) var t
    var body: some View {
        let current = model.nowPlayingID == track.id
        Button { model.play(track) } label: {
            HStack(spacing: t.space.m) {
                Text(track.trackNumber.map(String.init) ?? "").textStyle(.mono, t.gray.tertiaryText, theme: t)
                    .frame(width: 24 * t.scale, alignment: .trailing)
                Text(track.title).textStyle(.body, current ? t.accent : t.gray.text, theme: t).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(track.displayArtist).textStyle(.caption, t.gray.secondaryText, theme: t).lineLimit(1)
                    .frame(width: 160 * t.scale, alignment: .leading)
                Text(track.liked ? "Liked" : "").textStyle(.caption, t.accent, theme: t)
                    .frame(width: 44 * t.scale, alignment: .trailing)
                Text(formatClock(seconds: track.duration)).textStyle(.mono, t.gray.secondaryText, theme: t)
                    .frame(width: 48 * t.scale, alignment: .trailing)
            }
            .padding(horizontal: t.space.m, vertical: 0)
            .frame(maxWidth: .infinity, minHeight: t.size.row, alignment: .leading)
            .background(Rectangle().fill(current ? t.gray.raised : (stripe ? Color(white: 1, opacity: 0.02) : Theme.hitFill)))
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct TrackTable: View {
    let model: I2SModel
    let rows: [LibraryRow]
    @Environment(\.theme) var t
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                switch row {
                case .header(let title, let detail):
                    HStack {
                        Text(title).textStyle(.label, t.gray.text, theme: t)
                        Spacer(minLength: 0)
                        Text(detail).textStyle(.mono, t.gray.tertiaryText, theme: t)
                    }
                    .padding(horizontal: t.space.m, vertical: t.space.s)
                    .background(Rectangle().fill(t.gray.raised))
                case .track(let tr, let stripe):
                    TrackRowView(model: model, track: tr, stripe: stripe)
                }
            }
        }
    }
}

struct I2SPage: View {
    let model: I2SModel
    @Environment(\.theme) var t
    var body: some View {
        switch model.source {
        case .albums:
            VStack(spacing: 0) {
                if let a = model.selectedAlbum, model.filter.isEmpty {
                    AlbumHero(model: model, album: a)
                    ScrollView { TrackTable(model: model, rows: model.tracks(of: a).enumerated().map { .track($1, stripe: $0 % 2 == 1) }) }
                        .frame(maxHeight: 190 * t.scale)
                    PSectionHeader("Albums")
                }
                AlbumGrid(model: model)
            }
        case .artists:
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(Set(model.tracks.map(\.displayArtist))).sorted { $0.naturallyPrecedes($1) }, id: \.self) { a in
                        PListRow(a, detail: "\(model.tracks.filter { $0.displayArtist == a }.count)") { model.source = .artist(a) }
                    }
                }
            }
        case .profile:
            VStack(alignment: .leading, spacing: t.space.m) {
                Text("\(model.tracks.count) tracks · \(model.albums.count) albums · \(model.artistCount) artists")
                    .textStyle(.body, t.gray.text, theme: t)
                Text(formatClock(seconds: model.totalDuration) + " of music").textStyle(.mono, t.gray.secondaryText, theme: t)
            }.padding(t.space.l)
        default:
            ScrollView { TrackTable(model: model, rows: model.rows) }
        }
    }
}

struct NowPlayingPanel: View {
    let model: I2SModel
    @Environment(\.theme) var t
    var body: some View {
        IPanel("Now Playing") {
            VStack(alignment: .leading, spacing: t.space.s) {
                if let tr = model.nowPlaying {
                    CoverArt(key: tr.albumKey)
                    Text(tr.title).textStyle(.title, t.gray.text, theme: t).lineLimit(2)
                    Text(tr.displayArtist).textStyle(.body, t.gray.secondaryText, theme: t)
                    Text(tr.album).textStyle(.caption, t.gray.tertiaryText, theme: t)
                    Text(tr.qualitySummary).textStyle(.mono, t.gray.tertiaryText, theme: t)
                } else {
                    Text("Nothing playing").textStyle(.body, t.gray.tertiaryText, theme: t)
                }
            }
            .padding(t.space.m)
        }
    }
}

struct LyricsPanel: View {
    let model: I2SModel
    @Environment(\.theme) var t
    var body: some View {
        IPanel("Lyrics") {
            Text(model.nowPlaying == nil ? "Play a track to see its lyrics." : "No lyrics for this track.")
                .textStyle(.body, t.gray.tertiaryText, theme: t).padding(t.space.m)
        }
    }
}

struct PlayerBar: View {
    let model: I2SModel
    @Environment(\.theme) var t
    var body: some View {
        @Bindable var m = model
        HStack(spacing: t.space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.nowPlaying?.title ?? "Not playing").textStyle(.body, t.gray.text, theme: t).lineLimit(1)
                Text(model.nowPlaying?.displayArtist ?? "").textStyle(.caption, t.gray.secondaryText, theme: t).lineLimit(1)
            }
            .frame(width: 220 * t.scale, alignment: .leading)
            PButton("Previous") { model.step(-1) }
            PButton(model.isPlaying ? "Pause" : "Play", kind: .primary) { model.togglePlay() }
            PButton("Next") { model.step(1) }
            Text(formatClock(seconds: (model.nowPlaying?.duration ?? 0) * model.progress))
                .textStyle(.mono, t.gray.secondaryText, theme: t)
            PSlider("Position", value: $m.progress).frame(maxWidth: .infinity)
            Text(formatClock(seconds: model.nowPlaying?.duration ?? 0)).textStyle(.mono, t.gray.secondaryText, theme: t)
            PSlider("Volume", value: $m.volume).frame(width: 100 * t.scale)
        }
        .padding(horizontal: t.space.l, vertical: 0)
        .frame(maxWidth: .infinity, minHeight: 56 * t.scale, maxHeight: 56 * t.scale)
        .background(Rectangle().fill(t.gray.surface))
        .overlay(VStack(spacing: 0) { Rectangle().fill(t.gray.line).frame(height: t.line); Spacer(minLength: 0) })
    }
}

struct StatusBar: View {
    let model: I2SModel
    @Environment(\.theme) var t
    var body: some View {
        HStack {
            Text("\(model.visibleTracks.count) tracks · \(formatClock(seconds: model.visibleTracks.reduce(0) { $0 + $1.duration }))")
            Spacer(minLength: 0)
            Text(model.isPlaying ? "Playing" : "Stopped")
        }
        .textStyle(.mono, t.gray.tertiaryText, theme: t)
        .padding(horizontal: t.space.l, vertical: 0)
        .frame(maxWidth: .infinity, minHeight: 22 * t.scale, maxHeight: 22 * t.scale)
        .overlay(VStack(spacing: 0) { Rectangle().fill(t.gray.line).frame(height: t.line); Spacer(minLength: 0) })
    }
}

public struct I2SRoot: View {
    let model: I2SModel
    @Environment(\.theme) var t
    public init(model: I2SModel) { self.model = model }
    public var body: some View {
        VStack(spacing: 0) {
            PSidebarLayout {
                I2SSidebar(model: model)
            } detail: {
                VStack(spacing: 0) {
                    I2STopBar(model: model)
                    HStack(spacing: 0) {
                        I2SPage(model: model).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        if model.source != .profile {
                            Rectangle().fill(t.gray.line).frame(width: t.line)
                            VStack(spacing: t.space.s) {
                                NowPlayingPanel(model: model)
                                if model.showsLyrics { LyricsPanel(model: model).frame(height: 120 * t.scale) }
                            }
                            .padding(t.space.s)
                            .frame(width: 260 * t.scale)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            PlayerBar(model: model)
            StatusBar(model: model)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Rectangle().fill(t.gray.background))
    }
}

/// The window's root view with theme and customize wired in.
@MainActor
public func i2sRootView(model: I2SModel, sans: FontFace, mono: FontFace, accent: Color = Theme.defaultAccent,
                        customize: CustomizeModel = CustomizeModel()) -> some View {
    let theme = Theme(accent: accent, sans: mono, mono: mono)
    return I2SRoot(model: model)
        .designRoot(theme: theme, customize: customize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Rectangle().fill(theme.gray.background))
}
