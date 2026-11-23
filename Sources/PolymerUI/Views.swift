// Built-in leaf views: Text, Color, Rectangle, Spacer, Divider.
import PolymerBase
import PolymerText
import PolymerRender

/// Text in the environment's font and colour. Wraps to the width it is
/// offered; `lineLimit`, or a height too short for every line, caps the
/// lines and cuts the rest with an ellipsis.
public struct Text: View, PrimitiveView {
    let string: String
    public init(_ string: String) { self.string = string }

    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? TextNode) ?? TextNode()
        let e = c.environment
        n.update(string: string, font: e.font, lineLimit: e.lineLimit)
        n.color = e.foregroundColor
        n.options = e.textRendering
        n.alignment = e.multilineTextAlignment
        return n
    }
}

final class TextNode: Node {
    private(set) var string = ""
    private(set) var font: Font?
    private(set) var lineLimit: Int?
    var color: Color = .white
    var options: TextRenderingOptions = .standard
    var alignment: TextAlignment = .leading
    /// Line layouts for recent widths (points) and line limits; emptied when the text, font or limit changes.
    private var layouts: [(width: Double?, limit: Int?, lines: [TextLine])] = []
    private var configured = false

    func update(string: String, font: Font?, lineLimit: Int?) {
        if configured, string == self.string, font == self.font, lineLimit == self.lineLimit { return }
        configured = true
        self.string = string; self.font = font; self.lineLimit = lineLimit
        layouts.removeAll(keepingCapacity: true)
        if font == nil {
            Logger("PolymerUI").warning("Text(\"\(string)\") has no font; set one with .font(Font(face, size:)) on it or an ancestor")
        }
    }

    override var role: String { "Text" }
    override var detail: String { "\"\(string)\"" }
    override var isHitTarget: Bool { true }

    /// Lines wrapped to `width` points (nil: only explicit line breaks). Offered
    /// a `height` too short for them all, the text keeps the lines that fit (at
    /// least one) and the last of them ends in an ellipsis, as in SwiftUI.
    func lines(_ font: Font, width: Double?, height: Double?) -> [TextLine] {
        let all = layout(font, width: width, limit: lineLimit)
        guard let height, height.isFinite else { return all }
        let fit = max(1, Int(((height + 1e-6) / lineHeight(font)).rounded(.down)))
        return all.count > fit ? layout(font, width: width, limit: fit) : all
    }

    /// Lines for a width and a line limit; recent answers are kept.
    private func layout(_ font: Font, width: Double?, limit: Int?) -> [TextLine] {
        for l in layouts where l.width == width && l.limit == limit { return l.lines }
        let l = TextLayout.lines(string, font: font.face, pixelSize: font.size, maxWidth: width, lineLimit: limit)
        if layouts.count >= 6 { layouts.removeFirst() }
        layouts.append((width, limit, l))
        return l
    }

    func ceilToPixel(_ v: Double) -> Double { (v * scale).rounded(.up) / scale }

    /// Distance between baselines: the font's line height rounded up to whole pixels, so lines are evenly spaced.
    func lineHeight(_ font: Font) -> Double { ceilToPixel(font.lineHeight) }

    override func sizeThatFits(_ p: ProposedViewSize) -> Size {
        guard let font else { return .zero }
        let width = p.width.flatMap { $0.isFinite ? $0 : nil }
        let ls = lines(font, width: width, height: p.height)
        let widest = ls.reduce(0) { max($0, $1.width) }
        return Size(width: ceilToPixel(widest), height: lineHeight(font) * Double(ls.count))
    }

    override func draw(_ list: inout DisplayList) {
        guard let font, list.isVisible(frame) else { return }
        let ls = lines(font, width: frame.width, height: frame.height)
        let lh = lineHeight(font)
        let top = frame.minY + (frame.height - lh * Double(ls.count)) / 2 + (lh - font.lineHeight) / 2 + font.ascent
        for (i, line) in ls.enumerated() {
            // Baselines and line starts sit on whole pixels; glyphs keep their exact positions within the line.
            let baseline = ((top + Double(i) * lh) * scale).rounded() / scale
            let slack = max(0, frame.width - line.width)
            let dx: Double = switch alignment { case .leading: 0; case .center: slack / 2; case .trailing: slack }
            let x = ((frame.minX + dx) * scale).rounded() / scale
            list.drawGlyphs(line.glyphs, font: font.face, size: font.size, at: Point(x: x, y: baseline),
                              color: color, options: options)
        }
    }
}

/// A colour fills the space it is offered.
extension Color: View, PrimitiveView {
    public var body: Never { fatalError("Color is a built-in view") }
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? FillNode) ?? FillNode()
        n.color = self; n.name = "Color"
        return n
    }
}

/// A rectangle filled with the foreground colour.
public struct Rectangle: View, PrimitiveView {
    public init() {}
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? FillNode) ?? FillNode()
        n.color = c.environment.foregroundColor; n.name = "Rectangle"
        return n
    }
}

final class FillNode: Node {
    var color: Color = .clear
    var name = "Color"
    override var role: String { name }
    override var detail: String { color.description }
    override var isHitTarget: Bool { color.opacity > 0 }
    override func sizeThatFits(_ p: ProposedViewSize) -> Size {
        // SwiftUI shapes take 10 points when given no size.
        p.replacingUnspecified(Size(width: 10, height: 10))
    }
    override func draw(_ list: inout DisplayList) { if list.isVisible(frame) { list.fill(frame, color) } }
}

/// Flexible space along the enclosing stack's axis.
public struct Spacer: View, PrimitiveView {
    let minLength: Double?
    public init(minLength: Double? = nil) { self.minLength = minLength }
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? SpacerNode) ?? SpacerNode()
        n.minLength = minLength ?? 8; n.axis = c.stackAxis
        return n
    }
}

final class SpacerNode: Node {
    var minLength = 8.0
    var axis: Axis?
    override var role: String { "Spacer" }
    override func sizeThatFits(_ p: ProposedViewSize) -> Size {
        switch axis {
        case .horizontal: Size(width: max(minLength, p.width ?? minLength), height: 0)
        case .vertical: Size(width: 0, height: max(minLength, p.height ?? minLength))
        case nil: Size(width: max(minLength, p.width ?? minLength), height: max(minLength, p.height ?? minLength))
        }
    }
}

/// A 1-point line across the enclosing stack (vertical in an HStack, horizontal otherwise).
public struct Divider: View, PrimitiveView {
    public init() {}
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? DividerNode) ?? DividerNode()
        n.color = c.environment.separatorColor; n.vertical = c.stackAxis == .horizontal
        return n
    }
}

final class DividerNode: Node {
    var color: Color = .clear
    var vertical = false
    override var role: String { "Divider" }
    override func sizeThatFits(_ p: ProposedViewSize) -> Size {
        vertical ? Size(width: 1, height: p.height ?? 0) : Size(width: p.width ?? 0, height: 1)
    }
    override func draw(_ list: inout DisplayList) { if list.isVisible(frame) { list.fill(frame, color) } }
}

// MARK: Images

/// How a view scales to fit a proposed size (SwiftUI's `ContentMode`).
public enum ContentMode: Hashable, Sendable { case fit, fill }

/// A raster image view (SwiftUI's `Image`). Draws at its own pixel size in
/// points unless `.resizable()` is called.
public struct Image: View, PrimitiveView {
    let image: RenderImage
    var isResizable = false
    var filter: ImageFilter = .bilinear

    public init(_ image: RenderImage) { self.image = image }
    public init(_ bitmap: Bitmap) { self.image = RenderImage(bitmap) }

    public func resizable() -> Image {
        var copy = self; copy.isResizable = true; return copy
    }

    public func interpolation(_ filter: ImageFilter) -> Image {
        var copy = self; copy.filter = filter; return copy
    }

    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? ImageNode) ?? ImageNode()
        n.image = image; n.isResizable = isResizable; n.filter = filter
        return n
    }
}

final class ImageNode: Node {
    var image: RenderImage?
    var isResizable = false
    var filter: ImageFilter = .bilinear

    override var role: String { "Image" }
    override var detail: String {
        guard let image else { return "" }
        return "\(image.width)x\(image.height)"
    }
    override var isHitTarget: Bool { image != nil }

    override func sizeThatFits(_ p: ProposedViewSize) -> Size {
        guard let image else { return .zero }
        if !isResizable { return image.size }
        return p.replacingUnspecified(image.size)
    }

    override func draw(_ list: inout DisplayList) {
        guard let image, list.isVisible(frame) else { return }
        list.drawImage(image, in: frame, opacity: 1, filter: filter)
    }
}

// MARK: Shapes and dark glass

/// A rectangle with rounded corners filled with the foreground colour.
public struct RoundedRectangle: View, PrimitiveView {
    let cornerRadius: Double
    public init(cornerRadius: Double) { self.cornerRadius = cornerRadius }

    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? ShapeNode) ?? ShapeNode()
        n.kind = .roundedRect(cornerRadius)
        n.color = c.environment.foregroundColor
        return n
    }
}

/// A circle fitting the smaller side of the offered size, filled with the foreground colour.
public struct Circle: View, PrimitiveView {
    public init() {}
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? ShapeNode) ?? ShapeNode()
        n.kind = .circle
        n.color = c.environment.foregroundColor
        return n
    }
}

/// A pill shape (corner radius half the shorter side), filled with the foreground colour.
public struct Capsule: View, PrimitiveView {
    public init() {}
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? ShapeNode) ?? ShapeNode()
        n.kind = .capsule
        n.color = c.environment.foregroundColor
        return n
    }
}

extension Path: View, PrimitiveView {
    public var body: Never { fatalError("Path is a built-in view") }
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? ShapeNode) ?? ShapeNode()
        n.kind = .path(self)
        n.color = c.environment.foregroundColor
        return n
    }
}

final class ShapeNode: Node {
    enum Kind { case roundedRect(Double), circle, capsule, path(Path) }
    var kind: Kind = .circle
    var color: Color = .clear

    override var role: String {
        switch kind {
        case .roundedRect: "RoundedRectangle"
        case .circle: "Circle"
        case .capsule: "Capsule"
        case .path: "Path"
        }
    }
    override var detail: String { color.description }
    override var isHitTarget: Bool { color.opacity > 0 }

    override func sizeThatFits(_ p: ProposedViewSize) -> Size {
        switch kind {
        case .circle:
            let w = p.width ?? 10, h = p.height ?? 10
            let side = min(w, h)
            return Size(width: side, height: side)
        case .roundedRect, .capsule, .path:
            return p.replacingUnspecified(Size(width: 10, height: 10))
        }
    }

    override func draw(_ list: inout DisplayList) {
        guard list.isVisible(frame) else { return }
        switch kind {
        case .roundedRect(let r):
            list.fill(Path(roundedRect: frame, cornerRadius: r), color)
        case .circle:
            let side = min(frame.width, frame.height)
            let rect = Rect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side)
            list.fill(Path(ellipseIn: rect), color)
        case .capsule:
            list.fill(Path(roundedRect: frame, cornerRadius: min(frame.width, frame.height) / 2), color)
        case .path(let p):
            list.fill(p.applying(.translation(x: frame.minX, y: frame.minY)), color)
        }
    }
}

/// Blurs whatever was drawn behind it inside its frame (the building block of dark glass).
public struct BackdropBlur: View, PrimitiveView {
    let radius: Double
    public init(radius: Double) { self.radius = radius }

    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? BackdropBlurNode) ?? BackdropBlurNode()
        n.radius = radius
        return n
    }
}

final class BackdropBlurNode: Node {
    var radius: Double = 0
    override var role: String { "BackdropBlur" }
    override var detail: String { "r=\(radius)" }
    override func sizeThatFits(_ p: ProposedViewSize) -> Size { p.replacingUnspecified(Size(width: 10, height: 10)) }
    override func draw(_ list: inout DisplayList) {
        guard radius > 0, list.isVisible(frame) else { return }
        list.backdropBlur(frame, radius: radius)
    }
}
