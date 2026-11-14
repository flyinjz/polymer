import PolymerBase
import PolymerPlatform
import PolymerRender

@MainActor let renderChecks: [Check] = [
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
]
