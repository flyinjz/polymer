// Effects and materials as in SwiftUI (DESIGN section 11): `.glassEffect`
// with `Glass`, and `.background(_:in:)` with a `Material`. Both draw a
// backdrop effect behind the view, in a shape, filtering what was drawn
// before it. The default values are a starting point for the design
// system's tokens (see DESIGN 11.8).
import PolymerBase
import PolymerRender

/// Liquid glass: refracts, frosts and tints what is behind it, with a light rim.
public struct Glass: Hashable, Sendable {
    var style: GlassStyle?
    var name: String

    /// Frosted, darkened glass for controls and bars.
    public static let regular = Glass(style: GlassStyle(refraction: 6, bezel: 14, frost: 3,
                                                        tint: Color(white: 0.06, opacity: 0.3), rim: 0.35), name: "regular")
    /// Nearly clear glass: refraction and rim, little frost or tint.
    public static let clear = Glass(style: GlassStyle(refraction: 7, bezel: 14, frost: 0.5,
                                                      tint: Color(white: 1, opacity: 0.03), rim: 0.3), name: "clear")
    /// No glass at all (for turning the effect off without changing the view).
    public static let identity = Glass(style: nil, name: "identity")

    /// The same glass tinted with `color` (its opacity is the strength of the tint).
    public func tint(_ color: Color?) -> Glass {
        guard var s = style, let color else { return self }
        s.tint = color
        return Glass(style: s, name: name + " tinted")
    }
}

/// Blur and tint behind a view: SwiftUI's materials, darkened for the pgr glass.
public struct Material: Hashable, Sendable {
    let blur: Double
    let tint: Color
    let name: String
    public static let ultraThinMaterial = Material(blur: 6, tint: Color(white: 0.06, opacity: 0.25), name: "ultraThin")
    public static let thinMaterial = Material(blur: 10, tint: Color(white: 0.06, opacity: 0.4), name: "thin")
    public static let regularMaterial = Material(blur: 16, tint: Color(white: 0.06, opacity: 0.55), name: "regular")
    public static let thickMaterial = Material(blur: 22, tint: Color(white: 0.06, opacity: 0.7), name: "thick")
    public static let ultraThickMaterial = Material(blur: 30, tint: Color(white: 0.06, opacity: 0.82), name: "ultraThick")
}

extension EnvironmentValues {
    /// The user asked for less transparency (an OS accessibility setting):
    /// glass and materials draw as opaque fills of their shape.
    public var accessibilityReduceTransparency: Bool {
        get { self[ReduceTransparencyKey.self] }
        set { self[ReduceTransparencyKey.self] = newValue }
    }
}

struct ReduceTransparencyKey: EnvironmentKey { static let defaultValue = false }

extension View {
    /// Liquid glass behind the view, in `shape` (SwiftUI's default is a capsule).
    public func glassEffect<S: RoundedRectShape>(_ glass: Glass = .regular, in shape: S) -> some View {
        LayerView(content: self, layer: BackdropView(shape: shape, kind: .glass(glass)), behind: true)
    }
    public func glassEffect(_ glass: Glass = .regular) -> some View { glassEffect(glass, in: Capsule()) }

    /// A material behind the view, in `shape`.
    public func background<S: RoundedRectShape>(_ material: Material, in shape: S) -> some View {
        LayerView(content: self, layer: BackdropView(shape: shape, kind: .material(material)), behind: true)
    }
    public func background(_ material: Material) -> some View { background(material, in: Rectangle()) }
}

struct BackdropView<S: RoundedRectShape>: View, PrimitiveView {
    enum Kind { case glass(Glass), material(Material) }
    let shape: S
    let kind: Kind
    var body: Never { fatalError("BackdropView is a built-in view") }

    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? BackdropNode) ?? BackdropNode()
        let shape = self.shape
        n.geometry = { shape.roundedRect(in: $0) }
        n.opaque = c.environment.accessibilityReduceTransparency
        switch kind {
        case .glass(let g):
            n.effect = g.style.map { .glass($0) }
            n.name = "Glass"; n.label = g.name
        case .material(let m):
            n.effect = .material(blur: m.blur, tint: m.tint)
            n.name = "Material"; n.label = m.name
        }
        return n
    }
}

final class BackdropNode: Node {
    var geometry: (Rect) -> RoundedRect = { RoundedRect($0, cornerRadius: 0) }
    var effect: BackdropEffect?
    var opaque = false
    var name = "Glass", label = ""

    override var role: String { name }
    override var detail: String { opaque ? "\(label), opaque" : label }
    override func sizeThatFits(_ p: ProposedViewSize) -> Size { p.replacingUnspecified(Size(width: 10, height: 10)) }

    override func draw(_ list: inout DisplayList) {
        guard let effect, list.isVisible(frame) else { return }
        let shape = geometry(frame)
        if opaque {
            // Reduce transparency: an opaque fill of the shape, tinted as the effect would be.
            let tint: Color = switch effect { case .material(_, let t): t; case .glass(let g): g.tint }
            let base = Color(white: 0.11)
            let a = tint.opacity
            let solid = Color(red: tint.red * a + base.red * (1 - a), green: tint.green * a + base.green * (1 - a),
                              blue: tint.blue * a + base.blue * (1 - a))
            if shape.cornerRadius == 0 { list.fill(shape.rect, solid) } else { list.fill(shape.path(), solid) }
            return
        }
        list.drawBackdrop(shape, effect)
    }
}

// MARK: Layers: opacity, clipShape, blur

extension View {
    /// Draws the view with `opacity` (0 to 1). A view at 0 is not drawn and can't be clicked.
    public func opacity(_ opacity: Double) -> some View {
        LayerEffectView(content: self, opacity: min(max(opacity, 0), 1), shape: nil as Rectangle?, blur: 0)
    }
    /// Cuts the view to `shape` with an anti-aliased edge; clicks outside the shape miss it.
    public func clipShape<S: RoundedRectShape>(_ shape: S) -> some View {
        LayerEffectView(content: self, opacity: 1, shape: shape, blur: 0)
    }
    /// Blurs what the view draws (a Gaussian; `radius` in points), spreading past its frame by about 3 radii.
    public func blur(radius: Double) -> some View {
        LayerEffectView(content: self, opacity: 1, shape: nil as Rectangle?, blur: max(0, radius))
    }
}

struct LayerEffectView<Content: View, S: RoundedRectShape>: View, PrimitiveView {
    let content: Content
    let opacity: Double
    let shape: S?
    let blur: Double
    var body: Never { fatalError("LayerEffectView is a built-in view") }

    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? LayerEffectNode) ?? LayerEffectNode()
        n.opacity = opacity
        n.blur = blur
        if let shape { n.mask = { shape.roundedRect(in: $0) } } else { n.mask = nil }
        n.setChild(0, content, c)
        return n
    }
}

/// Draws its content as a display-list layer (opacity, a clipping shape, blur).
final class LayerEffectNode: Node {
    var opacity = 1.0
    var blur = 0.0
    var mask: ((Rect) -> RoundedRect)?

    override var isElement: Bool { false }
    override var clipsContent: Bool { mask != nil }
    override func sizeThatFits(_ p: ProposedViewSize) -> Size { children[0].measure(p) }
    override func placeChildren(in r: Rect) { children[0].place(r) }

    override func draw(_ list: inout DisplayList) {
        let effect = LayerEffect(opacity: opacity, mask: mask?(frame), blur: blur)
        list.layer(effect, area: frame) { children[0].draw(&$0) }
    }

    override func hitTest(_ p: Point) -> Node? {
        if opacity <= 0 { return nil }
        if let mask, mask(frame).signedDistance(p.x, p.y) > 0 { return nil }
        return children[0].hitTest(p)
    }
}
