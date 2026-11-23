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
    Check("render.image") { c in
        // 2x2 image: red, green / blue, translucent white.
        var bmp = Bitmap(width: 2, height: 2)
        bmp.pixels = [
            255, 0, 0, 255,     0, 255, 0, 255,
            0, 0, 255, 255,     255, 255, 255, 128,
        ]
        let img = RenderImage(bmp)
        // Nearest-neighbour 2x enlargement matches every quadrant cleanly.
        var near = Canvas(width: 4, height: 4, scale: 1, background: .black)
        near.drawImage(img, in: Rect(x: 0, y: 0, width: 4, height: 4), filter: .nearest)
        let np = near.bitmap
        c.expectEqual([np[0, 0].r, np[1, 1].r, np[2, 0].g, np[0, 2].b], [255, 255, 255, 255], "nearest quadrants")
        c.expectEqual(np[3, 3].r, 128, "translucent white over black")

        // Bilinear 2x enlargement blends across the seam between red and green.
        var lin = Canvas(width: 4, height: 4, scale: 1, background: .black)
        lin.drawImage(img, in: Rect(x: 0, y: 0, width: 4, height: 4), filter: .bilinear)
        let lp = lin.bitmap
        c.expect(lp[1, 0].r > lp[2, 0].r && lp[1, 0].g > 0 && lp[2, 0].r > 0, "bilinear interpolates smoothly between red and green")

        // DisplayList recording and partial redraw equal a full draw.
        var l1 = DisplayList(width: 40, height: 40, scale: 2)
        l1.fill(Rect(x: 0, y: 0, width: 20, height: 20), Color(white: 0.1))
        l1.drawImage(img, in: Rect(x: 2, y: 3, width: 8, height: 8), opacity: 0.75)
        var l2 = DisplayList(width: 40, height: 40, scale: 2)
        l2.fill(Rect(x: 0, y: 0, width: 20, height: 20), Color(white: 0.1))
        l2.drawImage(img, in: Rect(x: 6, y: 3, width: 8, height: 8), opacity: 0.75)
        var partial = Canvas(width: 40, height: 40, scale: 2, background: .black)
        partial.draw(l1)
        for r in l2.damage(since: l1) { partial.clear(r, to: .black); partial.draw(l2, in: r) }
        var whole = Canvas(width: 40, height: 40, scale: 2, background: .black)
        whole.draw(l2)
        c.expect(partial.bitmap == whole.bitmap, "image partial redraw equals full draw")
    },
    Check("render.blur") { c in
        // Sharp white stripe on black, blurred inside a dark glass panel.
        var l1 = DisplayList(width: 64, height: 64, scale: 1)
        l1.fill(Rect(x: 0, y: 0, width: 64, height: 64), .black)
        l1.fill(Rect(x: 28, y: 0, width: 8, height: 64), .white)
        l1.backdropBlur(Rect(x: 10, y: 10, width: 44, height: 44), radius: 4)
        l1.fill(Rect(x: 10, y: 10, width: 44, height: 44), Color(white: 0.06, opacity: 0.5))

        var full1 = Canvas(width: 64, height: 64, scale: 1, background: .black)
        full1.draw(l1)
        let b1 = full1.bitmap
        // Inside the blurred panel the sharp edge softens outward; outside it stays crisp.
        c.expect(b1[24, 32].r > 20 && b1[32, 32].r < 220, "blur softens the stripe inside the glass panel")
        c.expectEqual([b1[24, 2].r, b1[32, 2].r], [0, 255], "outside the panel stays crisp")

        // Moving the stripe behind the blur expands damage to the whole blur panel, so partial equals full.
        var l2 = DisplayList(width: 64, height: 64, scale: 1)
        l2.fill(Rect(x: 0, y: 0, width: 64, height: 64), .black)
        l2.fill(Rect(x: 30, y: 0, width: 8, height: 64), .white)
        l2.backdropBlur(Rect(x: 10, y: 10, width: 44, height: 44), radius: 4)
        l2.fill(Rect(x: 10, y: 10, width: 44, height: 44), Color(white: 0.06, opacity: 0.5))
        let dmg = l2.damage(since: l1)
        for r in dmg { full1.clear(r, to: .black); full1.draw(l2, in: r) }
        var full2 = Canvas(width: 64, height: 64, scale: 1, background: .black)
        full2.draw(l2)
        c.expect(full1.bitmap == full2.bitmap, "backdropBlur partial redraw equals full draw")
    },
    Check("render.scroll-blit") { c in
        func frame(offsetY: Double, highlightRow: Int = -1) -> DisplayList {
            var l = DisplayList(width: 100, height: 100, scale: 2)
            l.fill(Rect(x: 0, y: 0, width: 50, height: 50), Color(white: 0.063))
            l.fill(Rect(x: 0, y: 0, width: 50, height: 10), Color(white: 0.15))
            l.scrolled(in: Rect(x: 0, y: 10, width: 50, height: 40), offset: Point(x: 0, y: offsetY)) { c in
                for i in 0..<20 {
                    let col = i == highlightRow ? Color(red: 0.8, green: 0.2, blue: 0.2) : Color(white: Double(i % 5 + 2) / 10)
                    c.fill(Rect(x: 4, y: Double(i) * 10 + 1, width: 42, height: 8), col)
                }
            }
            return l
        }
        let a = frame(offsetY: 0)
        let b = frame(offsetY: 12)
        let plan = b.damagePlan(since: a)
        c.expectEqual(plan.blits, [ScrollBlit(rect: PixelRect(x: 0, y: 20, width: 100, height: 80), dx: 0, dy: -24)], "vertical scroll blits viewport")
        c.expectEqual(plan.damage, [PixelRect(x: 0, y: 76, width: 100, height: 24)], "only newly exposed bottom strip is damaged")
        var canvas = Canvas(width: 100, height: 100, scale: 2, background: .black)
        canvas.draw(a)
        for blit in plan.blits { canvas.scroll(blit.rect, dx: blit.dx, dy: blit.dy) }
        for r in plan.damage { canvas.clear(r, to: .black); canvas.draw(b, in: r) }
        var whole = Canvas(width: 100, height: 100, scale: 2, background: .black)
        whole.draw(b)
        c.expect(canvas.bitmap == whole.bitmap, "scroll blit + strip redraw equals full draw")

        // Simultaneous scroll + item change inside overlap still matches full draw.
        let cFrame = frame(offsetY: 18, highlightRow: 3)
        let plan2 = cFrame.damagePlan(since: b)
        c.expect(!plan2.blits.isEmpty, "simultaneous change still uses scroll blit")
        for blit in plan2.blits { canvas.scroll(blit.rect, dx: blit.dx, dy: blit.dy) }
        for r in plan2.damage { canvas.clear(r, to: .black); canvas.draw(cFrame, in: r) }
        var whole2 = Canvas(width: 100, height: 100, scale: 2, background: .black)
        whole2.draw(cFrame)
        c.expect(canvas.bitmap == whole2.bitmap, "simultaneous scroll + row highlight equals full draw")
    },
]
