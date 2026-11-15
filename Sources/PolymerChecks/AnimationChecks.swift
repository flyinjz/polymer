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
]
