// Mac-style text rendering: no hinting, exact fractional positions and
// stem darkening by pixels per em, tuned against CoreText.
import PolymerBase

/// Parameters of the text look, tuned against the CoreText references in
/// Tests/Reference/Text (Docs/HANDOFF.md has the measurements).
///
/// Stem darkening grows each glyph's outline by `slope * ppem` pixels in
/// width, up to `maxGrowth`, and by the same amount in height, upward only
/// (the bottom edge stays put). Like CoreGraphics, light text grows more
/// than dark text: the slope rises with the linear luminance of the text
/// colour. Coverage is then blended as plain source-over in sRGB-encoded
/// values, as CoreGraphics does.
public struct TextRenderingOptions: Hashable, Sendable {
    /// Growth per pixel-per-em for black text.
    public var slopeBlack: Double = 0.0118
    /// Added growth per pixel-per-em for white text (scaled by linear luminance).
    public var slopeLuminance: Double = 0.0191
    /// Largest growth in pixels.
    public var maxGrowth: Double = 0.6
    /// Turns stem darkening off (for comparisons).
    public var stemDarkening: Bool = true

    public init() {}

    public static let standard = TextRenderingOptions()

    /// Outline growth in pixels (width and height alike) for text of the given linear luminance.
    public func growth(ppem: Double, luminance: Double) -> Double {
        guard stemDarkening else { return 0 }
        return min(maxGrowth, ppem * (slopeBlack + slopeLuminance * luminance))
    }
}

/// One positioned glyph of a line. `x` and `advance` are in the units the
/// line was laid out in (pixels or points), relative to the line's origin.
public struct PositionedGlyph: Hashable, Sendable {
    public var glyph: GlyphID
    public var x: Double
    public var advance: Double
    /// Index, within its paragraph, of the first character the glyph stands for (a ligature stands for several).
    public var cluster: Int
    public init(glyph: GlyphID, x: Double, advance: Double, cluster: Int = 0) {
        self.glyph = glyph; self.x = x; self.advance = advance; self.cluster = cluster
    }
}

/// One line of laid-out text.
public struct TextLine: Hashable, Sendable {
    public var glyphs: [PositionedGlyph]
    /// Width of the visible glyphs: spaces at the end of a wrapped line are not counted.
    public var width: Double
    /// True when the line ends in an ellipsis because text was cut off.
    public var truncated: Bool = false
}

public enum TextLayout {
    /// Glyphs for one line at `pixelSize` per em: character map, advances and pair kerning.
    public static func line(_ text: String, font: FontFace, pixelSize: Double) -> [PositionedGlyph] {
        line(Array(text.unicodeScalars)[...], font: font, pixelSize: pixelSize)
    }

    static func line(_ scalars: ArraySlice<Unicode.Scalar>, font: FontFace, pixelSize: Double) -> [PositionedGlyph] {
        let scale = pixelSize / Double(font.unitsPerEm)
        let shaped = font.shape(scalars)
        var out: [PositionedGlyph] = []
        out.reserveCapacity(shaped.count)
        var x = 0.0
        var prev: GlyphID? = nil
        for s in shaped {
            let g = s.glyph
            if let p = prev { x += Double(font.kern(p, g)) * scale }
            let adv = Double(font.advance(g)) * scale
            out.append(PositionedGlyph(glyph: g, x: x, advance: adv, cluster: s.cluster))
            x += adv
            prev = g
        }
        return out
    }

    public static func width(_ glyphs: [PositionedGlyph]) -> Double {
        guard let l = glyphs.last else { return 0 }
        return l.x + l.advance
    }

    /// Lines of text wrapped to `maxWidth` (nil: only explicit line breaks).
    ///
    /// Lines break at UAX #14 opportunities (spaces, hyphens, dashes, slashes,
    /// zero-width spaces, CJK/ideographic boundaries) while respecting glue/joiners
    /// and punctuation rules; a word wider than the line breaks between characters.
    /// With a `lineLimit`, text that doesn't fit ends in an ellipsis. Always returns
    /// at least one line.
    public static func lines(_ text: String, font: FontFace, pixelSize: Double, maxWidth: Double? = nil,
                             lineLimit: Int? = nil) -> [TextLine] {
        let scalars = Array(text.unicodeScalars)
        var lines: [TextLine] = []
        let limit = max(1, lineLimit ?? Int.max)
        var start = 0
        // One paragraph per explicit line break.
        while true {
            var end = start
            while end < scalars.count, !isHardBreak(scalars[end]) { end += 1 }
            let para = Array(scalars[start..<end])
            let glyphs = line(para[...], font: font, pixelSize: pixelSize)
            let breaks = maxWidth != nil ? UnicodeLineBreak.breakOpportunities(in: para) : []
            var nextStart = end
            if end < scalars.count {
                if scalars[end] == "\r", end + 1 < scalars.count, scalars[end + 1] == "\n" {
                    nextStart = end + 2
                } else {
                    nextStart = end + 1
                }
            }
            let lastParagraph = end >= scalars.count
            var s = 0
            repeat {
                let e = maxWidth.map { lineEnd(glyphs, para, breaks: breaks, from: s, maxWidth: $0) }
                    ?? (end: glyphs.count, next: glyphs.count)
                // The last allowed line, with text left over, is cut with an ellipsis.
                if lines.count == limit - 1, e.next < glyphs.count || !lastParagraph {
                    lines.append(truncated(glyphs, para, from: s, maxWidth: maxWidth, font: font, pixelSize: pixelSize))
                    return lines
                }
                lines.append(slice(glyphs, s..<e.end))
                s = e.next
            } while s < glyphs.count
            if lastParagraph { break }
            start = nextStart
        }
        return lines
    }

    static func isHardBreak(_ s: Unicode.Scalar) -> Bool {
        let c = UnicodeLineBreak.lineBreakClass(for: s)
        return c == .LF || c == .CR || c == .BK
    }

    static func isSpace(_ s: Unicode.Scalar) -> Bool { s == " " || s == "\t" || s == "\u{200B}" }

    /// Where the line starting at glyph `s` ends: `end` is past its last visible
    /// glyph, `next` is where the following line starts.
    static func lineEnd(
        _ g: [PositionedGlyph], _ text: [Unicode.Scalar],
        breaks: [UnicodeLineBreak.BreakOpportunity], from s: Int, maxWidth: Double
    ) -> (end: Int, next: Int) {
        guard s < g.count else { return (s, s) }
        let x0 = g[s].x
        var breakEnd: Int? = nil, breakNext = 0
        var i = s
        while i < g.count {
            let ci = g[i].cluster
            if isSpace(text[ci]) {
                // A run of spaces hangs past the edge; record a break when UAX #14 allows one after it.
                var j = i
                while j < g.count, isSpace(text[g[j].cluster]) { j += 1 }
                if i > s {
                    if j < g.count {
                        let cj = g[j].cluster
                        if cj < breaks.count, breaks[cj] != .prohibited {
                            breakEnd = i; breakNext = j
                        }
                    } else {
                        breakEnd = i; breakNext = j
                    }
                }
                i = j
                continue
            }
            if i > s, ci < breaks.count, breaks[ci] != .prohibited, !isSpace(text[g[i - 1].cluster]) {
                breakEnd = i; breakNext = i
            }
            if g[i].x + g[i].advance - x0 > maxWidth + 1e-9, i > s {
                if let b = breakEnd { return (b, breakNext) }
                return (i, i)
            }
            i += 1
        }
        // The rest fits; spaces at the very end of a paragraph stay part of it.
        return (g.count, g.count)
    }

    static func slice(_ g: [PositionedGlyph], _ r: Range<Int>) -> TextLine {
        guard !r.isEmpty else { return TextLine(glyphs: [], width: 0) }
        let x0 = g[r.lowerBound].x
        let glyphs = g[r].map { PositionedGlyph(glyph: $0.glyph, x: $0.x - x0, advance: $0.advance) }
        return TextLine(glyphs: glyphs, width: width(glyphs))
    }

    static func ellipsis(font: FontFace, pixelSize: Double, at x: Double) -> [PositionedGlyph] {
        let scale = pixelSize / Double(font.unitsPerEm)
        let g = font.glyph(for: "\u{2026}")
        if g != 0 { return [PositionedGlyph(glyph: g, x: x, advance: Double(font.advance(g)) * scale)] }
        let dot = font.glyph(for: "."), adv = Double(font.advance(dot)) * scale
        return (0..<3).map { PositionedGlyph(glyph: dot, x: x + Double($0) * adv, advance: adv) }
    }

    /// The last allowed line when text is left over: as many glyphs as fit before an ellipsis.
    static func truncated(_ g: [PositionedGlyph], _ text: [Unicode.Scalar], from s: Int, maxWidth: Double?,
                          font: FontFace, pixelSize: Double) -> TextLine {
        let dotsWidth = width(ellipsis(font: font, pixelSize: pixelSize, at: 0))
        var e = g.count
        if let maxWidth, s < g.count {
            let x0 = g[s].x
            e = s
            while e < g.count, g[e].x + g[e].advance - x0 + dotsWidth <= maxWidth + 1e-9 { e += 1 }
        }
        while e > s, isSpace(text[g[e - 1].cluster]) { e -= 1 }
        var l = slice(g, s..<e)
        l.glyphs += ellipsis(font: font, pixelSize: pixelSize, at: l.width)
        l.width = width(l.glyphs)
        l.truncated = true
        return l
    }
}

/// Glyph outlines and coverage masks kept between draws. One per renderer;
/// not shared between threads.
///
/// Masks are keyed by the exact fractional pixel offset, so cached and
/// uncached drawing give identical pixels.
public final class GlyphCache {
    struct OutlineKey: Hashable {
        let face: ObjectIdentifier
        let glyph: GlyphID
        let pixelSize: Double
        let growth: Double
    }
    struct MaskKey: Hashable {
        let outline: OutlineKey
        let fx: Double
        let fy: Double
    }

    private var faces: [ObjectIdentifier: FontFace] = [:]
    private var outlines: [OutlineKey: [[Point]]] = [:]
    private var masks: [MaskKey: CoverageMask] = [:]
    /// Most masks (and outlines) kept; the cache is emptied when it fills.
    public var limit = 8192
    public private(set) var hits = 0
    public private(set) var misses = 0

    public init() {}

    func mask(font: FontFace, glyph: GlyphID, pixelSize: Double, growth: Double, fx: Double, fy: Double) -> CoverageMask {
        let ok = OutlineKey(face: ObjectIdentifier(font), glyph: glyph, pixelSize: pixelSize, growth: growth)
        let key = MaskKey(outline: ok, fx: fx, fy: fy)
        if let m = masks[key] { hits += 1; return m }
        misses += 1
        let contours: [[Point]]
        if let c = outlines[ok] { contours = c } else {
            contours = GlyphRenderer.contours(font: font, glyph: glyph, pixelSize: pixelSize, growth: growth)
            if outlines.count >= limit { outlines.removeAll(keepingCapacity: true) }
            outlines[ok] = contours
            faces[ok.face] = font   // keeps the face alive so its identity stays unique
        }
        let m = Rasterizer.rasterize(contours, dx: fx, dy: fy)
        if masks.count >= limit { masks.removeAll(keepingCapacity: true) }
        masks[key] = m
        return m
    }

    public func removeAll() {
        faces.removeAll(); outlines.removeAll(); masks.removeAll()
    }
}

public enum GlyphRenderer {
    /// Coverage of one glyph whose origin (baseline-left) sits at pixel position (x, y), y down.
    ///
    /// The glyph is rasterised at the fractional part of the position and the
    /// mask moved by the whole part, so the same glyph at the same fraction
    /// gives the same pixels anywhere on screen.
    public static func mask(font: FontFace, glyph: GlyphID, pixelSize: Double, x: Double, y: Double,
                            luminance: Double, options: TextRenderingOptions = .standard,
                            cache: GlyphCache? = nil) -> CoverageMask {
        let ix = x.rounded(.down), iy = y.rounded(.down)
        let fx = x - ix, fy = y - iy
        let growth = options.growth(ppem: pixelSize, luminance: luminance)
        var m: CoverageMask
        if let cache {
            m = cache.mask(font: font, glyph: glyph, pixelSize: pixelSize, growth: growth, fx: fx, fy: fy)
        } else {
            m = Rasterizer.rasterize(contours(font: font, glyph: glyph, pixelSize: pixelSize, growth: growth), dx: fx, dy: fy)
        }
        m.left += Int(ix); m.top += Int(iy)
        return m
    }

    /// The glyph's outline as polygons in pixels, origin at the baseline-left, y down, with stem darkening applied.
    static func contours(font: FontFace, glyph: GlyphID, pixelSize: Double, growth: Double) -> [[Point]] {
        let outline = font.outline(glyph)
        if outline.isEmpty { return [] }
        let s = pixelSize / Double(font.unitsPerEm)
        let t = AffineTransform(a: s, b: 0, c: 0, d: -s, tx: 0, ty: 0)
        var contours = outline.applying(t).flattened(tolerance: 0.01)
        guard growth > 0 else { return contours }
        contours = Embolden.apply(contours, x: growth, y: growth)
        // Growth goes upward: the bottom edge stays where it was.
        return contours.map { $0.map { Point(x: $0.x, y: $0.y - growth / 2) } }
    }
}
