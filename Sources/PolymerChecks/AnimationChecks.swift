// Checks for animation: timing curves, and frames, opacity and colours
// moving over `ViewTree.time` with `withAnimation` and `.animation(_:value:)`.
import PolymerBase
import PolymerRender
import PolymerUI

@Observable
final class AnimationModel {
    var wide = false
    var visible = true
    var dark = false
    var shift = 0.0
}

struct AnimationScreen: View {
    let model: AnimationModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.white.frame(width: model.wide ? 200 : 100, height: 20)
            Color.white.frame(width: 50, height: 20).opacity(model.visible ? 1 : 0)
            Color(white: model.dark ? 0 : 1).frame(width: 50, height: 20)
            Color.white.frame(width: 30, height: 10).offset(x: model.shift).animation(.linear(duration: 1), value: model.shift)
        }
        .frame(width: 300, height: 70, alignment: .topLeading)
    }
}

@MainActor let animationChecks: [Check] = [
    Check("ui.animation") { c in
        // Curves.
        c.expectClose(Animation.linear(duration: 1).progress(0.25), 0.25, tolerance: 1e-9, "linear")
        c.expectClose(Animation.easeInOut(duration: 1).progress(0.5), 0.5, tolerance: 1e-9, "ease in and out is symmetric")
        c.expect(Animation.easeIn(duration: 1).progress(0.5) < 0.4 && Animation.easeOut(duration: 1).progress(0.5) > 0.6, "ease in starts slow, ease out ends slow")
        let bouncy = Animation.spring(response: 0.4, dampingFraction: 0.5)
        let peak = stride(from: 0.0, to: bouncy.duration, by: 0.005).map { bouncy.progress($0) }.max() ?? 0
        c.expect(peak > 1.1, "an underdamped spring overshoots: peak \(peak)")
        let smooth = Animation.default
        var last = 0.0, monotonic = true
        for t in stride(from: 0.0, through: smooth.duration, by: 0.005) { let p = smooth.progress(t); if p < last - 1e-12 || p > 1 + 1e-12 { monotonic = false }; last = p }
        c.expect(monotonic, "the default spring never overshoots")
        c.expectEqual(smooth.progress(smooth.duration), 1, "it arrives at its duration")
        c.expect(smooth.duration > 0.6 && smooth.duration < 1.0, "and settles in under a second: \(smooth.duration)")

        let model = AnimationModel()
        let tree = ViewTree(AnimationScreen(model: model))
        @MainActor func colors() -> [String] {
            tree.elementTree.split(separator: "\n").map { String($0.drop { $0 == " " }) }.filter { $0.hasPrefix("Color (") }
        }
        tree.time = 0
        _ = tree.render()
        c.expectEqual(colors().first, "Color (0, 0, 100x20) #FFFFFF", "starts 100 wide")

        // withAnimation: the frame moves along the curve as time passes.
        withAnimation(.linear(duration: 1)) { model.wide = true }
        _ = tree.render()
        c.expectEqual(colors().first, "Color (0, 0, 100x20) #FFFFFF", "at the start of the animation, still where it was")
        c.expect(tree.isAnimating, "an animation is running")
        tree.time = 0.5
        _ = tree.render()
        c.expectEqual(colors().first, "Color (0, 0, 150x20) #FFFFFF", "half way: half way")
        // Interrupted: a new change starts from what is shown.
        withAnimation(.linear(duration: 1)) { model.wide = false }
        _ = tree.render()
        tree.time = 1.0
        _ = tree.render()
        c.expectEqual(colors().first, "Color (0, 0, 125x20) #FFFFFF", "an interrupted animation goes back from where it was")
        tree.time = 1.5
        c.expect(!tree.isAnimating, "and stops when it arrives")
        c.expectEqual(colors().first, "Color (0, 0, 100x20) #FFFFFF", "arrived")

        // Without an animation, changes jump.
        model.wide = true
        _ = tree.render()
        c.expectEqual(colors().first, "Color (0, 0, 200x20) #FFFFFF", "no animation: at once")
        c.expect(!tree.isAnimating, "nothing running")

        // Opacity eases out and in.
        withAnimation(.easeInOut(duration: 0.4)) { model.visible = false }
        _ = tree.render()
        tree.time = 1.7
        _ = tree.render()
        let opacities: [Double] = (tree.displayList?.items ?? []).compactMap { if case .beginLayer(let e) = $0.operation { e.opacity } else { nil } }
        c.expectEqual(opacities.count, 1, "the fading view is drawn as a layer")
        c.expectClose(opacities.first ?? 0, 0.5, tolerance: 1e-9, "half way through the fade")
        tree.time = 2
        _ = tree.render()
        c.expect(!(tree.displayList?.items ?? []).contains { if case .beginLayer = $0.operation { true } else { false } }, "faded out: not drawn")

        // Colours blend.
        withAnimation(.linear(duration: 1)) { model.dark = true }
        _ = tree.render()
        tree.time = 2.25
        _ = tree.render()
        let fills: [Color] = (tree.displayList?.items ?? []).compactMap { if case .rect(let r, let col) = $0.operation, r.minY == 40 { col } else { nil } }
        c.expect(fills.count == 1 && abs((fills.first?.red ?? 0) - 0.75) < 1e-9, "a quarter of the way from white to black: \(fills)")

        // .animation(_:value:) animates its view when the value changes, without withAnimation.
        tree.time = 5
        _ = tree.render()
        model.shift = 40
        _ = tree.render()
        tree.time = 5.5
        _ = tree.render()
        c.expect(colors().contains("Color (20, 60, 30x10) #FFFFFF"), "half way along a 40-point shift:\n\(colors())")

        // A spring that overshoots passes its target.
        withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) { model.wide = false }
        _ = tree.render()
        var narrowest = 1000.0
        for k in 1...60 {
            tree.time = 5.5 + Double(k) * 0.01
            _ = tree.render()
            if let w = colors().first?.split(separator: " ")[3].split(separator: "x").first, let v = Double(w) { narrowest = min(narrowest, v) }
        }
        c.expect(narrowest < 100, "the spring passes 100 on its way back: \(narrowest)")

        // Every animated frame redraws partially, identical to a whole draw.
        var e = EnvironmentValues()
        e.displayScale = 2
        let m2 = AnimationModel()
        let t2 = ViewTree(AnimationScreen(model: m2), environment: e)
        _ = t2.render(background: .black)
        withAnimation(.easeOut(duration: 0.3)) { m2.wide = true; m2.dark = true; m2.visible = false }
        for k in 0...6 {
            t2.time = Double(k) * 0.05
            let img = t2.render(background: .black)
            var whole = Canvas(width: img.width, height: img.height, scale: 2, background: .black)
            if let l = t2.displayList { whole.draw(l) }
            c.expect(img == whole.bitmap, "partial frame at \(t2.time) s equals a whole draw")
        }
    },

    Check("ui.animation-velocity") { c in
        // A spring interrupted in mid-flight keeps its speed: the motion bends instead of stopping.
        let model = AnimationModel()
        let tree = ViewTree(AnimationScreen(model: model))
        @MainActor func width(at t: Double) -> Double {
            tree.time = t
            let line = tree.elementTree.split(separator: "\n").first { $0.contains("Color (") } ?? ""
            let size = line.split(separator: " ").dropFirst(3).first ?? ""
            return Double(size.split(separator: "x").first ?? "") ?? -1
        }
        _ = width(at: 0)
        let spring = Animation.spring(response: 0.5, dampingFraction: 0.8)
        withAnimation(spring) { model.wide = true }
        _ = width(at: 0)
        let h = 0.0005, t0 = 0.12
        let before = (width(at: t0) - width(at: t0 - h)) / h
        let w0 = width(at: t0)
        c.expect(before > 100, "the spring is moving fast at \(t0) s: \(before) points per second")
        withAnimation(spring) { model.wide = false }
        let jumped = width(at: t0)
        c.expectClose(jumped, w0, tolerance: 1e-9, "an interruption starts where the view is")
        let after = (width(at: t0 + h) - width(at: t0)) / h
        c.expect(abs(after - before) < abs(before) * 0.02, "and at the speed it had: \(before) then \(after) points per second")
        var settled = 0.0
        for k in 1...400 { if !tree.isAnimating { break }; settled = t0 + Double(k) * 0.01; _ = width(at: settled) }
        c.expectEqual(width(at: settled + 0.01), 100, "then it settles at the new target")
        c.expect(settled < t0 + 2, "within two seconds: \(settled)")

        // A timing curve starts again from where the view is (no speed carried).
        _ = width(at: 10)
        withAnimation(.easeIn(duration: 1)) { model.wide = true }
        _ = width(at: 10)
        let mid = width(at: 10.5)
        withAnimation(.easeIn(duration: 1)) { model.wide = false }
        c.expectClose(width(at: 10.5), mid, tolerance: 1e-9, "an interrupted curve starts where the view is")
        let start = (width(at: 10.5 + h) - width(at: 10.5)) / h
        c.expect(abs(start) < 1, "from rest (ease in): \(start)")
    },

    Check("ui.transition") { c in
        let font = Font(try TextReference.font(root: c.root, "Geist-Regular.otf"), size: 13)
        let model = TransitionModel()
        let tree = ViewTree(TransitionScreen(model: model, font: font))
        @MainActor func colors() -> [String] {
            tree.elementTree.split(separator: "\n").map { String($0.drop { $0 == " " }) }.filter { $0.hasPrefix("Color (") }
        }
        @MainActor func items() -> [DisplayItem] { tree.displayList?.items ?? [] }
        @MainActor func layerOpacities() -> [Double] {
            items().compactMap { if case .beginLayer(let e) = $0.operation { e.opacity } else { nil } }
        }
        /// Where rectangles of `color` are drawn (origin included).
        @MainActor func rects(_ color: Color) -> [Rect] {
            items().compactMap {
                if case .rect(let r, let col) = $0.operation, col == color { r.offsetBy(dx: $0.origin.x, dy: $0.origin.y) } else { nil }
            }
        }
        let grey = Color(white: 0.5)
        tree.time = 0
        _ = tree.render()
        c.expectEqual(colors().prefix(2).joined(separator: "; "), "Color (0, 0, 40x20) #FFFFFF; Color (0, 20, 40x20) #808080", "two bars at first")

        // Removed with an animation: the view fades where it was while the rest moves up.
        withAnimation(.linear(duration: 1)) { model.showA = false }
        _ = tree.render()
        c.expect(colors().first == "Color (0, 0, 40x20) #FFFFFF leaving", "the removed bar is still there, leaving:\n\(colors())")
        tree.time = 0.5
        _ = tree.render()
        c.expectEqual(layerOpacities(), [0.5], "half way it is drawn at half opacity")
        c.expectEqual(rects(grey), [Rect(x: 0, y: 10, width: 40, height: 20)], "and the bar below is half way up")
        c.expect(tree.click(at: Point(x: 20, y: 5)) == false, "a leaving view can't be clicked")
        tree.time = 1
        _ = tree.render()
        c.expect(!colors().contains { $0.contains("leaving") }, "gone when the transition ends:\n\(colors())")
        c.expectEqual(layerOpacities(), [], "nothing fading any more")
        c.expect(!tree.isAnimating, "and nothing runs")

        // Inserted with .move(edge: .leading): it slides in by its own width.
        withAnimation(.linear(duration: 1)) { model.showB = true }
        _ = tree.render()
        let white = Color.white
        c.expect(rects(white).isEmpty, "starts a whole width to the left, out of the image: nothing drawn")
        tree.time = 1.25
        _ = tree.render()
        c.expectEqual(rects(white).first, Rect(x: -30, y: 20, width: 40, height: 20), "a quarter of the way in")
        c.expectEqual(layerOpacities(), [], "a move doesn't fade")
        tree.time = 2
        _ = tree.render()
        c.expectEqual(rects(white).first, Rect(x: 0, y: 20, width: 40, height: 20), "in place")

        // ForEach: a removed element leaves by its own transition (.offset), an inserted one comes in by it.
        tree.time = 3
        _ = tree.render()
        let rows = (1...3).map { Color(white: Double($0) / 10) }
        c.expectEqual(rects(rows[1]), [Rect(x: 0, y: 50, width: 30, height: 10)], "row 2 at first")
        withAnimation(.linear(duration: 1)) { model.items = [1, 3, 4] }
        _ = tree.render()
        tree.time = 3.5
        _ = tree.render()
        c.expectEqual(rects(rows[1]), [Rect(x: 25, y: 50, width: 30, height: 10)], "row 2 leaves to the right from where it was")
        c.expectEqual(rects(rows[2]), [Rect(x: 0, y: 55, width: 30, height: 10)], "row 3 moves into its place")
        c.expectEqual(rects(Color(white: 0.4)), [Rect(x: 25, y: 60, width: 30, height: 10)], "row 4 comes in from the right")
        let order = items().compactMap { i -> Double? in if case .rect(_, let col) = i.operation, col.red < 0.45, col.red > 0.05 { col.red } else { nil } }
        c.expectEqual(order.map { Int(($0 * 10).rounded()) }, [1, 2, 3, 4], "the leaving row is drawn in its old place among the others")

        // Re-inserted while still leaving: a new view comes in while the old one goes on leaving (as in SwiftUI).
        tree.time = 5
        withAnimation(.linear(duration: 1)) { model.showA = true }
        _ = tree.render()
        withAnimation(.linear(duration: 1)) { model.showA = false }
        tree.time = 5.4
        _ = tree.render()
        withAnimation(.linear(duration: 1)) { model.showA = true }
        _ = tree.render()
        tree.time = 5.6
        _ = tree.render()
        c.expectEqual(layerOpacities().map { ($0 * 1000).rounded() / 1000 }, [0.32, 0.2], "one fading out from 0.4 behind, one fading in")
        tree.time = 7
        _ = tree.render()

        // Without an animation, removal is immediate.
        model.showB = false
        _ = tree.render()
        c.expect(!colors().contains { $0.contains("leaving") } && rects(white).count == 1, "no animation, no transition")

        // Shape fills and text colours move too.
        tree.time = 8
        _ = tree.render()
        withAnimation(.linear(duration: 1)) { model.tint = true }
        _ = tree.render()
        tree.time = 8.5
        _ = tree.render()
        let pathColors = items().compactMap { if case .path(_, let col) = $0.operation { col } else { nil } }
        let textColors = items().compactMap { if case .glyphs(let g) = $0.operation { g.color } else { nil } }
        c.expect(pathColors.count == 1 && abs(pathColors[0].red - 0.5) < 1e-9, "a rounded rectangle half way from white to black: \(pathColors)")
        c.expect(textColors.count == 1 && abs(textColors[0].red - 0.5) < 1e-9, "text half way from white to black: \(textColors)")

        // Every frame of a transition redraws partially, identical to a whole draw.
        var e = EnvironmentValues()
        e.displayScale = 2
        let m2 = TransitionModel()
        let t2 = ViewTree(TransitionScreen(model: m2, font: font), environment: e)
        _ = t2.render(background: .black)
        withAnimation(.easeOut(duration: 0.3)) { m2.showA = false; m2.showB = true; m2.items = [3, 1]; m2.tint = true }
        for k in 0...7 {
            t2.time = Double(k) * 0.05
            let img = t2.render(background: .black)
            var whole = Canvas(width: img.width, height: img.height, scale: 2, background: .black)
            if let l = t2.displayList { whole.draw(l) }
            c.expect(img == whole.bitmap, "partial frame at \(t2.time) s equals a whole draw")
        }
        c.expect(!t2.isAnimating, "all done after 0.35 s")

        // .transition(.scale) grows from the centre; .scaleEffect scales what is drawn, not the layout.
        let c7 = Color(white: 0.7), c8 = Color(white: 0.8)
        tree.time = 20
        _ = tree.render()
        let small = rects(c8).first ?? .zero
        c.expectEqual(small.size, Size(width: 20, height: 20), "the scaled view at 1")
        withAnimation(.linear(duration: 1)) { model.showC = true; model.big = true }
        _ = tree.render()
        tree.time = 20.5
        _ = tree.render()
        let growing = rects(c7).first ?? .zero
        let half8 = rects(c8).first ?? .zero
        tree.time = 21
        _ = tree.render()
        let full = rects(c7).first ?? .zero
        c.expectEqual(full.size, Size(width: 40, height: 40), "inserted with .scale, full size at the end")
        c.expectEqual(growing, Rect(x: full.minX + 10, y: full.minY + 10, width: 20, height: 20), "half size about its centre half way")
        c.expectEqual(half8.size, Size(width: 30, height: 30), "scaleEffect half way from 1 to 2")
        c.expectEqual(rects(c8).first, Rect(x: small.minX, y: full.maxY, width: 40, height: 40), "at 2, about its top-leading corner")
        c.expect(tree.elementTree.contains("Color (\(Int(small.minX)), \(Int(full.maxY)), 20x20)"), "its layout frame stays 20x20:\n\(tree.elementTree)")
        withAnimation(.linear(duration: 1)) { model.showC = false }
        _ = tree.render()
        tree.time = 21.75
        _ = tree.render()
        let shrinking = rects(c7).first ?? .zero
        func r6(_ v: Double) -> Double { (v * 1e6).rounded() / 1e6 }
        c.expectEqual(Rect(x: r6(shrinking.minX), y: r6(shrinking.minY), width: r6(shrinking.width), height: r6(shrinking.height)),
                      Rect(x: full.minX + 15, y: full.minY + 15, width: 10, height: 10), "removed with .scale: a quarter size three quarters of the way")
    },
]

@Observable
final class TransitionModel {
    var showA = true
    var showB = false
    var items = [1, 2, 3]
    var tint = false
    var showC = false
    var big = false
}

struct TransitionScreen: View {
    let model: TransitionModel
    let font: Font
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.showA { Color.white.frame(width: 40, height: 20) }
            Color(white: 0.5).frame(width: 40, height: 20)
            if model.showB { Color.white.frame(width: 40, height: 20).transition(.move(edge: .leading)) }
            ForEach(model.items, id: \.self) { i in
                Color(white: Double(i) / 10).frame(width: 30, height: 10).transition(.offset(x: 50))
            }
            RoundedRectangle(cornerRadius: 4).fill(model.tint ? .black : .white).frame(width: 20, height: 20)
            Text("Tint").foregroundStyle(model.tint ? .black : .white)
            if model.showC { Color(white: 0.7).frame(width: 40, height: 40).transition(.scale) }
            Color(white: 0.8).frame(width: 20, height: 20).scaleEffect(model.big ? 2 : 1, anchor: .topLeading)
        }
        .font(font)
        .frame(width: 200, height: 200, alignment: .topLeading)
    }
}
