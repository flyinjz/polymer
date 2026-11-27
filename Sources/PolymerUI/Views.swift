// Built-in leaf views: Text, Color, Spacer, Divider. Shapes are in Shapes.swift.
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
    private var animatedColor = Animated(ColorVector(Color.white))
    /// The text colour set by the view (the target while it animates).
    var color: Color {
        get { animatedColor.target.color }
        set { change(&animatedColor, to: ColorVector(newValue)) }
    }
    override func isAnimating(at now: Double) -> Bool { super.isAnimating(at: now) || animatedColor.isRunning(at: now) }
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
    // Escaped, so one element is always one line of the element tree.
    override var detail: String { "\"\(string.escapedForElementTree)\"" }
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

    override func drawContent(_ list: inout DisplayList) {
        // While the frame animates, the text keeps its final lines and size and moves with the frame's centre.
        let shown = frame, laid = layoutFrame
        let frame = Rect(x: shown.midX - laid.width / 2, y: shown.midY - laid.height / 2, width: laid.width, height: laid.height)
        guard let font, list.isVisible(frame) else { return }
        let ls = lines(font, width: frame.width, height: frame.height)
        let shownColor = animatedColor.value(at: tree?.now ?? 0).color
        let lh = lineHeight(font)
        let top = frame.minY + (frame.height - lh * Double(ls.count)) / 2 + (lh - font.lineHeight) / 2 + font.ascent
        for (i, line) in ls.enumerated() {
            // Baselines and line starts sit on whole pixels; glyphs keep their exact positions within the line.
            let baseline = ((top + Double(i) * lh) * scale).rounded() / scale
            let slack = max(0, frame.width - line.width)
            let dx: Double = switch alignment { case .leading: 0; case .center: slack / 2; case .trailing: slack }
            let x = ((frame.minX + dx) * scale).rounded() / scale
            list.drawGlyphs(line.glyphs, font: font.face, size: font.size, at: Point(x: x, y: baseline),
                              color: shownColor, options: options)
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

final class FillNode: Node {
    private var animatedColor = Animated(ColorVector(Color.clear))
    /// The colour set by the view (the target while it animates).
    var color: Color {
        get { animatedColor.target.color }
        set { change(&animatedColor, to: ColorVector(newValue)) }
    }
    override func isAnimating(at now: Double) -> Bool { super.isAnimating(at: now) || animatedColor.isRunning(at: now) }
    var name = "Color"
    override var role: String { name }
    override var detail: String { color.description }
    override var isHitTarget: Bool { color.opacity > 0 }
    override func sizeThatFits(_ p: ProposedViewSize) -> Size {
        // SwiftUI shapes take 10 points when given no size.
        p.replacingUnspecified(Size(width: 10, height: 10))
    }
    override func drawContent(_ list: inout DisplayList) {
        if list.isVisible(frame) { list.fill(frame, animatedColor.value(at: tree?.now ?? 0).color) }
    }
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
    override func drawContent(_ list: inout DisplayList) { if list.isVisible(frame) { list.fill(frame, color) } }
}

extension String {
    /// The text as it sits inside the element tree's quotes: line breaks and
    /// quotes are escaped, so a multi-line `Text` stays one line and nothing
    /// in it can be read as another element.
    var escapedForElementTree: String {
        var out = ""
        out.reserveCapacity(count)
        for c in self {
            switch c {
            case "\r\n", "\n", "\r": out += "\\n"
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            default: out.append(c)
            }
        }
        return out
    }
}
