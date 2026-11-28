// Flagship interactive demos for `polymer demo` (and headless `polymer render studio`).
// Full-window responsive layout, live UI scaling, real-time theming, adaptive grids,
// procedural artwork, Liquid Glass lab, Design System studio, and Audio/DSP monitor.
import PolymerBase
import PolymerText
import PolymerRender
import PolymerUI
import PolymerDesign
import PolymerChecks
import I2S

// MARK: - Entry Points

/// The demo screens exposed by `polymer demo` and `polymer render`.
let demoScreenNames = ["studio", "studio-glass", "studio-design", "studio-audio", "i2s"]

enum DemoTab: String, Hashable, CaseIterable, Sendable {
    case library
    case glass
    case design
    case audio

    var title: String {
        switch self {
        case .library: return "Library"
        case .glass: return "Liquid Glass"
        case .design: return "Design System"
        case .audio: return "Audio & DSP"
        }
    }
}

enum DemoFormatFilter: String, Hashable, CaseIterable, Sendable {
    case all = "All"
    case hiRes = "Hi-Res"
    case flac = "FLAC"
    case vinyl = "Vinyl"
}

enum DemoSort: String, Hashable, CaseIterable, Sendable {
    case recent = "Recent"
    case title = "Title"
    case artist = "Artist"
    case year = "Year"
}

enum DemoBackdropKind: String, Hashable, CaseIterable, Sendable {
    case aurora = "Aurora"
    case sunset = "Sunset"
    case prism = "Prism"
    case obsidian = "Obsidian"
}

struct DemoAccent: Identifiable, Sendable {
    let id: String
    let name: String
    let color: Color

    static let all: [DemoAccent] = [
        DemoAccent(id: "cobalt", name: "Cobalt", color: Color(hex: 0x4F8CF0)),
        DemoAccent(id: "coral", name: "Coral", color: Color(hex: 0xF0685A)),
        DemoAccent(id: "emerald", name: "Emerald", color: Color(hex: 0x3ECF8E)),
        DemoAccent(id: "amber", name: "Amber", color: Color(hex: 0xEFA83B)),
        DemoAccent(id: "violet", name: "Violet", color: Color(hex: 0xA277FF)),
        DemoAccent(id: "silver", name: "Silver", color: Color(hex: 0xD4D4D8)),
    ]
}

struct DemoAlbum: Identifiable, Sendable {
    let id: Int
    let title: String
    let artist: String
    let year: Int
    let format: String
    let category: DemoFormatFilter
    let duration: String
    let trackCount: Int
    let paletteIndex: Int
    let tracks: [(String, String)]
}

@MainActor
func demoScreenTree(_ name: String, root: String, scale: Double,
                    initialWidth: Double? = nil, initialHeight: Double? = nil,
                    customize: CustomizeModel? = nil) throws -> ViewTree? {
    if name == "i2s" {
        let font = try TextReference.font(root: root, "GeistMono-Regular.otf")
        let model = I2SModel(tracks: I2SSample.tracks())
        var env = EnvironmentValues()
        env.displayScale = scale
        let tree = ViewTree(i2sRootView(model: model, sans: font, mono: font, customize: customize ?? CustomizeModel()),
                            environment: env)
        if let w = initialWidth, let h = initialHeight { tree.proposedSize = ProposedViewSize(width: w, height: h) }
        return tree
    }
    let tab: DemoTab
    switch name {
    case "studio": tab = .library
    case "studio-glass": tab = .glass
    case "studio-design": tab = .design
    case "studio-audio": tab = .audio
    default: return nil
    }
    let sans = try TextReference.font(root: root, "Geist-Regular.otf")
    let mono = try TextReference.font(root: root, "GeistMono-Regular.otf")
    let model = DemoStudioModel(tab: tab)
    var env = EnvironmentValues()
    env.displayScale = scale
    let view = DemoStudioView(model: model, sans: sans, mono: mono, customize: customize ?? CustomizeModel())
    let tree = ViewTree(view, environment: env)
    if let w = initialWidth, let h = initialHeight {
        tree.proposedSize = ProposedViewSize(width: w, height: h)
    }
    return tree
}

/// Maps `polymer demo <name>` onto the full-window flagship demo when appropriate.
@MainActor
func demoWindowTree(_ name: String, root: String) throws -> (tree: ViewTree, title: String, width: Double, height: Double)? {
    let mapped: (screen: String, title: String)? = switch name {
    case "studio", "albums": ("studio", "Polymer Studio — Library")
    case "glass", "studio-glass": ("studio-glass", "Polymer Studio — Liquid Glass")
    case "components", "design", "studio-design": ("studio-design", "Polymer Studio — Design System")
    case "i2s": ("i2s", "i2s")
    case "audio", "studio-audio": ("studio-audio", "Polymer Studio — Audio & DSP")
    default: nil
    }
    if let m = mapped, let tree = try demoScreenTree(m.screen, root: root, scale: 1, initialWidth: 1280, initialHeight: 820) {
        return (tree, m.title, 1280, 820)
    }
    return nil
}

// MARK: - Procedural Artwork Cache

@MainActor
enum DemoArt {
    private static var albumCache: [Int: Bitmap] = [:]
    private static var backdropCache: [DemoBackdropKind: Bitmap] = [:]

    static func albumCover(_ index: Int) -> Bitmap {
        if let cached = albumCache[index] { return cached }
        let bmp = generateAlbumCover(index: index, size: 220)
        albumCache[index] = bmp
        return bmp
    }

    static func backdrop(_ kind: DemoBackdropKind) -> Bitmap {
        if let cached = backdropCache[kind] { return cached }
        let bmp = generateBackdrop(kind: kind, width: 640, height: 400)
        backdropCache[kind] = bmp
        return bmp
    }

    private struct RGB { var r: Double, g: Double, b: Double }

    private static func lerp(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        let u = min(max(t, 0), 1)
        return RGB(r: a.r + (b.r - a.r) * u, g: a.g + (b.g - a.g) * u, b: a.b + (b.b - a.b) * u)
    }

    private static func clampByte(_ x: Double) -> UInt8 {
        UInt8(min(max((x * 255.0 + 0.5), 0), 255))
    }

    private static func generateAlbumCover(index: Int, size: Int) -> Bitmap {
        let palettes: [(RGB, RGB, RGB)] = [
            (RGB(r: 0.08, g: 0.14, b: 0.34), RGB(r: 0.24, g: 0.56, b: 0.96), RGB(r: 0.94, g: 0.86, b: 0.68)),
            (RGB(r: 0.18, g: 0.07, b: 0.12), RGB(r: 0.88, g: 0.30, b: 0.24), RGB(r: 0.98, g: 0.78, b: 0.42)),
            (RGB(r: 0.05, g: 0.17, b: 0.15), RGB(r: 0.16, g: 0.76, b: 0.58), RGB(r: 0.82, g: 0.96, b: 0.88)),
            (RGB(r: 0.14, g: 0.09, b: 0.26), RGB(r: 0.56, g: 0.34, b: 0.94), RGB(r: 0.96, g: 0.62, b: 0.82)),
            (RGB(r: 0.16, g: 0.12, b: 0.08), RGB(r: 0.86, g: 0.58, b: 0.22), RGB(r: 0.98, g: 0.93, b: 0.82)),
            (RGB(r: 0.07, g: 0.10, b: 0.14), RGB(r: 0.28, g: 0.40, b: 0.52), RGB(r: 0.86, g: 0.90, b: 0.95)),
            (RGB(r: 0.22, g: 0.06, b: 0.22), RGB(r: 0.92, g: 0.26, b: 0.58), RGB(r: 0.34, g: 0.84, b: 0.96)),
            (RGB(r: 0.06, g: 0.15, b: 0.22), RGB(r: 0.12, g: 0.68, b: 0.82), RGB(r: 0.96, g: 0.88, b: 0.52)),
            (RGB(r: 0.14, g: 0.14, b: 0.14), RGB(r: 0.32, g: 0.32, b: 0.34), RGB(r: 0.94, g: 0.36, b: 0.26)),
            (RGB(r: 0.09, g: 0.16, b: 0.08), RGB(r: 0.44, g: 0.72, b: 0.24), RGB(r: 0.94, g: 0.92, b: 0.72)),
            (RGB(r: 0.20, g: 0.08, b: 0.06), RGB(r: 0.74, g: 0.24, b: 0.18), RGB(r: 0.96, g: 0.84, b: 0.74)),
            (RGB(r: 0.06, g: 0.08, b: 0.20), RGB(r: 0.20, g: 0.36, b: 0.88), RGB(r: 0.44, g: 0.92, b: 0.82)),
        ]
        let (c0, c1, c2) = palettes[abs(index) % palettes.count]
        let style = abs(index) % 4
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        let inv = 1.0 / Double(size - 1)
        for y in 0..<size {
            let ny = Double(y) * inv
            for x in 0..<size {
                let nx = Double(x) * inv
                // Base smooth diagonal gradient
                var col = lerp(c0, c1, 0.25 + 0.75 * (nx * 0.65 + (1.0 - ny) * 0.35))
                let dx = nx - 0.52
                let dy = ny - 0.48
                let dist = (dx * dx + dy * dy).squareRoot()

                switch style {
                case 0:
                    // Concentric vinyl/studio rings + warm luminous disc (anti-aliased)
                    let disc = max(0.0, 1.0 - dist * 2.5)
                    col = lerp(col, c2, disc * disc * 0.82)
                    if dist > 0.20 && dist < 0.46 {
                        let ringDist = abs((dist * 26.0) - (dist * 26.0).rounded())
                        let ringAlpha = max(0.0, 1.0 - ringDist / 0.16)
                        let fade = min(min((dist - 0.20) * 14.0, (0.46 - dist) * 14.0), 1.0)
                        col = lerp(col, c2, ringAlpha * ringAlpha * fade * 0.32)
                    }
                case 1:
                    // Swiss diagonal architectural bands (smoothstep anti-aliased)
                    let band = nx * 0.75 + ny * 0.55
                    let b1 = min(max((band - 0.51) * 90.0, 0.0), 1.0) * min(max((0.75 - band) * 90.0, 0.0), 1.0)
                    let b2 = min(max((band - 0.78) * 90.0, 0.0), 1.0) * min(max((0.84 - band) * 90.0, 0.0), 1.0)
                    col = lerp(col, c2, b1 * 0.72 + b2 * 0.35)
                    let orb = max(0.0, 1.0 - ((nx - 0.28) * (nx - 0.28) + (ny - 0.30) * (ny - 0.30)).squareRoot() * 3.8)
                    col = lerp(col, c2, orb * orb * 0.6)
                case 2:
                    // Bauhaus split horizon + crisp sun circle (anti-aliased)
                    let horiz = min(max((ny - 0.615) * 120.0, 0.0), 1.0)
                    col = lerp(col, lerp(c0, col, 0.45), horiz)
                    let sunD = ((nx - 0.5) * (nx - 0.5) + (ny - 0.44) * (ny - 0.44)).squareRoot()
                    let sunEdge = min(max((0.24 - sunD) * 110.0, 0.0), 1.0)
                    col = lerp(col, lerp(c1, c2, 1.0 - ny), sunEdge * 0.9)
                default:
                    // Soft dual-orb studio mesh + subtle geometric grid
                    let o1 = max(0.0, 1.0 - ((nx - 0.25) * (nx - 0.25) + (ny - 0.72) * (ny - 0.72)).squareRoot() * 2.1)
                    let o2 = max(0.0, 1.0 - ((nx - 0.76) * (nx - 0.76) + (ny - 0.26) * (ny - 0.26)).squareRoot() * 2.2)
                    col = lerp(col, c2, o2 * o2 * 0.85)
                    col = lerp(col, c1, o1 * o1 * 0.55)
                    let gx = abs((nx * 5.0) - (nx * 5.0).rounded())
                    let gy = abs((ny * 5.0) - (ny * 5.0).rounded())
                    let grid = max(max(0.0, 1.0 - gx * 45.0), max(0.0, 1.0 - gy * 45.0))
                    col = lerp(col, c2, grid * 0.12)
                }

                // Subtle dark vignette at corners for depth
                let v = max(0.0, (dist - 0.32) * 0.7)
                col = RGB(r: col.r * (1.0 - v * 0.35), g: col.g * (1.0 - v * 0.35), b: col.b * (1.0 - v * 0.35))

                let o = (y * size + x) * 4
                pixels[o] = clampByte(col.r)
                pixels[o + 1] = clampByte(col.g)
                pixels[o + 2] = clampByte(col.b)
                pixels[o + 3] = 255
            }
        }
        return Bitmap(width: size, height: size, pixels: pixels)
    }

    private static func generateBackdrop(kind: DemoBackdropKind, width: Int, height: Int) -> Bitmap {
        let spec: (bg: RGB, a: RGB, b: RGB, c: RGB) = switch kind {
        case .aurora:
            (RGB(r: 0.04, g: 0.06, b: 0.13), RGB(r: 0.10, g: 0.78, b: 0.74), RGB(r: 0.36, g: 0.42, b: 0.98), RGB(r: 0.86, g: 0.32, b: 0.72))
        case .sunset:
            (RGB(r: 0.10, g: 0.05, b: 0.09), RGB(r: 0.96, g: 0.36, b: 0.26), RGB(r: 0.98, g: 0.72, b: 0.24), RGB(r: 0.52, g: 0.20, b: 0.68))
        case .prism:
            (RGB(r: 0.05, g: 0.07, b: 0.10), RGB(r: 0.20, g: 0.88, b: 0.56), RGB(r: 0.98, g: 0.82, b: 0.24), RGB(r: 0.28, g: 0.60, b: 0.98))
        case .obsidian:
            (RGB(r: 0.05, g: 0.05, b: 0.06), RGB(r: 0.22, g: 0.25, b: 0.30), RGB(r: 0.34, g: 0.54, b: 0.92), RGB(r: 0.18, g: 0.18, b: 0.22))
        }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let invW = 1.0 / Double(width - 1)
        let invH = 1.0 / Double(height - 1)
        for y in 0..<height {
            let ny = Double(y) * invH
            for x in 0..<width {
                let nx = Double(x) * invW
                var col = spec.bg
                // Three sweeping luminous studio orbs
                let d1 = ((nx - 0.22) * (nx - 0.22) + (ny - 0.28) * (ny - 0.28)).squareRoot()
                let d2 = ((nx - 0.78) * (nx - 0.78) + (ny - 0.32) * (ny - 0.32)).squareRoot()
                let d3 = ((nx - 0.48) * (nx - 0.48) + (ny - 0.80) * (ny - 0.80)).squareRoot()
                let w1 = max(0.0, 1.0 - d1 * 1.65)
                let w2 = max(0.0, 1.0 - d2 * 1.55)
                let w3 = max(0.0, 1.0 - d3 * 1.60)
                col = lerp(col, spec.a, w1 * w1 * 0.92)
                col = lerp(col, spec.b, w2 * w2 * 0.88)
                col = lerp(col, spec.c, w3 * w3 * 0.82)

                // Smooth anti-aliased diagonal studio light bars so glass refraction bends crisp geometry
                let diag = (nx * 1.15 + ny * 0.68) * 8.0
                let distToBar = abs(diag - diag.rounded())
                let bar = max(0.0, 1.0 - distToBar / 0.055)
                if bar > 0 {
                    col = lerp(col, RGB(r: 1, g: 1, b: 1), bar * bar * 0.22)
                }

                let o = (y * width + x) * 4
                pixels[o] = clampByte(col.r)
                pixels[o + 1] = clampByte(col.g)
                pixels[o + 2] = clampByte(col.b)
                pixels[o + 3] = 255
            }
        }
        return Bitmap(width: width, height: height, pixels: pixels)
    }
}

// MARK: - Studio Model

@Observable
final class DemoStudioModel {
    var activeTab: DemoTab
    var accentIndex = 0
    var uiScale = 1.0

    // Library state
    var search = ""
    var formatFilter: DemoFormatFilter = .all
    var sort: DemoSort = .recent
    var selectedAlbumID = 0
    var isPlaying = true
    var playbackProgress = 0.38
    var volume = 0.76
    var statusNote = "Ready · Direct3D 12 · 0.24 ms/frame"
    var showsInspectorSheet = false

    // Liquid Glass Lab state
    var backdropKind: DemoBackdropKind = .aurora
    var glassTintOpacity = 0.24
    var glassCornerRadius = 18.0
    var glassClearStyle = false
    var glassExpanded = false

    // Design System state
    var toggleGapless = true
    var toggleExclusive = false
    var toggleBitPerfect = true
    var designSlider = 0.68
    var designSegment = "Grid"
    var designPicker = "Geist"
    var designText = "Polymer pure-Swift native UI"
    var designSelectedRow = 1
    var showsDesignSheet = false
    var showsDesignPopover = false

    // Audio & DSP state
    var eqBands: [Double] = [1.5, -0.5, 0.0, 2.0, 1.0]   // dB (-12...+12)
    var replayGain = true
    var truePeakLimiter = true
    var crossfeed = false
    var tpdfDither = true
    var gaplessPreload = true
    var eqPreset = "Studio"

    let albums: [DemoAlbum] = [
        DemoAlbum(id: 0, title: "Blue Train", artist: "John Coltrane", year: 1957, format: "24/192 FLAC", category: .hiRes, duration: "42:14", trackCount: 5, paletteIndex: 0,
                  tracks: [("Blue Train", "10:43"), ("Moment's Notice", "09:10"), ("Locomotion", "07:14"), ("I'm Old Fashioned", "07:58"), ("Lazy Bird", "07:09")]),
        DemoAlbum(id: 1, title: "Selected Ambient Works", artist: "Aphex Twin", year: 1992, format: "16/44 FLAC", category: .flac, duration: "74:33", trackCount: 13, paletteIndex: 1,
                  tracks: [("Xtal", "04:54"), ("Tha", "09:06"), ("Pulsewidth", "03:46"), ("Ageispolis", "05:23"), ("Heliosphan", "04:51")]),
        DemoAlbum(id: 2, title: "Geogaddi", artist: "Boards of Canada", year: 2002, format: "24/96 Vinyl", category: .vinyl, duration: "66:06", trackCount: 23, paletteIndex: 2,
                  tracks: [("Music Is Math", "05:21"), ("Gyroscope", "03:34"), ("Julie and Candy", "04:45"), ("1969", "04:19"), ("Dawn Chorus", "03:55")]),
        DemoAlbum(id: 3, title: "Mezzanine", artist: "Massive Attack", year: 1998, format: "24/96 FLAC", category: .hiRes, duration: "63:40", trackCount: 11, paletteIndex: 3,
                  tracks: [("Angel", "06:18"), ("Risingson", "04:58"), ("Teardrop", "05:29"), ("Inertia Creeps", "05:56"), ("Group Four", "08:13")]),
        DemoAlbum(id: 4, title: "Kind of Blue", artist: "Miles Davis", year: 1959, format: "24/192 ALAC", category: .hiRes, duration: "45:44", trackCount: 5, paletteIndex: 4,
                  tracks: [("So What", "09:22"), ("Freddie Freeloader", "09:46"), ("Blue in Green", "05:37"), ("All Blues", "11:33"), ("Flamenco Sketches", "09:26")]),
        DemoAlbum(id: 5, title: "Untrue", artist: "Burial", year: 2007, format: "16/44 FLAC", category: .flac, duration: "50:32", trackCount: 13, paletteIndex: 5,
                  tracks: [("Archangel", "03:58"), ("Near Dark", "03:54"), ("Ghost Hardware", "04:53"), ("Etched Headplate", "05:59"), ("Raver", "04:59")]),
        DemoAlbum(id: 6, title: "Discovery", artist: "Daft Punk", year: 2001, format: "24/88 Vinyl", category: .vinyl, duration: "60:54", trackCount: 14, paletteIndex: 6,
                  tracks: [("One More Time", "05:20"), ("Aerodynamic", "03:27"), ("Digital Love", "04:58"), ("Voyager", "03:47"), ("Veridis Quo", "05:44")]),
        DemoAlbum(id: 7, title: "In Rainbows", artist: "Radiohead", year: 2007, format: "24/48 FLAC", category: .hiRes, duration: "42:39", trackCount: 10, paletteIndex: 7,
                  tracks: [("15 Step", "03:57"), ("Bodysnatchers", "04:02"), ("Nude", "04:15"), ("Weird Fishes", "05:18"), ("Reckoner", "04:50")]),
        DemoAlbum(id: 8, title: "Aja", artist: "Steely Dan", year: 1977, format: "24/192 Vinyl", category: .vinyl, duration: "39:58", trackCount: 7, paletteIndex: 8,
                  tracks: [("Black Cow", "05:10"), ("Aja", "07:57"), ("Deacon Blues", "07:37"), ("Peg", "03:57"), ("Josie", "04:33")]),
        DemoAlbum(id: 9, title: "Music for 18 Musicians", artist: "Steve Reich", year: 1978, format: "24/96 WAV", category: .hiRes, duration: "56:31", trackCount: 14, paletteIndex: 9,
                  tracks: [("Pulses", "05:26"), ("Section I", "03:59"), ("Section II", "05:12"), ("Section IIIA", "03:55"), ("Section IV", "06:36")]),
        DemoAlbum(id: 10, title: "Dummy", artist: "Portishead", year: 1994, format: "16/44 FLAC", category: .flac, duration: "49:17", trackCount: 11, paletteIndex: 10,
                  tracks: [("Mysterons", "05:02"), ("Sour Times", "04:11"), ("Wandering Star", "04:51"), ("Roads", "05:02"), ("Glory Box", "05:06")]),
        DemoAlbum(id: 11, title: "Random Access Memories", artist: "Daft Punk", year: 2013, format: "24/88 FLAC", category: .hiRes, duration: "74:24", trackCount: 13, paletteIndex: 11,
                  tracks: [("Give Life Back to Music", "04:34"), ("Giorgio by Moroder", "09:04"), ("Instant Crush", "05:37"), ("Touch", "08:18"), ("Contact", "06:21")]),
    ]

    init(tab: DemoTab = .library) {
        self.activeTab = tab
    }

    var currentAccent: Color {
        DemoAccent.all[accentIndex % DemoAccent.all.count].color
    }

    var selectedAlbum: DemoAlbum {
        albums.first { $0.id == selectedAlbumID } ?? albums[0]
    }

    var filteredAlbums: [DemoAlbum] {
        let q = search.trimmingCharacters(in: " ").lowercased()
        let base = albums.filter { album in
            let matchesFormat = formatFilter == .all || album.category == formatFilter
            let matchesQuery = q.isEmpty
                || album.title.lowercased().contains(q)
                || album.artist.lowercased().contains(q)
                || album.format.lowercased().contains(q)
            return matchesFormat && matchesQuery
        }
        switch sort {
        case .recent: return base
        case .title: return base.sorted { $0.title < $1.title }
        case .artist: return base.sorted { $0.artist < $1.artist }
        case .year: return base.sorted { $0.year > $1.year }
        }
    }

    func applyEQPreset(_ preset: String) {
        eqPreset = preset
        switch preset {
        case "Flat": eqBands = [0, 0, 0, 0, 0]
        case "Warm": eqBands = [3.5, 2.0, -0.5, -1.0, -1.5]
        case "Vocal": eqBands = [-1.5, 0.5, 3.0, 2.5, 0.5]
        default: eqBands = [1.5, -0.5, 0.0, 2.0, 1.0]
        }
    }

    func stepAlbum(_ delta: Int) {
        let next = (selectedAlbumID + delta + albums.count) % albums.count
        selectedAlbumID = next
        playbackProgress = 0.08
        statusNote = "Playing \(selectedAlbum.title) — \(selectedAlbum.artist)"
    }
}

private extension String {
    func trimmingCharacters(in char: Character) -> String {
        var s = self
        while s.first == char { s.removeFirst() }
        while s.last == char { s.removeLast() }
        return s
    }
}

// MARK: - Root Studio View

struct DemoStudioView: View {
    let model: DemoStudioModel
    let sans: FontFace
    let mono: FontFace
    let customize: CustomizeModel

    var body: some View {
        var baseTheme = Theme(accent: model.currentAccent, sans: sans, mono: mono)
            .scaled(by: model.uiScale)
        baseTheme.size.sidebar = 236 * model.uiScale
        return DemoStudioShell(model: model)
            .designRoot(theme: baseTheme, customize: customize)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Rectangle().fill(baseTheme.gray.background))
    }
}

struct DemoStudioShell: View {
    let model: DemoStudioModel
    @Environment(\.theme) var theme

    var body: some View {
        PSidebarLayout {
            DemoSidebar(model: model)
        } detail: {
            VStack(spacing: 0) {
                DemoTopBar(model: model)
                ZStack(alignment: .bottom) {
                    Group {
                        switch model.activeTab {
                        case .library: DemoLibraryView(model: model)
                        case .glass: DemoGlassLabView(model: model)
                        case .design: DemoDesignSystemView(model: model)
                        case .audio: DemoAudioStudioView(model: model)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if model.activeTab == .library {
                        DemoNowPlayingDock(model: model)
                            .padding(horizontal: theme.space.l, vertical: theme.space.m)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .panelSheet(isPresented: Binding(get: { model.showsInspectorSheet }, set: { model.showsInspectorSheet = $0 }),
                        title: model.selectedAlbum.title) {
                DemoAlbumInspectorSheet(model: model)
            }
        }
    }
}

// MARK: - Sidebar

struct DemoSidebar: View {
    let model: DemoStudioModel
    @Environment(\.theme) var theme

    var body: some View {
        let t = theme
        VStack(alignment: .leading, spacing: 0) {
            // Brand mark
            HStack(spacing: t.space.s) {
                ZStack {
                    Rectangle().fill(t.accent).frame(width: 22 * t.scale, height: 22 * t.scale)
                    Text("P").textStyle(.mono, t.onAccent, theme: t)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Polymer Studio").textStyle(.title, t.gray.text, theme: t)
                    Text("PURE SWIFT · D3D12").textStyle(.caption, t.gray.tertiaryText, theme: t)
                }
            }
            .padding(horizontal: t.space.m, vertical: t.space.m)

            Rectangle().fill(t.gray.line).frame(height: t.line)

            PSectionHeader("SHOWCASE")
            PListRow("Library", detail: "\(model.albums.count)", isSelected: model.activeTab == .library) {
                model.activeTab = .library
            }
            PListRow("Liquid Glass", detail: "GPU", isSelected: model.activeTab == .glass) {
                model.activeTab = .glass
            }
            PListRow("Design System", detail: "22", isSelected: model.activeTab == .design) {
                model.activeTab = .design
            }
            PListRow("Audio & DSP", detail: "64b", isSelected: model.activeTab == .audio) {
                model.activeTab = .audio
            }

            PSectionHeader("ACCENT")
            HStack(spacing: t.space.s) {
                ForEach(Array(DemoAccent.all.enumerated()), id: \.offset) { idx, item in
                    let active = model.accentIndex == idx
                    Button(action: { model.accentIndex = idx }) {
                        Rectangle()
                            .fill(item.color)
                            .frame(width: 18 * t.scale, height: 18 * t.scale)
                            .border(active ? t.gray.text : t.gray.line, width: active ? 2 : 1)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibilityLabel("Accent \(item.name)")
                }
            }
            .padding(horizontal: t.space.m, vertical: t.space.s)

            PSectionHeader("UI SCALE")
            HStack(spacing: t.space.xs) {
                ForEach([0.85, 1.0, 1.15, 1.3], id: \.self) { s in
                    let active = abs(model.uiScale - s) < 0.01
                    Button(action: { model.uiScale = s }) {
                        Text("\(Int((s * 100).rounded()))%")
                            .textStyle(.caption, active ? t.onAccent : t.gray.secondaryText, theme: t)
                            .padding(horizontal: t.space.xs, vertical: t.space.xs)
                            .background(Rectangle().fill(active ? t.accent : t.gray.raised))
                            .border(active ? t.accent : t.gray.line, width: t.line)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(horizontal: t.space.m, vertical: t.space.s)

            Spacer(minLength: t.space.m)

            Rectangle().fill(t.gray.line).frame(height: t.line)
            VStack(alignment: .leading, spacing: t.space.xs) {
                Text("NOW PLAYING").textStyle(.caption, t.gray.tertiaryText, theme: t)
                HStack(spacing: t.space.s) {
                    Image(DemoArt.albumCover(model.selectedAlbum.paletteIndex))
                        .resizable()
                        .frame(width: 34 * t.scale, height: 34 * t.scale)
                        .border(t.gray.line, width: t.line)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.selectedAlbum.title).textStyle(.body, t.gray.text, theme: t).lineLimit(1)
                        Text(model.selectedAlbum.artist).textStyle(.caption, t.gray.secondaryText, theme: t).lineLimit(1)
                    }
                }
                Text("Right-click any control to Customize")
                    .textStyle(.caption, t.gray.tertiaryText, theme: t)
            }
            .padding(t.space.m)
        }
    }
}

// MARK: - Top Toolbar

struct DemoTopBar: View {
    let model: DemoStudioModel
    @Environment(\.theme) var theme

    var body: some View {
        let t = theme
        PToolbar {
            Text(model.activeTab.title).textStyle(.title, t.gray.text, theme: t)
            if model.activeTab == .library {
                PTextField("Filter albums, artists...",
                           text: Binding(get: { model.search }, set: { model.search = $0 }),
                           name: "search")
                    .frame(width: 210 * t.scale)
                PSegmentedControl("Format",
                                  selection: Binding(get: { model.formatFilter }, set: { model.formatFilter = $0 }),
                                  options: DemoFormatFilter.allCases.map { PickerOption($0.rawValue, value: $0) },
                                  name: "format")
                    .frame(minWidth: 236 * t.scale)
                PPicker("Sort",
                        selection: Binding(get: { model.sort }, set: { model.sort = $0 }),
                        options: DemoSort.allCases.map { PickerOption($0.rawValue, value: $0) },
                        name: "sort")
                    .frame(minWidth: 96 * t.scale)
            } else {
                Text(model.statusNote).textStyle(.mono, t.gray.secondaryText, theme: t)
            }
            Spacer(minLength: t.space.s)
            PButton("-", kind: .secondary, name: "scale-down") {
                model.uiScale = max(0.8, ((model.uiScale - 0.1) * 10).rounded() / 10)
            }
            Text("\(Int((model.uiScale * 100).rounded()))%").textStyle(.mono, t.gray.secondaryText, theme: t)
            PButton("+", kind: .secondary, name: "scale-up") {
                model.uiScale = min(1.5, ((model.uiScale + 0.1) * 10).rounded() / 10)
            }
            if model.activeTab == .library {
                PButton("Inspect", kind: .primary, name: "inspect") {
                    model.showsInspectorSheet = true
                }
            }
        }
    }
}

// MARK: - Tab 1: Library (Adaptive Grid + Floating Glass Dock)

struct DemoLibraryView: View {
    let model: DemoStudioModel
    @Environment(\.theme) var theme

    var body: some View {
        let t = theme
        let items = model.filteredAlbums
        let minCard = 178 * t.scale
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: t.space.l) {
                        // Featured header strip
                        DemoHeroBanner(model: model)

                        // Section header + count
                        HStack {
                            Text("COLLECTION").textStyle(.caption, t.gray.tertiaryText, theme: t)
                            Spacer(minLength: t.space.s)
                            Text("\(items.count) ALBUMS · RESIZE WINDOW TO REFLOW GRID")
                                .textStyle(.caption, t.gray.tertiaryText, theme: t)
                        }

                        // Responsive adaptive grid
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: minCard), spacing: t.space.l)], spacing: t.space.l) {
                            ForEach(items) { album in
                                DemoAlbumCard(album: album, isSelected: album.id == model.selectedAlbumID) {
                                    model.selectedAlbumID = album.id
                                    model.isPlaying = true
                                    model.statusNote = "Playing \(album.title) · \(album.format)"
                                } onInspect: {
                                    model.selectedAlbumID = album.id
                                    model.showsInspectorSheet = true
                                }
                            }
                        }

                        // Breathing room for floating glass dock
                        Spacer(minLength: 92 * t.scale)
                    }
                    .padding(t.space.l)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                PScrollBar(proxy)
                    .padding(horizontal: 2, vertical: t.space.s)
            }
        }
    }
}

struct DemoHeroBanner: View {
    let model: DemoStudioModel
    @Environment(\.theme) var theme

    var body: some View {
        let t = theme
        let album = model.selectedAlbum
        HStack(spacing: t.space.l) {
            Image(DemoArt.albumCover(album.paletteIndex))
                .resizable()
                .frame(width: 112 * t.scale, height: 112 * t.scale)
                .border(t.gray.strongLine, width: t.line)

            VStack(alignment: .leading, spacing: t.space.xs) {
                HStack(spacing: t.space.s) {
                    Text("FEATURED MASTER")
                        .textStyle(.caption, t.accent, theme: t)
                    Text("·").textStyle(.caption, t.gray.tertiaryText, theme: t)
                    Text(album.format)
                        .textStyle(.mono, t.gray.secondaryText, theme: t)
                }
                Text(album.title).textStyle(.largeTitle, t.gray.text, theme: t)
                Text("\(album.artist) · \(album.year) · \(album.trackCount) tracks · \(album.duration)")
                    .textStyle(.body, t.gray.secondaryText, theme: t)
                Spacer(minLength: t.space.xs)
                HStack(spacing: t.space.s) {
                    PButton(model.isPlaying ? "Pause" : "Play Album", kind: .primary, name: "hero-play") {
                        model.isPlaying.toggle()
                    }
                    PButton("Tracklist", kind: .secondary, name: "hero-tracks") {
                        model.showsInspectorSheet = true
                    }
                    PButton("Next", kind: .secondary, name: "hero-next") {
                        model.stepAlbum(1)
                    }
                }
            }
            Spacer(minLength: t.space.s)
        }
        .padding(t.space.l)
        .background(Rectangle().fill(t.gray.surface))
        .border(t.gray.line, width: t.line)
    }
}

struct DemoAlbumCard: View {
    let album: DemoAlbum
    let isSelected: Bool
    let onSelect: @MainActor () -> Void
    let onInspect: @MainActor () -> Void
    @Environment(\.theme) var theme
    @State var hovered = false

    var body: some View {
        let t = theme
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: t.space.s) {
                Image(DemoArt.albumCover(album.paletteIndex))
                    .resizable()
                    .aspectRatio(1, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .overlay(
                        VStack {
                            HStack {
                                Spacer(minLength: 0)
                                Text(album.format)
                                    .textStyle(.caption, t.gray.text, theme: t)
                                    .padding(horizontal: t.space.xs + 2, vertical: 2)
                                    .background(t.material)
                                    .border(t.gray.line, width: t.line)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(t.space.xs)
                    )
                    .border(isSelected ? t.accent : (hovered ? t.gray.strongLine : t.gray.line), width: isSelected ? 2 : t.line)

                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title).textStyle(.body, t.gray.text, theme: t).lineLimit(1)
                    HStack {
                        Text(album.artist).textStyle(.caption, t.gray.secondaryText, theme: t).lineLimit(1)
                        Spacer(minLength: t.space.xs)
                        Text("\(album.year)").textStyle(.mono, t.gray.tertiaryText, theme: t)
                    }
                }
            }
            .padding(t.space.s)
            .background(Rectangle().fill(isSelected ? t.gray.raised : (hovered ? t.gray.surface : Theme.hitFill)))
            .border(isSelected ? t.accent : (hovered ? t.gray.line : Color.clear), width: t.line)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Play Now") { onSelect() }
            Button("Inspect Tracklist") { onInspect() }
        }
    }
}

struct DemoNowPlayingDock: View {
    let model: DemoStudioModel
    @Environment(\.theme) var theme

    var body: some View {
        let t = theme
        let album = model.selectedAlbum
        let dockGlass = Glass.regular.tint(Color(white: 0.04, opacity: 0.58))
        HStack(alignment: .center, spacing: t.space.m) {
            Image(DemoArt.albumCover(album.paletteIndex))
                .resizable()
                .frame(width: 44 * t.scale, height: 44 * t.scale)
                .border(t.gray.strongLine, width: t.line)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.tracks.first?.0 ?? album.title).textStyle(.body, t.gray.text, theme: t).lineLimit(1)
                Text("\(album.artist) — \(album.title)").textStyle(.caption, t.gray.secondaryText, theme: t).lineLimit(1)
            }
            .frame(minWidth: 168 * t.scale, alignment: .leading)

            HStack(spacing: t.space.xs) {
                PButton("Prev", kind: .secondary, name: "dock-prev") { model.stepAlbum(-1) }
                PButton(model.isPlaying ? "Pause" : "Play", kind: .primary, name: "dock-play") {
                    model.isPlaying.toggle()
                }
                PButton("Next", kind: .secondary, name: "dock-next") { model.stepAlbum(1) }
            }

            VStack(spacing: 4) {
                PSlider("Position", value: Binding(get: { model.playbackProgress }, set: { model.playbackProgress = $0 }), in: 0...1, name: "dock-scrub")
                HStack {
                    Text("04:06").textStyle(.caption, t.gray.secondaryText, theme: t)
                    Spacer(minLength: t.space.s)
                    Text(album.format).textStyle(.caption, t.accent, theme: t)
                    Spacer(minLength: t.space.s)
                    Text(album.tracks.first?.1 ?? "10:43").textStyle(.caption, t.gray.secondaryText, theme: t)
                }
            }
            .frame(maxWidth: .infinity)

            HStack(alignment: .center, spacing: t.space.xs) {
                Text("VOL").textStyle(.caption, t.gray.secondaryText, theme: t)
                PSlider("Volume", value: Binding(get: { model.volume }, set: { model.volume = $0 }), in: 0...1, name: "dock-vol")
                    .frame(width: 96 * t.scale)
            }
        }
        .padding(horizontal: t.space.m, vertical: t.space.s + 2)
        .glassEffect(dockGlass, in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: 1080 * t.scale)
    }
}

struct DemoAlbumInspectorSheet: View {
    let model: DemoStudioModel
    @Environment(\.theme) var theme
    @Environment(\.dismiss) var dismiss

    var body: some View {
        let t = theme
        let album = model.selectedAlbum
        VStack(alignment: .leading, spacing: t.space.m) {
            HStack(spacing: t.space.m) {
                Image(DemoArt.albumCover(album.paletteIndex))
                    .resizable()
                    .frame(width: 72 * t.scale, height: 72 * t.scale)
                    .border(t.gray.strongLine, width: t.line)
                VStack(alignment: .leading, spacing: t.space.xs) {
                    Text(album.artist).textStyle(.body, t.gray.secondaryText, theme: t)
                    Text("\(album.year) · \(album.format) · \(album.duration)").textStyle(.mono, t.accent, theme: t)
                }
            }
            PSectionHeader("TRACKLIST")
            VStack(spacing: 0) {
                ForEach(Array(album.tracks.enumerated()), id: \.offset) { idx, track in
                    PListRow("\(idx + 1). \(track.0)", detail: track.1, isSelected: idx == 0) {
                        model.isPlaying = true
                        model.statusNote = "Playing \(track.0)"
                    }
                }
            }
            HStack {
                Spacer(minLength: 0)
                PButton("Close", kind: .primary, name: "sheet-close") { dismiss() }
            }
        }
        .frame(width: 420 * t.scale)
    }
}

// MARK: - Tab 2: Liquid Glass Lab

struct DemoGlassLabView: View {
    let model: DemoStudioModel
    @Environment(\.theme) var theme

    var body: some View {
        let t = theme
        let baseGlass: Glass = model.glassClearStyle
            ? .clear.tint(Color(white: 1, opacity: model.glassTintOpacity * 0.25))
            : .regular.tint(Color(white: 0.05, opacity: model.glassTintOpacity))
        let interactiveGlass = baseGlass.interactive()
        let radius = model.glassCornerRadius

        ZStack {
            // Full-bleed high-contrast chromatic studio backdrop
            Image(DemoArt.backdrop(model.backdropKind))
                .resizable()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: t.space.l) {
                // Top floating Liquid Glass HUD bar
                HStack(spacing: t.space.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("LIQUID GLASS · DIRECT3D 12").textStyle(.caption, t.gray.text, theme: t)
                        Text("Bezel refraction, Kawase blur, specular rim & interactive morphing")
                            .textStyle(.body, t.gray.secondaryText, theme: t)
                    }
                    Spacer(minLength: t.space.s)
                    Text("0.24 ms GPU").textStyle(.mono, t.accent, theme: t)
                }
                .padding(horizontal: t.space.l, vertical: t.space.m)
                .glassEffect(baseGlass, in: RoundedRectangle(cornerRadius: radius))

                Spacer(minLength: t.space.s)

                // Centerpiece: Interactive GlassEffectContainer
                GlassEffectContainer(spacing: 28) {
                    VStack(spacing: t.space.l) {
                        HStack(spacing: t.space.l) {
                            // Interactive Glass Card 1
                            VStack(alignment: .leading, spacing: t.space.s) {
                                Text("REFRACTION").textStyle(.caption, t.accent, theme: t)
                                Text("Optical Bezel").textStyle(.largeTitle, t.gray.text, theme: t)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Edges bend the chromatic light bars behind")
                                        .textStyle(.body, t.gray.secondaryText, theme: t)
                                    Text("the surface with crisp specular rim falloff.")
                                        .textStyle(.body, t.gray.secondaryText, theme: t)
                                }
                            }
                            .padding(t.space.l)
                            .frame(width: 340 * t.scale, alignment: .leading)
                            .glassEffect(interactiveGlass, in: RoundedRectangle(cornerRadius: radius))

                            // Interactive Glass Card 2
                            VStack(alignment: .leading, spacing: t.space.s) {
                                Text("INTERACTIVE").textStyle(.caption, t.accent, theme: t)
                                Text("Hover & Press").textStyle(.largeTitle, t.gray.text, theme: t)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Move across these glass panels or click")
                                        .textStyle(.body, t.gray.secondaryText, theme: t)
                                    Text("the pill below to feel live GPU feedback.")
                                        .textStyle(.body, t.gray.secondaryText, theme: t)
                                }
                            }
                            .padding(t.space.l)
                            .frame(width: 340 * t.scale, alignment: .leading)
                            .glassEffect(interactiveGlass, in: RoundedRectangle(cornerRadius: radius))
                        }

                        // Floating Glass Pill Cluster
                        HStack(spacing: t.space.m) {
                            Button(action: {
                                withAnimation(.spring) {
                                    model.glassExpanded.toggle()
                                }
                            }) {
                                Text(model.glassExpanded ? "Collapse Cluster" : "Expand Glass Cluster")
                                    .textStyle(.body, t.gray.text, theme: t)
                                    .padding(horizontal: t.space.l, vertical: t.space.m)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .glassEffect(interactiveGlass)

                            if model.glassExpanded {
                                Text("Clear Capsule")
                                    .textStyle(.body, t.gray.text, theme: t)
                                    .padding(horizontal: t.space.l, vertical: t.space.m)
                                    .glassEffect(Glass.clear.interactive())

                                Text("Accent Tint")
                                    .textStyle(.body, t.gray.text, theme: t)
                                    .padding(horizontal: t.space.l, vertical: t.space.m)
                                    .glassEffect(Glass.regular.tint(t.accent.opacity(0.32)).interactive())
                            }
                        }
                    }
                }

                // Material Ladder comparison
                HStack(spacing: t.space.m) {
                    materialTile("Ultra Thin", .ultraThinMaterial, radius: min(radius, 12))
                    materialTile("Thin", .thinMaterial, radius: min(radius, 12))
                    materialTile("Regular", .regularMaterial, radius: min(radius, 12))
                    materialTile("Thick", .thickMaterial, radius: min(radius, 12))
                }
                .frame(maxWidth: 740 * t.scale)

                Spacer(minLength: t.space.s)

                // Live Glass Parameter Controls
                HStack(spacing: t.space.l) {
                    PSegmentedControl("Backdrop",
                                      selection: Binding(get: { model.backdropKind }, set: { model.backdropKind = $0 }),
                                      options: DemoBackdropKind.allCases.map { PickerOption($0.rawValue, value: $0) },
                                      name: "glass-backdrop")

                    VStack(alignment: .leading, spacing: 2) {
                        Text("TINT \(Int((model.glassTintOpacity * 100).rounded()))%").textStyle(.caption, t.gray.secondaryText, theme: t)
                        PSlider("Tint", value: Binding(get: { model.glassTintOpacity }, set: { model.glassTintOpacity = $0 }), in: 0.05...0.65, name: "glass-tint")
                            .frame(width: 130 * t.scale)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("RADIUS \(Int(model.glassCornerRadius.rounded())) pt").textStyle(.caption, t.gray.secondaryText, theme: t)
                        PSlider("Radius", value: Binding(get: { model.glassCornerRadius }, set: { model.glassCornerRadius = $0 }), in: 0...32, name: "glass-radius")
                            .frame(width: 130 * t.scale)
                    }

                    PToggle("Clear", isOn: Binding(get: { model.glassClearStyle }, set: { model.glassClearStyle = $0 }), name: "glass-clear")
                        .frame(width: 110 * t.scale)
                }
                .padding(horizontal: t.space.l, vertical: t.space.m)
                .background(t.material, in: RoundedRectangle(cornerRadius: 12))
                .border(t.gray.line, width: t.line)
            }
            .padding(t.space.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func materialTile(_ label: String, _ material: Material, radius: Double) -> some View {
        let t = theme
        return VStack(alignment: .leading, spacing: 2) {
            Text("MATERIAL").textStyle(.caption, t.gray.tertiaryText, theme: t)
            Text(label).textStyle(.body, t.gray.text, theme: t)
        }
        .padding(t.space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(material, in: RoundedRectangle(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).stroke(t.gray.line, lineWidth: t.line))
    }
}

// MARK: - Tab 3: Design System Studio

struct DemoDesignSystemView: View {
    let model: DemoStudioModel
    @Environment(\.theme) var theme

    var body: some View {
        let t = theme
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: t.space.l) {
                        // Top 2-column responsive grid of panels
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 340 * t.scale), spacing: t.space.l)], spacing: t.space.l) {
                            PPanel("Buttons & Actions", name: "ds-buttons") {
                                VStack(alignment: .leading, spacing: t.space.m) {
                                    Text("Four semantic button kinds driven by Theme tokens. Right-click any button to Customize its style or size.")
                                        .textStyle(.body, t.gray.secondaryText, theme: t)
                                    HStack(spacing: t.space.s) {
                                        PButton("Primary Action", kind: .primary, name: "ds-primary") {
                                            model.statusNote = "Triggered Primary Action"
                                        }
                                        PButton("Secondary", kind: .secondary, name: "ds-secondary") {
                                            model.statusNote = "Triggered Secondary"
                                        }
                                        PButton("Plain", kind: .plain, name: "ds-plain") {
                                            model.statusNote = "Triggered Plain"
                                        }
                                        PButton(symbol: "+", help: "Add item", name: "ds-icon") {
                                            model.statusNote = "Triggered Icon Button"
                                        }
                                    }
                                    HStack(spacing: t.space.s) {
                                        PButton("Open Modal Sheet", kind: .secondary, name: "ds-sheet-btn") {
                                            model.showsDesignSheet = true
                                        }
                                        PButton("Show Popover", kind: .secondary, name: "ds-pop-btn") {
                                            model.showsDesignPopover.toggle()
                                        }
                                        .panelPopover(isPresented: Binding(get: { model.showsDesignPopover }, set: { model.showsDesignPopover = $0 })) {
                                            VStack(alignment: .leading, spacing: t.space.s) {
                                                Text("Live Popover").textStyle(.title, t.gray.text, theme: t)
                                                Text("Anchored automatically to its trigger control.")
                                                    .textStyle(.body, t.gray.secondaryText, theme: t)
                                            }
                                            .frame(width: 240 * t.scale)
                                        }
                                    }
                                }
                            }

                            PPanel("Continuous & Choice Controls", name: "ds-controls") {
                                VStack(alignment: .leading, spacing: t.space.m) {
                                    HStack {
                                        Text("Level").textStyle(.body, t.gray.text, theme: t)
                                        Spacer(minLength: t.space.s)
                                        Text("\(Int((model.designSlider * 100).rounded()))%").textStyle(.mono, t.accent, theme: t)
                                    }
                                    PSlider("Level", value: Binding(get: { model.designSlider }, set: { model.designSlider = $0 }), in: 0...1, name: "ds-slider")
                                    PProgressBar("Progress", value: model.designSlider, name: "ds-progress")
                                    HStack(spacing: t.space.s) {
                                        PSegmentedControl("Layout",
                                                          selection: Binding(get: { model.designSegment }, set: { model.designSegment = $0 }),
                                                          options: [PickerOption("Grid", value: "Grid"), PickerOption("List", value: "List"), PickerOption("Split", value: "Split")],
                                                          name: "ds-segmented")
                                        Spacer(minLength: t.space.s)
                                        PPicker("Font",
                                                selection: Binding(get: { model.designPicker }, set: { model.designPicker = $0 }),
                                                options: [PickerOption("Geist", value: "Geist"), PickerOption("Inter", value: "Inter"), PickerOption("Geist Mono", value: "Geist Mono")],
                                                name: "ds-picker")
                                    }
                                }
                            }

                            PPanel("Switches & Text Input", name: "ds-inputs") {
                                VStack(alignment: .leading, spacing: t.space.s) {
                                    PToggle("Gapless playback", isOn: Binding(get: { model.toggleGapless }, set: { model.toggleGapless = $0 }), name: "ds-t1")
                                    PToggle("WASAPI exclusive mode", isOn: Binding(get: { model.toggleExclusive }, set: { model.toggleExclusive = $0 }), name: "ds-t2")
                                    PToggle("Bit-perfect output", isOn: Binding(get: { model.toggleBitPerfect }, set: { model.toggleBitPerfect = $0 }), name: "ds-t3")
                                    PTextField("Type anything...", text: Binding(get: { model.designText }, set: { model.designText = $0 }), name: "ds-field")
                                    Text("Echo: \(model.designText)").textStyle(.mono, t.gray.secondaryText, theme: t).lineLimit(1)
                                }
                            }

                            PPanel("Selectable List & Typography", name: "ds-list") {
                                VStack(alignment: .leading, spacing: 0) {
                                    PSectionHeader("TYPE SCALE")
                                    PListRow("Heading · 20 pt Geist", detail: "heading", isSelected: model.designSelectedRow == 0) { model.designSelectedRow = 0 }
                                    PListRow("Title · 15 pt Geist", detail: "title", isSelected: model.designSelectedRow == 1) { model.designSelectedRow = 1 }
                                    PListRow("Body · 13 pt Geist", detail: "body", isSelected: model.designSelectedRow == 2) { model.designSelectedRow = 2 }
                                    PListRow("Mono · 12 pt Geist Mono", detail: "0.24 ms", isSelected: model.designSelectedRow == 3) { model.designSelectedRow = 3 }
                                }
                            }
                        }
                    }
                    .padding(t.space.l)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                PScrollBar(proxy)
                    .padding(horizontal: 2, vertical: t.space.s)
            }
        }
        .panelSheet(isPresented: Binding(get: { model.showsDesignSheet }, set: { model.showsDesignSheet = $0 }), title: "Polymer Sheet") {
            VStack(alignment: .leading, spacing: t.space.m) {
                Text("Sheets dim the window, trap Escape cleanly, and compose with full theme tokens.")
                    .textStyle(.body, t.gray.secondaryText, theme: t)
                HStack {
                    Spacer(minLength: 0)
                    PButton("Done", kind: .primary, name: "ds-sheet-done") { model.showsDesignSheet = false }
                }
            }
            .frame(width: 360 * t.scale)
        }
    }
}

// MARK: - Tab 4: Audio & DSP Studio

struct DemoAudioStudioView: View {
    let model: DemoStudioModel
    @Environment(\.theme) var theme

    var body: some View {
        let t = theme
        let bands = ["60 Hz", "250 Hz", "1 kHz", "4 kHz", "14 kHz"]
        let avgGain = model.eqBands.reduce(0, +) / Double(model.eqBands.count)
        let peakNorm = min(max(0.68 + avgGain * 0.03 - (model.truePeakLimiter ? 0.08 : 0), 0.1), 0.98)
        let lufsNorm = min(max(0.56 + avgGain * 0.025, 0.1), 0.95)

        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: t.space.l) {
                        // Engine Spec Banner
                        HStack(spacing: t.space.l) {
                            specBadge("PIPELINE", "64-bit Float DSP")
                            specBadge("CODECS", "FLAC · ALAC · WAV · AIFF · MP3")
                            specBadge("OUTPUT", "WASAPI · Zero-Alloc Audio Thread")
                            specBadge("LOUDNESS", "ITU-R BS.1770-4")
                        }
                        .padding(t.space.m)
                        .background(Rectangle().fill(t.gray.surface))
                        .border(t.gray.line, width: t.line)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 360 * t.scale), spacing: t.space.l, alignment: .top)], spacing: t.space.l) {
                            PPanel("5-Band Parametric EQ (RBJ Biquad)", name: "audio-eq") {
                                VStack(alignment: .leading, spacing: t.space.m) {
                                    PSegmentedControl("Preset",
                                                      selection: Binding(get: { model.eqPreset }, set: { model.applyEQPreset($0) }),
                                                      options: [PickerOption("Studio", value: "Studio"), PickerOption("Flat", value: "Flat"), PickerOption("Warm", value: "Warm"), PickerOption("Vocal", value: "Vocal")],
                                                      name: "audio-preset")
                                    ForEach(Array(bands.enumerated()), id: \.offset) { idx, label in
                                        let v = model.eqBands[idx]
                                        let tenths = Int((v * 10).rounded())
                                        let sign = tenths > 0 ? "+" : (tenths < 0 ? "-" : "")
                                        let dbText = "\(sign)\(abs(tenths) / 10).\(abs(tenths) % 10) dB"
                                        HStack(spacing: t.space.s) {
                                            Text(label).textStyle(.mono, t.gray.secondaryText, theme: t).frame(width: 56 * t.scale, alignment: .leading)
                                            PSlider(label,
                                                    value: Binding(get: { model.eqBands[idx] }, set: { model.eqBands[idx] = $0; model.eqPreset = "Custom" }),
                                                    in: -12...12,
                                                    step: 0.5,
                                                    name: "eq-\(idx)")
                                            Text(dbText).textStyle(.mono, t.gray.text, theme: t).frame(width: 64 * t.scale, alignment: .trailing)
                                        }
                                    }
                                }
                            }

                            PPanel("Signal Chain & Metering", name: "audio-chain") {
                                VStack(alignment: .leading, spacing: t.space.m) {
                                    PToggle("ReplayGain (Album Mode)", isOn: Binding(get: { model.replayGain }, set: { model.replayGain = $0 }), name: "aud-rg")
                                    PToggle("True-Peak Limiter (-1.0 dBTP)", isOn: Binding(get: { model.truePeakLimiter }, set: { model.truePeakLimiter = $0 }), name: "aud-lim")
                                    PToggle("Bauer Binaural Crossfeed", isOn: Binding(get: { model.crossfeed }, set: { model.crossfeed = $0 }), name: "aud-xf")
                                    PToggle("TPDF Triangular Dither (24-bit)", isOn: Binding(get: { model.tpdfDither }, set: { model.tpdfDither = $0 }), name: "aud-dith")
                                    PToggle("Gapless Ring-Buffer Preload", isOn: Binding(get: { model.gaplessPreload }, set: { model.gaplessPreload = $0 }), name: "aud-gap")

                                    Rectangle().fill(t.gray.line).frame(height: t.line)

                                    VStack(alignment: .leading, spacing: t.space.xs) {
                                        HStack {
                                            Text("INTEGRATED LOUDNESS").textStyle(.caption, t.gray.tertiaryText, theme: t)
                                            Spacer(minLength: 0)
                                            Text("-14.2 LUFS").textStyle(.mono, t.accent, theme: t)
                                        }
                                        PProgressBar("Loudness", value: lufsNorm, name: "meter-lufs")
                                        HStack {
                                            Text("TRUE PEAK (4× OVERSAMPLED)").textStyle(.caption, t.gray.tertiaryText, theme: t)
                                            Spacer(minLength: 0)
                                            Text(model.truePeakLimiter ? "-1.0 dBTP" : "-0.2 dBTP").textStyle(.mono, t.gray.text, theme: t)
                                        }
                                        PProgressBar("True Peak", value: peakNorm, name: "meter-tp")
                                    }
                                }
                            }
                        }
                    }
                    .padding(t.space.l)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                PScrollBar(proxy)
                    .padding(horizontal: 2, vertical: t.space.s)
            }
        }
    }

    private func specBadge(_ label: String, _ value: String) -> some View {
        let t = theme
        return VStack(alignment: .leading, spacing: 2) {
            Text(label).textStyle(.caption, t.gray.tertiaryText, theme: t)
            Text(value).textStyle(.mono, t.gray.text, theme: t)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
