import PolymerBase
import PolymerPlatform
import PolymerText
import PolymerRender

/// Comparison of Polymer's text with the CoreText references.
public enum TextReference {
    public struct Case: Sendable {
        public let file: String
        public let font: String
        public let pointSize: Double
        public let scale: Double
        public let theme: String
        public let background: Double
        public let foreground: Double
        public let text: String
        public let originX: Double
        public let baselineFromBottom: Double
        public let width: Int
        public let height: Int
    }

    public struct Result: Sendable {
        public let file: String
        /// Mean absolute difference, 0...255.
        public let meanError: Double
        /// Largest single-pixel difference, 0...255.
        public let maxError: Int
        /// Ink (coverage-weighted) of ours relative to CoreText's; 1 = same weight.
        public let inkRatio: Double
        public let ours: Bitmap
        public let reference: Bitmap
    }

    public static func cases(root: String) throws -> [Case] {
        let manifest = try JSON.parse(try Platform.files.read(Path.join(root, "Tests/Reference/Text/manifest.json")))
        guard let images = manifest["images"]?.array else { throw FileError(path: "manifest.json", message: "no images array") }
        return images.compactMap { j in
            guard let file = j["file"]?.string, let font = j["font"]?.string, let size = j["pointSize"]?.double,
                  let scale = j["scale"]?.double, let theme = j["theme"]?.string, let bg = j["background"]?.double,
                  let fg = j["foreground"]?.double, let text = j["text"]?.string, let ox = j["originX"]?.double,
                  let base = j["baselineFromBottom"]?.double, let w = j["width"]?.int, let h = j["height"]?.int else { return nil }
            return Case(file: file, font: font, pointSize: size, scale: scale, theme: theme, background: bg, foreground: fg,
                        text: text, originX: ox, baselineFromBottom: base, width: w, height: h)
        }
    }

    nonisolated(unsafe) static var fontCache: [String: FontFace] = [:]
    nonisolated(unsafe) static var referenceCache: [String: Bitmap] = [:]

    public static func font(root: String, _ name: String) throws -> FontFace {
        if let f = fontCache[name] { return f }
        let f = try FontFace(data: try Platform.files.read(Path.join(root, "Tests/Fixtures/Fonts", name)))
        fontCache[name] = f
        return f
    }

    public static func reference(root: String, _ file: String) throws -> Bitmap {
        if let b = referenceCache[file] { return b }
        let b = try PNG.decode(try Platform.files.read(Path.join(root, "Tests/Reference/Text", file)))
        referenceCache[file] = b
        return b
    }

    public static func render(_ c: Case, root: String, options: TextRenderingOptions) throws -> Bitmap {
        let font = try font(root: root, c.font)
        var canvas = Canvas(width: c.width, height: c.height, scale: c.scale, background: Color(white: c.background))
        // The manifest gives pixel positions with y up from the bottom.
        let baselineY = (Double(c.height) - c.baselineFromBottom) / c.scale
        canvas.drawText(c.text, font: font, size: c.pointSize, at: Point(x: c.originX / c.scale, y: baselineY),
                        color: Color(white: c.foreground), options: options)
        return canvas.bitmap
    }

    public static func compare(_ c: Case, root: String, options: TextRenderingOptions) throws -> Result {
        let ours = try render(c, root: root, options: options)
        let ref = try reference(root: root, c.file)
        guard ref.width == ours.width, ref.height == ours.height else {
            throw FileError(path: c.file, message: "reference is \(ref.width)x\(ref.height), manifest says \(c.width)x\(c.height)")
        }
        let a = ours.grey, b = ref.grey
        var sum = 0.0, maxE = 0.0, inkA = 0.0, inkB = 0.0
        let bg = c.background, span = c.foreground - c.background
        for i in 0..<a.count {
            let e = abs(a[i] - b[i]) * 255
            sum += e; maxE = max(maxE, e)
            inkA += (a[i] - bg) / span
            inkB += (b[i] - bg) / span
        }
        return Result(file: c.file, meanError: sum / Double(a.count), maxError: Int(maxE.rounded()),
                      inkRatio: inkB != 0 ? inkA / inkB : 0, ours: ours, reference: ref)
    }

    /// Stacked: CoreText on top, ours in the middle, difference (4x) below.
    /// In the difference, red marks where ours is darker, green where it is lighter.
    public static func diffImage(_ r: Result) -> Bitmap {
        let w = r.ours.width, h = r.ours.height
        var out = Bitmap(width: w, height: h * 3, fill: (0, 0, 0, 255))
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                for c in 0..<4 {
                    out.pixels[i + c] = r.reference.pixels[i + c]
                    out.pixels[(h * w) * 4 + i + c] = r.ours.pixels[i + c]
                }
                let d = Int(r.ours.pixels[i]) - Int(r.reference.pixels[i])
                let o = (2 * h * w) * 4 + i
                out.pixels[o] = UInt8(min(255, max(0, -d * 4)))
                out.pixels[o + 1] = UInt8(min(255, max(0, d * 4)))
                out.pixels[o + 2] = 0
            }
        }
        return out
    }

    /// Mean error over all cases (or those whose file name contains `filter`).
    public static func score(root: String, options: TextRenderingOptions, filter: String? = nil) throws -> (mean: Double, results: [Result]) {
        var results: [Result] = []
        for k in try cases(root: root) where filter == nil || k.file.contains(filter!) {
            results.append(try compare(k, root: root, options: options))
        }
        let mean = results.isEmpty ? 0 : results.reduce(0) { $0 + $1.meanError } / Double(results.count)
        return (mean, results)
    }
}

@MainActor let textChecks: [Check] = [
    Check("text.parse") { c in
        for name in ["JetBrainsMono-Regular.ttf", "GeistMono-Regular.otf", "Inter-Regular.otf", "Geist-Regular.otf"] {
            let f = try TextReference.font(root: c.root, name)
            c.expect(f.unitsPerEm >= 1000, "\(name): unitsPerEm \(f.unitsPerEm)")
            let g = f.glyph(for: "H")
            c.expect(g != 0, "\(name): no glyph for H")
            let b = f.outline(g).controlBounds
            c.expect(b.height > Double(f.unitsPerEm) / 2, "\(name): H outline height \(b.height)")
            c.note("\(name): \(f.familyName), upem \(f.unitsPerEm), \(f.glyphCount) glyphs, \(f.hasCFF ? "CFF" : "TrueType"), AV kern \(f.kern(f.glyph(for: "A"), f.glyph(for: "V")))")
        }
    },
    Check("text.coretext") { c in
        let dir = Path.join(c.outputDirectory, "text")
        try Platform.files.createDirectory(dir)
        let (mean, results) = try TextReference.score(root: c.root, options: .standard)
        c.expectEqual(results.count, 128, "reference cases")
        var report: [JSON] = []
        var worst = results.first
        for r in results {
            if r.meanError > worst!.meanError { worst = r }
            report.append(["file": .string(r.file), "meanError": .number((r.meanError * 1000).rounded() / 1000),
                           "maxError": .number(Double(r.maxError)), "inkRatio": .number((r.inkRatio * 1000).rounded() / 1000)])
            try Platform.files.write(PNG.encode(TextReference.diffImage(r)), to: Path.join(dir, r.file))
        }
        try Platform.files.write(JSON.array(report).pretty, to: Path.join(dir, "report.json"))
        c.note("mean error \(mean) / 255 over \(results.count) images; worst \(worst?.meanError ?? 0) (\(worst?.file ?? ""))")
        c.note("diff images and report.json in \(dir)")
        // Regression bound, tightened as tuning improves (Docs/HANDOFF.md).
        c.expect(mean < 1.2, "mean error \(mean) is above the bound")
    },
    Check("text.substitution") { c in
        // Inter raises the colon between digits (contextual alternates, on by default as in CoreText).
        let inter = try TextReference.font(root: c.root, "Inter-Regular.otf")
        let colon = inter.glyph(for: ":")
        let time = TextLayout.line("3:42", font: inter, pixelSize: 13)
        let words = TextLayout.line("a:b", font: inter, pixelSize: 13)
        c.expectEqual(time.count, 4, "one glyph per character in 3:42")
        c.expect(time.count == 4 && time[1].glyph != colon, "the colon between digits is the raised form")
        c.expect(words.count == 3 && words[1].glyph == colon, "the colon between letters is the plain one")
        c.expectEqual(time.map(\.cluster), [0, 1, 2, 3], "each glyph remembers its character")
        // Fonts without substitutions for a text are unchanged.
        let mono = try TextReference.font(root: c.root, "GeistMono-Regular.otf")
        let plain = TextLayout.line("Tracks 12", font: mono, pixelSize: 11)
        c.expectEqual(plain.map(\.glyph), "Tracks 12".unicodeScalars.map { mono.glyph(for: $0) }, "plain text keeps its character-map glyphs")
    },
    Check("text.cache") { c in
        let face = try TextReference.font(root: c.root, "Inter-Regular.otf")
        func draw(_ cache: GlyphCache?) -> Bitmap {
            var canvas = Canvas(width: 300, height: 40, scale: 2, background: Color(white: 0.063))
            canvas.glyphCache = cache
            canvas.drawText("Cached glyphs 3:42", font: face, size: 13, at: Point(x: 6.25, y: 14), color: .white)
            return canvas.bitmap
        }
        let cache = GlyphCache()
        let plain = draw(nil), first = draw(cache), second = draw(cache)
        c.expect(plain == first && first == second, "cached and uncached drawing give the same pixels")
        c.expect(cache.hits >= 18, "the second draw comes from the cache (\(cache.hits) hits, \(cache.misses) misses)")
        // The same glyph at the same fraction of a pixel is the same anywhere on screen.
        let g = face.glyph(for: "g")
        let near = GlyphRenderer.mask(font: face, glyph: g, pixelSize: 26, x: 3.3, y: 20.6, luminance: 1)
        let far = GlyphRenderer.mask(font: face, glyph: g, pixelSize: 26, x: 5003.3, y: 9020.6, luminance: 1)
        c.expect(near.coverage == far.coverage && far.left - near.left == 5000 && far.top - near.top == 9000,
                 "a glyph's pixels don't depend on how far it is from the origin")
    },
]
