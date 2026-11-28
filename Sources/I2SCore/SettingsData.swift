// Every persisted i2s preference: ported from Meimei's SettingsData, with
// the stored JSON keys and raw values unchanged so Meimei settings files
// round-trip. Sizes are points (Double). Also here, data only: the cleanup
// rules (from Meimei's MetadataTools) because they are a settings field, and
// the backdrop migrations and column helpers (from Meimei's AppSettings).
import PolymerBase

// MARK: - Enumerated customization options

/// Row height, bar heights, and type size app-wide.
public enum LayoutDensity: String, CaseIterable, Sendable {
    case compact, comfortable, spacious

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .compact: return "Compact"
        case .comfortable: return "Comfortable"
        case .spacious: return "Spacious"
        }
    }

    public var rowHeight: Double {
        switch self {
        case .compact: return 18
        case .comfortable: return 21
        case .spacious: return 26
        }
    }

    public var statusBarHeight: Double {
        switch self {
        case .compact: return 18
        case .comfortable: return 20
        case .spacious: return 25
        }
    }

    public var rowFontSize: Double {
        switch self {
        case .compact: return 10.5
        case .comfortable: return 11.5
        case .spacious: return 13
        }
    }
}

public enum SidebarWidthMode: String, CaseIterable, Sendable {
    case proportional, fixed

    public var id: String { rawValue }
    public var label: String { self == .proportional ? "Proportional (scales with window)" : "Fixed width" }
}

/// Optional library table columns. Title is always shown.
public enum TrackColumnKind: String, CaseIterable, Sendable {
    case track, artist, album, year, time, genre, plays, format, quality

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .track: return "Track #"
        case .artist: return "Artist"
        case .album: return "Album"
        case .year: return "Year"
        case .time: return "Time"
        case .genre: return "Genre"
        case .plays: return "Plays"
        case .format: return "Format"
        case .quality: return "Quality"
        }
    }

    public static let defaults: [TrackColumnKind] = [.track, .artist, .album, .time, .genre, .format]
}

/// Styles from older builds (e.g. "diamond") read as `.line`.
public enum SliderStyleOption: String, CaseIterable, Sendable {
    case line, knob

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .line: return "Line (knob on hover)"
        case .knob: return "Line with knob"
        }
    }
}

/// The close / minimize / full-screen buttons in i2s's own window frame.
public enum WindowControlStyle: String, CaseIterable, Sendable {
    case outline, filled, bare

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .outline: return "Outline"
        case .filled: return "Filled"
        case .bare: return "Icon only"
        }
    }
}

public enum WindowControlShape: String, CaseIterable, Sendable {
    case square, rounded, circle

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .square: return "Square"
        case .rounded: return "Rounded"
        case .circle: return "Circle"
        }
    }
}

/// What color the window buttons are at rest.
public enum WindowControlColoring: String, CaseIterable, Sendable {
    case theme, accent, custom

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .theme: return "Theme"
        case .accent: return "Accent"
        case .custom: return "Per button"
        }
    }
}

/// What a window button turns under the pointer.
public enum WindowControlHover: String, CaseIterable, Sendable {
    case accent, own, brighten

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .accent: return "Accent"
        case .own: return "Its color"
        case .brighten: return "Brighten"
        }
    }
}

public enum WindowControlGlyphs: String, CaseIterable, Sendable {
    case hover, always, never

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .hover: return "On hover"
        case .always: return "Always"
        case .never: return "Never"
        }
    }
}

public enum WindowControlSize: String, CaseIterable, Sendable {
    case small, regular, large

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .small: return "Small"
        case .regular: return "Regular"
        case .large: return "Large"
        }
    }

    public var side: Double {
        switch self {
        case .small: return 11
        case .regular: return 13
        case .large: return 16
        }
    }
}

/// How buttons are drawn, app-wide.
public enum ButtonFill: String, CaseIterable, Sendable {
    case solid, outline, text

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .solid: return "Solid"
        case .outline: return "Outline"
        case .text: return "Text only"
        }
    }
}

/// What a labeled button shows.
public enum ButtonContent: String, CaseIterable, Sendable {
    case iconAndText, text, icon

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .iconAndText: return "Icon + text"
        case .text: return "Text"
        case .icon: return "Icon"
        }
    }
}

public enum ButtonSize: String, CaseIterable, Sendable {
    case compact, regular, large

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .compact: return "Compact"
        case .regular: return "Regular"
        case .large: return "Large"
        }
    }

    /// Added to the base height; the font steps with it.
    public var delta: Double {
        switch self {
        case .compact: return -3
        case .regular: return 0
        case .large: return 5
        }
    }
}

/// How panes and bars are drawn.
public enum SurfaceStyle: String, CaseIterable, Sendable {
    case glass, solid

    public var id: String { rawValue }
    public var label: String { self == .glass ? "Glass" : "Solid" }
}

/// What fills the window behind the panes.
public enum BackdropStyle: String, CaseIterable, Sendable {
    case translucent, themeColor, ambient, artwork

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .translucent: return "Wallpaper"
        case .themeColor: return "Solid"
        case .ambient: return "Grid"
        case .artwork: return "Album Art"
        }
    }
}

/// Where the player bar sits.
public enum PlayerBarPosition: String, CaseIterable, Sendable {
    case top, bottom

    public var id: String { rawValue }
    public var label: String { self == .top ? "Top" : "Bottom" }
}

/// How much room the player bar takes.
public enum PlayerBarStyle: String, CaseIterable, Sendable {
    case comfy, compact

    public var id: String { rawValue }
    public var label: String { self == .comfy ? "Comfy" : "Compact" }
    public var height: Double { self == .comfy ? 58 : 42 }
}

public enum SpectrumStyleOption: String, CaseIterable, Sendable {
    case gradient, solid, segmented, mirrored

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .gradient: return "Gradient"
        case .solid: return "Solid"
        case .segmented: return "LED"
        case .mirrored: return "Mirrored"
        }
    }
}

/// The configurable pieces of window chrome listed under Settings, Panels.
public enum PanelKind: String, CaseIterable, Sendable {
    case nowPlayingRail, albumGrid, lyrics, statusBar, spectrum, transportButtons, eqToggle

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .nowPlayingRail: return "Now Playing Rail"
        case .albumGrid: return "Collection Rail"
        case .lyrics: return "Lyrics"
        case .statusBar: return "Status Bar"
        case .spectrum: return "Spectrum Analyzer"
        case .transportButtons: return "Player Bar"
        case .eqToggle: return "Equalizer"
        }
    }

    /// Meimei's SF Symbol names; map to the bundled icon set when drawn.
    public var icon: String {
        switch self {
        case .nowPlayingRail: return "rectangle.leftthird.inset.filled"
        case .albumGrid: return "music.note.list"
        case .lyrics: return "text.alignleft"
        case .statusBar: return "rectangle.bottomthird.inset.filled"
        case .spectrum: return "waveform"
        case .transportButtons: return "playpause.fill"
        case .eqToggle: return "slider.horizontal.3"
        }
    }

    public var summary: String {
        switch self {
        case .nowPlayingRail: return "Artwork, title, and format info"
        case .albumGrid: return "Playlists and liked songs on the right"
        case .lyrics: return "Synced .lrc words beside the table"
        case .statusBar: return "Bottom info strip"
        case .spectrum: return "Live audio-reactive bars"
        case .transportButtons: return "Position, size, and which controls appear"
        case .eqToggle: return "Opens the EQ rack from the transport bar"
        }
    }
}

// MARK: - Cleanup rules (data only; the cleanup itself is not ported yet)

public enum CaseStyle: String, CaseIterable, Sendable {
    case title, sentence

    public var id: String { rawValue }
    public var label: String { self == .title ? "Title Case" : "Sentence case" }
}

public enum FeatStyle: String, CaseIterable, Sendable {
    case parentheses, inline, asIs

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .parentheses: return "(feat. X)"
        case .inline: return "feat. X"
        case .asIs: return "As written"
        }
    }
}

/// How titles and names get tidied. Each rule is optional.
public struct CleanupRules: Hashable, Sendable {
    /// nil means "leave capitalization alone". As in Meimei, nil is stored
    /// by omitting the key, and a missing key reads back as `.title`.
    public var caseStyle: CaseStyle? = .title
    public var feat: FeatStyle = .parentheses
    public var tidySpaces = true
    public var straightQuotes = false
    public var removeEditionTags = false

    public init() {}

    /// Missing or null keys default; a present key that can't be read
    /// fails the whole value (the settings decode then uses the defaults).
    public init?(strict f: LenientFields) {
        self.init()
        func present(_ k: String) -> JSON? {
            guard let v = f[k], !v.isNull else { return nil }
            return v
        }
        if let v = present("caseStyle") {
            guard let s = v.string.flatMap(CaseStyle.init(rawValue:)) else { return nil }
            caseStyle = s
        }
        if let v = present("feat") {
            guard let s = v.string.flatMap(FeatStyle.init(rawValue:)) else { return nil }
            feat = s
        }
        if let v = present("tidySpaces") {
            guard let b = v.bool else { return nil }
            tidySpaces = b
        }
        if let v = present("straightQuotes") {
            guard let b = v.bool else { return nil }
            straightQuotes = b
        }
        if let v = present("removeEditionTags") {
            guard let b = v.bool else { return nil }
            removeEditionTags = b
        }
    }

    public var json: JSON {
        var o: [String: JSON] = [
            "feat": .raw(feat),
            "tidySpaces": .bool(tidySpaces),
            "straightQuotes": .bool(straightQuotes),
            "removeEditionTags": .bool(removeEditionTags),
        ]
        if let caseStyle { o["caseStyle"] = .raw(caseStyle) }
        return .object(o)
    }
}

// MARK: - Persisted settings

/// Every user preference, stored as one blob. Defaults reproduce the stock
/// look; keys missing from an older payload fall back to them.
public struct AppSettingsData: LenientDecodable, Equatable {
    /// Meimei's storage key for this blob (its UserDefaults key).
    public static let storageKey = "com.meimei.player.appSettings.v1"

    // Panels
    public var showSidebar = true
    public var showAlbumGrid = true
    public var showStatusBar = true
    /// The platform's own window frame instead of i2s's square one.
    public var systemWindowFrame = false

    // Metadata
    /// Online lookups (covers, album details) on request; off hides them.
    public var onlineLookups = true
    /// Sources to ask, in order.
    public var metadataSources: [OnlineSource] = OnlineSource.allCases
    /// Edits go into the audio files' tags, not just the library.
    public var writeTagsToFiles = true
    public var cleanupRules = CleanupRules()
    // Lyrics
    public var lyricsSaveMode: LyricsSaveMode = .lrcFile
    /// Lyrics sources to ask, in order.
    public var lyricsSources: [LyricsSource] = LyricsSource.allCases
    /// Take only timed lyrics; plain text counts as not found.
    public var lyricsSyncedOnly = false
    public var lyricsReplaceExisting = false

    // Icons
    public var iconPack: IconPack = .material
    /// Drawn size within each icon's box (0.8...1.25).
    public var iconScale: Double = 1
    /// Icon role to a glyph chosen by hand.
    public var iconOverrides: [String: UInt32] = [:]

    // Buttons
    public var buttonFill: ButtonFill = .solid
    public var buttonContent: ButtonContent = .iconAndText
    public var buttonSize: ButtonSize = .regular
    /// Primary actions (Play, Save) in the accent; otherwise like the rest.
    public var buttonAccentPrimary = true

    // Window controls (own frame only)
    public var windowControlStyle: WindowControlStyle = .outline
    public var windowControlGlyphs: WindowControlGlyphs = .hover
    public var windowControlSize: WindowControlSize = .regular
    /// Tint the controls with the accent at rest, not only on hover.
    public var windowControlAccent = false
    public var windowControlShape: WindowControlShape = .square
    /// Box size, in points (`windowControlSize` is the older preset).
    public var windowControlSide: Double = 13
    public var windowControlSpacing: Double = 6
    /// The icon's size within its box.
    public var windowControlIconScale: Double = 0.62
    public var windowControlBorder: Double = 1
    public var windowControlColoring: WindowControlColoring = .theme
    /// Per button ("close", "minimize", "zoom") when coloring is Custom.
    public var windowControlColors: [String: UInt32] = [:]
    public var windowControlHover: WindowControlHover = .accent
    /// How strong the icons are before you point at them.
    public var windowControlRestOpacity: Double = 0.6
    /// Close at the far end instead of first.
    public var windowControlCloseLast = false
    public var showSpectrum = false
    public var showLyrics = false

    // Layout
    public var density: LayoutDensity = .comfortable
    public var sidebarWidthMode: SidebarWidthMode = .proportional
    public var sidebarProportionalPercent: Double = 0.25
    public var sidebarFixedWidth: Double = 280
    public var lyricsPanelWidth: Double = 290
    public var collectionRailWidth: Double = 250

    // Library table
    public var groupBy: TableGroupMode = .none
    public var visibleColumns: [TrackColumnKind] = TrackColumnKind.defaults
    public var tableShowGridLines = false
    public var tableAlternatingRows = true
    public var showHiResBadge = true

    // Album grid
    public var albumGridTileSize: Double = 150

    // Library header
    public var showSearchField = true
    public var searchFieldWidth: Double = 200

    // Now playing rail
    public var showFormatStrip = true
    public var showNowPlayingSubtitle = true

    // Status bar
    public var statusBarShowSelectionCount = true
    public var statusBarShowScanProgress = true

    // Spectrum analyzer
    public var spectrumStyle: SpectrumStyleOption = .gradient
    public var spectrumBarSpacing: Double = 2
    public var spectrumWidth: Double = 90
    public var spectrumBandCount: Int = 24
    public var spectrumShowPeaks = true

    // Player bar
    public var playerBarPosition: PlayerBarPosition = .top
    public var playerBarStyle: PlayerBarStyle = .comfy
    public var transportButtonScale: Double = 1.0
    public var volumeSliderWidth: Double = 84
    public var showShuffleRepeat = true
    public var showEQToggle = true
    public var showLyricsButton = true
    public var showQueueButton = true
    public var showMiniPlayerButton = false
    public var accentProgress = false

    // Appearance
    public var surfaceStyle: SurfaceStyle = .glass
    public var backdropStyle: BackdropStyle = .artwork
    /// How strongly the theme tints the window glass: low shows more of
    /// what's behind the window, high more of the theme.
    public var glassTintStrength: Double = 0.55
    /// How much the theme darkens the frosted Downloads and legal windows.
    public var downloadsGlassTint: Double = 0.04
    public var sliderStyle: SliderStyleOption = .line
    public var useMonospacedNumbers = true
    public var hairlineOpacity: Double = 1.0
    public var fontFamily: AppFontFamily = .geistMono

    // Behavior
    public var playOnSingleClick = false
    public var confirmBeforeRemovingFromLibrary = true
    public var rememberLastView = false
    public var resumeLastSession = true
    public var crossfadeSeconds: Double = 0
    public var lyricsOffset: Double = 0
    /// Empty means "use the account name". Never leaves the machine.
    public var localAccountName = ""

    public init() {}

    public init(lenient f: LenientFields) {
        self.init()
        showSidebar = f.bool("showSidebar", showSidebar)
        showAlbumGrid = f.bool("showAlbumGrid", showAlbumGrid)
        showStatusBar = f.bool("showStatusBar", showStatusBar)
        systemWindowFrame = f.bool("systemWindowFrame", systemWindowFrame)

        onlineLookups = f.bool("onlineLookups", onlineLookups)
        metadataSources = f.values("metadataSources", metadataSources)
        writeTagsToFiles = f.bool("writeTagsToFiles", writeTagsToFiles)
        cleanupRules = f.fields("cleanupRules").flatMap(CleanupRules.init(strict:)) ?? cleanupRules
        lyricsSaveMode = f.value("lyricsSaveMode", lyricsSaveMode)
        lyricsSources = f.values("lyricsSources", lyricsSources)
        lyricsSyncedOnly = f.bool("lyricsSyncedOnly", lyricsSyncedOnly)
        lyricsReplaceExisting = f.bool("lyricsReplaceExisting", lyricsReplaceExisting)

        iconPack = f.value("iconPack", iconPack)
        iconScale = f.double("iconScale", iconScale)
        iconOverrides = f.codes("iconOverrides", iconOverrides)

        buttonFill = f.value("buttonFill", buttonFill)
        buttonContent = f.value("buttonContent", buttonContent)
        buttonSize = f.value("buttonSize", buttonSize)
        buttonAccentPrimary = f.bool("buttonAccentPrimary", buttonAccentPrimary)

        windowControlStyle = f.value("windowControlStyle", windowControlStyle)
        windowControlGlyphs = f.value("windowControlGlyphs", windowControlGlyphs)
        windowControlSize = f.value("windowControlSize", windowControlSize)
        windowControlAccent = f.bool("windowControlAccent", windowControlAccent)
        windowControlShape = f.value("windowControlShape", windowControlShape)
        windowControlSide = f.double("windowControlSide", windowControlSide)
        windowControlSpacing = f.double("windowControlSpacing", windowControlSpacing)
        windowControlIconScale = f.double("windowControlIconScale", windowControlIconScale)
        windowControlBorder = f.double("windowControlBorder", windowControlBorder)
        windowControlColoring = f.value("windowControlColoring", windowControlColoring)
        windowControlColors = f.codes("windowControlColors", windowControlColors)
        windowControlHover = f.value("windowControlHover", windowControlHover)
        windowControlRestOpacity = f.double("windowControlRestOpacity", windowControlRestOpacity)
        windowControlCloseLast = f.bool("windowControlCloseLast", windowControlCloseLast)
        showSpectrum = f.bool("showSpectrum", showSpectrum)
        showLyrics = f.bool("showLyrics", showLyrics)

        density = f.value("density", density)
        sidebarWidthMode = f.value("sidebarWidthMode", sidebarWidthMode)
        sidebarProportionalPercent = f.double("sidebarProportionalPercent", sidebarProportionalPercent)
        sidebarFixedWidth = f.double("sidebarFixedWidth", sidebarFixedWidth)
        lyricsPanelWidth = f.double("lyricsPanelWidth", lyricsPanelWidth)
        collectionRailWidth = f.double("collectionRailWidth", collectionRailWidth)

        groupBy = f.value("groupBy", groupBy)
        visibleColumns = f.values("visibleColumns", visibleColumns)
        tableShowGridLines = f.bool("tableShowGridLines", tableShowGridLines)
        tableAlternatingRows = f.bool("tableAlternatingRows", tableAlternatingRows)
        showHiResBadge = f.bool("showHiResBadge", showHiResBadge)

        albumGridTileSize = f.double("albumGridTileSize", albumGridTileSize)

        showSearchField = f.bool("showSearchField", showSearchField)
        searchFieldWidth = f.double("searchFieldWidth", searchFieldWidth)

        showFormatStrip = f.bool("showFormatStrip", showFormatStrip)
        showNowPlayingSubtitle = f.bool("showNowPlayingSubtitle", showNowPlayingSubtitle)

        statusBarShowSelectionCount = f.bool("statusBarShowSelectionCount", statusBarShowSelectionCount)
        statusBarShowScanProgress = f.bool("statusBarShowScanProgress", statusBarShowScanProgress)

        spectrumStyle = f.value("spectrumStyle", spectrumStyle)
        spectrumBarSpacing = f.double("spectrumBarSpacing", spectrumBarSpacing)
        spectrumWidth = f.double("spectrumWidth", spectrumWidth)
        spectrumBandCount = f.int("spectrumBandCount", spectrumBandCount)
        spectrumShowPeaks = f.bool("spectrumShowPeaks", spectrumShowPeaks)

        playerBarPosition = f.value("playerBarPosition", playerBarPosition)
        playerBarStyle = f.value("playerBarStyle", playerBarStyle)
        transportButtonScale = f.double("transportButtonScale", transportButtonScale)
        volumeSliderWidth = f.double("volumeSliderWidth", volumeSliderWidth)
        showShuffleRepeat = f.bool("showShuffleRepeat", showShuffleRepeat)
        showEQToggle = f.bool("showEQToggle", showEQToggle)
        showLyricsButton = f.bool("showLyricsButton", showLyricsButton)
        showQueueButton = f.bool("showQueueButton", showQueueButton)
        showMiniPlayerButton = f.bool("showMiniPlayerButton", showMiniPlayerButton)
        accentProgress = f.bool("accentProgress", accentProgress)

        surfaceStyle = f.value("surfaceStyle", surfaceStyle)
        backdropStyle = f.value("backdropStyle", backdropStyle)
        glassTintStrength = f.double("glassTintStrength", glassTintStrength)
        downloadsGlassTint = f.double("downloadsGlassTint", downloadsGlassTint)
        sliderStyle = f.value("sliderStyle", sliderStyle)
        useMonospacedNumbers = f.bool("useMonospacedNumbers", useMonospacedNumbers)
        hairlineOpacity = f.double("hairlineOpacity", hairlineOpacity)
        fontFamily = f.value("fontFamily", fontFamily)

        playOnSingleClick = f.bool("playOnSingleClick", playOnSingleClick)
        confirmBeforeRemovingFromLibrary = f.bool("confirmBeforeRemovingFromLibrary", confirmBeforeRemovingFromLibrary)
        rememberLastView = f.bool("rememberLastView", rememberLastView)
        resumeLastSession = f.bool("resumeLastSession", resumeLastSession)
        crossfadeSeconds = f.double("crossfadeSeconds", crossfadeSeconds)
        lyricsOffset = f.double("lyricsOffset", lyricsOffset)
        localAccountName = f.string("localAccountName", localAccountName)
    }

    public var json: JSON {
        .object([
            "showSidebar": .bool(showSidebar),
            "showAlbumGrid": .bool(showAlbumGrid),
            "showStatusBar": .bool(showStatusBar),
            "systemWindowFrame": .bool(systemWindowFrame),

            "onlineLookups": .bool(onlineLookups),
            "metadataSources": .raws(metadataSources),
            "writeTagsToFiles": .bool(writeTagsToFiles),
            "cleanupRules": cleanupRules.json,
            "lyricsSaveMode": .raw(lyricsSaveMode),
            "lyricsSources": .raws(lyricsSources),
            "lyricsSyncedOnly": .bool(lyricsSyncedOnly),
            "lyricsReplaceExisting": .bool(lyricsReplaceExisting),

            "iconPack": .raw(iconPack),
            "iconScale": .number(iconScale),
            "iconOverrides": .codes(iconOverrides),

            "buttonFill": .raw(buttonFill),
            "buttonContent": .raw(buttonContent),
            "buttonSize": .raw(buttonSize),
            "buttonAccentPrimary": .bool(buttonAccentPrimary),

            "windowControlStyle": .raw(windowControlStyle),
            "windowControlGlyphs": .raw(windowControlGlyphs),
            "windowControlSize": .raw(windowControlSize),
            "windowControlAccent": .bool(windowControlAccent),
            "windowControlShape": .raw(windowControlShape),
            "windowControlSide": .number(windowControlSide),
            "windowControlSpacing": .number(windowControlSpacing),
            "windowControlIconScale": .number(windowControlIconScale),
            "windowControlBorder": .number(windowControlBorder),
            "windowControlColoring": .raw(windowControlColoring),
            "windowControlColors": .codes(windowControlColors),
            "windowControlHover": .raw(windowControlHover),
            "windowControlRestOpacity": .number(windowControlRestOpacity),
            "windowControlCloseLast": .bool(windowControlCloseLast),
            "showSpectrum": .bool(showSpectrum),
            "showLyrics": .bool(showLyrics),

            "density": .raw(density),
            "sidebarWidthMode": .raw(sidebarWidthMode),
            "sidebarProportionalPercent": .number(sidebarProportionalPercent),
            "sidebarFixedWidth": .number(sidebarFixedWidth),
            "lyricsPanelWidth": .number(lyricsPanelWidth),
            "collectionRailWidth": .number(collectionRailWidth),

            "groupBy": .raw(groupBy),
            "visibleColumns": .raws(visibleColumns),
            "tableShowGridLines": .bool(tableShowGridLines),
            "tableAlternatingRows": .bool(tableAlternatingRows),
            "showHiResBadge": .bool(showHiResBadge),

            "albumGridTileSize": .number(albumGridTileSize),

            "showSearchField": .bool(showSearchField),
            "searchFieldWidth": .number(searchFieldWidth),

            "showFormatStrip": .bool(showFormatStrip),
            "showNowPlayingSubtitle": .bool(showNowPlayingSubtitle),

            "statusBarShowSelectionCount": .bool(statusBarShowSelectionCount),
            "statusBarShowScanProgress": .bool(statusBarShowScanProgress),

            "spectrumStyle": .raw(spectrumStyle),
            "spectrumBarSpacing": .number(spectrumBarSpacing),
            "spectrumWidth": .number(spectrumWidth),
            "spectrumBandCount": .number(Double(spectrumBandCount)),
            "spectrumShowPeaks": .bool(spectrumShowPeaks),

            "playerBarPosition": .raw(playerBarPosition),
            "playerBarStyle": .raw(playerBarStyle),
            "transportButtonScale": .number(transportButtonScale),
            "volumeSliderWidth": .number(volumeSliderWidth),
            "showShuffleRepeat": .bool(showShuffleRepeat),
            "showEQToggle": .bool(showEQToggle),
            "showLyricsButton": .bool(showLyricsButton),
            "showQueueButton": .bool(showQueueButton),
            "showMiniPlayerButton": .bool(showMiniPlayerButton),
            "accentProgress": .bool(accentProgress),

            "surfaceStyle": .raw(surfaceStyle),
            "backdropStyle": .raw(backdropStyle),
            "glassTintStrength": .number(glassTintStrength),
            "downloadsGlassTint": .number(downloadsGlassTint),
            "sliderStyle": .raw(sliderStyle),
            "useMonospacedNumbers": .bool(useMonospacedNumbers),
            "hairlineOpacity": .number(hairlineOpacity),
            "fontFamily": .raw(fontFamily),

            "playOnSingleClick": .bool(playOnSingleClick),
            "confirmBeforeRemovingFromLibrary": .bool(confirmBeforeRemovingFromLibrary),
            "rememberLastView": .bool(rememberLastView),
            "resumeLastSession": .bool(resumeLastSession),
            "crossfadeSeconds": .number(crossfadeSeconds),
            "lyricsOffset": .number(lyricsOffset),
            "localAccountName": .string(localAccountName),
        ])
    }
}

// MARK: - From Meimei's AppSettings

extension AppSettingsData {
    /// Meimei's one-time backdrop migrations, in the order they run. The
    /// strings are its flag keys, kept so a store can record them as done.
    public static let migrationKeys = [
        "com.meimei.player.liquidGlassMigration.v1",
        "com.meimei.player.neutralBackdropMigration.v2",
        "com.meimei.player.windowGlassMigration.v3",
    ]

    /// Runs each migration not yet in `done`, then adds it. v1: Grid to
    /// Wallpaper; v2: Wallpaper to Grid; v3: Grid to Wallpaper. Later
    /// choices are kept because each runs once.
    public mutating func migrate(done: inout Set<String>) {
        let keys = Self.migrationKeys
        if !done.contains(keys[0]) {
            done.insert(keys[0])
            if backdropStyle == .ambient { backdropStyle = .translucent }
        }
        if !done.contains(keys[1]) {
            done.insert(keys[1])
            if backdropStyle == .translucent { backdropStyle = .ambient }
        }
        if !done.contains(keys[2]) {
            done.insert(keys[2])
            if backdropStyle == .ambient { backdropStyle = .translucent }
        }
    }

    /// Enabled optional columns, in the table's canonical order.
    public var orderedVisibleColumns: [TrackColumnKind] {
        TrackColumnKind.allCases.filter { visibleColumns.contains($0) }
    }

    /// Keeps at least one optional column so the table never collapses to the title alone.
    public mutating func toggleColumn(_ column: TrackColumnKind) {
        if let i = visibleColumns.firstIndex(of: column) {
            guard visibleColumns.count > 1 else { return }
            visibleColumns.remove(at: i)
        } else {
            visibleColumns.append(column)
        }
    }
}
