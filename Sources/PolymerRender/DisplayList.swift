// The display list: what a frame draws, recorded instead of drawn. Views
// record into one each frame; a renderer (the CPU `Canvas` today, the GPU
// later) draws it. Comparing a frame's list with the last one gives the
// damage: the pixels that can differ, so a frame redraws only those.
import PolymerBase
import PolymerText

/// One drawing operation, with the clip and origin in force when it was recorded.
public struct DisplayItem: Hashable {
    public enum Operation: Hashable {
        /// A rectangle in points, filled with partial coverage at its edges.
        case rect(Rect, Color)
        /// A path in points (non-zero winding, anti-aliased).
        case path(Path, Color)
        case glyphs(GlyphRun)
        /// An image stretched to a rectangle in points (corners rounded to whole pixels).
        case image(RasterImage, Rect)
        /// A backdrop effect inside a rounded rectangle in points (DESIGN section 11).
        case backdrop(BackdropShape, BackdropEffect)
        /// The items up to the matching `endLayer` are drawn apart, then composited with the effect.
        case beginLayer(LayerEffect)
        case endLayer
    }
    public var operation: Operation
    /// Added to every position, in points (`Canvas.origin`).
    public var origin: Point
    /// Pixels the operation may draw into.
    public var clip: PixelRect
    /// Pixels the operation may change: its extent inside the clip, never empty.
    public var bounds: PixelRect
    /// For backdrop effects and blurred layers: how many pixels around a point
    /// the effect reads (0 for everything else).
    public var reach: Int = 0
}

/// What a layer does to its content when compositing it: opacity, a shape
/// that clips it (anti-aliased), and blur.
public struct LayerEffect: Hashable, Sendable {
    public var opacity: Double
    /// Clips the content, in points (in the coordinates the layer was recorded in).
    public var mask: RoundedRect?
    /// Gaussian blur of the content, radius in points.
    public var blur: Double

    public init(opacity: Double = 1, mask: RoundedRect? = nil, blur: Double = 0) {
        self.opacity = opacity; self.mask = mask; self.blur = blur
    }

    /// True when the layer would change nothing.
    public var isIdentity: Bool { opacity >= 1 && mask == nil && blur <= 0 }
}

/// Laid-out glyphs with the line's baseline-left at `position` (points).
public struct GlyphRun: Hashable, Sendable {
    public var glyphs: [PositionedGlyph]
    public var font: FontFace
    /// Points per em.
    public var size: Double
    public var position: Point
    public var color: Color
    public var options: TextRenderingOptions

    public static func == (a: GlyphRun, b: GlyphRun) -> Bool {
        a.font === b.font && a.size == b.size && a.position == b.position && a.color == b.color
            && a.options == b.options && a.glyphs == b.glyphs
    }
    public func hash(into h: inout Hasher) {
        h.combine(ObjectIdentifier(font)); h.combine(size); h.combine(position); h.combine(color)
        h.combine(glyphs.count); h.combine(glyphs.first?.glyph)
    }
}

/// Drawing operations in order, recorded with the same calls as `Canvas`
/// (`fill`, `drawGlyphs`, `clipped`, `translated`, `isVisible`) and drawn
/// with `Canvas.draw(_:in:)`. Operations that would draw nothing are left out.
public struct DisplayList {
    /// Size in pixels.
    public let width: Int
    public let height: Int
    /// Pixels per point.
    public let scale: Double
    public private(set) var items: [DisplayItem] = []
    /// Recording is limited to this pixel rectangle.
    public private(set) var clip: PixelRect
    /// Added to every position recorded, in points.
    public private(set) var origin: Point = .zero

    public init(width: Int, height: Int, scale: Double = 1) {
        self.width = width; self.height = height; self.scale = scale
        clip = PixelRect(x: 0, y: 0, width: width, height: height)
    }

    /// The whole image.
    public var fullRect: PixelRect { PixelRect(x: 0, y: 0, width: width, height: height) }

    /// Empties the list for the next frame, keeping its storage.
    public mutating func removeAll() {
        items.removeAll(keepingCapacity: true)
        clip = fullRect
        origin = .zero
    }

    // MARK: Recording

    /// Runs `body` with recording limited to `rect` (points, rounded outward
    /// to whole pixels) inside the current clip.
    public mutating func clipped(to rect: Rect, _ body: (inout DisplayList) -> Void) {
        let saved = clip
        clip = PixelRect.covering(rect, origin: origin, scale: scale).clamped(to: clip)
        body(&self)
        clip = saved
    }

    /// Runs `body` with everything it records moved by `offset` (points).
    public mutating func translated(by offset: Point, _ body: (inout DisplayList) -> Void) {
        let saved = origin
        origin = origin + offset
        body(&self)
        origin = saved
    }

    /// False when `rect` (points) lies entirely outside the clip, so recording it would add nothing.
    public func isVisible(_ rect: Rect) -> Bool {
        let x0 = (rect.minX + origin.x) * scale, y0 = (rect.minY + origin.y) * scale
        let x1 = (rect.maxX + origin.x) * scale, y1 = (rect.maxY + origin.y) * scale
        return x1 > Double(clip.x) && x0 < Double(clip.x + clip.width) && y1 > Double(clip.y) && y0 < Double(clip.y + clip.height)
    }

    /// Fills a rectangle given in points.
    public mutating func fill(_ rect: Rect, _ color: Color) {
        guard color.opacity > 0 else { return }
        add(.rect(rect, color), PixelRect.covering(rect, origin: origin, scale: scale))
    }

    /// Fills a path given in points.
    public mutating func fill(_ path: Path, _ color: Color) {
        guard color.opacity > 0, !path.isEmpty else { return }
        add(.path(path, color), PixelRect.covering(path.controlBounds, origin: origin, scale: scale).outset(by: 1))
    }

    /// Records laid-out glyphs with the line's baseline-left at `position` (points).
    public mutating func drawGlyphs(_ glyphs: [PositionedGlyph], font: FontFace, size: Double, at position: Point,
                                    color: Color, options: TextRenderingOptions = .standard) {
        guard color.opacity > 0, let first = glyphs.first, let last = glyphs.last else { return }
        // Every glyph lies inside the font's glyph box at its position; 2 pixels
        // more cover stem darkening and coverage at the box's edge.
        // A font without a glyph box gets a generous one.
        let k = size / Double(font.unitsPerEm), b = font.glyphBounds
        let boxless = b.yMax <= b.yMin || b.xMax <= b.xMin
        let ascent = boxless ? size * 2 : Double(b.yMax) * k, descent = boxless ? size : max(0, -Double(b.yMin) * k)
        let left = boxless ? -size : min(0, Double(b.xMin) * k)
        let right = boxless ? last.advance + size : max(last.advance, Double(b.xMax) * k)
        let minX = min(first.x, last.x), maxX = max(first.x, last.x)   // positions run in order along the line
        let box = Rect(x: position.x + minX + left, y: position.y - ascent,
                       width: maxX - minX + right - left, height: ascent + descent)
        let run = GlyphRun(glyphs: glyphs, font: font, size: size, position: position, color: color, options: options)
        add(.glyphs(run), PixelRect.covering(box, origin: origin, scale: scale).outset(by: 2))
    }

    /// Records an image stretched to `rect` (points).
    public mutating func draw(_ image: RasterImage, in rect: Rect) {
        add(.image(image, rect), PixelRect.snapping(rect, origin: origin, scale: scale))
    }

    /// Records `body` as a layer over `area` (points): drawn apart, then
    /// composited with `effect`. Content outside `area` (plus the blur's
    /// spread) is cut off. Nothing is recorded when the area is out of view.
    public mutating func layer(_ effect: LayerEffect, area: Rect, _ body: (inout DisplayList) -> Void) {
        if effect.isIdentity { body(&self); return }
        if effect.opacity <= 0 { return }
        let spread = 3 * effect.blur
        let grown = Rect(x: area.minX - spread, y: area.minY - spread, width: area.width + 2 * spread, height: area.height + 2 * spread)
        let bounds = PixelRect.covering(grown, origin: origin, scale: scale).clamped(to: clip)
        guard !bounds.isEmpty else { return }
        let reach = effect.blur > 0 ? Int((3 * effect.blur * scale).rounded(.up)) + 1 : 0
        items.append(DisplayItem(operation: .beginLayer(effect), origin: origin, clip: clip, bounds: bounds, reach: reach))
        let saved = clip
        clip = bounds
        body(&self)
        clip = saved
        items.append(DisplayItem(operation: .endLayer, origin: origin, clip: clip, bounds: bounds))
    }

    /// Records a backdrop effect inside `shape` (points): it filters what was recorded before it.
    public mutating func drawBackdrop(_ shape: RoundedRect, _ effect: BackdropEffect) { drawBackdrop(.single(shape), effect) }

    /// Records a backdrop effect inside a shape that may be several merged into one.
    public mutating func drawBackdrop(_ shape: BackdropShape, _ effect: BackdropEffect) {
        let b = shape.bounds
        guard b.width > 0, b.height > 0 else { return }
        add(.backdrop(shape, effect), PixelRect.covering(b, origin: origin, scale: scale), reach: effect.reach(scale: scale))
    }

    private mutating func add(_ op: DisplayItem.Operation, _ extent: PixelRect, reach: Int = 0) {
        let bounds = extent.clamped(to: clip)
        guard !bounds.isEmpty else { return }
        items.append(DisplayItem(operation: op, origin: origin, clip: clip, bounds: bounds, reach: reach))
    }

    // MARK: Damage

    /// The pixels that can differ between drawing `old` and drawing this
    /// list, as a few rectangles (empty when nothing changed).
    ///
    /// Items found in both lists, in the same order, draw the same pixels;
    /// every other item, added, removed or moved past another, damages its
    /// bounds. A pixel outside the damage is therefore covered by the same
    /// items in the same order in both frames.
    public func damage(since old: DisplayList) -> [PixelRect] {
        guard old.width == width, old.height == height, old.scale == scale else { return [fullRect] }
        let a = old.items, b = items
        var start = 0
        while start < a.count, start < b.count, a[start] == b[start] { start += 1 }
        var endA = a.count, endB = b.count
        while endA > start, endB > start, a[endA - 1] == b[endB - 1] { endA -= 1; endB -= 1 }
        if start == endA, start == endB { return [] }

        var rects: [PixelRect] = []
        // New items by value, with the next unmatched place of each.
        var places: [DisplayItem: (indices: [Int], next: Int)] = [:]
        for j in start..<endB { places[b[j], default: ([], 0)].indices.append(j) }
        var matched = [Bool](repeating: false, count: endB - start)
        var last = start - 1
        for i in start..<endA {
            if var p = places[a[i]] {
                while p.next < p.indices.count, p.indices[p.next] <= last { p.next += 1 }
                if p.next < p.indices.count {
                    let j = p.indices[p.next]
                    p.next += 1
                    places[a[i]] = p
                    matched[j - start] = true
                    last = j
                    continue
                }
                places[a[i]] = p
            }
            rects.append(a[i].bounds)
        }
        for j in start..<endB where !matched[j - start] { rects.append(b[j].bounds) }
        return PixelRect.merged(Self.spreadThroughEffects(rects, a, b), within: fullRect)
    }

    /// A backdrop effect redraws wherever its input changed: each damaged
    /// rectangle within an effect's reach damages the effect's pixels within
    /// reach of it. Repeated, because effects can sit on effects.
    static func spreadThroughEffects(_ damage: [PixelRect], _ old: [DisplayItem], _ new: [DisplayItem]) -> [PixelRect] {
        let effects = (old + new).filter { $0.reach > 0 }
        guard !effects.isEmpty, !damage.isEmpty else { return damage }
        var rects = damage
        for _ in 0..<8 {
            var added = false
            for e in effects {
                let reachArea = e.bounds.outset(by: e.reach)
                for d in rects where d.intersects(reachArea) {
                    let more = d.outset(by: e.reach).clamped(to: e.bounds)
                    if more.isEmpty || rects.contains(where: { $0.contains(more) }) { continue }
                    rects.append(more)
                    added = true
                }
            }
            if !added { break }
        }
        return rects
    }
}

extension PixelRect {
    /// `rect` (points) moved by `origin`, in pixels, rounded outward.
    static func covering(_ rect: Rect, origin: Point, scale: Double) -> PixelRect {
        let x0 = Int(((rect.minX + origin.x) * scale).rounded(.down)), y0 = Int(((rect.minY + origin.y) * scale).rounded(.down))
        let x1 = Int(((rect.maxX + origin.x) * scale).rounded(.up)), y1 = Int(((rect.maxY + origin.y) * scale).rounded(.up))
        return PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// `rect` (points) moved by `origin`, in pixels, each corner rounded to the nearest pixel.
    static func snapping(_ rect: Rect, origin: Point, scale: Double) -> PixelRect {
        let x0 = Int(((rect.minX + origin.x) * scale).rounded()), y0 = Int(((rect.minY + origin.y) * scale).rounded())
        let x1 = Int(((rect.maxX + origin.x) * scale).rounded()), y1 = Int(((rect.maxY + origin.y) * scale).rounded())
        return PixelRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    /// The part inside `r`, with the same arithmetic as `Canvas.clipped`.
    func clamped(to r: PixelRect) -> PixelRect {
        let x0 = max(r.x, x), y0 = max(r.y, y)
        let x1 = min(r.x + r.width, x + width), y1 = min(r.y + r.height, y + height)
        return PixelRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    func outset(by n: Int) -> PixelRect { PixelRect(x: x - n, y: y - n, width: width + 2 * n, height: height + 2 * n) }

    func union(_ r: PixelRect) -> PixelRect {
        let x0 = min(x, r.x), y0 = min(y, r.y)
        return PixelRect(x: x0, y: y0, width: max(x + width, r.x + r.width) - x0, height: max(y + height, r.y + r.height) - y0)
    }

    /// True when the two overlap or touch.
    func touches(_ r: PixelRect) -> Bool {
        x <= r.x + r.width && r.x <= x + width && y <= r.y + r.height && r.y <= y + height
    }

    func intersects(_ r: PixelRect) -> Bool {
        x < r.x + r.width && r.x < x + width && y < r.y + r.height && r.y < y + height
    }

    var area: Int { width * height }

    /// True when `r` lies entirely inside.
    func contains(_ r: PixelRect) -> Bool {
        r.x >= x && r.y >= y && r.x + r.width <= x + width && r.y + r.height <= y + height
    }

    /// Few rectangles covering `rects`: touching ones are joined, and past
    /// eight the two whose union adds the least area are joined, so a frame
    /// draws each pixel once and the renderer has little to set up.
    static func merged(_ rects: [PixelRect], within bounds: PixelRect) -> [PixelRect] {
        var out: [PixelRect] = []
        for r in rects {
            var r = r.clamped(to: bounds)
            if r.isEmpty { continue }
            // Join with every rectangle it touches, repeatedly (a join can reach others).
            var i = 0
            while i < out.count {
                if out[i].touches(r) { r = r.union(out.remove(at: i)); i = 0 } else { i += 1 }
            }
            out.append(r)
        }
        while out.count > 8 {
            var best = (0, 1, Int.max)
            for i in 0..<out.count {
                for j in (i + 1)..<out.count {
                    let extra = out[i].union(out[j]).area - out[i].area - out[j].area
                    if extra < best.2 { best = (i, j, extra) }
                }
            }
            let u = out[best.0].union(out[best.1])
            out.remove(at: best.1); out.remove(at: best.0)
            // The union may now touch others.
            out = merged(out + [u], within: bounds)
        }
        return out.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
    }
}
