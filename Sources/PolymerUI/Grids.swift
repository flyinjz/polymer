// LazyVGrid and LazyHGrid with SwiftUI-compatible GridItem track sizing
// (.fixed, .flexible, .adaptive) and lazy ForEach materialization.
import PolymerBase
import PolymerRender

/// Describes a single column in a `LazyVGrid` or a single row in a `LazyHGrid`.
public struct GridItem: Equatable, Sendable {
    public enum Size: Equatable, Sendable {
        case fixed(Double)
        case flexible(minimum: Double = 10, maximum: Double = .infinity)
        case adaptive(minimum: Double, maximum: Double = .infinity)
    }

    public var size: Size
    public var spacing: Double?
    public var alignment: Alignment?

    public init(_ size: Size = .flexible(), spacing: Double? = nil, alignment: Alignment? = nil) {
        self.size = size
        self.spacing = spacing
        self.alignment = alignment
    }
}

/// Arranges child views in a vertically growing grid of columns, building
/// `ForEach` elements lazily only as rows enter the visible viewport.
public struct LazyVGrid<Content: View>: View, PrimitiveView {
    let columns: [GridItem]
    let alignment: HorizontalAlignment
    let spacing: Double?
    let content: Content

    public init(columns: [GridItem], alignment: HorizontalAlignment = .center, spacing: Double? = nil,
                @ViewBuilder content: () -> Content) {
        self.columns = columns
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        LazyGridNode.resolve(
            existing,
            axis: .vertical,
            tracks: columns,
            crossAlignment: Alignment(horizontal: alignment, vertical: .center),
            spacing: spacing,
            content: content,
            c
        )
    }
}

/// Arranges child views in a horizontally growing grid of rows, building
/// `ForEach` elements lazily only as columns enter the visible viewport.
public struct LazyHGrid<Content: View>: View, PrimitiveView {
    let rows: [GridItem]
    let alignment: VerticalAlignment
    let spacing: Double?
    let content: Content

    public init(rows: [GridItem], alignment: VerticalAlignment = .center, spacing: Double? = nil,
                @ViewBuilder content: () -> Content) {
        self.rows = rows
        self.alignment = alignment
        self.spacing = spacing
        self.content = content()
    }

    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        LazyGridNode.resolve(
            existing,
            axis: .horizontal,
            tracks: rows,
            crossAlignment: Alignment(horizontal: .center, vertical: alignment),
            spacing: spacing,
            content: content,
            c
        )
    }
}

// MARK: Track resolution

struct ResolvedGridTrack: Equatable {
    var offset: Double
    var size: Double
    var alignment: Alignment?
}

enum GridTrackLayout {
    private enum ExpandedKind {
        case fixed(Double)
        case flexible(min: Double, max: Double)
    }

    private struct ExpandedTrack {
        var kind: ExpandedKind
        var spacing: Double
        var alignment: Alignment?
    }

    static func resolve(_ items: [GridItem], availableCross: Double?, defaultCrossSpacing: Double = defaultSpacing) -> (tracks: [ResolvedGridTrack], totalCross: Double) {
        guard !items.isEmpty else { return ([], 0) }

        let finiteCross = availableCross.flatMap { $0.isFinite ? max(0, $0) : nil }

        // First calculate space consumed by non-adaptive items to compute adaptive column/row counts.
        var fixedAndMinNonAdaptive = 0.0
        var topLevelSpacings = 0.0
        var adaptiveCount = 0
        for (idx, item) in items.enumerated() {
            if idx + 1 < items.count {
                topLevelSpacings += item.spacing ?? defaultCrossSpacing
            }
            switch item.size {
            case .fixed(let v):
                fixedAndMinNonAdaptive += max(0, v)
            case .flexible(let lo, _):
                fixedAndMinNonAdaptive += max(0, lo)
            case .adaptive:
                adaptiveCount += 1
            }
        }

        let adaptiveBudgetPerItem: Double
        if let avail = finiteCross, adaptiveCount > 0 {
            adaptiveBudgetPerItem = max(0, avail - fixedAndMinNonAdaptive - topLevelSpacings) / Double(adaptiveCount)
        } else {
            adaptiveBudgetPerItem = 0
        }

        // Expand adaptive descriptors into concrete flexible tracks.
        var expanded: [ExpandedTrack] = []
        expanded.reserveCapacity(items.count)
        for item in items {
            let sp = item.spacing ?? defaultCrossSpacing
            switch item.size {
            case .fixed(let v):
                expanded.append(ExpandedTrack(kind: .fixed(max(0, v)), spacing: sp, alignment: item.alignment))
            case .flexible(let lo, let hi):
                let minV = max(0, lo)
                let maxV = max(minV, hi)
                expanded.append(ExpandedTrack(kind: .flexible(min: minV, max: maxV), spacing: sp, alignment: item.alignment))
            case .adaptive(let lo, let hi):
                let minV = max(1, lo)
                let maxV = max(minV, hi)
                let count: Int
                if finiteCross != nil {
                    count = max(1, Int(((adaptiveBudgetPerItem + sp) / (minV + sp)).rounded(.down)))
                } else {
                    count = 1
                }
                for _ in 0..<count {
                    expanded.append(ExpandedTrack(kind: .flexible(min: minV, max: maxV), spacing: sp, alignment: item.alignment))
                }
            }
        }

        let k = expanded.count
        var sizes = [Double](repeating: 0, count: k)
        var fixedSum = 0.0
        var flexIndices: [Int] = []
        var totalSpacings = 0.0

        for i in 0..<k {
            if i + 1 < k { totalSpacings += expanded[i].spacing }
            switch expanded[i].kind {
            case .fixed(let v):
                sizes[i] = v
                fixedSum += v
            case .flexible(let lo, _):
                sizes[i] = lo
                flexIndices.append(i)
            }
        }

        // Distribute remaining cross space across flexible tracks respecting [min, max] bounds.
        if let avail = finiteCross, !flexIndices.isEmpty {
            var remaining = max(0, avail - totalSpacings - fixedSum)
            var unresolved = flexIndices
            while !unresolved.isEmpty {
                let share = remaining / Double(unresolved.count)
                var clampedAny = false
                var nextUnresolved: [Int] = []
                for idx in unresolved {
                    guard case .flexible(let lo, let hi) = expanded[idx].kind else { continue }
                    if share < lo {
                        sizes[idx] = lo
                        remaining = max(0, remaining - lo)
                        clampedAny = true
                    } else if share > hi {
                        sizes[idx] = hi
                        remaining = max(0, remaining - hi)
                        clampedAny = true
                    } else {
                        nextUnresolved.append(idx)
                    }
                }
                if !clampedAny {
                    for idx in nextUnresolved { sizes[idx] = share }
                    break
                }
                unresolved = nextUnresolved
            }
        }

        var result: [ResolvedGridTrack] = []
        result.reserveCapacity(k)
        var cursor = 0.0
        for i in 0..<k {
            result.append(ResolvedGridTrack(offset: cursor, size: sizes[i], alignment: expanded[i].alignment))
            cursor += sizes[i]
            if i + 1 < k { cursor += expanded[i].spacing }
        }
        return (result, cursor)
    }
}

// MARK: LazyGridNode

final class LazyGridNode: Node {
    var axis: Axis = .vertical
    var gridItems: [GridItem] = []
    var crossAlignment: Alignment = .center
    var spacing: Double = defaultSpacing
    private weak var tree: TreeState?

    private var segmentCache: [LazySegment]?
    private var resolvedTracks: [ResolvedGridTrack] = []
    private var resolvedTotalCross: Double = 0
    private var lastOfferedCross: Double? = nil
    private var offeredCrossSet = false

    private var bandSizes: [Double] = []
    private var knownBandSum: Double = 0
    private var knownBandCount: Int = 0
    private var bandStarts: [Double] = []
    private var bandStartsValid = false
    private var reportedLength: Double = 0

    private(set) var inViewBands: Range<Int> = 0..<0
    private(set) var inViewItems: Range<Int> = 0..<0

    static func resolve<Content: View>(
        _ existing: Node?,
        axis: Axis,
        tracks: [GridItem],
        crossAlignment: Alignment,
        spacing: Double?,
        content: Content,
        _ c: ResolveContext
    ) -> Node {
        let reuse = (existing as? LazyGridNode).flatMap { $0.axis == axis ? $0 : nil }
        let n = reuse ?? LazyGridNode()
        let newSpacing = spacing ?? defaultSpacing
        if n.gridItems != tracks || n.spacing != newSpacing {
            n.gridItems = tracks
            n.spacing = newSpacing
            n.offeredCrossSet = false
            n.forgetBandSizes()
        }
        n.axis = axis
        n.crossAlignment = crossAlignment
        n.tree = c.tree
        var childCtx = c
        childCtx.stackAxis = axis
        n.setChild(0, content, childCtx)
        return n
    }

    override var role: String { axis == .horizontal ? "LazyHGrid" : "LazyVGrid" }
    override var detail: String {
        "in view \(inViewItems.lowerBound)..<\(inViewItems.upperBound) of \(totalItemCount)"
    }
    override func childrenAreLazy(_ inherited: Bool) -> Bool { true }

    var segments: [LazySegment] {
        if let s = segmentCache { return s }
        let s = children.first?.lazySegments ?? []
        segmentCache = s
        return s
    }

    var totalItemCount: Int {
        var total = 0
        for seg in segments {
            switch seg {
            case .node: total += 1
            case .elements(let f): total += f.ids.count
            }
        }
        return total
    }

    override func invalidateLayout() {
        segmentCache = nil
        bandStartsValid = false
        super.invalidateLayout()
    }

    private func main(_ s: Size) -> Double { axis == .horizontal ? s.width : s.height }
    private func cross(_ s: Size) -> Double { axis == .horizontal ? s.height : s.width }

    private func forgetBandSizes() {
        bandSizes.removeAll(keepingCapacity: true)
        knownBandSum = 0
        knownBandCount = 0
        bandStartsValid = false
    }

    private func ensureTracks(forCross offered: Double?) {
        if offeredCrossSet, offered == lastOfferedCross { return }
        let prevTracks = resolvedTracks
        lastOfferedCross = offered
        offeredCrossSet = true
        let resolved = GridTrackLayout.resolve(gridItems, availableCross: offered)
        resolvedTracks = resolved.tracks
        resolvedTotalCross = resolved.totalCross
        if resolvedTracks != prevTracks {
            forgetBandSizes()
        }
    }

    private var trackCount: Int { max(1, resolvedTracks.count) }

    private var bandCount: Int {
        let total = totalItemCount
        guard total > 0, !resolvedTracks.isEmpty else { return 0 }
        return (total + trackCount - 1) / trackCount
    }

    private func syncBandStorage() {
        let count = bandCount
        if bandSizes.count == count { return }
        var next = [Double](repeating: -1, count: count)
        let keep = min(bandSizes.count, count)
        var sum = 0.0
        var known = 0
        for i in 0..<keep {
            let v = bandSizes[i]
            next[i] = v
            if v >= 0 { sum += v; known += 1 }
        }
        bandSizes = next
        knownBandSum = sum
        knownBandCount = known
        bandStartsValid = false
    }

    private var bandEstimate: Double {
        knownBandCount > 0 ? knownBandSum / Double(knownBandCount) : 0
    }

    private func setBandSize(_ band: Int, _ size: Double) {
        if bandSizes[band] >= 0 {
            knownBandSum -= bandSizes[band]
            knownBandCount -= 1
        }
        bandSizes[band] = size
        knownBandSum += size
        knownBandCount += 1
    }

    private func itemProposal(forTrack trackIndex: Int) -> ProposedViewSize {
        let trackSize = resolvedTracks[trackIndex].size
        return axis == .horizontal
            ? ProposedViewSize(width: nil, height: trackSize)
            : ProposedViewSize(width: trackSize, height: nil)
    }

    /// Resolves the node at `globalIndex` across `segments` (building it if inside a `LazyForEachNode`).
    private func nodeAt(_ globalIndex: Int) -> Node? {
        var cursor = 0
        for seg in segments {
            switch seg {
            case .node(let n):
                if globalIndex == cursor { return n }
                cursor += 1
            case .elements(let f):
                let count = f.ids.count
                if globalIndex < cursor + count {
                    return f.node(at: globalIndex - cursor)
                }
                cursor += count
            }
        }
        return nil
    }

    /// Measures every item in `band` and records the band's maximum main-axis size.
    /// Returns true if the band's size differed from the size previously used for layout.
    @discardableResult
    private func measureBand(_ band: Int) -> Bool {
        let total = totalItemCount
        let tc = trackCount
        let startItem = band * tc
        let endItem = min(total, startItem + tc)
        guard startItem < endItem else { return false }

        var bandMain = 0.0
        for g in startItem..<endItem {
            guard let itemNode = nodeAt(g) else { continue }
            let t = g % tc
            let prop = itemProposal(forTrack: t)
            let flatNodes = itemNode.flattened
            var itemMain = 0.0
            for (k, n) in flatNodes.enumerated() {
                let s = n.measure(prop)
                itemMain += main(s) + (k > 0 ? spacing : 0)
            }
            bandMain = max(bandMain, itemMain)
        }

        let used = bandSizes[band] >= 0 ? bandSizes[band] : bandEstimate
        if bandSizes[band] != bandMain {
            setBandSize(band, bandMain)
        }
        return bandMain != used
    }

    private func ensureBandStarts() {
        syncBandStorage()
        if bandStartsValid { return }
        let count = bandCount
        if count > 0, knownBandCount == 0 {
            _ = measureBand(0)
        }
        bandStarts.removeAll(keepingCapacity: true)
        bandStarts.reserveCapacity(count + 1)
        let est = bandEstimate
        var pos = 0.0
        for b in 0..<count {
            if b > 0 { pos += spacing }
            bandStarts.append(pos)
            let h = bandSizes[b] >= 0 ? bandSizes[b] : est
            pos += h
        }
        bandStarts.append(pos)
        bandStartsValid = true
    }

    override func sizeThatFits(_ p: ProposedViewSize) -> Size {
        let crossP = axis == .horizontal ? p.height : p.width
        let finiteCross = crossP.flatMap { $0.isFinite ? $0 : nil }
        ensureTracks(forCross: finiteCross)
        ensureBandStarts()
        reportedLength = bandStarts.last ?? 0
        let finalCross = finiteCross ?? resolvedTotalCross
        return axis == .horizontal
            ? Size(width: reportedLength, height: finalCross)
            : Size(width: finalCross, height: reportedLength)
    }

    private func visibleSpan(_ r: Rect) -> (Double, Double) {
        var view: Rect? = nil
        var top: Node = self
        var n = parent
        while let x = n {
            if let s = x as? ScrollNode { view = s.viewport; break }
            top = x
            n = x.parent
        }
        let v = view ?? top.frame
        let (lo, hi, edge) = axis == .horizontal
            ? (v.minX, v.maxX, r.minX)
            : (v.minY, v.maxY, r.minY)
        return (max(lo, edge) - edge, min(hi, edge + main(r.size)) - edge)
    }

    private func bands(in span: (Double, Double)) -> Range<Int> {
        let n = bandStarts.count - 1
        guard n > 0, span.0 < span.1 else { return 0..<0 }
        var a = 0, b = n
        while a < b {
            let m = (a + b) / 2
            if bandStarts[m + 1] > span.0 { b = m } else { a = m + 1 }
        }
        let first = a
        a = first; b = n
        while a < b {
            let m = (a + b) / 2
            if bandStarts[m] >= span.1 { b = m } else { a = m + 1 }
        }
        return first..<a
    }

    override func placeChildren(in r: Rect) {
        ensureTracks(forCross: cross(r.size))
        guard !resolvedTracks.isEmpty else {
            inViewBands = 0..<0
            inViewItems = 0..<0
            return
        }
        ensureBandStarts()
        let span = visibleSpan(r)
        var range = bands(in: span)

        for _ in 0..<4 {
            var resized = false
            for b in range where measureBand(b) { resized = true }
            if !resized { break }
            bandStartsValid = false
            ensureBandStarts()
            range = bands(in: span)
        }

        let tc = trackCount
        let total = totalItemCount
        inViewBands = range
        let visItemLo = min(total, range.lowerBound * tc)
        let visItemHi = min(total, range.upperBound * tc)
        inViewItems = visItemLo..<visItemHi

        // Cross-axis offset for aligning the whole grid inside `r`.
        let gridCrossOffset: Double
        if axis == .vertical {
            let slack = max(0, r.width - resolvedTotalCross)
            gridCrossOffset = switch crossAlignment.horizontal {
            case .leading: 0
            case .center: slack / 2
            case .trailing: slack
            }
        } else {
            let slack = max(0, r.height - resolvedTotalCross)
            gridCrossOffset = switch crossAlignment.vertical {
            case .top: 0
            case .center: slack / 2
            case .bottom: slack
            }
        }

        func placeItem(_ itemNode: Node, at globalIndex: Int) {
            let band = globalIndex / tc
            let t = globalIndex % tc
            let track = resolvedTracks[t]
            let bandPos = bandStarts[band]
            let bandMain = bandSizes[band] >= 0 ? bandSizes[band] : bandEstimate
            let prop = itemProposal(forTrack: t)
            let cellAlign = track.alignment ?? .center

            let cellRect: Rect = axis == .vertical
                ? Rect(x: r.minX + gridCrossOffset + track.offset, y: r.minY + bandPos, width: track.size, height: bandMain)
                : Rect(x: r.minX + bandPos, y: r.minY + gridCrossOffset + track.offset, width: bandMain, height: track.size)

            for child in itemNode.flattened {
                let s = child.measure(prop)
                let origin = cellAlign.origin(of: s, in: cellRect)
                child.place(Rect(origin: origin, size: s))
            }
        }

        var cursor = 0
        for seg in segments {
            switch seg {
            case .node(let n):
                if cursor >= visItemLo && cursor < visItemHi {
                    placeItem(n, at: cursor)
                }
                cursor += 1
            case .elements(let f):
                let count = f.ids.count
                let lo = max(visItemLo, cursor)
                let hi = min(visItemHi, cursor + count)
                var shown: [Node] = []
                if lo < hi {
                    shown.reserveCapacity(hi - lo)
                    for g in lo..<hi {
                        let e = f.node(at: g - cursor)
                        shown.append(e)
                        placeItem(e, at: g)
                    }
                }
                f.setInView(shown)
                cursor += count
            }
        }

        if (bandStarts.last ?? 0) != reportedLength {
            invalidateLayoutUpward()
            tree?.layoutRequested = true
        }
    }

    func viewportMoved() {
        guard bandStartsValid, bands(in: visibleSpan(frame)) == inViewBands else {
            setNeedsPlacementUpward()
            tree?.layoutRequested = true
            return
        }
    }

    override func draw(_ list: inout DisplayList) {
        for seg in segments {
            switch seg {
            case .node(let n):
                if list.isVisible(n.frame) { n.draw(&list) }
            case .elements(let f):
                for e in f.children {
                    for x in e.flattened where list.isVisible(x.frame) {
                        x.draw(&list)
                    }
                }
            }
        }
    }
}
