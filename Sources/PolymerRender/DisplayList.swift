// The display list: what a frame draws, recorded instead of drawn. Views
// record into one each frame; a renderer (the CPU `Canvas` today, the GPU
// later) draws it. Comparing a frame's list with the last one gives the
// damage: the pixels that can differ, so a frame redraws only those.
import PolymerBase
import PolymerText

/// One drawing operation, with the clip and origin in force when it was recorded.
public struct DisplayItem: Hashable, Sendable {
    public enum Operation: Hashable, Sendable {
        /// A rectangle in points, filled with partial coverage at its edges.
        case rect(Rect, Color)
        /// A path in points (non-zero winding, anti-aliased).
        case path(Path, Color)
        case glyphs(GlyphRun)
        /// An image drawn into a rectangle in points.
        case image(RenderImage, Rect, Double, ImageFilter)
        /// Blurs whatever was already drawn inside the rectangle (points).
        case backdropBlur(Rect, Double)
    }
    public var operation: Operation
    /// Added to every position, in points (`Canvas.origin`).
    public var origin: Point
    /// Pixels the operation may draw into.
    public var clip: PixelRect
    /// Pixels the operation may change: its extent inside the clip, never empty.
    public var bounds: PixelRect
}

/// A scroll view recorded in a display list, so the next frame can move the
/// surviving pixels instead of redrawing the whole viewport.
public struct ScrollHint: Equatable, Sendable {
    public var clip: PixelRect
    public var offset: Point
    public var startIndex: Int
    public var endIndex: Int
    public init(clip: PixelRect, offset: Point, startIndex: Int, endIndex: Int) {
        self.clip = clip; self.offset = offset; self.startIndex = startIndex; self.endIndex = endIndex
    }
}

/// A pixel-aligned copy inside the kept canvas (`rect` shifted by `dx, dy` pixels).
public struct ScrollBlit: Equatable, Sendable {
    public var rect: PixelRect
    public var dx: Int
    public var dy: Int
    public init(rect: PixelRect, dx: Int, dy: Int) { self.rect = rect; self.dx = dx; self.dy = dy }
}

/// How to update the kept canvas from the previous frame: apply `blits` first,
/// then clear and redraw each rectangle in `damage`.
public struct DamagePlan: Equatable, Sendable {
    public var blits: [ScrollBlit]
    public var damage: [PixelRect]
    public init(blits: [ScrollBlit], damage: [PixelRect]) { self.blits = blits; self.damage = damage }
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
public struct DisplayList: Sendable {
    /// Size in pixels.
    public let width: Int
    public let height: Int
    /// Pixels per point.
    public let scale: Double
    public private(set) var items: [DisplayItem] = []
    /// Scroll views recorded during this frame, in drawing order.
    public private(set) var scrollHints: [ScrollHint] = []
    /// Recording is limited to this pixel rectangle.
    public private(set) var clip: PixelRect
    /// Added to every position recorded, in points.
    public private(set) var origin: Point = .zero
    /// Multiplier applied to every colour and image recorded (0...1).
    public private(set) var opacity: Double = 1.0

    public init(width: Int, height: Int, scale: Double = 1) {
        self.width = width; self.height = height; self.scale = scale
        clip = PixelRect(x: 0, y: 0, width: width, height: height)
    }

    /// The whole image.
    public var fullRect: PixelRect { PixelRect(x: 0, y: 0, width: width, height: height) }

    /// Empties the list for the next frame, keeping its storage.
    public mutating func removeAll() {
        items.removeAll(keepingCapacity: true)
        scrollHints.removeAll(keepingCapacity: true)
        clip = fullRect
        origin = .zero
        opacity = 1.0
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

    /// Runs `body` with the opacity of everything it records multiplied by `factor` (0...1).
    public mutating func withOpacity(_ factor: Double, _ body: (inout DisplayList) -> Void) {
        let clamped = min(max(factor, 0), 1)
        guard clamped > 0 else { return }
        let saved = opacity
        opacity *= clamped
        body(&self)
        opacity = saved
    }

    /// Records a scroll viewport: clips to `rect`, translates by `-offset`,
    /// and records a scroll hint so the next frame can blit surviving pixels.
    public mutating func scrolled(in rect: Rect, offset: Point, _ body: (inout DisplayList) -> Void) {
        let savedClip = clip, savedOrigin = origin
        let innerClip = PixelRect.covering(rect, origin: origin, scale: scale).clamped(to: clip)
        let start = items.count
        clip = innerClip
        origin = origin + Point(x: -offset.x, y: -offset.y)
        body(&self)
        let end = items.count
        clip = savedClip
        origin = savedOrigin
        if !innerClip.isEmpty {
            scrollHints.append(ScrollHint(clip: innerClip, offset: offset, startIndex: start, endIndex: end))
        }
    }

    /// False when `rect` (points) lies entirely outside the clip, so recording it would add nothing.
    public func isVisible(_ rect: Rect) -> Bool {
        let x0 = (rect.minX + origin.x) * scale, y0 = (rect.minY + origin.y) * scale
        let x1 = (rect.maxX + origin.x) * scale, y1 = (rect.maxY + origin.y) * scale
        return x1 > Double(clip.x) && x0 < Double(clip.x + clip.width) && y1 > Double(clip.y) && y0 < Double(clip.y + clip.height)
    }

    /// Fills a rectangle given in points.
    public mutating func fill(_ rect: Rect, _ color: Color) {
        let c = opacity < 1 ? color.opacity(opacity) : color
        guard c.opacity > 0 else { return }
        add(.rect(rect, c), PixelRect.covering(rect, origin: origin, scale: scale))
    }

    /// Fills a path given in points.
    public mutating func fill(_ path: Path, _ color: Color) {
        let c = opacity < 1 ? color.opacity(opacity) : color
        guard c.opacity > 0, !path.isEmpty else { return }
        add(.path(path, c), PixelRect.covering(path.controlBounds, origin: origin, scale: scale).outset(by: 1))
    }

    /// Records an image drawn into `rect` (points).
    public mutating func drawImage(_ image: RenderImage, in rect: Rect, opacity imageOpacity: Double = 1, filter: ImageFilter = .bilinear) {
        let effective = min(max(imageOpacity, 0), 1) * opacity
        guard effective > 0, image.width > 0, image.height > 0, !rect.isEmpty else { return }
        add(.image(image, rect, effective, filter), PixelRect.covering(rect, origin: origin, scale: scale))
    }

    /// Records a backdrop blur over `rect` (points) with standard deviation `radius` points.
    public mutating func backdropBlur(_ rect: Rect, radius: Double) {
        guard radius > 0, opacity > 0, !rect.isEmpty else { return }
        add(.backdropBlur(rect, radius), PixelRect.covering(rect, origin: origin, scale: scale))
    }

    /// Records laid-out glyphs with the line's baseline-left at `position` (points).
    public mutating func drawGlyphs(_ glyphs: [PositionedGlyph], font: FontFace, size: Double, at position: Point,
                                    color: Color, options: TextRenderingOptions = .standard) {
        let c = opacity < 1 ? color.opacity(opacity) : color
        guard c.opacity > 0, let first = glyphs.first, let last = glyphs.last else { return }
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
        let run = GlyphRun(glyphs: glyphs, font: font, size: size, position: position, color: c, options: options)
        add(.glyphs(run), PixelRect.covering(box, origin: origin, scale: scale).outset(by: 2))
    }

    private mutating func add(_ op: DisplayItem.Operation, _ extent: PixelRect) {
        let bounds = extent.clamped(to: clip)
        guard !bounds.isEmpty else { return }
        items.append(DisplayItem(operation: op, origin: origin, clip: clip, bounds: bounds))
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
        return expandForBackdropBlurs(PixelRect.merged(rects, within: fullRect))
    }

    /// Expands damage to cover any backdropBlur it touches so pre-blur pixels
    /// are freshly drawn before the blur runs (avoids double-blur seams).
    private func expandForBackdropBlurs(_ initial: [PixelRect]) -> [PixelRect] {
        guard !initial.isEmpty else { return [] }
        var out = initial
        var grew = true
        while grew {
            grew = false
            for item in items {
                guard case .backdropBlur = item.operation else { continue }
                if out.contains(where: { $0.intersects(item.bounds) }) && !out.contains(where: { $0.contains(item.bounds) }) {
                    out = PixelRect.merged(out + [item.bounds], within: fullRect)
                    grew = true
                }
            }
        }
        return out
    }

    /// Computes scroll blits (in-place pixel copies for scrolled viewports) and
    /// the remaining damage rectangles. Applying `blits` then clearing and
    /// redrawing `damage` produces pixels identical to drawing the whole list.
    public func damagePlan(since old: DisplayList) -> DamagePlan {
        guard old.width == width, old.height == height, old.scale == scale else {
            return DamagePlan(blits: [], damage: [fullRect])
        }
        guard !scrollHints.isEmpty, old.scrollHints.count == scrollHints.count else {
            return DamagePlan(blits: [], damage: damage(since: old))
        }

        // Candidate hints: same non-empty clip, whole-pixel shift smaller than clip,
        // no overlapping hints, no backdrop blur, translation-invariant backdrop, no overlays.
        struct Candidate {
            var oldHint: ScrollHint
            var newHint: ScrollHint
            var dx: Int
            var dy: Int
        }
        var candidates: [Candidate] = []
        for idx in 0..<scrollHints.count {
            let oldH = old.scrollHints[idx], newH = scrollHints[idx]
            guard oldH.clip == newH.clip, !newH.clip.isEmpty, oldH.offset != newH.offset else { continue }
            let clip = newH.clip
            let ddx = (oldH.offset.x - newH.offset.x) * scale
            let ddy = (oldH.offset.y - newH.offset.y) * scale
            guard abs(ddx - ddx.rounded()) < 1e-6, abs(ddy - ddy.rounded()) < 1e-6 else { continue }
            let dx = Int(ddx.rounded()), dy = Int(ddy.rounded())
            guard (dx != 0 || dy != 0), abs(dx) < clip.width, abs(dy) < clip.height else { continue }
            // Disjoint from other scroll hints (no nested/overlapping scroll blits).
            let overlapsOther = scrollHints.enumerated().contains { $0.offset != idx && $0.element.clip.intersects(clip) }
            if overlapsOther { continue }
            // No backdrop blur intersecting this clip in either frame.
            if old.items.contains(where: { if case .backdropBlur = $0.operation { return $0.bounds.intersects(clip) }; return false }) { continue }
            if items.contains(where: { if case .backdropBlur = $0.operation { return $0.bounds.intersects(clip) }; return false }) { continue }
            // Nothing drawn over this clip after the scroll view in either frame.
            if old.items[oldH.endIndex...].contains(where: { $0.bounds.intersects(clip) }) { continue }
            if items[newH.endIndex...].contains(where: { $0.bounds.intersects(clip) }) { continue }
            // Background items behind the scroll view must be uniform rects covering the whole clip and unchanged.
            func uniformBackdrop(_ list: DisplayList, end: Int) -> [DisplayItem]? {
                var bg: [DisplayItem] = []
                for item in list.items[0..<end] where item.bounds.intersects(clip) {
                    guard case .rect(let r, _) = item.operation,
                          (r.minX + item.origin.x) * scale <= Double(clip.x) + 1e-9,
                          (r.minY + item.origin.y) * scale <= Double(clip.y) + 1e-9,
                          (r.maxX + item.origin.x) * scale >= Double(clip.x + clip.width) - 1e-9,
                          (r.maxY + item.origin.y) * scale >= Double(clip.y + clip.height) - 1e-9,
                          item.bounds.contains(clip) else { return nil }
                    bg.append(item)
                }
                return bg
            }
            guard let oldBg = uniformBackdrop(old, end: oldH.startIndex),
                  let newBg = uniformBackdrop(self, end: newH.startIndex),
                  oldBg == newBg else { continue }
            candidates.append(Candidate(oldHint: oldH, newHint: newH, dx: dx, dy: dy))
        }
        guard !candidates.isEmpty else {
            return DamagePlan(blits: [], damage: damage(since: old))
        }

        // Diff items outside the candidate scroll ranges.
        func outsideItems(_ list: DisplayList, ranges: [Range<Int>]) -> [DisplayItem] {
            var out: [DisplayItem] = []
            out.reserveCapacity(list.items.count)
            for (i, item) in list.items.enumerated() {
                if !ranges.contains(where: { $0.contains(i) }) { out.append(item) }
            }
            return out
        }
        let oldOutside = outsideItems(old, ranges: candidates.map { $0.oldHint.startIndex..<$0.oldHint.endIndex })
        let newOutside = outsideItems(self, ranges: candidates.map { $0.newHint.startIndex..<$0.newHint.endIndex })
        var damageRects = Self.diffItems(oldOutside, newOutside)

        // If any outside damage touches a candidate's clip, fall back to normal damage.
        if candidates.contains(where: { c in damageRects.contains(where: { $0.intersects(c.newHint.clip) }) }) {
            return DamagePlan(blits: [], damage: damage(since: old))
        }

        var blits: [ScrollBlit] = []
        for c in candidates {
            let clip = c.newHint.clip
            blits.append(ScrollBlit(rect: clip, dx: c.dx, dy: c.dy))
            // Newly exposed strips inside clip.
            if c.dy < 0 { damageRects.append(PixelRect(x: clip.x, y: clip.y + clip.height + c.dy, width: clip.width, height: -c.dy)) }
            else if c.dy > 0 { damageRects.append(PixelRect(x: clip.x, y: clip.y, width: clip.width, height: c.dy)) }
            if c.dx < 0 { damageRects.append(PixelRect(x: clip.x + clip.width + c.dx, y: clip.y, width: -c.dx, height: clip.height)) }
            else if c.dx > 0 { damageRects.append(PixelRect(x: clip.x, y: clip.y, width: c.dx, height: clip.height)) }

            // Surviving overlap: diff shifted old items against new items.
            let shiftedClip = PixelRect(x: clip.x + c.dx, y: clip.y + c.dy, width: clip.width, height: clip.height)
            let overlap = clip.clamped(to: shiftedClip)
            if !overlap.isEmpty {
                struct ShiftedKey: Hashable {
                    var op: DisplayItem.Operation
                    var ox: Int64
                    var oy: Int64
                    var clip: PixelRect
                }
                func quantize(_ v: Double) -> Int64 { Int64((v * 1_000_000).rounded()) }
                let dOx = Double(c.dx) / scale, dOy = Double(c.dy) / scale
                var oldOverlap: [(ShiftedKey, PixelRect)] = []
                for item in old.items[c.oldHint.startIndex..<c.oldHint.endIndex] {
                    let sb = PixelRect(x: item.bounds.x + c.dx, y: item.bounds.y + c.dy, width: item.bounds.width, height: item.bounds.height).clamped(to: overlap)
                    guard !sb.isEmpty else { continue }
                    let sc = PixelRect(x: item.clip.x + c.dx, y: item.clip.y + c.dy, width: item.clip.width, height: item.clip.height).clamped(to: overlap)
                    let key = ShiftedKey(op: item.operation, ox: quantize(item.origin.x + dOx), oy: quantize(item.origin.y + dOy), clip: sc)
                    oldOverlap.append((key, sb))
                }
                var newOverlap: [(ShiftedKey, PixelRect)] = []
                for item in items[c.newHint.startIndex..<c.newHint.endIndex] {
                    let nb = item.bounds.clamped(to: overlap)
                    guard !nb.isEmpty else { continue }
                    let nc = item.clip.clamped(to: overlap)
                    let key = ShiftedKey(op: item.operation, ox: quantize(item.origin.x), oy: quantize(item.origin.y), clip: nc)
                    newOverlap.append((key, nb))
                }
                var places: [ShiftedKey: (indices: [Int], next: Int)] = [:]
                for (j, entry) in newOverlap.enumerated() { places[entry.0, default: ([], 0)].indices.append(j) }
                var matched = [Bool](repeating: false, count: newOverlap.count)
                var last = -1
                for (key, bounds) in oldOverlap {
                    if var p = places[key] {
                        while p.next < p.indices.count, p.indices[p.next] <= last { p.next += 1 }
                        if p.next < p.indices.count {
                            let j = p.indices[p.next]
                            p.next += 1
                            places[key] = p
                            matched[j] = true
                            last = j
                            continue
                        }
                        places[key] = p
                    }
                    damageRects.append(bounds)
                }
                for (j, entry) in newOverlap.enumerated() where !matched[j] { damageRects.append(entry.1) }
            }
        }
        return DamagePlan(blits: blits, damage: expandForBackdropBlurs(PixelRect.merged(damageRects, within: fullRect)))
    }

    private static func diffItems(_ a: [DisplayItem], _ b: [DisplayItem]) -> [PixelRect] {
        var start = 0
        while start < a.count, start < b.count, a[start] == b[start] { start += 1 }
        var endA = a.count, endB = b.count
        while endA > start, endB > start, a[endA - 1] == b[endB - 1] { endA -= 1; endB -= 1 }
        if start == endA, start == endB { return [] }
        var rects: [PixelRect] = []
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

    func contains(_ r: PixelRect) -> Bool {
        x <= r.x && y <= r.y && x + width >= r.x + r.width && y + height >= r.y + r.height
    }

    var area: Int { width * height }

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
