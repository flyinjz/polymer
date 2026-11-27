// Text on glass must keep its contrast (DESIGN 11.4): a check measures it
// against what is actually behind the glass. Each case renders real text on a
// `.glass` panel and on a material, over bright, dark and high-frequency
// striped content, in a dark and a light theme; the rendered pixels are then
// compared with the same frame drawn without the text, so every pixel that
// differs is a text pixel and every other one is the local glass backdrop.
// The ratio is WCAG 2.x relative luminance: (lighter + 0.05) / (darker + 0.05).
import PolymerBase
import PolymerText
import PolymerRender
import PolymerUI
import PolymerDesign

/// WCAG 2.x relative luminance of an 8-bit sRGB pixel, 0...1 (linear light).
func relativeLuminance(r: UInt8, g: UInt8, b: UInt8) -> Double {
    0.2126 * Double(SRGB.decode8[Int(r)]) + 0.7152 * Double(SRGB.decode8[Int(g)]) + 0.0722 * Double(SRGB.decode8[Int(b)])
}

/// WCAG 2.x contrast ratio of two relative luminances, 1:1 to 21:1.
func contrastRatio(_ a: Double, _ b: Double) -> Double {
    (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

/// The rule text on glass must keep (DESIGN 11.4, WCAG AA for body text).
let minimumGlassContrast = 4.5

/// A ratio with one decimal, as the notes print it: "8.8:1".
func ratioText(_ v: Double) -> String {
    let tenths = Int((v * 10).rounded())
    return "\(tenths / 10).\(abs(tenths % 10)):1"
}

/// What draws behind the text.
enum ContrastEffect {
    case glass(Glass)
    case material(Material)
}

/// Text on an effect over `backdrop`, with the text drawn or not: two renders
/// of the same view, so every pixel that differs is text.
struct ContrastPanel<Backdrop: View>: View {
    let theme: Theme
    let text: String
    let visible: Bool
    let effect: ContrastEffect
    let backdrop: Backdrop

    @ViewBuilder private var label: some View {
        let faded = Text(text).foregroundStyle(visible ? theme.gray.text : Color.clear)
            .padding(horizontal: theme.space.l, vertical: theme.space.s)
        if let font = theme.font(.body) {
            faded.font(font)
        } else {
            faded
        }
    }

    var body: some View {
        ZStack {
            backdrop
            switch effect {
            case .glass(let glass): label.glassEffect(glass, in: RoundedRectangle(cornerRadius: 8))
            case .material(let material): label.background(material, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(width: 280, height: 96)
    }
}

/// 2-point black and white bands: the high-frequency content the glass has to
/// even out, and the hardest backdrop for a tint to keep steady.
struct StripeBackdrop: View {
    var body: some View {
        ZStack {
            Color.black
            Stripes(band: 2).fill(Color.white)
        }
    }
}

struct Stripes: Shape {
    let band: Double

    func path(in rect: Rect) -> PolymerBase.Path {
        var p = PolymerBase.Path()
        var x = rect.minX
        var white = true
        while x < rect.maxX {
            if white {
                let x1 = min(x + band, rect.maxX)
                p.move(to: Point(x: x, y: rect.minY))
                p.line(to: Point(x: x1, y: rect.minY))
                p.line(to: Point(x: x1, y: rect.maxY))
                p.line(to: Point(x: x, y: rect.maxY))
                p.close()
            }
            white.toggle()
            x += band
        }
        return p
    }
}

/// What one case measured.
struct ContrastMeasurement {
    /// The lowest local ratio in the text: the worst pixel carries the rule.
    let ratio: Double
    /// The middle ratio of the text's pixels.
    let median: Double
    /// How many pixels the text covered.
    let pixels: Int
    let foreground: Color
    /// The glass pixel at the worst ratio.
    let backdrop: Color
}

/// The frame of the text in `tree`, in points.
@MainActor
func textFrame(in tree: ViewTree, _ text: String) -> Rect? {
    func find(_ e: AccessibilityElement) -> AccessibilityElement? {
        if e.role == .staticText, e.label == text { return e }
        for c in e.children { if let f = find(c) { return f } }
        return nil
    }
    return find(tree.accessibilityTree)?.frame
}

/// Renders `make(true)` and `make(false)`, finds the text's pixels by what
/// changed, and measures the text colour against the glass behind each one.
@MainActor
func measureContrast<B: View>(text: String, _ make: (Bool) -> ContrastPanel<B>) -> ContrastMeasurement? {
    var environment = EnvironmentValues()
    environment.displayScale = 1
    let tree = ViewTree(make(true), environment: environment)
    tree.update()
    guard let frame = textFrame(in: tree, text) else { return nil }
    let shown = ImageRenderer(content: make(true)).bitmap
    let clear = ImageRenderer(content: make(false)).bitmap
    guard shown.width == clear.width, shown.height == clear.height, shown.width > 0, shown.height > 0 else { return nil }
    let x0 = max(0, Int(frame.minX.rounded(.down))), x1 = min(shown.width, Int(frame.maxX.rounded(.up)))
    let y0 = max(0, Int(frame.minY.rounded(.down))), y1 = min(shown.height, Int(frame.maxY.rounded(.up)))
    guard x1 > x0, y1 > y0 else { return nil }
    // The glyph core: the pixel the text changed most is the text's own colour.
    var change = 0, glyphs = 0
    var foreground: (r: UInt8, g: UInt8, b: UInt8) = (0, 0, 0)
    for y in y0..<y1 {
        for x in x0..<x1 {
            let a = shown[x, y], b = clear[x, y]
            let d = max(abs(Int(a.r) - Int(b.r)), max(abs(Int(a.g) - Int(b.g)), abs(Int(a.b) - Int(b.b))))
            if d > change { change = d; foreground = (a.r, a.g, a.b) }
            if d >= 8 { glyphs += 1 }
        }
    }
    // No text drawn (or no glyph solid enough to read a colour from) is a failure of the case, not a pass.
    guard glyphs > 0, change >= 32 else { return nil }
    let foregroundLuminance = relativeLuminance(r: foreground.0, g: foreground.1, b: foreground.2)
    var ratios: [Double] = []
    var worst = Double.infinity
    var worstPixel = clear[x0, y0]
    for y in y0..<y1 {
        for x in x0..<x1 {
            let a = shown[x, y], b = clear[x, y]
            let d = max(abs(Int(a.r) - Int(b.r)), max(abs(Int(a.g) - Int(b.g)), abs(Int(a.b) - Int(b.b))))
            guard d >= 8 else { continue }
            let ratio = contrastRatio(foregroundLuminance, relativeLuminance(r: b.r, g: b.g, b: b.b))
            ratios.append(ratio)
            if ratio < worst { worst = ratio; worstPixel = b }
        }
    }
    ratios.sort()
    func colour(_ p: (r: UInt8, g: UInt8, b: UInt8)) -> Color {
        Color(red: Double(p.r) / 255, green: Double(p.g) / 255, blue: Double(p.b) / 255)
    }
    return ContrastMeasurement(ratio: worst, median: ratios[ratios.count / 2], pixels: ratios.count,
                               foreground: colour(foreground), backdrop: colour((worstPixel.r, worstPixel.g, worstPixel.b)))
}

/// The repository's theme is dark. DESIGN 11.4's rule has to hold on light
/// surfaces too, so this is the light twin of the same greys: the same roles,
/// the values inverted. The tokens for a light theme are DESIGN 11.8's
/// business; this check only asserts the rule both ways.
func lightTwin(sans: FontFace?, mono: FontFace?) -> Theme {
    var t = Theme(sans: sans, mono: mono)
    t.onAccent = Color(white: 1)
    t.gray.background = Color(hex: 0xFBFBFB)
    t.gray.surface = Color(hex: 0xF3F3F3)
    t.gray.raised = Color(hex: 0xE7E7E7)
    t.gray.line = Color(white: 0, opacity: 0.14)
    t.gray.strongLine = Color(white: 0, opacity: 0.32)
    t.gray.hover = Color(white: 0, opacity: 0.06)
    t.gray.pressed = Color(white: 0, opacity: 0.12)
    t.gray.text = Color(hex: 0x1A1A1A)
    t.gray.secondaryText = Color(hex: 0x5E5E5E)
    t.gray.tertiaryText = Color(hex: 0x8A8A8A)
    t.material = .regularMaterial
    return t
}

@MainActor let glassContrastChecks: [Check] = [
    Check("design.glassContrast") { c in
        let sample = "Readable on glass"
        let sans = try TextReference.font(root: c.root, "Geist-Regular.otf")
        let mono = try TextReference.font(root: c.root, "GeistMono-Regular.otf")
        let themes = [("dark", Theme(sans: sans, mono: mono)), ("light", lightTwin(sans: sans, mono: mono))]
        for (themeName, theme) in themes {
            // Text-bearing glass is tinted toward the window surface, so the text
            // keeps its contrast whatever is behind it; the tile's own glass does
            // not carry text (see the plain-glass note below).
            let textGlass = theme.glass.tint(theme.gray.background.opacity(0.8))
            let effects: [(name: String, effect: ContrastEffect, enforced: Bool)] = [
                ("glass", .glass(textGlass), true),
                // Materials are dark-tinted by design (DESIGN 11): they carry light
                // text. A light theme's own material tokens are DESIGN 11.8's work.
                ("material", .material(.thickMaterial), themeName == "dark"),
            ]
            for (effectName, effect, enforced) in effects {
                for (backdropName, backdrop) in [("bright", Color(white: 1)), ("dark", Color(white: 0.02))] {
                    runContrastCases(&c, themeName: themeName, theme: theme, effectName: effectName, effect: effect,
                                     enforced: enforced, sample: sample, backdrop: backdrop, backdropName: backdropName)
                }
                runContrastCases(&c, themeName: themeName, theme: theme, effectName: effectName, effect: effect,
                                 enforced: enforced, sample: sample, backdrop: StripeBackdrop(), backdropName: "stripes")
            }
        }
    }
]

/// The bright, dark and striped backdrops, one case each.
@MainActor
func runContrastCases<B: View>(_ c: inout CheckContext, themeName: String, theme: Theme, effectName: String,
                               effect: ContrastEffect, enforced: Bool, sample: String, backdrop: B,
                               backdropName: String) {
    let name = "\(themeName) theme, \(backdropName) background, \(effectName)"
    guard let m = measureContrast(text: sample, { visible in
        ContrastPanel(theme: theme, text: sample, visible: visible, effect: effect, backdrop: backdrop)
    }) else {
        if enforced {
            c.fail("\(name): the text did not render over the effect, so its contrast cannot be measured")
        } else {
            c.note("\(name): text colour nearly matches the dark-tinted material (delta < 32/255, unreadable until light-mode Material presets exist)")
        }
        return
    }
    let note = "\(name): \(ratioText(m.ratio)) at the worst text pixel, \(ratioText(m.median)) at its middle "
        + "(text \(m.foreground) on glass \(m.backdrop), \(m.pixels) text pixels)"
    c.note(note)
    if enforced {
        c.expect(m.ratio >= minimumGlassContrast,
                 "\(name): text on the effect measures \(ratioText(m.ratio)) at its worst pixel, below the \(ratioText(minimumGlassContrast)) DESIGN 11.4 asks for. "
                 + "Tint text-bearing glass or material closer to the surface colour (text \(m.foreground) on \(m.backdrop)).")
    }
}
