import PolymerBase
import PolymerText
import PolymerRender
import PolymerUI

@Observable
private final class ClipColorModel {
    var color: Color
    init(_ color: Color) { self.color = color }
}

private struct ClippedCircleView: View {
    let model: ClipColorModel
    var body: some View {
        model.color
            .frame(width: 60, height: 60)
            .clipShape(Circle())
    }
}

@MainActor public let clipPathChecks: [Check] = [
    Check("render.clip-path") { c in
        let red = Color(red: 1, green: 0, blue: 0)
        let green = Color(red: 0, green: 1, blue: 0)
        let blue = Color(red: 0, green: 0, blue: 1)
        let bg = Color(white: 0.1)
        let face = try TextReference.font(root: c.root, "Inter-Regular.otf")

        // 1. Solid red rect clipped to an ellipse on a clear canvas:
        //    outside corners have alpha == 0, center is opaque red, boundary has 0 < alpha < 255.
        let circlePath = Path(ellipseIn: Rect(x: 4, y: 4, width: 40, height: 40))
        var circleList = DisplayList(width: 48, height: 48, scale: 1)
        circleList.clipped(to: circlePath) { l in
            l.fill(Rect(x: 0, y: 0, width: 48, height: 48), red)
        }
        c.expectEqual(circleList.items.count, 1, "clipped fill emits one item")
        c.expectEqual(circleList.items.first?.bounds, PixelRect(x: 4, y: 4, width: 40, height: 40),
                      "clipPath tightens item bounds to path bounds")
        c.expectEqual(circleList.items.first?.clipPaths.count, 1, "clipPath recorded on item")

        var circleCanvas = Canvas(width: 48, height: 48, scale: 1, background: .clear)
        circleCanvas.draw(circleList)
        let cb = circleCanvas.bitmap
        for (x, y) in [(4, 4), (43, 4), (4, 43), (43, 43), (0, 0)] {
            let p = cb[x, y]
            c.expectEqual([p.r, p.g, p.b, p.a], [0, 0, 0, 0], "corner (\(x),\(y)) outside ellipse is untouched clear")
        }
        let center = cb[24, 24]
        c.expectEqual([center.r, center.g, center.b, center.a], [255, 0, 0, 255], "center inside ellipse is pure red")
        var circleAA = 0
        for y in 4..<44 {
            for x in 4..<44 {
                let a = cb[x, y].a
                if a > 0 && a < 255 { circleAA += 1 }
            }
        }
        c.expect(circleAA > 40, "ellipse edge has smoothly anti-aliased pixels (\(circleAA))")

        // 2. Solid red rect clipped to a rounded rect over an opaque background.
        let rrPath = Path(roundedRect: Rect(x: 4, y: 4, width: 40, height: 40), cornerRadius: 12)
        var rrList = DisplayList(width: 48, height: 48, scale: 1)
        rrList.fill(Rect(x: 0, y: 0, width: 48, height: 48), bg)
        rrList.clipped(to: rrPath) { l in
            l.fill(Rect(x: 0, y: 0, width: 48, height: 48), red)
        }
        var rrCanvas = Canvas(width: 48, height: 48, scale: 1, background: .black)
        rrCanvas.draw(rrList)
        let rrb = rrCanvas.bitmap
        let bgByte = UInt8((bg.red * 255).rounded())
        for (x, y) in [(5, 5), (42, 5), (5, 42), (42, 42)] {
            let p = rrb[x, y]
            c.expectEqual([p.r, p.g, p.b, p.a], [bgByte, bgByte, bgByte, 255],
                          "rounded-rect outer corner (\(x),\(y)) is untouched background")
        }
        let rrc = rrb[24, 24]
        c.expectEqual([rrc.r, rrc.g, rrc.b, rrc.a], [255, 0, 0, 255], "rounded-rect center is pure red")
        var rrCornerAA = 0
        for y in 4..<16 {
            for x in 4..<16 {
                let p = rrb[x, y]
                if p.r > bgByte && p.r < 255 { rrCornerAA += 1 }
            }
        }
        c.expect(rrCornerAA > 4, "rounded-rect corner arc has anti-aliased pixels (\(rrCornerAA))")

        // 3. Image clipped to ellipse and rounded rect.
        let imgBmp = Bitmap(width: 4, height: 4, fill: (0, 200, 120, 255))
        let renderImage = RenderImage(imgBmp)
        var imgList = DisplayList(width: 48, height: 48, scale: 1)
        imgList.clipped(to: circlePath) { l in
            l.drawImage(renderImage, in: Rect(x: 4, y: 4, width: 40, height: 40), filter: .bilinear)
        }
        var imgCanvas = Canvas(width: 48, height: 48, scale: 1, background: .clear)
        imgCanvas.draw(imgList)
        let ib = imgCanvas.bitmap
        c.expectEqual(ib[5, 5].a, 0, "image corner outside circle clip is untouched clear")
        c.expectEqual([ib[24, 24].r, ib[24, 24].g, ib[24, 24].b, ib[24, 24].a], [0, 200, 120, 255],
                      "image center inside circle clip is intact")
        var imgAA = 0
        for y in 4..<44 { for x in 4..<44 where ib[x, y].a > 0 && ib[x, y].a < 255 { imgAA += 1 } }
        c.expect(imgAA > 40, "clipped image edge is anti-aliased (\(imgAA))")

        // 4. Text run clipped to ellipse and rounded rect.
        let glyphs = TextLayout.line("MMMMMM", font: face, pixelSize: 22)
        var textList = DisplayList(width: 80, height: 48, scale: 1)
        textList.clipped(to: Path(ellipseIn: Rect(x: 16, y: 4, width: 40, height: 40))) { l in
            l.drawGlyphs(glyphs, font: face, size: 22, at: Point(x: 2, y: 30), color: .white)
        }
        var textCanvas = Canvas(width: 80, height: 48, scale: 1, background: .clear)
        textCanvas.draw(textList)
        let tb = textCanvas.bitmap
        var outsideTextLit = 0
        for y in 0..<48 {
            for x in 0..<14 where tb[x, y].a > 0 { outsideTextLit += 1 }
            for x in 58..<80 where tb[x, y].a > 0 { outsideTextLit += 1 }
        }
        c.expectEqual(outsideTextLit, 0, "text outside ellipse clip draws zero pixels")
        var insideTextLit = 0
        for y in 12..<34 {
            for x in 20..<52 where tb[x, y].a > 200 { insideTextLit += 1 }
        }
        c.expect(insideTextLit > 20, "text inside ellipse clip renders cleanly (\(insideTextLit) bright pixels)")

        // 5. Nested path clips intersect properly (two overlapping circles).
        let circleA = Path(ellipseIn: Rect(x: 4, y: 8, width: 32, height: 32))   // center (20, 24), r=16
        let circleB = Path(ellipseIn: Rect(x: 20, y: 8, width: 32, height: 32))  // center (36, 24), r=16
        var nestedList = DisplayList(width: 56, height: 48, scale: 1)
        nestedList.clipped(to: circleA) { l in
            l.clipped(to: circleB) { l in
                l.fill(Rect(x: 0, y: 0, width: 56, height: 48), blue)
            }
        }
        c.expectEqual(nestedList.items.first?.clipPaths.count, 2, "nested path clips preserve stack")
        var nestedCanvas = Canvas(width: 56, height: 48, scale: 1, background: .clear)
        nestedCanvas.draw(nestedList)
        let nb = nestedCanvas.bitmap
        // Midpoint of intersection is (28, 24): distance 8 from both centers (< 16).
        c.expectEqual([nb[28, 24].r, nb[28, 24].g, nb[28, 24].b, nb[28, 24].a], [0, 0, 255, 255],
                      "nested clip intersection center is pure blue")
        // (14, 24) is inside circleA only (dist 6 from A, 22 from B); (42, 24) is inside circleB only.
        c.expectEqual(nb[14, 24].a, 0, "pixel inside first clip only is excluded")
        c.expectEqual(nb[42, 24].a, 0, "pixel inside second clip only is excluded")
        var nestedAA = 0
        for y in 8..<40 { for x in 20..<36 where nb[x, y].a > 0 && nb[x, y].a < 255 { nestedAA += 1 } }
        c.expect(nestedAA > 10, "nested clip intersection edge is anti-aliased (\(nestedAA))")

        // 6. Combined multi-operation scene (rect, path, image, text, nested clip) at 2x scale:
        //    partial-region Canvas.draw(list, in: region) is bit-for-bit identical to full Canvas.draw(list).
        var scene = DisplayList(width: 160, height: 120, scale: 2)
        scene.fill(Rect(x: 0, y: 0, width: 80, height: 60), bg)
        scene.clipped(to: Path(ellipseIn: Rect(x: 4, y: 4, width: 32, height: 32))) { l in
            l.fill(Rect(x: 0, y: 0, width: 40, height: 40), red)
            l.drawImage(renderImage, in: Rect(x: 8, y: 8, width: 24, height: 24), opacity: 0.75)
        }
        scene.clipped(to: Path(roundedRect: Rect(x: 40, y: 4, width: 36, height: 28), cornerRadius: 10)) { l in
            l.fill(Path(ellipseIn: Rect(x: 42, y: 6, width: 32, height: 24)), green)
            l.drawGlyphs(glyphs, font: face, size: 14, at: Point(x: 38, y: 24), color: .white)
        }
        scene.clipped(to: Path(ellipseIn: Rect(x: 12, y: 28, width: 36, height: 28))) { l in
            l.clipped(to: Path(roundedRect: Rect(x: 24, y: 32, width: 36, height: 24), cornerRadius: 8)) { l in
                l.fill(Rect(x: 0, y: 24, width: 80, height: 36), blue.opacity(0.8))
            }
        }
        var fullCanvas = Canvas(width: 160, height: 120, scale: 2, background: .black)
        fullCanvas.draw(scene)
        var tiledCanvas = Canvas(width: 160, height: 120, scale: 2, background: .black)
        let tileW = 29, tileH = 23
        var ty = 0
        while ty < 120 {
            var tx = 0
            while tx < 160 {
                let r = PixelRect(x: tx, y: ty, width: min(tileW, 160 - tx), height: min(tileH, 120 - ty))
                tiledCanvas.draw(scene, in: r)
                tx += tileW
            }
            ty += tileH
        }
        c.expectEqual(tiledCanvas.pixels, fullCanvas.pixels,
                      "partial-region draws produce bit-for-bit identical float pixels to full draw")
        c.expectEqual(tiledCanvas.bitmap, fullCanvas.bitmap,
                      "partial-region draws produce bit-for-bit identical bitmap to full draw")

        // 7. Damage detection when only clipPath changes, plus backdropBlur under clipPath.
        var blurA = DisplayList(width: 64, height: 64, scale: 1)
        blurA.fill(Rect(x: 0, y: 0, width: 64, height: 64), .black)
        blurA.fill(Rect(x: 28, y: 0, width: 8, height: 64), .white)
        blurA.clipped(to: Path(ellipseIn: Rect(x: 10, y: 10, width: 44, height: 44))) { l in
            l.backdropBlur(Rect(x: 10, y: 10, width: 44, height: 44), radius: 4)
        }
        var blurB = DisplayList(width: 64, height: 64, scale: 1)
        blurB.fill(Rect(x: 0, y: 0, width: 64, height: 64), .black)
        blurB.fill(Rect(x: 28, y: 0, width: 8, height: 64), .white)
        blurB.clipped(to: Path(roundedRect: Rect(x: 10, y: 10, width: 44, height: 44), cornerRadius: 8)) { l in
            l.backdropBlur(Rect(x: 10, y: 10, width: 44, height: 44), radius: 4)
        }
        let blurDamage = blurB.damage(since: blurA)
        c.expect(!blurDamage.isEmpty, "changing clipPath reports damage")

        var blurIncremental = Canvas(width: 64, height: 64, scale: 1, background: .black)
        blurIncremental.draw(blurA)
        let baBmp = blurIncremental.bitmap
        // Corner of bounding box (12, 12) is outside the circle, so blur must not touch it.
        c.expectEqual(baBmp[12, 12].r, 0, "backdropBlur outside circle clip stays untouched")
        // Inside the circle, the vertical white stripe softens into adjacent pixels.
        c.expect(baBmp[24, 32].r > 20 && baBmp[32, 32].r < 220, "backdropBlur softens pixels inside circle clip")

        for r in blurDamage {
            blurIncremental.clear(r, to: .black)
            blurIncremental.draw(blurB, in: r)
        }
        var blurFullB = Canvas(width: 64, height: 64, scale: 1, background: .black)
        blurFullB.draw(blurB)
        c.expectEqual(blurIncremental.bitmap, blurFullB.bitmap,
                      "clipPath change + backdropBlur damage redraw matches full draw bit-for-bit")
    },

    Check("ui.clip-shape-pixels") { c in
        let initialColor = Color(hex: 0x3B82F6)
        let model = ClipColorModel(initialColor)
        var env = EnvironmentValues()
        env.displayScale = 2
        let tree = ViewTree(ClippedCircleView(model: model), environment: env)

        let img1 = tree.render(background: .black)
        c.expectEqual(img1.width, 120, "60pt at 2x scale renders 120px wide")
        c.expectEqual(img1.height, 120, "60pt at 2x scale renders 120px tall")

        // Corner pixels outside the circle must be pure black.
        for (x, y) in [(2, 2), (117, 2), (2, 117), (117, 117)] {
            let p = img1[x, y]
            c.expectEqual([p.r, p.g, p.b, p.a], [0, 0, 0, 255], "corner (\(x),\(y)) outside Circle clip is pure black")
        }

        // Center pixel (60, 60) must be pure #3B82F6.
        let center1 = img1[60, 60]
        c.expectEqual([center1.r, center1.g, center1.b, center1.a], [0x3B, 0x82, 0xF6, 255],
                      "center pixel (60,60) is pure #3B82F6")

        // Circle edge must have smoothly anti-aliased pixels between black and #3B82F6.
        var aaCount = 0
        for y in 0..<120 {
            for x in 0..<120 {
                let b = img1[x, y].b
                if b > 0 && b < 0xF6 { aaCount += 1 }
            }
        }
        c.expect(aaCount > 80, "2x circle clip has smoothly anti-aliased edge (\(aaCount) pixels)")

        // Change color and verify incremental damage redraw matches fresh full render bit-for-bit.
        let updatedColor = Color(hex: 0xEF4444)
        model.color = updatedColor
        let img2 = tree.render(background: .black)
        c.expect(!tree.damage.isEmpty, "color change produces non-empty damage")
        let corner2 = img2[2, 2]
        c.expectEqual([corner2.r, corner2.g, corner2.b, corner2.a], [0, 0, 0, 255],
                      "corner (2,2) stays pure black after color update")
        let center2 = img2[60, 60]
        c.expectEqual([center2.r, center2.g, center2.b, center2.a], [0xEF, 0x44, 0x44, 255],
                      "center pixel (60,60) updated to #EF4444")

        let freshTree = ViewTree(
            updatedColor
                .frame(width: 60, height: 60)
                .clipShape(Circle()),
            environment: env
        )
        let fullImg2 = freshTree.render(background: .black)
        c.expectEqual(img2, fullImg2, "damage redraw after color change equals full redraw bit-for-bit")

        // Rectangle clipShape stays on the rectangular clip fast path (no clipPaths).
        let rectTree = ViewTree(
            initialColor
                .frame(width: 40, height: 40)
                .clipShape(Rectangle()),
            environment: env
        )
        _ = rectTree.render(background: .black)
        c.expect(rectTree.displayList?.items.allSatisfy { $0.clipPaths.isEmpty } == true,
                 "Rectangle clipShape uses rectangular clip fast path without clipPaths")
    },
]
