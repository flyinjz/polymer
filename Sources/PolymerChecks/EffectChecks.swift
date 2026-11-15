// Checks for shapes and effects (DESIGN section 11): exact coverage, 1px
// lines, backdrop blur, materials and liquid glass, and damage with effects.
import PolymerBase
import PolymerPlatform
import PolymerRender
import PolymerUI

/// Sum of a channel over an image, in units of full pixels (0...1 each).
func coverage(_ b: Bitmap, channel: Int = 0) -> Double {
    var s = 0.0
    for i in stride(from: channel, to: b.pixels.count, by: 4) { s += Double(b.pixels[i]) }
    return s / 255
}

@MainActor let effectChecks: [Check] = [
    Check("effects.shapes") { c in
        func line(_ tree: String, _ role: String) -> String {
            tree.split(separator: "\n").first { $0.contains(role + " (") }.map { String($0.drop { $0 == " " }) } ?? ""
        }
        let red = Color(red: 1, green: 0, blue: 0)
        c.expectEqual(line(ImageRenderer(content: RoundedRectangle(cornerRadius: 8).fill(red).frame(width: 40, height: 20)).elementTree, "RoundedRectangle"),
                      "RoundedRectangle (0, 0, 40x20) #FF0000", "a filled shape in the element tree")
        c.expectEqual(line(ImageRenderer(content: Circle().strokeBorder(.white, lineWidth: 1).frame(width: 20, height: 20)).elementTree, "Circle"),
                      "Circle (0, 0, 20x20) border 1 #FFFFFF", "an outlined shape says so")
        c.expectEqual(line(ImageRenderer(content: Capsule().frame(width: 30, height: 10)).elementTree, "Capsule"),
                      "Capsule (0, 0, 30x10) #FFFFFF", "a shape alone fills with the foreground colour")

        // Exact areas: white shapes on black, summed coverage in pixels.
        @MainActor func area<V: View>(_ v: V, _ w: Double, _ h: Double) -> Double {
            var r = ImageRenderer(content: v.frame(width: w, height: h))
            r.background = .black
            return coverage(r.bitmap)
        }
        c.expectClose(area(Circle(), 40, 40), Double.pi * 400, tolerance: 0.5, "circle of radius 20")
        c.expectClose(area(Capsule(), 60, 20), 40 * 20 + Double.pi * 100, tolerance: 0.5, "capsule 60x20")
        c.expectClose(area(RoundedRectangle(cornerRadius: 6), 40, 30), 40 * 30 - (4 - Double.pi) * 36, tolerance: 0.5, "rounded rectangle")
        c.expectClose(area(Circle().strokeBorder(.white, lineWidth: 2), 40, 40), Double.pi * (400 - 324), tolerance: 0.5, "a 2-point ring inside a circle")
        var padded = ImageRenderer(content: RoundedRectangle(cornerRadius: 10).stroke(.white, lineWidth: 2).frame(width: 40, height: 40).padding(2))
        padded.background = .black
        c.expectClose(coverage(padded.bitmap),
                      (42 * 42 - (4 - Double.pi) * 121) - (38 * 38 - (4 - Double.pi) * 81), tolerance: 0.5, "a centred stroke straddles the edge")

        // 1px lines: a border on a pixel-aligned rectangle is fully covered, nothing else is.
        var r = ImageRenderer(content: Rectangle().strokeBorder(.white, lineWidth: 1).frame(width: 20, height: 12))
        r.background = .black
        let b = r.bitmap
        var full = 0, partial = 0
        for i in stride(from: 0, to: b.pixels.count, by: 4) { if b.pixels[i] == 255 { full += 1 } else if b.pixels[i] > 0 { partial += 1 } }
        c.expect(full == 2 * 20 + 2 * 10 && partial == 0, "a crisp 1px frame: \(full) full and \(partial) partial pixels")
        var r2 = ImageRenderer(content: Rectangle().strokeBorder(.white, lineWidth: 1).frame(width: 20, height: 12))
        r2.scale = 2; r2.background = .black
        let b2 = r2.bitmap
        full = 0; partial = 0
        for i in stride(from: 0, to: b2.pixels.count, by: 4) { if b2.pixels[i] == 255 { full += 1 } else if b2.pixels[i] > 0 { partial += 1 } }
        c.expect(full == 2 * 2 * 40 + 2 * 2 * 20 && partial == 0, "at 2x the line is 2 crisp pixels: \(full) full and \(partial) partial")

        // A custom shape fills its own path.
        struct Triangle: Shape {
            func path(in rect: Rect) -> PolymerBase.Path {
                var p = PolymerBase.Path()
                p.move(to: Point(x: rect.minX, y: rect.maxY)); p.line(to: Point(x: rect.midX, y: rect.minY))
                p.line(to: Point(x: rect.maxX, y: rect.maxY)); p.close()
                return p
            }
        }
        c.expectClose(area(Triangle(), 40, 20), 400, tolerance: 0.5, "a custom triangle")

        // The distance field behind effects.
        let g = RoundedRect(Rect(x: 0, y: 0, width: 40, height: 20), cornerRadius: 8)
        c.expectClose(g.signedDistance(20, 10), -10, tolerance: 1e-12, "centre: half the height inside")
        c.expectClose(g.signedDistance(20, 0), 0, tolerance: 1e-12, "on the top edge")
        c.expectClose(g.signedDistance(-3, 10), 3, tolerance: 1e-12, "outside the left edge")
        let corner = 8 - 8 / 2.0.squareRoot()   // on the corner arc, 45 degrees
        c.expectClose(g.signedDistance(corner, corner), 0, tolerance: 1e-12, "on the corner arc")
        let n = g.normal(corner - 1, corner - 1)
        c.expectClose(n.x, -1 / 2.0.squareRoot(), tolerance: 1e-12, "corner normal points out diagonally")
        c.expectEqual(g.normal(20, 1), Point(x: 0, y: -1), "top edge normal points up")
    },
    Check("effects.blur") { c in
        let white = Color(white: 1)
        // Two-pixel stripes behind a blurred rectangle.
        func stripes(_ effect: BackdropEffect?) -> Bitmap {
            var l = DisplayList(width: 60, height: 40)
            for x in stride(from: 0, to: 60, by: 4) { l.fill(Rect(x: Double(x), y: 0, width: 2, height: 40), white) }
            if let effect { l.drawBackdrop(RoundedRect(Rect(x: 10, y: 10, width: 40, height: 20), cornerRadius: 0), effect) }
            var canvas = Canvas(width: 60, height: 40, background: .black)
            canvas.draw(l)
            return canvas.bitmap
        }
        let plain = stripes(nil), blurred = stripes(.material(blur: 3, tint: .clear))
        c.expect(abs(Int(blurred[30, 20].r) - 128) <= 3, "stripes average to grey inside: \(blurred[30, 20].r)")
        var outsideSame = true
        for y in 0..<40 { for x in 0..<60 where x < 10 || x >= 50 || y < 10 || y >= 30 { if blurred[x, y] != plain[x, y] { outsideSame = false } } }
        c.expect(outsideSame, "nothing outside the shape changes")

        // A flat colour stays flat; a material over it is exactly its tint over that colour.
        var flat = DisplayList(width: 30, height: 30)
        flat.fill(Rect(x: 0, y: 0, width: 30, height: 30), Color(red: 0.2, green: 0.6, blue: 1))
        flat.drawBackdrop(RoundedRect(Rect(x: 5, y: 5, width: 20, height: 20), cornerRadius: 0),
                          .material(blur: 4, tint: Color(white: 0, opacity: 0.5)))
        var fc = Canvas(width: 30, height: 30, background: .black)
        fc.draw(flat)
        let fb = fc.bitmap
        let expected = (UInt8((0.2 * 0.5 * 255).rounded()), UInt8((0.6 * 0.5 * 255).rounded()), UInt8((0.5 * 255).rounded()))
        var off = 0
        for y in 5..<25 { for x in 5..<25 {
            let p = fb[x, y]
            if abs(Int(p.r) - Int(expected.0)) > 1 || abs(Int(p.g) - Int(expected.1)) > 1 || abs(Int(p.b) - Int(expected.2)) > 1 { off += 1 }
        } }
        c.expectEqual(off, 0, "material over a flat colour is the tint over it")

        // Blur keeps the total light: one white pixel spreads but sums to one.
        var dot = DisplayList(width: 41, height: 41)
        dot.fill(Rect(x: 20, y: 20, width: 1, height: 1), white)
        dot.drawBackdrop(RoundedRect(Rect(x: 0, y: 0, width: 41, height: 41), cornerRadius: 0), .material(blur: 3, tint: .clear))
        var dc = Canvas(width: 41, height: 41, background: .black)
        dc.draw(dot)
        var total: Float = 0
        for i in stride(from: 0, to: dc.pixels.count, by: 4) { total += dc.pixels[i] }
        c.expectClose(Double(total), 1, tolerance: 1e-4, "a blurred dot keeps its light")
        c.expect(dc.pixels[(20 * 41 + 20) * 4] < 0.05, "and is spread out")
    },
    Check("effects.glass") { c in
        let white = Color(white: 1)
        let glass = GlassStyle(refraction: 6, bezel: 10, frost: 0, tint: .clear, rim: 0)
        // A white line just outside the glass's left edge.
        func line(_ g: GlassStyle) -> Bitmap {
            var l = DisplayList(width: 60, height: 30)
            l.fill(Rect(x: 6, y: 0, width: 2, height: 30), white)
            l.drawBackdrop(RoundedRect(Rect(x: 10, y: 5, width: 40, height: 20), cornerRadius: 0), .glass(g))
            var canvas = Canvas(width: 60, height: 30, background: .black)
            canvas.draw(l)
            return canvas.bitmap
        }
        let bent = line(glass)
        // Inside the left edge (pixels 10 to 13) the line from x = 6 to 8 is pulled in.
        let rimPixels = (10..<14).map { bent[$0, 15].r }
        c.expect(rimPixels.max()! > 200, "the rim shows what is just outside: \(rimPixels)")
        var flatGlass = glass; flatGlass.refraction = 0
        let flat = line(flatGlass)
        c.expectEqual((10..<14).map { flat[$0, 15].r }.max(), 0, "without refraction the rim shows what is under it")
        c.expectEqual(bent[30, 15].r, 0, "the middle is not bent")

        // Through the flat middle, content is exactly what is behind.
        var pattern = DisplayList(width: 60, height: 60)
        for k in 0..<12 { pattern.fill(Rect(x: Double(k * 5), y: Double(k * 5), width: 3, height: 3), Color(red: 1, green: Double(k) / 12, blue: 0)) }
        var noGlass = Canvas(width: 60, height: 60, background: .black)
        noGlass.draw(pattern)
        pattern.drawBackdrop(RoundedRect(Rect(x: 0, y: 0, width: 60, height: 60), cornerRadius: 20), .glass(glass))
        var withGlass = Canvas(width: 60, height: 60, background: .black)
        withGlass.draw(pattern)
        let a = noGlass.bitmap, b = withGlass.bitmap
        var differ = 0
        for y in 15..<45 { for x in 15..<45 where a[x, y] != b[x, y] { differ += 1 } }
        c.expectEqual(differ, 0, "the middle (past the bezel) shows the content unchanged")

        // Rim light: the edge facing the light (top-left by default) is brighter than the opposite one.
        var lit = DisplayList(width: 40, height: 40)
        lit.drawBackdrop(RoundedRect(Rect(x: 5, y: 5, width: 30, height: 30), cornerRadius: 15),
                         .glass(GlassStyle(refraction: 0, bezel: 10, frost: 0, tint: .clear, rim: 1)))
        var lc = Canvas(width: 40, height: 40, background: .black)
        lc.draw(lit)
        let lb = lc.bitmap
        // Pixels (9, 9) and (30, 30) sit just inside the circle's edge, on opposite sides.
        c.expect(lb[9, 9].r > 2 * lb[30, 30].r && lb[9, 9].r > 60 && lb[30, 30].r > 0, "lit top-left \(lb[9, 9].r) against \(lb[30, 30].r)")
        c.expectEqual(lb[20, 20].r, 0, "no light in the middle")

        // In a view tree: glass over scrolling content redraws partially, identical to a whole draw.
        let face = try TextReference.font(root: c.root, "Geist-Regular.otf")
        let screen = ZStack(alignment: .top) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(0..<60, id: \.self) { i in
                        Text("Row \(i)").frame(maxWidth: .infinity, alignment: .leading).padding(6)
                            .background(i % 2 == 0 ? Color(white: 0.15) : Color(white: 0.3))
                    }
                }
            }
            Text("Albums").padding(horizontal: 16, vertical: 8).glassEffect(.regular, in: Capsule()).padding(8)
        }
        .frame(width: 240, height: 200)
        .font(Font(face, size: 13))
        var e = EnvironmentValues()
        e.displayScale = 2
        let tree = ViewTree(screen, environment: e)
        c.expect(tree.elementTree.contains("Glass (") && tree.elementTree.contains(" regular"), "glass in the element tree:\n\(tree.elementTree.prefix(600))")
        _ = tree.render(background: .black)
        for dy: Double in [9, 40, 3, 120] {
            _ = tree.scroll(at: Point(x: 120, y: 150), dy: dy)
            let img = tree.render(background: .black)
            var whole = Canvas(width: img.width, height: img.height, scale: 2, background: .black)
            if let l = tree.displayList { whole.draw(l) }
            var bad = 0
            let w = whole.bitmap
            for i in 0..<img.pixels.count where img.pixels[i] != w.pixels[i] { bad += 1 }
            c.expect(bad == 0, "partial frame under glass after scrolling \(dy) equals a whole draw (\(bad) values differ)")
        }
        try Platform.files.createDirectory(Path.join(c.outputDirectory, "effects"))
        try Platform.files.write(PNG.encode(tree.render(background: .black)), to: Path.join(c.outputDirectory, "effects/glass-over-list@2x.png"))

        // Reduce transparency: an opaque fill instead.
        var opaque = EnvironmentValues()
        opaque.accessibilityReduceTransparency = true
        let solid = ViewTree(Text("A").padding(10).glassEffect().font(Font(face, size: 13)), environment: opaque)
        c.expect(solid.elementTree.contains("regular, opaque"), "opaque with reduced transparency:\n\(solid.elementTree)")

        // A showcase for review: glass shapes over a photo-like pattern.
        let photo = try JPEG.decode(try Platform.files.read(Path.join(c.root, "Tests/Fixtures/Images/progressive-mandel.jpg")))
        let show = ZStack {
            Image(photo).resizable().frame(width: 320, height: 240)
            VStack(spacing: 16) {
                Text("Liquid glass").padding(horizontal: 20, vertical: 10).glassEffect(.regular, in: Capsule())
                HStack(spacing: 16) {
                    Color.clear.frame(width: 64, height: 64).glassEffect(.clear, in: Circle())
                    Color.clear.frame(width: 120, height: 64).glassEffect(.clear, in: RoundedRectangle(cornerRadius: 16))
                }
                Text("Thin material").padding(horizontal: 16, vertical: 8).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .font(Font(face, size: 15))
        var showcase = ImageRenderer(content: show)
        showcase.scale = 2
        try Platform.files.write(PNG.encode(showcase.bitmap), to: Path.join(c.outputDirectory, "effects/glass-showcase@2x.png"))
        c.note("showcase in \(c.outputDirectory)/effects")
    },
    Check("effects.layers") { c in
        @MainActor func render<V: View>(_ v: V, scale: Double = 1) -> Bitmap {
            var r = ImageRenderer(content: v)
            r.scale = scale
            r.background = .black
            return r.bitmap
        }
        let red = Color(red: 1, green: 0, blue: 0)
        // Opacity on one view equals a colour with that opacity.
        c.expect(render(Color.white.frame(width: 10, height: 10).opacity(0.5)) == render(Color(white: 1, opacity: 0.5).frame(width: 10, height: 10)),
                 "opacity(0.5) on a fill equals a half-transparent fill")
        // Group opacity: overlapping content is composited first, so the overlap shows only the top view at half strength.
        let group = render(ZStack {
            Color.white.frame(width: 20, height: 20)
            red.frame(width: 10, height: 10)
        }.opacity(0.5))
        let p = group[10, 10]
        c.expect(p.r == 128 && p.g == 0 && p.b == 0, "the overlap is the red view at half strength, not white showing through: \(p)")

        // clipShape: the same area as the shape filled, with an anti-aliased edge.
        let clipped = render(Color.white.frame(width: 40, height: 40).clipShape(Circle()))
        c.expectClose(coverage(clipped), Double.pi * 400, tolerance: 0.5, "a square cut to a circle has the circle's area")
        let photo = try JPEG.decode(try Platform.files.read(Path.join(c.root, "Tests/Fixtures/Images/baseline-444.jpg")))
        let art = render(Image(photo).resizable().frame(width: 60, height: 40).clipShape(RoundedRectangle(cornerRadius: 8)), scale: 2)
        c.expect(art[0, 0] == (0, 0, 0, 255) && art[60, 40] != (0, 0, 0, 255), "rounded corners cut, middle kept")

        // Clicks miss outside a clip shape.
        var taps = 0
        let tree = ViewTree(Color.white.frame(width: 40, height: 40).onTapGesture { taps += 1 }.clipShape(Circle()))
        c.expect(!tree.click(at: Point(x: 2, y: 2)), "a click in the cut-off corner misses")
        c.expect(tree.click(at: Point(x: 20, y: 20)) && taps == 1, "a click in the circle hits")

        // Opacity 0: nothing drawn, nothing clicked.
        let hidden = ViewTree(Color.white.frame(width: 40, height: 40).onTapGesture { taps += 1 }.opacity(0))
        _ = hidden.render()
        c.expectEqual(hidden.displayList?.items.count, 0, "nothing recorded")
        c.expect(!hidden.click(at: Point(x: 20, y: 20)), "and nothing to click")

        // Blur spreads the content past its frame and keeps its light.
        let blurred = render(Color.white.frame(width: 10, height: 10).blur(radius: 2).padding(10))
        c.expectClose(coverage(blurred), 100, tolerance: 0.6, "a blurred square keeps its light")
        c.expect(blurred[8, 15].r > 0 && blurred[15, 15].r < 255, "and spreads past its edge")

        // In a tree: partial frames equal whole draws with layers, while scrolling and when a layer changes.
        let face = try TextReference.font(root: c.root, "Geist-Regular.otf")
        let model = CounterModel()
        struct Screen: View {
            let model: CounterModel
            let photo: Bitmap
            var body: some View {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(0..<30, id: \.self) { i in
                            HStack {
                                Image(photo).resizable().frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 6))
                                Text("Track \(i)").opacity(i % 3 == 0 ? 0.5 : 1)
                                Spacer()
                                Text("\(model.count)").blur(radius: i == 4 ? 1.5 : 0)
                            }
                            .padding(4)
                        }
                    }
                }
                .frame(width: 220, height: 180)
            }
        }
        var e = EnvironmentValues()
        e.displayScale = 2
        let t = ViewTree(Screen(model: model, photo: photo).font(Font(face, size: 13)), environment: e)
        _ = t.render(background: .black)
        @MainActor func matchesWhole(_ what: String) {
            let img = t.render(background: .black)
            var whole = Canvas(width: img.width, height: img.height, scale: 2, background: .black)
            if let l = t.displayList { whole.draw(l) }
            c.expect(img == whole.bitmap, "partial frame equals a whole draw: \(what)")
        }
        for dy: Double in [7, 30, -11, 90] {
            _ = t.scroll(at: Point(x: 100, y: 100), dy: dy)
            matchesWhole("after scrolling \(dy)")
        }
        _ = t.scroll(at: Point(x: 100, y: 100), dy: -1000)
        model.count += 7
        matchesWhole("after blurred text changed")
        try Platform.files.createDirectory(Path.join(c.outputDirectory, "effects"))
        try Platform.files.write(PNG.encode(t.render(background: .black)), to: Path.join(c.outputDirectory, "effects/layers@2x.png"))
    },
]
