// LazyVGrid and LazyHGrid. Cells fill rows (columns for LazyHGrid) in order;
// a `ForEach` inside builds, lays out and draws only the rows in view, as in
// lazy stacks (rows never built are given the average size of those that were).
import PolymerBase
import PolymerRender

/// One column of a `LazyVGrid` (or row of a `LazyHGrid`).
public struct GridItem: Sendable {
    public enum Size: Sendable {
        /// Exactly this many points.
        case fixed(Double)
        /// A share of the space left after fixed items, within the bounds.
        case flexible(minimum: Double = 10, maximum: Double = .infinity)
        /// As many columns as fit in its share, each at least `minimum` wide.
        case adaptive(minimum: Double, maximum: Double = .infinity)
    }
    public var size: Size
    /// Space after this item, before the next; nil for the default (8 points).
    public var spacing: Double?
    /// Where a cell's view sits in the cell; nil for the centre.
    public var alignment: Alignment?
    public init(_ size: Size = .flexible(), spacing: Double? = nil, alignment: Alignment? = nil) {
        self.size = size; self.spacing = spacing; self.alignment = alignment
    }
}

public struct LazyVGrid<Content: View>: View, PrimitiveView {
    let columns: [GridItem], alignment: HorizontalAlignment, spacing: Double?, content: Content
    /// `alignment` places the columns when they are narrower than the grid; `spacing` is between rows.
    public init(columns: [GridItem], alignment: HorizontalAlignment = .center, spacing: Double? = nil,
                @ViewBuilder content: () -> Content) {
        self.columns = columns; self.alignment = alignment; self.spacing = spacing; self.content = content()
    }
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        LazyGridNode.resolve(existing, axis: .vertical, tracks: columns,
                             alignment: Alignment(horizontal: alignment, vertical: .center), spacing: spacing, content: content, c)
    }
}

public struct LazyHGrid<Content: View>: View, PrimitiveView {
    let rows: [GridItem], alignment: VerticalAlignment, spacing: Double?, content: Content
    /// `alignment` places the rows when they are shorter than the grid; `spacing` is between columns.
    public init(rows: [GridItem], alignment: VerticalAlignment = .center, spacing: Double? = nil,
                @ViewBuilder content: () -> Content) {
        self.rows = rows; self.alignment = alignment; self.spacing = spacing; self.content = content()
    }
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        LazyGridNode.resolve(existing, axis: .horizontal, tracks: rows,
                             alignment: Alignment(horizontal: .center, vertical: alignment), spacing: spacing, content: content, c)
    }
}

/// A column of a vertical grid (a row of a horizontal one), once sizes are known.
struct GridTrack: Equatable {
    var position: Double, size: Double
    var alignment: Alignment?
}

/// Column sizes for `items` across `available` points (nil: each at its minimum).
/// Fixed items take their size; flexible and adaptive items share the rest
/// evenly within their bounds; an adaptive item fits as many columns of at
/// least its minimum into its share as it can.
func gridTracks(_ items: [GridItem], available: Double?) -> [GridTrack] {
    guard !items.isEmpty else { return [] }
    func bounds(_ s: GridItem.Size) -> (Double, Double) {
        switch s {
        case .fixed(let w): return (w, w)
        case .flexible(let lo, let hi), .adaptive(let lo, let hi): return (lo, max(lo, hi))
        }
    }
    let gaps = items.dropLast().reduce(0.0) { $0 + ($1.spacing ?? defaultSpacing) }
    var share = [Double](repeating: 0, count: items.count)
    var pending: [Int] = []
    var left = (available ?? 0) - gaps
    for (i, item) in items.enumerated() {
        if case .fixed(let w) = item.size { share[i] = w; left -= w } else { pending.append(i) }
    }
    if available == nil {
        for i in pending { share[i] = bounds(items[i].size).0 }
    } else {
        // Water-filling: items whose maximum is below the even share take their maximum, then
        // items whose minimum is above it take their minimum, until the rest share evenly.
        var changed = true
        while changed, !pending.isEmpty {
            changed = false
            let even = left / Double(pending.count)
            if let k = pending.firstIndex(where: { bounds(items[$0].size).1 < even }) ?? pending.firstIndex(where: { bounds(items[$0].size).0 > even }) {
                let i = pending.remove(at: k)
                let (lo, hi) = bounds(items[i].size)
                share[i] = min(max(even, lo), hi)
                left -= share[i]
                changed = true
            }
        }
        let even = pending.isEmpty ? 0 : left / Double(pending.count)
        for i in pending { share[i] = even }
    }
    var tracks: [GridTrack] = []
    var pos = 0.0
    for (i, item) in items.enumerated() {
        let gap = item.spacing ?? defaultSpacing
        if case .adaptive(let lo, let hi) = item.size, available != nil {
            let n = max(1, Int(((share[i] + gap) / (lo + gap)).rounded(.down)))
            let w = min(max((share[i] - gap * Double(n - 1)) / Double(n), lo), max(lo, hi))
            for k in 0..<n {
                tracks.append(GridTrack(position: pos, size: w, alignment: item.alignment))
                pos += w + (k < n - 1 || i < items.count - 1 ? gap : 0)
            }
        } else {
            tracks.append(GridTrack(position: pos, size: share[i], alignment: item.alignment))
            pos += share[i] + (i < items.count - 1 ? gap : 0)
        }
    }
    return tracks
}

/// LazyVGrid and LazyHGrid. "Rows" below run along the scrolling axis (rows
/// of a vertical grid, columns of a horizontal one); "tracks" across it.
/// Each `ForEach` element is one cell; any other view in the grid is one cell too.
final class LazyGridNode: Node, LazyViewport {
    var axis: Axis = .vertical
    var items: [GridItem] = []
    var alignment: Alignment = .center
    var spacing = defaultSpacing
    private var segmentCache: [LazySegment]?
    private var tracks: [GridTrack] = []
    private var tracksFor: Double?? = nil
    /// Where each row starts along the axis, then the total length.
    private var starts: [Double] = []
    private var startsValid = false
    private var reportedLength = 0.0
    /// Cells in view at the last placement.
    private(set) var inView: Range<Int> = 0..<0

    static func resolve<Content: View>(_ existing: Node?, axis: Axis, tracks: [GridItem], alignment: Alignment, spacing: Double?,
                                       content: Content, _ c: ResolveContext) -> Node {
        let reuse = (existing as? LazyGridNode).flatMap { $0.axis == axis ? $0 : nil }
        let n = reuse ?? LazyGridNode()
        n.axis = axis; n.items = tracks; n.alignment = alignment; n.spacing = spacing ?? defaultSpacing
        n.tracksFor = nil
        var c = c
        c.stackAxis = axis
        n.setChild(0, content, c)
        return n
    }

    override var role: String { axis == .horizontal ? "LazyHGrid" : "LazyVGrid" }
    override var detail: String { "\(tracks.count) \(axis == .horizontal ? "rows" : "columns"), in view \(inView.lowerBound)..<\(inView.upperBound) of \(cellCount)" }
    override func childrenAreLazy(_ inherited: Bool) -> Bool { true }

    var segments: [LazySegment] {
        if let s = segmentCache { return s }
        let s = children.first?.lazySegments ?? []
        segmentCache = s
        return s
    }

    var cellCount: Int {
        segments.reduce(0) { n, s in
            switch s { case .node: n + 1; case .elements(let f): n + f.ids.count }
        }
    }

    override func invalidateLayout() {
        segmentCache = nil
        startsValid = false
        super.invalidateLayout()
    }

    func main(_ s: Size) -> Double { axis == .horizontal ? s.width : s.height }
    func cross(_ s: Size) -> Double { axis == .horizontal ? s.height : s.width }

    /// Works out the tracks for `available` points across; forgets measured sizes when they change.
    private func layTracks(_ available: Double?) {
        if let t = tracksFor, t == available { return }
        let next = gridTracks(items, available: available)
        if next != tracks {
            for case .elements(let f) in segments { f.forgetSizes() }
            startsValid = false
        }
        tracks = next
        tracksFor = .some(available)
    }

    private func proposal(_ track: Int) -> ProposedViewSize {
        let c = tracks.isEmpty ? nil : tracks[track % tracks.count].size
        return axis == .horizontal ? ProposedViewSize(width: nil, height: c) : ProposedViewSize(width: c, height: nil)
    }

    /// The nodes of cell `g` (an element's views, or a view of the grid), building the element if needed.
    private func cell(_ g: Int, build: Bool) -> (nodes: [Node], forEach: LazyForEachNode?, index: Int)? {
        var k = 0
        for seg in segments {
            switch seg {
            case .node(let n):
                if g == k { return ([n], nil, 0) }
                k += 1
            case .elements(let f):
                if g < k + f.ids.count { return (build ? f.node(at: g - k).flattened : [], f, g - k) }
                k += f.ids.count
            }
        }
        return nil
    }

    /// Measures cell `g` (building it) and records its size; true when it differs from the size used.
    @discardableResult
    private func measureCell(_ g: Int) -> Bool {
        guard let c = cell(g, build: true) else { return false }
        let m = c.nodes.reduce(0.0) { max($0, main($1.measure(proposal(g)))) }
        guard let f = c.forEach else { return false }
        let used = f.sizes[c.index] >= 0 ? f.sizes[c.index] : f.estimate
        if f.sizes[c.index] != m { f.setSize(c.index, m) }
        return m != used
    }

    private func ensureStarts() {
        if startsValid { return }
        let n = max(1, tracks.count)
        let segs = segments
        // Elements never measured take the average of those that were; measure the first if none was.
        var first = 0
        for seg in segs {
            switch seg {
            case .node: first += 1
            case .elements(let f):
                if !f.ids.isEmpty, f.estimate == nil { measureCell(first) }
                first += f.ids.count
            }
        }
        // Each cell's size along the axis: measured, estimated, or (for plain views) measured now.
        var sizes: [Double] = []
        var g = 0
        for seg in segs {
            switch seg {
            case .node(let v):
                sizes.append(main(v.measure(proposal(g)))); g += 1
            case .elements(let f):
                let e = f.estimate ?? 0
                for s in f.sizes { sizes.append(s >= 0 ? s : e) }
                g += f.ids.count
            }
        }
        starts.removeAll(keepingCapacity: true)
        var pos = 0.0
        var r = 0
        while r * n < sizes.count {
            if r > 0 { pos += spacing }
            starts.append(pos)
            pos += sizes[(r * n)..<min(sizes.count, r * n + n)].max() ?? 0
            r += 1
        }
        starts.append(pos)
        startsValid = true
    }

    override func sizeThatFits(_ p: ProposedViewSize) -> Size {
        let crossP = axis == .horizontal ? p.height : p.width
        let finite = crossP.flatMap { $0.isFinite ? $0 : nil }
        layTracks(finite)
        ensureStarts()
        reportedLength = starts.last ?? 0
        let c = finite ?? tracks.last.map { $0.position + $0.size } ?? 0
        return axis == .horizontal ? Size(width: reportedLength, height: c) : Size(width: c, height: reportedLength)
    }

    /// Rows that overlap the span [lo, hi).
    private func rows(in span: (Double, Double)) -> Range<Int> {
        let n = starts.count - 1
        guard n > 0, span.0 < span.1 else { return 0..<0 }
        var a = 0, b = n
        while a < b { let m = (a + b) / 2; if starts[m + 1] > span.0 { b = m } else { a = m + 1 } }
        let first = a
        a = first; b = n
        while a < b { let m = (a + b) / 2; if starts[m] >= span.1 { b = m } else { a = m + 1 } }
        return first..<a
    }

    private func cells(_ rows: Range<Int>) -> Range<Int> {
        let n = max(1, tracks.count)
        return min(rows.lowerBound * n, cellCount)..<min(rows.upperBound * n, cellCount)
    }

    override func placeChildren(in r: Rect) {
        layTracks(cross(r.size))
        ensureStarts()
        let span = visibleSpan(self, axis: axis, r)
        var range = rows(in: span)
        for _ in 0..<4 {
            var resized = false
            for g in cells(range) where measureCell(g) { resized = true }
            if !resized { break }
            startsValid = false
            ensureStarts()
            range = rows(in: span)
        }
        let shown = cells(range)
        inView = shown

        let n = max(1, tracks.count)
        let total = tracks.last.map { $0.position + $0.size } ?? 0
        let crossEdge = axis == .horizontal ? r.minY : r.minX
        let slack = cross(r.size) - total
        let shift: Double = axis == .horizontal
            ? (alignment.vertical == .top ? 0 : alignment.vertical == .center ? slack / 2 : slack)
            : (alignment.horizontal == .leading ? 0 : alignment.horizontal == .center ? slack / 2 : slack)
        let mainEdge = axis == .horizontal ? r.minX : r.minY
        // Cells to place: those in view, and every view that is not a ForEach element (always built).
        var toPlace = Array(shown)
        var k = 0
        for seg in segments {
            switch seg {
            case .node: if !shown.contains(k) { toPlace.append(k) }; k += 1
            case .elements(let f): k += f.ids.count
            }
        }
        // Visible cells by ForEach, so each knows which of its elements are in view.
        var inViewByForEach: [ObjectIdentifier: [Node]] = [:]
        for g in toPlace {
            guard let c = cell(g, build: true) else { continue }
            let row = g / n, t = tracks.isEmpty ? GridTrack(position: 0, size: cross(r.size)) : tracks[g % n]
            let rowLength = starts[row + 1] - starts[row] - (row + 1 < starts.count - 1 ? spacing : 0)
            let slot: Rect = axis == .horizontal
                ? Rect(x: mainEdge + starts[row], y: crossEdge + shift + t.position, width: rowLength, height: t.size)
                : Rect(x: crossEdge + shift + t.position, y: mainEdge + starts[row], width: t.size, height: rowLength)
            let a = t.alignment ?? .center
            for v in c.nodes {
                let s = v.measure(proposal(g))
                v.place(Rect(origin: a.origin(of: s, in: slot), size: s))
            }
            if let f = c.forEach { inViewByForEach[ObjectIdentifier(f), default: []].append(f.node(at: c.index)) }
        }
        for case .elements(let f) in segments { f.setInView(inViewByForEach[ObjectIdentifier(f)] ?? []) }
        if (starts.last ?? 0) != reportedLength {
            invalidateLayoutUpward()
            tree?.layoutRequested = true
        }
    }

    func viewportMoved() {
        guard startsValid, cells(rows(in: visibleSpan(self, axis: axis, frame))) == inView else {
            setNeedsPlacementUpward()
            tree?.layoutRequested = true
            return
        }
    }

    override func draw(_ list: inout DisplayList) {
        for seg in segments {
            switch seg {
            case .node(let v): if list.isVisible(v.frame) { v.draw(&list) }
            case .elements(let f):
                for e in f.children { for x in e.flattened where list.isVisible(x.frame) { x.draw(&list) } }
            }
        }
    }
}
