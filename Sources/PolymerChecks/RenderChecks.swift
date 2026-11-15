import PolymerBase
import PolymerPlatform
import PolymerRender
import PolymerText

@MainActor let renderChecks: [Check] = [
    Check("render.jpeg") { c in
        let dir = Path.join(c.root, "Tests/Fixtures/Images")
        let cases = ["baseline-420", "baseline-422", "baseline-444", "baseline-440", "baseline-411", "grey", "rgb",
                     "restart-optimized", "coarse-16bit-tables", "progressive-420", "progressive-444-restart", "progressive-mandel"]
        let clock = ContinuousClock()
        for name in cases {
            let data = try Platform.files.read(Path.join(dir, name + ".jpg"))
            let reference = try PNG.decode(try Platform.files.read(Path.join(dir, name + ".png")))
            let ours: Bitmap
            do { ours = try JPEG.decode(data) } catch { c.fail("\(name): \(error)"); continue }
            guard ours.width == reference.width, ours.height == reference.height else {
                c.fail("\(name): \(ours.width)x\(ours.height), expected \(reference.width)x\(reference.height)"); continue
            }
            // Exact match with libjpeg-turbo; on failure, say how far off and where.
            var differing = 0, worst = 0, first: (Int, Int)? = nil
            for y in 0..<ours.height {
                for x in 0..<ours.width {
                    let a = ours[x, y], b = reference[x, y]
                    let d = max(abs(Int(a.r) - Int(b.r)), abs(Int(a.g) - Int(b.g)), abs(Int(a.b) - Int(b.b)), abs(Int(a.a) - Int(b.a)))
                    if d > 0 { differing += 1; worst = max(worst, d); if first == nil { first = (x, y) } }
                }
            }
            c.expect(differing == 0, "\(name): \(differing) pixels differ from libjpeg-turbo, by up to \(worst), first at \(first.map { "\($0.0),\($0.1)" } ?? "")")
        }
        do {
            _ = try JPEG.decode(try Platform.files.read(Path.join(dir, "arithmetic.jpg")))
            c.fail("an arithmetic-coded file must be refused")
        } catch {
            c.expect("\(error)".contains("arithmetic"), "the error names the reason: \(error)")
        }
        c.expect((try? JPEG.decode([0xFF, 0xD8, 0xFF, 0xC0, 0, 4])) == nil, "a cut-off header is an error, not a crash")
        // A file cut in the middle of its data still decodes (zeros after the cut), as in libjpeg.
        let full = try Platform.files.read(Path.join(dir, "baseline-420.jpg"))
        do {
            let cut = try JPEG.decode(Array(full[0..<(full.count * 2 / 3)]))
            c.expect(cut.width == 98 && cut.height == 66, "a truncated file gives a whole-size image")
            let whole = try JPEG.decode(full)
            c.expect(cut.pixels[0..<(98 * 4 * 8)] == whole.pixels[0..<(98 * 4 * 8)], "its first rows are the same as the whole file's")
        } catch {
            c.fail("a truncated file gives a partial image, not: \(error)")
        }

        // Speed, for the record: the largest fixture.
        let mandel = try Platform.files.read(Path.join(dir, "progressive-mandel.jpg"))
        let start = clock.now
        for _ in 0..<10 { _ = try JPEG.decode(mandel) }
        c.note("progressive 320x240: \((clock.now - start).seconds * 100) ms per decode")
    },
    Check("render.png") { c in
        var b = Bitmap(width: 37, height: 11)
        for i in 0..<b.pixels.count { b.pixels[i] = UInt8(truncatingIfNeeded: i &* 31 &+ i / 7) }
        c.expectEqual(try PNG.decode(PNG.encode(b)), b, "RGBA round trip")
        let grey = Bitmap(width: 5, height: 3, fill: (40, 40, 40, 255))
        c.expectEqual(try PNG.decode(PNG.encode(grey)), grey, "grey round trip")
        // A PNG written by CoreGraphics (zlib with dynamic Huffman codes).
        let ref = try PNG.decode(try Platform.files.read(Path.join(c.root, "Tests/Reference/Text/Inter-Regular-10pt-1x-dark.png")))
        c.expectEqual(ref.width, 308, "reference width (manifest)")
        c.expectEqual(Int(ref[0, 0].r), 16, "reference background (0.063 * 255)")
    },
    Check("render.coverage") { c in
        var canvas = Canvas(width: 4, height: 2, scale: 1, background: .black)
        canvas.fill(Rect(x: 0.5, y: 0, width: 2, height: 1), .white)
        let p = canvas.bitmap
        c.expectEqual([p[0, 0].r, p[1, 0].r, p[2, 0].r, p[3, 0].r, p[0, 1].r], [128, 255, 128, 0, 0], "half-covered edge pixels")
        var path = Path()
        path.move(to: Point(x: 0, y: 0)); path.line(to: Point(x: 4, y: 0)); path.line(to: Point(x: 0, y: 2)); path.close()
        var tri = Canvas(width: 4, height: 2, scale: 1, background: .black)
        tri.fill(path, .white)
        var total = 0.0
        for v in tri.pixels.enumerated() where v.offset % 4 == 0 { total += Double(v.element) }
        c.expectClose(total, 4, tolerance: 1e-4, "triangle area 4 exactly")
    },
    Check("render.transparent") { c in
        // On a clear canvas, partly covered pixels keep the drawn colour and carry coverage in alpha only.
        let face = try TextReference.font(root: c.root, "Inter-Regular.otf")
        var canvas = Canvas(width: 60, height: 24, scale: 1)
        canvas.drawText("Hg", font: face, size: 18, at: Point(x: 2, y: 18), color: .white)
        let b = canvas.bitmap
        var partial = 0, wrong = 0
        for y in 0..<b.height {
            for x in 0..<b.width {
                let p = b[x, y]
                if p.a > 0 && p.a < 255 { partial += 1 }
                if p.a > 0 && (p.r != 255 || p.g != 255 || p.b != 255) { wrong += 1 }
            }
        }
        c.expect(partial > 20, "text has anti-aliased edges (\(partial) partly covered pixels)")
        c.expectEqual(wrong, 0, "white text on a clear canvas stays white at its edges")
        // Clipping limits drawing to a rectangle.
        var clip = Canvas(width: 8, height: 8, scale: 1, background: .black)
        clip.clipped(to: Rect(x: 2, y: 2, width: 3, height: 3)) { $0.fill(Rect(x: 0, y: 0, width: 8, height: 8), .white) }
        let k = clip.bitmap
        var lit = 0
        for y in 0..<8 { for x in 0..<8 where k[x, y].r == 255 { lit += 1 } }
        c.expectEqual(lit, 9, "only the clipped 3x3 area is filled")
    },

    Check("render.scaled") { c in
        // Recording inside `scaled(by:about:)` equals recording the scaled geometry directly.
        let face = try TextReference.font(root: c.root, "Inter-Regular.otf")
        let glyphs = TextLayout.line("Scale 42", font: face, pixelSize: 12)
        let glass = GlassStyle(refraction: 6, bezel: 8, frost: 2, tint: Color(white: 1, opacity: 0.1), rim: 0.5)
        let anchor = Point(x: 30, y: 20), s = 1.5
        func at(_ p: Point) -> Point { Point(x: anchor.x + (p.x - anchor.x) * s, y: anchor.y + (p.y - anchor.y) * s) }
        func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Rect {
            let o = at(Point(x: x, y: y)); return Rect(x: o.x, y: o.y, width: w * s, height: h * s)
        }
        var a = DisplayList(width: 300, height: 200, scale: 2)
        a.translated(by: Point(x: 4, y: 3)) { l in
            l.scaled(by: s, about: anchor) { l in
                l.fill(Rect(x: 10, y: 10, width: 20, height: 8), .white)
                l.translated(by: Point(x: 2, y: 1)) { l in l.fill(Rect(x: 30, y: 30, width: 5, height: 5), .white) }
                l.drawGlyphs(glyphs, font: face, size: 12, at: Point(x: 8, y: 40), color: .white)
                l.drawBackdrop(RoundedRect(Rect(x: 12, y: 12, width: 30, height: 14), cornerRadius: 7), .glass(glass))
            }
        }
        var b = DisplayList(width: 300, height: 200, scale: 2)
        b.translated(by: Point(x: 4, y: 3)) { l in
            l.fill(r(10, 10, 20, 8), .white)
            l.fill(r(32, 31, 5, 5), .white)
            let p = at(Point(x: 8, y: 40))
            let scaled = glyphs.map { PositionedGlyph(glyph: $0.glyph, x: $0.x * s, advance: $0.advance * s, cluster: $0.cluster) }
            l.drawGlyphs(scaled, font: face, size: 12 * s, at: p, color: .white)
            l.drawBackdrop(RoundedRect(r(12, 12, 30, 14), cornerRadius: 7 * s), BackdropEffect.glass(glass).scaled(by: s))
        }
        c.expectEqual(a.items.count, 4, "everything recorded")
        c.expectEqual(a.items.map(\.bounds), b.items.map(\.bounds), "the same pixel bounds")
        var ca = Canvas(width: 300, height: 200, scale: 2, background: Color(white: 0.2)), cb = ca
        ca.draw(a); cb.draw(b)
        c.expect(ca.bitmap == cb.bitmap, "scaled recording draws the pixels of the scaled geometry")
        c.expectEqual(a.zoom, 1, "zoom restored")
    },

    Check("render.blur") { c in
        // A pattern with hard edges and colour, premultiplied.
        let w = 512, h = 384
        var src = [Float](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4, a: Float = (x / 37 + y / 23) % 3 == 0 ? 0.5 : 1
                src[i] = Float((x * 7 + y * 3) % 256) / 255 * a; src[i + 1] = ((x / 16) % 2 == 0 ? 0.9 : 0.1) * a
                src[i + 2] = Float(y % 64) / 64 * a; src[i + 3] = a
            }
        }
        let clock = ContinuousClock()
        func ms(_ body: () -> Void) -> Double {
            let start = clock.now; body(); return (clock.now - start).seconds * 1000
        }
        for sigma in [3.0, 6, 16, 40] {
            var fast: [Float] = [], exact: [Float] = []
            let tFast = ms { fast = Blur.apply(src, width: w, height: h, sigma: sigma) }
            let tExact = ms { exact = Blur.direct(src, width: w, height: h, sigma: sigma) }
            var sum = 0.0, worst = 0.0, light = 0.0, lightExact = 0.0
            for i in 0..<src.count {
                let d = Double(abs(fast[i] - exact[i])); sum += d; worst = max(worst, d)
                if i % 4 == 3 { light += Double(fast[i]); lightExact += Double(exact[i]) }
            }
            let mean = sum / Double(src.count)
            c.note("blur sigma \(sigma) px, 512x384: \(Double(Int(tExact * 10)) / 10) ms direct, \(Double(Int(tFast * 10)) / 10) ms with factor \(Blur.factor(sigma)); mean difference \(Double(Int(mean * 100000)) / 100000), max \(Double(Int(worst * 1000)) / 1000)")
            // Measured: mean at most 0.002 (half an 8-bit step), worst 0.065 on the sharpest edges.
            c.expect(mean < 0.006 && worst < 0.08, "sigma \(sigma): the reduced blur strays from the Gaussian: mean \(mean), max \(worst)")
            c.expect(abs(light - lightExact) / lightExact < 0.002, "sigma \(sigma): light kept (\(light) against \(lightExact))")

            // A part blurred alone, with `reach` of margin, equals that part of the whole.
            let r = Blur.reach(sigma), part = PixelRect(x: 130, y: 101, width: 120, height: 90)
            let area = part.outset(by: r).clamped(to: PixelRect(x: 0, y: 0, width: w, height: h))
            var sub = [Float](repeating: 0, count: area.width * area.height * 4)
            for y in 0..<area.height {
                for i in 0..<(area.width * 4) { sub[y * area.width * 4 + i] = src[((area.y + y) * w + area.x) * 4 + i] }
            }
            let blurredPart = Blur.apply(sub, width: area.width, height: area.height, sigma: sigma, x: area.x, y: area.y)
            var same = true
            for y in part.y..<(part.y + part.height) {
                for x in part.x..<(part.x + part.width) {
                    for ch in 0..<4 where blurredPart[((y - area.y) * area.width + x - area.x) * 4 + ch] != fast[(y * w + x) * 4 + ch] { same = false }
                }
            }
            c.expect(same, "sigma \(sigma): a part blurred alone differs from the whole")
        }
        let flat = [Float](repeating: 0.25, count: 64 * 48 * 4)
        c.expect(Blur.apply(flat, width: 64, height: 48, sigma: 20, x: 3, y: 5).allSatisfy { abs($0 - 0.25) < 1e-6 }, "a flat colour stays flat")
    },
    Check("render.display-list") { c in
        let red = Color(red: 1, green: 0, blue: 0), blue = Color(red: 0, green: 0, blue: 1)
        func list(_ body: (inout DisplayList) -> Void) -> DisplayList {
            var l = DisplayList(width: 100, height: 100, scale: 2)
            body(&l)
            return l
        }
        let a = list { l in
            l.fill(Rect(x: 0, y: 0, width: 10, height: 10), red)
            l.fill(Rect(x: 20, y: 20, width: 10, height: 10), blue)
            l.fill(Rect(x: 40, y: 0, width: 5, height: 5), .white)
        }
        c.expectEqual(a.damage(since: a), [], "the same list: no damage")
        // Recording mirrors the canvas: clipping and moving are folded into each item.
        let clipped = list { l in
            l.translated(by: Point(x: 5, y: 0)) { l in
                l.clipped(to: Rect(x: 0, y: 0, width: 4, height: 4)) { l in l.fill(Rect(x: 0, y: 0, width: 10, height: 10), red) }
            }
            l.fill(Rect(x: 60, y: 60, width: 10, height: 10), .clear)
            l.fill(Rect(x: 200, y: 0, width: 10, height: 10), red)
        }
        c.expectEqual(clipped.items.count, 1, "invisible and off-canvas fills are left out")
        c.expectEqual(clipped.items.first?.bounds, PixelRect(x: 10, y: 0, width: 8, height: 8), "bounds in pixels, inside the clip")

        // One item changed: its old and new pixels, nothing else.
        let b = list { l in
            l.fill(Rect(x: 0, y: 0, width: 10, height: 10), red)
            l.fill(Rect(x: 20, y: 20, width: 10, height: 10), red)
            l.fill(Rect(x: 40, y: 0, width: 5, height: 5), .white)
        }
        c.expectEqual(b.damage(since: a), [PixelRect(x: 40, y: 40, width: 20, height: 20)], "a recoloured square")
        // Two separate changes stay two rectangles.
        let d = list { l in
            l.fill(Rect(x: 0, y: 0, width: 10, height: 11), red)
            l.fill(Rect(x: 20, y: 20, width: 10, height: 10), blue)
            l.fill(Rect(x: 40, y: 0, width: 5, height: 5), red)
        }
        c.expectEqual(d.damage(since: a), [PixelRect(x: 0, y: 0, width: 20, height: 22), PixelRect(x: 80, y: 0, width: 10, height: 10)],
                      "two changes far apart")
        // Order matters where items overlap: swapping two damages both.
        let over = list { l in
            l.fill(Rect(x: 0, y: 0, width: 10, height: 10), red)
            l.fill(Rect(x: 5, y: 5, width: 10, height: 10), blue)
        }
        let swapped = list { l in
            l.fill(Rect(x: 5, y: 5, width: 10, height: 10), blue)
            l.fill(Rect(x: 0, y: 0, width: 10, height: 10), red)
        }
        c.expectEqual(swapped.damage(since: over), [PixelRect(x: 10, y: 10, width: 20, height: 20)], "reordered overlapping items: the one now out of order")
        // An item added in the middle damages only itself.
        let inserted = list { l in
            l.fill(Rect(x: 0, y: 0, width: 10, height: 10), red)
            l.fill(Rect(x: 30, y: 40, width: 5, height: 5), red)
            l.fill(Rect(x: 20, y: 20, width: 10, height: 10), blue)
            l.fill(Rect(x: 40, y: 0, width: 5, height: 5), .white)
        }
        c.expectEqual(inserted.damage(since: a), [PixelRect(x: 60, y: 80, width: 10, height: 10)], "an inserted item")
        c.expectEqual(DisplayList(width: 50, height: 100, scale: 2).damage(since: a), [PixelRect(x: 0, y: 0, width: 50, height: 100)],
                      "another size: everything")

        // Drawing only the damage gives the pixels of drawing everything.
        var canvas = Canvas(width: 100, height: 100, scale: 2, background: .black)
        canvas.draw(a)
        for r in d.damage(since: a) { canvas.clear(r, to: .black); canvas.draw(d, in: r) }
        var full = Canvas(width: 100, height: 100, scale: 2, background: .black)
        full.draw(d)
        c.expect(canvas.bitmap == full.bitmap, "partial redraw equals a full draw")
    },
]
