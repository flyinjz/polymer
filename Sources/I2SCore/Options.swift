// Font, icon, lyrics and online-source options: ported from Meimei's
// Options. Raw values are the stored JSON strings and must not change.
// The online and lyrics sources are kept as data so stored settings
// round-trip; Polymer itself makes no network requests.
import PolymerBase

/// The bundled type families. The mono ones are Nerd Fonts, so the same
/// file draws the text and the icons.
public enum AppFontFamily: String, CaseIterable, Sendable {
    case geistMono, jetBrainsMono, blexMono, iosevka, commitMono, monaspiceNeon
    case inter, geist, plexSans, spaceGrotesk

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .geistMono: return "Geist Mono"
        case .jetBrainsMono: return "JetBrains Mono"
        case .blexMono: return "Blex Mono"
        case .iosevka: return "Iosevka"
        case .commitMono: return "Commit Mono"
        case .monaspiceNeon: return "Monaspice Neon"
        case .inter: return "Inter"
        case .geist: return "Geist"
        case .plexSans: return "IBM Plex Sans"
        case .spaceGrotesk: return "Space Grotesk"
        }
    }

    public var note: String {
        switch self {
        case .geistMono: return "Calm and thin. The default."
        case .jetBrainsMono: return "Taller letters, very legible."
        case .blexMono: return "IBM Plex Mono, warm and engineered."
        case .iosevka: return "Narrow; fits the most into dense tables."
        case .commitMono: return "Neutral and quiet."
        case .monaspiceNeon: return "GitHub's Monaspace Neon, crisp and technical."
        case .inter: return "The neutral interface sans."
        case .geist: return "Geist Mono's proportional sibling."
        case .plexSans: return "IBM's sans, warm and engineered."
        case .spaceGrotesk: return "Geometric, with a technical edge."
        }
    }

    /// PostScript names of the bundled light, regular and bold faces.
    public var faces: (light: String, regular: String, bold: String) {
        switch self {
        case .geistMono: return ("GeistMonoNF-Light", "GeistMonoNF", "GeistMonoNF-Bold")
        case .jetBrainsMono: return ("JetBrainsMonoNF-Light", "JetBrainsMonoNF-Regular", "JetBrainsMonoNF-Bold")
        case .blexMono: return ("BlexMonoNF-Light", "BlexMonoNF", "BlexMonoNF-Bold")
        case .iosevka: return ("IosevkaNF-Light", "IosevkaNF", "IosevkaNF-Bold")
        case .commitMono: return ("CommitMonoNF", "CommitMonoNF", "CommitMonoNF-Bold")
        case .monaspiceNeon: return ("MonaspiceNeNF-Light", "MonaspiceNeNF", "MonaspiceNeNF-Bold")
        case .inter: return ("Inter-Light", "Inter-Regular", "Inter-Bold")
        case .geist: return ("Geist-Light", "Geist-Regular", "Geist-Bold")
        case .plexSans: return ("IBMPlexSans-Light", "IBMPlexSans", "IBMPlexSans-Bold")
        case .spaceGrotesk: return ("SpaceGrotesk-Light", "SpaceGrotesk-Regular", "SpaceGrotesk-Bold")
        }
    }

    /// Mono faces are Nerd Fonts; the sans faces are proportional and get
    /// tabular figures wherever numbers line up.
    public var isMonospaced: Bool {
        switch self {
        case .inter, .geist, .plexSans, .spaceGrotesk: return false
        default: return true
        }
    }
}

/// The icon set. The role-to-codepoint tables (Meimei's IconPackTables)
/// are not ported yet.
public enum IconPack: String, CaseIterable, Sendable {
    case material, materialOutline, materialFilled, materialCircle, materialBox, codicons, fontAwesome, octicons

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .material: return "Material"
        case .materialOutline: return "Material Outline"
        case .materialFilled: return "Material Filled"
        case .materialCircle: return "Material Circle"
        case .materialBox: return "Material Box"
        case .codicons: return "Codicons"
        case .fontAwesome: return "Font Awesome"
        case .octicons: return "Octicons"
        }
    }
}

/// Where found lyrics are kept.
public enum LyricsSaveMode: String, CaseIterable, Sendable {
    case lrcFile, embedded, both

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .lrcFile: return ".lrc file"
        case .embedded: return "In the file's tags"
        case .both: return "Both"
        }
    }
}

/// Where lyrics come from (stored preference only).
public enum LyricsSource: String, CaseIterable, Sendable {
    case lrclib, lyricsOvh

    public var id: String { rawValue }
    public var label: String { self == .lrclib ? "lrclib.net" : "lyrics.ovh" }
    public var detail: String {
        self == .lrclib ? "Community lyrics database, including synced lyrics." : "Plain lyrics (no timing)."
    }
    public var host: String { self == .lrclib ? "lrclib.net" : "api.lyrics.ovh" }
}

/// Where online covers and album details come from (stored preference only).
public enum OnlineSource: String, CaseIterable, Sendable {
    case appleMusic, musicBrainz, deezer

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .appleMusic: return "Apple Music"
        case .musicBrainz: return "MusicBrainz"
        case .deezer: return "Deezer"
        }
    }

    public var detail: String {
        switch self {
        case .appleMusic: return "iTunes Search. Large covers (up to 3000 px), tracklists, genres."
        case .musicBrainz: return "The open music encyclopedia, with the Cover Art Archive. Exact editions and originals."
        case .deezer: return "Deezer's catalog. Covers up to 1000 px, tracklists."
        }
    }

    /// The hosts a lookup contacts, shown so it's clear where requests go.
    public var hosts: String {
        switch self {
        case .appleMusic: return "itunes.apple.com, is*-ssl.mzstatic.com"
        case .musicBrainz: return "musicbrainz.org, coverartarchive.org"
        case .deezer: return "api.deezer.com, cdn-images.dzcdn.net"
        }
    }

    public var tag: String {
        switch self {
        case .appleMusic: return "apple"
        case .musicBrainz: return "musicbrainz"
        case .deezer: return "deezer"
        }
    }
}
