// Grid and GridRow, as in SwiftUI (not lazy): every cell is built and
// measured. Columns are as wide as their widest cell; offered a width, the
// grid shares it among columns the way a stack shares space among its
// children (least flexible first). Rows are as tall as their tallest cell.
// A view directly in the grid, outside any GridRow, is a row of its own
// across every column.
import PolymerBase
import PolymerRender

public struct Grid<Content: View>: View, PrimitiveView {
    let alignment: Alignment
    let horizontalSpacing: Double?
    let verticalSpacing: Double?
    let content: Content

    public init(alignment: Alignment = .center, horizontalSpacing: Double? = nil, verticalSpacing: Double? = nil,
                @ViewBuilder content: () -> Content) {
        self.alignment = alignment; self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing; self.content = content()
    }
    public var body: Never { fatalError("Grid is a built-in view") }

    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? GridNode) ?? GridNode()
        n.alignment = alignment
        n.hSpacing = horizontalSpacing ?? defaultSpacing
        n.vSpacing = verticalSpacing ?? defaultSpacing
        var c = c
        c.stackAxis = .vertical   // a Divider between rows runs across
        n.setChild(0, content, c)
        return n
    }
}

/// One row of a `Grid`: each view in it is a cell, in column order.
public struct GridRow<Content: View>: View, PrimitiveView {
    let alignment: VerticalAlignment?
    let content: Content
    public init(alignment: VerticalAlignment? = nil, @ViewBuilder content: () -> Content) {
        self.alignment = alignment; self.content = content()
    }
    public var body: Never { fatalError("GridRow is a built-in view") }

    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? GridRowNode) ?? GridRowNode()
        n.alignment = alignment
        var c = c
        c.stackAxis = .horizontal   // a Divider between cells runs down
        n.setChild(0, content, c)
        return n
    }
}

extension View {
    /// In a `GridRow`, makes the cell span `count` columns.
    public func gridCellColumns(_ count: Int) -> some View { GridSpanView(content: self, columns: max(1, count)) }
}

struct GridSpanView<Content: View>: View, PrimitiveView {
    let content: Content
    let columns: Int
    var body: Never { fatalError("GridSpanView is a built-in view") }
    func resolve(_ existing: Node?, _ c: ResolveContext) -> Node {
        let n = (existing as? GridSpanNode) ?? GridSpanNode()
        if n.columns != columns { n.columns = columns; n.invalidateLayout() }
        n.setChild(0, content, c)
        return n
    }
}

/// A cell that spans several columns; sized and placed as its content.
final class GridSpanNode: Node {
    var columns = 1
    override var isElement: Bool { false }
    override func sizeThatFits(_ p: ProposedViewSize) -> Size { children[0].measure(p) }
    override func placeChildren(in r: Rect) { children[0].place(r) }
}

final class GridRowNode: Node {
    var alignment: VerticalAlignment?
    override var role: String { "GridRow" }
    /// The cells, in column order.
    var cells: [Node] { children.first?.flattened ?? [] }
    // The grid measures and places the cells; the row only takes its rectangle.
    override func placeChildren(in r: Rect) {}
}

final class GridNode: Node {
    var alignment = Alignment.center
    var hSpacing = defaultSpacing, vSpacing = defaultSpacing

    override var role: String { "Grid" }

    /// A row: its cells with the first column and span of each, or one view across the grid.
    private struct Row {
        var node: Node
        var cells: [(node: Node, column: Int, span: Int)]
        var spansAll: Bool
    }

    private func rows() -> (rows: [Row], columns: Int) {
        var out: [Row] = []
        var columns = 0
        for n in children.first?.flattened ?? [] {
            if let r = n as? GridRowNode {
                var col = 0
                var cells: [(Node, Int, Int)] = []
                for cell in r.cells {
                    let span = (cell as? GridSpanNode)?.columns ?? 1
                    cells.append((cell, col, span))
                    col += span
                }
                columns = max(columns, col)
                out.append(Row(node: r, cells: cells, spansAll: false))
            } else {
                out.append(Row(node: n, cells: [], spansAll: true))
            }
        }
        return (out, max(columns, out.contains { $0.spansAll } ? 1 : 0))
    }

    /// Column widths and row heights for a proposal.
    private func tracks(_ p: ProposedViewSize, _ rows: [Row], _ columns: Int) -> (widths: [Double], heights: [Double]) {
        guard columns > 0 else { return ([], rows.map { _ in 0 }) }
        // Width of column j for an offered width: its widest single-column cell.
        func columnWidth(_ j: Int, _ w: Double?) -> Double {
            var m = 0.0
            for r in rows { for c in r.cells where c.column == j && c.span == 1 { m = max(m, c.node.measure(ProposedViewSize(width: w, height: nil)).width) } }
            return m
        }
        var widths = [Double](repeating: 0, count: columns)
        if let total = p.width {
            // As a stack shares its length: least flexible columns first, each taking an even share of what is left.
            let flex = (0..<columns).map { columnWidth($0, .infinity) - columnWidth($0, 0) }
            let order = (0..<columns).sorted { flex[$0] < flex[$1] || (flex[$0] == flex[$1] && $0 < $1) }
            var remaining = max(0, total - hSpacing * Double(columns - 1))
            for (k, j) in order.enumerated() {
                let w = columnWidth(j, remaining / Double(columns - k))
                widths[j] = w
                remaining = max(0, remaining - w)
            }
        } else {
            for j in 0..<columns { widths[j] = columnWidth(j, nil) }
        }
        // Cells spanning several columns widen them evenly when they need more room.
        for r in rows {
            for c in r.cells where c.span > 1 {
                let cols = c.column..<min(columns, c.column + c.span)
                let have = cols.reduce(0) { $0 + widths[$1] } + hSpacing * Double(cols.count - 1)
                let need = c.node.measure(ProposedViewSize(width: p.width == nil ? nil : have, height: nil)).width
                if need > have { for j in cols { widths[j] += (need - have) / Double(cols.count) } }
            }
        }
        let full = widths.reduce(0, +) + hSpacing * Double(columns - 1)
        func cellWidth(_ c: (node: Node, column: Int, span: Int)) -> Double {
            let cols = c.column..<min(columns, c.column + c.span)
            return cols.reduce(0) { $0 + widths[$1] } + hSpacing * Double(max(0, cols.count - 1))
        }
        func rowHeight(_ r: Row, _ h: Double?) -> Double {
            if r.spansAll { return r.node.measure(ProposedViewSize(width: full, height: h)).height }
            return r.cells.reduce(0) { max($0, $1.node.measure(ProposedViewSize(width: cellWidth($1), height: h)).height) }
        }
        var heights = [Double](repeating: 0, count: rows.count)
        if let total = p.height, !rows.isEmpty {
            let flex = rows.map { rowHeight($0, .infinity) - rowHeight($0, 0) }
            let order = rows.indices.sorted { flex[$0] < flex[$1] || (flex[$0] == flex[$1] && $0 < $1) }
            var remaining = max(0, total - vSpacing * Double(rows.count - 1))
            for (k, i) in order.enumerated() {
                let h = rowHeight(rows[i], remaining / Double(rows.count - k))
                heights[i] = h
                remaining = max(0, remaining - h)
            }
        } else {
            for (i, r) in rows.enumerated() { heights[i] = rowHeight(r, nil) }
        }
        return (widths, heights)
    }

    override func sizeThatFits(_ p: ProposedViewSize) -> Size {
        let (rs, columns) = rows()
        let (w, h) = tracks(p, rs, columns)
        guard !rs.isEmpty else { return .zero }
        return Size(width: w.reduce(0, +) + hSpacing * Double(max(0, columns - 1)),
                    height: h.reduce(0, +) + vSpacing * Double(rs.count - 1))
    }

    override func placeChildren(in r: Rect) {
        let (rs, columns) = rows()
        let (widths, heights) = tracks(ProposedViewSize(r.size), rs, columns)
        var xs: [Double] = []
        var x = r.minX
        for w in widths { xs.append(x); x += w + hSpacing }
        let full = widths.reduce(0, +) + hSpacing * Double(max(0, columns - 1))
        var y = r.minY
        for (i, row) in rs.enumerated() {
            let h = heights[i]
            let rowRect = Rect(x: r.minX, y: y, width: full, height: h)
            if row.spansAll {
                let s = row.node.measure(ProposedViewSize(rowRect.size))
                row.node.place(Rect(origin: alignment.origin(of: s, in: rowRect), size: s))
            } else {
                row.node.place(rowRect)
                let a = Alignment(horizontal: alignment.horizontal, vertical: (row.node as? GridRowNode)?.alignment ?? alignment.vertical)
                for c in row.cells {
                    let cols = c.column..<min(columns, c.column + c.span)
                    let w = cols.reduce(0) { $0 + widths[$1] } + hSpacing * Double(max(0, cols.count - 1))
                    let cell = Rect(x: xs[c.column], y: y, width: w, height: h)
                    let s = c.node.measure(ProposedViewSize(cell.size))
                    c.node.place(Rect(origin: a.origin(of: s, in: cell), size: s))
                }
            }
            y += h + vSpacing
        }
    }
}
