// Interactive glass (`Glass.interactive()`, as in SwiftUI): glass that
// answers the pointer. Pressed, the glass and what it holds swell a little
// on a lively spring and the glass brightens; released, they settle back.
// It never takes the click: buttons inside work as before. The amounts are
// placeholders for PolymerDesign tokens (DESIGN 11.8).
import PolymerBase
import PolymerRender

extension Glass {
    /// Glass that responds to the pointer: it swells and brightens while pressed.
    public func interactive(_ isEnabled: Bool = true) -> Glass {
        var g = self
        g.isInteractive = isEnabled && style != nil
        return g
    }
}

/// How interactive glass moves (placeholders for design tokens).
enum InteractiveGlassLook {
    /// Points the longer side grows by when pressed.
    static let growth = 4.0
    /// How far the tint goes toward white when pressed.
    static let brighten = 0.12
    /// The spring of the press and release.
    static let spring = Animation.spring(response: 0.3, dampingFraction: 0.6)
}

struct InteractiveGlassView<Content: View>: View, PrimitiveView {
    let content: Content
    let enabled: Bool
    var body: Never { fatalError("InteractiveGlassView is a built-in view") }

    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? InteractiveGlassNode) ?? InteractiveGlassNode()
        n.enabled = enabled
        n.setChild(0, content, c)
        n.glass?.interactive = enabled ? n : nil
        if enabled { c.tree.addInteractiveGlass(n) } else if n.pressed { n.setPressed(false) }
        return n
    }
}

/// Wraps a view with interactive glass behind it: tracks the press and draws
/// the view and its glass swelling about their centre.
final class InteractiveGlassNode: Node {
    var enabled = false

    /// The glass: the background of the view this node wraps.
    var glass: BackdropNode? { (children.first as? LayerNode)?.children.last as? BackdropNode }

    /// 0 at rest, 1 fully pressed (a spring may pass 1).
    private var press = Animated(0.0)
    private(set) var pressed = false

    override var isElement: Bool { false }
    override func sizeThatFits(_ p: ProposedViewSize) -> Size { children[0].measure(p) }
    override func placeChildren(in r: Rect) { children[0].place(r) }
    override func isAnimating(at now: Double) -> Bool { super.isAnimating(at: now) || press.isRunning(at: now) }

    func setPressed(_ down: Bool) {
        guard down != pressed, let tree else { return }
        pressed = down
        if press.set(down ? 1 : 0, animation: InteractiveGlassLook.spring, now: tree.now) { tree.startedAnimation(self) }
    }

    /// How pressed the glass looks now.
    var pressAmount: Double { press.value(at: tree?.now ?? 0) }

    /// The scale the view and its glass are drawn at now.
    var shownScale: Double {
        let longest = max(frame.width, frame.height)
        guard longest > 0 else { return 1 }
        return max(0, 1 + InteractiveGlassLook.growth / longest * pressAmount)
    }

    /// The glass's tint while pressed.
    func pressedTint(_ tint: Color) -> Color {
        let k = InteractiveGlassLook.brighten * min(max(pressAmount, 0), 1)
        if k == 0 { return tint }
        return ColorVector(tint).adding(ColorVector(r: 1 - tint.red, g: 1 - tint.green, b: 1 - tint.blue, a: 0).scaled(by: k)).color
    }

    /// True when `p` (screen points) is on the glass.
    func contains(_ p: Point) -> Bool {
        guard isMounted, enabled else { return false }
        let shift = Point(x: screenFrame.minX - frame.minX, y: screenFrame.minY - frame.minY)
        guard let glass else { return screenFrame.contains(p) }
        return glass.geometry(glass.frame).signedDistance(p.x - shift.x, p.y - shift.y) <= 0
    }

    override func drawContent(_ list: inout DisplayList) {
        let s = shownScale
        if s == 1 { children[0].draw(&list); return }
        list.scaled(by: s, about: Point(x: frame.midX, y: frame.midY)) { children[0].draw(&$0) }
    }

    override func hitTest(_ p: Point) -> Node? {
        let s = shownScale
        guard s != 1 else { return children[0].hitTest(p) }
        let c = Point(x: frame.midX, y: frame.midY)
        return children[0].hitTest(Point(x: c.x + (p.x - c.x) / s, y: c.y + (p.y - c.y) / s))
    }

    override func unmount() {
        pressed = false
        super.unmount()
    }
}
