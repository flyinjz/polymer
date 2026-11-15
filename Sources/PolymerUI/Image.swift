// Images: `Image` with SwiftUI's sizing (`resizable`), and the
// `aspectRatio` modifier with `scaledToFit` and `scaledToFill`.
import PolymerBase
import PolymerRender

/// A bitmap. Shown at its own size (pixels divided by `scale`, in points)
/// unless made `resizable()`, when it stretches to the size it is offered.
/// Decode files with `PNG.decode` or `JPEG.decode`.
public struct Image: View, PrimitiveView {
    let bitmap: Bitmap
    let scale: Double
    var isResizable = false

    /// `scale` is the image's pixels per point: 2 for an image made for 2x screens.
    public init(_ bitmap: Bitmap, scale: Double = 1) {
        self.bitmap = bitmap
        self.scale = scale > 0 ? scale : 1
    }

    /// Stretches the image to the size it is offered. Combine with
    /// `aspectRatio(contentMode:)`, `scaledToFit()` or `scaledToFill()` to keep its shape.
    public func resizable() -> Image {
        var i = self
        i.isResizable = true
        return i
    }

    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? ImageNode) ?? ImageNode()
        n.update(bitmap, scale: scale, resizable: isResizable)
        return n
    }
}

final class ImageNode: Node {
    private(set) var image: RasterImage?
    private var imageScale = 1.0
    private var resizable = false

    func update(_ bitmap: Bitmap, scale: Double, resizable: Bool) {
        // Equal bitmaps sharing storage compare in constant time; a new bitmap starts a new image (and its scaled copies).
        if image?.bitmap != bitmap { image = RasterImage(bitmap) }
        imageScale = scale
        self.resizable = resizable
    }

    override var role: String { "Image" }
    override var detail: String { image.map { "\($0.bitmap.width)x\($0.bitmap.height) px" } ?? "" }
    override var isHitTarget: Bool { true }

    /// The image's own size in points.
    var naturalSize: Size {
        guard let b = image?.bitmap else { return .zero }
        return Size(width: Double(b.width) / imageScale, height: Double(b.height) / imageScale)
    }

    override func sizeThatFits(_ p: ProposedViewSize) -> Size {
        let n = naturalSize
        guard resizable else { return n }
        let w = p.width.flatMap { $0.isFinite ? $0 : nil } ?? n.width
        let h = p.height.flatMap { $0.isFinite ? $0 : nil } ?? n.height
        return Size(width: w, height: h)
    }

    override func drawContent(_ list: inout DisplayList) {
        guard let image, list.isVisible(frame) else { return }
        list.draw(image, in: frame)
    }
}

/// How `aspectRatio` fits a shape into the size offered.
public enum ContentMode: Hashable, Sendable {
    /// The largest size of that shape inside the offer.
    case fit
    /// The smallest size of that shape covering the offer (it may stick out; `.clipped()` hides that).
    case fill
}

extension View {
    /// Offers the view a size of `ratio` (width / height) that fits or fills
    /// what this view is offered. With no ratio, the view's own ideal shape.
    public func aspectRatio(_ ratio: Double? = nil, contentMode: ContentMode) -> some View {
        AspectRatioView(content: self, ratio: ratio, mode: contentMode)
    }
    public func scaledToFit() -> some View { aspectRatio(contentMode: .fit) }
    public func scaledToFill() -> some View { aspectRatio(contentMode: .fill) }
}

struct AspectRatioView<Content: View>: View, PrimitiveView {
    let content: Content, ratio: Double?, mode: ContentMode
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? AspectRatioNode) ?? AspectRatioNode()
        n.ratio = ratio; n.mode = mode
        n.setChild(0, content, c)
        return n
    }
}

final class AspectRatioNode: Node {
    var ratio: Double?, mode = ContentMode.fit
    override var isElement: Bool { false }

    /// The size offered to the content for a proposal.
    func target(_ p: ProposedViewSize) -> ProposedViewSize {
        let ideal = children[0].measure(.unspecified)
        let r = ratio ?? (ideal.height > 0 ? ideal.width / ideal.height : 1)
        guard r > 0, r.isFinite else { return p }
        let w = p.width.flatMap { $0.isFinite ? $0 : nil }, h = p.height.flatMap { $0.isFinite ? $0 : nil }
        switch (w, h) {
        case (nil, nil): return ProposedViewSize(width: ideal.width, height: ideal.width / r)
        case (let w?, nil): return ProposedViewSize(width: w, height: w / r)
        case (nil, let h?): return ProposedViewSize(width: h * r, height: h)
        case (let w?, let h?):
            let wider = w / max(h, 1e-9) > r
            switch mode {
            case .fit: return wider ? ProposedViewSize(width: h * r, height: h) : ProposedViewSize(width: w, height: w / r)
            case .fill: return wider ? ProposedViewSize(width: w, height: w / r) : ProposedViewSize(width: h * r, height: h)
            }
        }
    }

    override func sizeThatFits(_ p: ProposedViewSize) -> Size { children[0].measure(target(p)) }
    override func placeChildren(in r: Rect) { children[0].place(r) }
}
