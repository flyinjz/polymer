// The i2s main window: sidebar, top bar, library pages, now playing and player bar.
import PolymerBase
import PolymerText
import PolymerUI
import PolymerDesign
import I2SCore

// MARK: Type

/// The two faces i2s draws with. Sizes come from the theme's type scale.
struct I2SFonts: Equatable, Sendable {
    let sans: FontFace
    let mono: FontFace
    static func == (a: I2SFonts, b: I2SFonts) -> Bool { a.sans === b.sans && a.mono === b.mono }
}

private enum I2SFontsKey: EnvironmentKey {
    static var defaultValue: I2SFonts? { nil }
}

extension EnvironmentValues {
    var i2sFonts: I2SFonts? {
        get { self[I2SFontsKey.self] }
        set { self[I2SFontsKey.self] = newValue }
    }
}

/// The text roles i2s uses. `label` and `mono` are the mono face at caption size.
enum I2SType {
    case caption, body, headline, title, largeTitle, label, mono
}

/// Applies a text role and colour to everything inside.
struct I2SStyled<Content: View>: View {
    let content: Content
    let role: I2SType
    let color: Color
    @Environment(\.i2sFonts) var fonts
    @Environment(\.theme) var t
    @Environment(\.customizeScale) var s

    /// The role's face and size, scaled by an enclosing `.customizable(_:)`.
    func resolved(_ f: I2SFonts) -> Font {
        let ty = t.typography
        switch role {
        case .caption: return Font(f.sans, size: ty.captionSize * s)
        case .body: return Font(f.sans, size: ty.bodySize * s)
        case .headline: return Font(f.sans, size: ty.headlineSize * s)
        case .title: return Font(f.sans, size: ty.titleSize * s)
        case .largeTitle: return Font(f.sans, size: 28 * s)
        case .label, .mono: return Font(f.mono, size: ty.captionSize * s)
        }
    }

    var body: some View {
        if let fonts {
            content.font(resolved(fonts)).foregroundStyle(color)
        } else {
            content.foregroundStyle(color)
        }
    }
}

extension View {
    func i2sText(_ role: I2SType, _ color: Color) -> some View {
        I2SStyled(content: self, role: role, color: color)
    }
}

/// A fill that draws nothing visible but keeps the whole row hit-testable.
private let hitFill = Color(white: 0, opacity: 0.0001)

/// Fixed heights of the window's bars, in points before Customize scale.
private enum I2SMetrics {
    static let toolbar = 44.0
    static let row = 28.0
    static let sidebar = 220.0
    static let rightColumn = 260.0
    static let playerBar = 56.0
    static let statusBar = 22.0
}

// MARK: Building blocks

/// A 1px line along the bottom (or top) edge of a view.
struct EdgeLine: View {
    let top: Bool
    var body: some View {
        VStack(spacing: 0) {
            if top {
                HairlineDivider()
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                HairlineDivider()
            }
        }
    }
}

/// A muted caption that opens a group of rows.
struct I2SSectionHeader: View {
    let title: String
    @Environment(\.theme) var t
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).i2sText(.caption, t.colors.textMuted)
            .padding(EdgeInsets(top: t.spacing.md, leading: t.spacing.md, bottom: t.spacing.xs, trailing: t.spacing.md))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A selectable list row: title, optional count, accent bar when selected.
struct I2SListRow: View {
    let title: String
    let detail: String?
    let isSelected: Bool
    let action: @MainActor () -> Void
    @Environment(\.theme) var t
    @Environment(\.customizeScale) var s

    init(_ title: String, detail: String? = nil, isSelected: Bool = false, action: @escaping @MainActor () -> Void) {
        self.title = title; self.detail = detail; self.isSelected = isSelected; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: t.spacing.sm) {
                (isSelected ? t.colors.accent : hitFill).frame(width: 2, height: 14 * s)
                Text(title).i2sText(.body, isSelected ? t.colors.textPrimary : t.colors.textSecondary).lineLimit(1)
                Spacer(minLength: 0)
                if let detail { Text(detail).i2sText(.mono, t.colors.textMuted) }
            }
            .padding(EdgeInsets(top: 0, leading: t.spacing.xs, bottom: 0, trailing: t.spacing.md))
            .frame(maxWidth: .infinity, minHeight: I2SMetrics.row * s, maxHeight: I2SMetrics.row * s, alignment: .leading)
            .background(isSelected ? t.colors.surfaceElevated : hitFill)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

/// A boxed region with a mono caption: the i2s panel look (solid surface, 1px line).
struct IPanel<Content: View>: View {
    let title: String
    let trailing: String?
    let content: Content
    @Environment(\.theme) var t
    @Environment(\.displayScale) var displayScale
    init(_ title: String, trailing: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.trailing = trailing; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).i2sText(.label, t.colors.textSecondary)
                Spacer(minLength: 0)
                if let trailing { Text(trailing).i2sText(.mono, t.colors.textMuted) }
            }
            .padding(horizontal: t.spacing.md, vertical: t.spacing.sm)
            .overlay(EdgeLine(top: false))
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(t.colors.surface)
        .border(t.colors.hairline, width: t.borders.resolvedHairlineWidth(scale: displayScale))
    }
}

/// Square cover art made from the album name (no artwork files are read here).
struct CoverArt: View {
    let key: String
    @Environment(\.theme) var t
    @Environment(\.displayScale) var displayScale

    static func hash(_ key: String) -> UInt32 {
        var h: UInt32 = 2166136261
        for b in key.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return h
    }

    var body: some View {
        let h = CoverArt.hash(key)
        let g = 0.14 + Double(h % 17) / 100
        let bar = Double((h >> 8) % 70) / 100 + 0.2
        let tick: Color = t.colors.accent.opacity(0.85)
        ZStack(alignment: .bottomLeading) {
            Color(white: g)
            tick.frame(width: 3, height: 1).frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Color(white: g + 0.12).frame(height: 1)
                Color(white: g + 0.05).frame(maxWidth: .infinity, minHeight: 0, maxHeight: 40 * bar)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .border(t.colors.hairline, width: t.borders.resolvedHairlineWidth(scale: displayScale))
    }
}

// MARK: Sidebar and top bar

struct I2SSidebar: View {
    let model: I2SModel
    @Environment(\.theme) var t

    func row(_ title: String, _ detail: String?, _ source: LibrarySource) -> I2SListRow {
        I2SListRow(title, detail: detail, isSelected: model.source == source) { model.source = source }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("i2s").i2sText(.title, t.colors.textPrimary)
                .padding(horizontal: t.spacing.md, vertical: t.spacing.md)
            I2SSectionHeader("Library")
            row("Albums", "\(model.albums.count)", .albums)
            row("Artists", "\(model.artistCount)", .artists)
            row("All Music", "\(model.tracks.count)", .all)
            row("Liked", "\(model.likedCount)", .liked)
            I2SSectionHeader("Collections")
            row("Recently Added", nil, .recentlyAdded)
            row("Recently Played", nil, .recentlyPlayed)
            row("Most Played", nil, .mostPlayed)
            if !model.playlists.isEmpty {
                I2SSectionHeader("Playlists")
                ForEach(model.playlists) { p in row(p.name, "\(p.trackIDs.count)", .playlist(p.id)) }
            }
            Spacer(minLength: 0)
            HairlineDivider()
            row("Profile", nil, .profile)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(t.colors.surface)
    }
}

struct I2STopBar: View {
    let model: I2SModel
    @Environment(\.theme) var t
    @Environment(\.customizeScale) var s
    var body: some View {
        @Bindable var m = model
        HStack(spacing: t.spacing.md) {
            Text(title).i2sText(.title, t.colors.textPrimary).lineLimit(1)
            Spacer(minLength: 0)
            PolymerTextField("Search", text: $m.filter).frame(width: 260 * s)
        }
        .padding(horizontal: t.spacing.lg, vertical: 0)
        .frame(maxWidth: .infinity, minHeight: I2SMetrics.toolbar * s, maxHeight: I2SMetrics.toolbar * s)
        .overlay(EdgeLine(top: false))
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

// MARK: Library pages

struct AlbumGrid: View {
    let model: I2SModel
    @Environment(\.theme) var t
    @Environment(\.customizeScale) var s
    var body: some View {
        let words = LibraryRules.searchWords(model.filter)
        let albums = model.albums.filter { a in
            let hay = (a.title + " " + a.artist).asciiLowercased
            return words.allSatisfy { hay.contains($0) }
        }
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150 * s), spacing: t.spacing.lg)], spacing: t.spacing.lg) {
                ForEach(albums, id: \.key) { a in
                    Button { model.selectedAlbumKey = a.key } label: {
                        VStack(alignment: .leading, spacing: t.spacing.xs) {
                            CoverArt(key: a.key)
                            Text(a.title)
                                .i2sText(.body, model.selectedAlbumKey == a.key ? t.colors.accent : t.colors.textPrimary)
                                .lineLimit(1)
                            Text(a.year.map { "\(a.artist) · \($0)" } ?? a.artist)
                                .i2sText(.caption, t.colors.textSecondary).lineLimit(1)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(t.spacing.lg)
        }
    }
}

struct AlbumHero: View {
    let model: I2SModel
    let album: AlbumGroup
    @Environment(\.theme) var t
    @Environment(\.customizeScale) var s
    var body: some View {
        let list = model.tracks(of: album)
        let count = list.count == 1 ? "1 track" : "\(list.count) tracks"
        let meta = (album.year.map { "\($0) · " } ?? "") + "\(count) · \(formatClock(seconds: album.duration))"
        HStack(alignment: .top, spacing: t.spacing.lg) {
            CoverArt(key: album.key).frame(width: 168 * s, height: 168 * s)
            VStack(alignment: .leading, spacing: t.spacing.sm) {
                Text(album.title).i2sText(.largeTitle, t.colors.textPrimary).lineLimit(1)
                Text(album.artist).i2sText(.body, t.colors.textSecondary)
                Text(meta).i2sText(.mono, t.colors.textMuted)
                if let q = list.first?.qualitySummary { Text(q).i2sText(.mono, t.colors.textMuted) }
                Spacer(minLength: 0)
                Button("Play") { if let f = list.first { model.play(f) } }
                    .buttonStyle(.polymerPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 168 * s)
        .padding(t.spacing.lg)
    }
}

struct TrackRowView: View {
    let model: I2SModel
    let track: Track
    let stripe: Bool
    @Environment(\.theme) var t
    @Environment(\.customizeScale) var s
    var body: some View {
        let current = model.nowPlayingID == track.id
        let fill: Color = current ? t.colors.surfaceElevated : (stripe ? Color(white: 1, opacity: 0.02) : hitFill)
        Button { model.play(track) } label: {
            HStack(spacing: t.spacing.md) {
                Text(track.trackNumber.map(String.init) ?? "").i2sText(.mono, t.colors.textMuted)
                    .frame(width: 24 * s, alignment: .trailing)
                Text(track.title).i2sText(.body, current ? t.colors.accent : t.colors.textPrimary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(track.displayArtist).i2sText(.caption, t.colors.textSecondary).lineLimit(1)
                    .frame(width: 160 * s, alignment: .leading)
                Text(track.liked ? "Liked" : "").i2sText(.caption, t.colors.accent)
                    .frame(width: 44 * s, alignment: .trailing)
                Text(formatClock(seconds: track.duration)).i2sText(.mono, t.colors.textSecondary)
                    .frame(width: 48 * s, alignment: .trailing)
            }
            .padding(horizontal: t.spacing.md, vertical: 0)
            .frame(maxWidth: .infinity, minHeight: I2SMetrics.row * s, alignment: .leading)
            .background(fill)
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
            ForEach(Array(rows.enumerated()), id: \.offset) { item in
                switch item.element {
                case .header(let title, let detail):
                    HStack {
                        Text(title).i2sText(.label, t.colors.textPrimary)
                        Spacer(minLength: 0)
                        Text(detail).i2sText(.mono, t.colors.textMuted)
                    }
                    .padding(horizontal: t.spacing.md, vertical: t.spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(t.colors.surfaceElevated)
                case .track(let tr, let stripe):
                    TrackRowView(model: model, track: tr, stripe: stripe)
                }
            }
        }
    }
}

struct ArtistList: View {
    let model: I2SModel
    var body: some View {
        let counts = Dictionary(model.tracks.map { ($0.displayArtist, 1) }, uniquingKeysWith: +)
        let names = counts.keys.sorted { $0.naturallyPrecedes($1) }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(names, id: \.self) { a in
                    I2SListRow(a, detail: "\(counts[a] ?? 0)") { model.source = .artist(a) }
                }
            }
        }
    }
}

struct I2SPage: View {
    let model: I2SModel
    @Environment(\.theme) var t
    @Environment(\.customizeScale) var s
    var body: some View {
        switch model.source {
        case .albums:
            VStack(spacing: 0) {
                if let a = model.selectedAlbum, model.filter.isEmpty {
                    AlbumHero(model: model, album: a)
                    ScrollView {
                        TrackTable(model: model, rows: model.tracks(of: a).enumerated().map {
                            LibraryRow.track($1, stripe: $0 % 2 == 1)
                        })
                    }
                    .frame(maxHeight: 190 * s)
                    HairlineDivider()
                    I2SSectionHeader("Albums")
                }
                AlbumGrid(model: model)
            }
        case .artists:
            ArtistList(model: model)
        case .profile:
            VStack(alignment: .leading, spacing: t.spacing.md) {
                Text("\(model.tracks.count) tracks · \(model.albums.count) albums · \(model.artistCount) artists")
                    .i2sText(.body, t.colors.textPrimary)
                Text(formatClock(seconds: model.totalDuration) + " of music").i2sText(.mono, t.colors.textSecondary)
            }
            .padding(t.spacing.lg)
        default:
            ScrollView { TrackTable(model: model, rows: model.rows) }
        }
    }
}

// MARK: Right column

struct NowPlayingPanel: View {
    let model: I2SModel
    @Environment(\.theme) var t
    var body: some View {
        IPanel("Now Playing") {
            VStack(alignment: .leading, spacing: t.spacing.sm) {
                if let tr = model.nowPlaying {
                    CoverArt(key: tr.albumKey)
                    Text(tr.title).i2sText(.title, t.colors.textPrimary).lineLimit(2)
                    Text(tr.displayArtist).i2sText(.body, t.colors.textSecondary)
                    Text(tr.album).i2sText(.caption, t.colors.textMuted)
                    Text(tr.qualitySummary).i2sText(.mono, t.colors.textMuted)
                } else {
                    Text("Nothing playing").i2sText(.body, t.colors.textMuted)
                }
            }
            .padding(t.spacing.md)
        }
    }
}

struct LyricsPanel: View {
    let model: I2SModel
    @Environment(\.theme) var t
    var body: some View {
        IPanel("Lyrics") {
            Text(model.nowPlaying == nil ? "Play a track to see its lyrics." : "No lyrics for this track.")
                .i2sText(.body, t.colors.textMuted)
                .padding(t.spacing.md)
        }
    }
}

// MARK: Bottom bars

struct PlayerBar: View {
    let model: I2SModel
    @Environment(\.theme) var t
    @Environment(\.customizeScale) var s
    var body: some View {
        @Bindable var m = model
        let duration = model.nowPlaying?.duration ?? 0
        HStack(spacing: t.spacing.md) {
            VStack(alignment: .leading, spacing: t.spacing.xxs) {
                Text(model.nowPlaying?.title ?? "Not playing").i2sText(.body, t.colors.textPrimary).lineLimit(1)
                Text(model.nowPlaying?.displayArtist ?? "").i2sText(.caption, t.colors.textSecondary).lineLimit(1)
            }
            .frame(width: 220 * s, alignment: .leading)
            Button("Previous") { model.step(-1) }
                .buttonStyle(.polymerSecondary)
            Button(model.isPlaying ? "Pause" : "Play") { model.togglePlay() }
                .buttonStyle(.polymerPrimary)
            Button("Next") { model.step(1) }
                .buttonStyle(.polymerSecondary)
            Spacer(minLength: t.spacing.md)
            Text(formatClock(seconds: duration * model.progress)).i2sText(.mono, t.colors.textSecondary)
            PolymerSlider(value: $m.progress, width: 240)
                .accessibilityIdentifier("i2s-position")
            Text(formatClock(seconds: duration)).i2sText(.mono, t.colors.textSecondary)
            Spacer(minLength: t.spacing.md)
            Text("Volume").i2sText(.caption, t.colors.textMuted)
            PolymerSlider(value: $m.volume, width: 100)
                .accessibilityIdentifier("i2s-volume")
        }
        .padding(horizontal: t.spacing.lg, vertical: 0)
        .frame(maxWidth: .infinity, minHeight: I2SMetrics.playerBar * s, maxHeight: I2SMetrics.playerBar * s)
        .background(t.colors.surface)
        .overlay(EdgeLine(top: true))
    }
}

struct StatusBar: View {
    let model: I2SModel
    @Environment(\.theme) var t
    @Environment(\.customizeScale) var s
    var body: some View {
        let visible = model.visibleTracks
        let total = visible.reduce(0) { $0 + $1.duration }
        HStack {
            Text("\(visible.count == 1 ? "1 track" : "\(visible.count) tracks") · \(formatClock(seconds: total))")
            Spacer(minLength: 0)
            Text(model.isPlaying ? "Playing" : "Stopped")
        }
        .i2sText(.mono, t.colors.textMuted)
        .padding(horizontal: t.spacing.lg, vertical: 0)
        .frame(maxWidth: .infinity, minHeight: I2SMetrics.statusBar * s, maxHeight: I2SMetrics.statusBar * s)
        .overlay(EdgeLine(top: true))
    }
}

// MARK: Window

public struct I2SRoot: View {
    let model: I2SModel
    @Environment(\.theme) var t
    @Environment(\.customizeScale) var s
    public init(model: I2SModel) { self.model = model }
    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                I2SSidebar(model: model)
                    .frame(width: I2SMetrics.sidebar * s)
                    .customizable("i2s-sidebar")
                HairlineDivider(axis: .vertical)
                VStack(spacing: 0) {
                    I2STopBar(model: model)
                        .customizable("i2s-topBar")
                    HStack(spacing: 0) {
                        I2SPage(model: model)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .customizable("i2s-page")
                        if model.source != .profile {
                            HairlineDivider(axis: .vertical)
                            VStack(spacing: t.spacing.sm) {
                                NowPlayingPanel(model: model)
                                    .customizable("i2s-nowPlaying")
                                if model.showsLyrics {
                                    LyricsPanel(model: model)
                                        .frame(height: 120 * s)
                                        .customizable("i2s-lyrics")
                                }
                            }
                            .padding(t.spacing.sm)
                            .frame(width: I2SMetrics.rightColumn * s)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            PlayerBar(model: model)
                .customizable("i2s-playerBar")
            StatusBar(model: model)
                .customizable("i2s-statusBar")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(t.colors.background)
    }
}

/// The window's root view with theme, fonts and Customize wired in.
/// `accent` replaces the pgr accent; nil keeps it. `customize` defaults to a fresh state.
@MainActor
public func i2sRootView(model: I2SModel, sans: FontFace, mono: FontFace, accent: Color? = nil,
                        customize: CustomizeState? = nil) -> some View {
    let theme = accent.map { Theme.pgr.withAccent($0) } ?? Theme.pgr
    return I2SRoot(model: model)
        .font(Font(sans, size: theme.typography.bodySize))
        .environment(\.i2sFonts, I2SFonts(sans: sans, mono: mono))
        .customizeState(customize ?? CustomizeState())
        .theme(theme)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.colors.background)
}
