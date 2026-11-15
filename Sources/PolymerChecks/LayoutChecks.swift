// Checks for drag gestures, Grid and GridRow, and GeometryReader.
import PolymerBase
import PolymerRender
import PolymerUI

@Observable
final class DragModel {
    var offset = Point.zero
    var changes = 0
    var ended: DragGesture.Value?
    var taps = 0
}

struct DragScreen: View {
    let model: DragModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A tile that follows the pointer while dragged, and is also a button.
            Button { model.taps += 1 } label: { Color.white.frame(width: 40, height: 40) }
                .offset(x: model.offset.x, y: model.offset.y)
                .gesture(DragGesture()
                    .onChanged { v in model.changes += 1; model.offset = Point(x: v.translation.width, y: v.translation.height) }
                    .onEnded { v in model.ended = v })
            Color(white: 0.3).frame(width: 40, height: 40)
        }
        .frame(width: 200, height: 120, alignment: .topLeading)
    }
}

@MainActor let layoutChecks: [Check] = [
    Check("ui.drag") { c in
        let model = DragModel()
        let tree = ViewTree(DragScreen(model: model))
        tree.time = 0
        _ = tree.render()

        // Under the minimum distance it is a click.
        tree.drag(from: Point(x: 20, y: 20), to: Point(x: 24, y: 23))
        c.expectEqual(model.taps, 1, "so the button runs")
        c.expectEqual(model.changes, 0, "and the drag saw nothing")

        // Further: the drag takes the press and follows the pointer.
        tree.pointerDown(at: Point(x: 20, y: 20))
        tree.time = 0.05
        tree.pointerMoved(to: Point(x: 26, y: 20))
        c.expectEqual(model.changes, 0, "6 points: not yet")
        tree.time = 0.1
        tree.pointerMoved(to: Point(x: 32, y: 20))
        c.expectEqual(model.changes, 1, "12 points: the drag begins")
        _ = tree.render()
        c.expect(tree.elementTree.contains("Color (12, 0, 40x40)"), "the tile followed:\n\(tree.elementTree)")
        tree.time = 0.2
        tree.pointerMoved(to: Point(x: 52, y: 30))
        tree.time = 0.3
        tree.pointerMoved(to: Point(x: 72, y: 40))
        c.expect(tree.pointerUp(at: Point(x: 72, y: 40)), "letting go ends the drag")
        c.expectEqual(model.taps, 1, "the button under the drag did not run")
        if let v = model.ended {
            c.expectEqual(v.translation, Size(width: 52, height: 20), "translation from where it started")
            c.expectEqual(v.startLocation, Point(x: 20, y: 20), "start in the view's own coordinates (it hadn't moved yet)")
            c.expectClose(v.velocity.width, 200, tolerance: 1e-9, "speed over the last tenth of a second: 20 points in 0.1 s")
            c.expectClose(v.velocity.height, 100, tolerance: 1e-9, "and 10 points down")
            c.expectEqual(v.predictedEndTranslation, Size(width: 152, height: 70), "a flick goes on half a second at that speed")
        } else {
            c.expect(false, "onEnded ran")
        }
        _ = tree.render()
        c.expect(tree.elementTree.contains("Color (52, 20, 40x40)"), "the tile stays where it was let go:\n\(tree.elementTree)")

        // Minimum distance 0: the press is a drag at once.
        var seen: [Size] = []
        let t2 = ViewTree(Color.white.frame(width: 50, height: 50)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global).onChanged { seen.append($0.translation) }))
        _ = t2.render()
        t2.click(at: Point(x: 10, y: 10))
        c.expectEqual(seen, [Size(width: 0, height: 0)], "a click is a drag of nothing")
        // A press beside what the view draws starts nothing.
        let t3 = ViewTree(VStack { Color.white.frame(width: 50, height: 50).gesture(DragGesture().onChanged { _ in seen.append(.zero) }) }
            .frame(width: 100, height: 100))
        _ = t3.render()
        t3.drag(from: Point(x: 5, y: 5), to: Point(x: 60, y: 60))
        c.expectEqual(seen.count, 1, "nothing drawn there, no drag")
    },

    Check("ui.grid-plain") { c in
        let font = Font(try TextReference.font(root: c.root, "Geist-Regular.otf"), size: 13)
        // Columns as wide as their widest cell, rows as tall as their tallest.
        let grid = Grid(alignment: .topLeading, horizontalSpacing: 4, verticalSpacing: 2) {
            GridRow {
                Color.white.frame(width: 30, height: 10)
                Color.white.frame(width: 10, height: 20)
                Color.white.frame(width: 15, height: 10)
            }
            GridRow(alignment: .bottom) {
                Color(white: 0.5).frame(width: 50, height: 10)
                Color(white: 0.5).frame(width: 5, height: 5)
            }
            Color(white: 0.2).frame(width: 20, height: 6)
            GridRow {
                Color(white: 0.7).frame(width: 60, height: 8).gridCellColumns(2)
                Text("x")
            }
        }
        let tree = ViewTree(grid.font(font))
        let lines = tree.elementTree.split(separator: "\n").map { String($0.drop { $0 == " " }) }
        let colors = lines.filter { $0.hasPrefix("Color (") }.map { String($0.prefix { $0 != "#" }).trimmingSpaces }
        // Columns: max(30, 50) = 50, then 10 (60 spanning two columns fits 50 + 4 + 10 = 64), then 15 and the text.
        c.expectEqual(colors, [
            "Color (0, 0, 30x10)", "Color (54, 0, 10x20)", "Color (68, 0, 15x10)",
            "Color (0, 22, 50x10)", "Color (54, 27, 5x5)",
            "Color (0, 34, 20x6)",
            "Color (0, 42, 60x8)",
        ], "cells in their columns and rows:\n\(lines.joined(separator: "\n"))")
        c.expect(lines.first?.hasPrefix("Grid (0, 0, ") == true && lines.contains { $0.hasPrefix("GridRow (0, 22, ") }, "grid and rows in the element tree:\n\(lines.joined(separator: "\n"))")
        c.expect(lines.contains { $0.hasPrefix("Text (68, 42, ") }, "the text after the spanning cell:\n\(lines.joined(separator: "\n"))")

        // Offered a width, flexible cells share what is left, as in a stack.
        let flexible = ViewTree(Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                Color.white.frame(width: 40, height: 10)
                Color(white: 0.5).frame(height: 10)
                Color(white: 0.6).frame(maxWidth: 30).frame(height: 10)
            }
        })
        flexible.proposedSize = ProposedViewSize(width: 200, height: nil)
        let fl = flexible.elementTree.split(separator: "\n").map { String($0.drop { $0 == " " }) }.filter { $0.hasPrefix("Color (") }
        c.expectEqual(fl.map { String($0.prefix { $0 != "#" }).trimmingSpaces }, [
            "Color (0, 0, 40x10)", "Color (40, 0, 130x10)", "Color (170, 0, 30x10)",
        ], "fixed 40, capped 30, the rest to the flexible column:\n\(fl.joined(separator: "\n"))")

        // Pixels: a grid draws exactly what the same cells placed by hand draw.
        let img = ImageRenderer(content: grid.font(font)).bitmap
        let byHand = ZStack(alignment: .topLeading) {
            Color.white.frame(width: 30, height: 10)
            Color.white.frame(width: 10, height: 20).offset(x: 54)
            Color.white.frame(width: 15, height: 10).offset(x: 68)
            Color(white: 0.5).frame(width: 50, height: 10).offset(y: 22)
            Color(white: 0.5).frame(width: 5, height: 5).offset(x: 54, y: 27)
            Color(white: 0.2).frame(width: 20, height: 6).offset(y: 34)
            Color(white: 0.7).frame(width: 60, height: 8).offset(y: 42)
            Text("x").offset(x: 68, y: 42)
        }.font(font).frame(width: Double(img.width), height: Double(img.height), alignment: .topLeading)
        c.expect(img == ImageRenderer(content: byHand).bitmap, "same pixels as placing the cells by hand")
    },

    Check("ui.geometry") { c in
        @MainActor final class Box { var proxies: [GeometryProxy] = [] }
        let box = Box()
        let model = AnimationModel()
        struct Screen: View {
            let model: AnimationModel
            let box: Box
            var body: some View {
                VStack(spacing: 0) {
                    Color.white.frame(height: model.wide ? 30 : 10)
                    GeometryReader { proxy in
                        let _ = box.proxies.append(proxy)
                        Color(white: 0.5).frame(width: proxy.size.width / 2, height: proxy.size.height / 2)
                    }
                }
                .frame(width: 100, height: 70)
            }
        }
        let tree = ViewTree(Screen(model: model, box: box))
        let lines = tree.elementTree.split(separator: "\n").map { String($0.drop { $0 == " " }) }
        c.expect(lines.contains("GeometryReader (0, 10, 100x60)"), "takes the space offered:\n\(lines.joined(separator: "\n"))")
        c.expect(lines.contains { $0.hasPrefix("Color (0, 10, 50x30)") }, "content built from its size, at the top-leading corner:\n\(lines.joined(separator: "\n"))")
        c.expectEqual(box.proxies.last?.frame(in: .global), Rect(x: 0, y: 10, width: 100, height: 60), "global frame")
        c.expectEqual(box.proxies.last?.frame(in: .local), Rect(x: 0, y: 0, width: 100, height: 60), "local frame")
        let builds = box.proxies.count
        _ = tree.render()
        c.expectEqual(box.proxies.count, builds, "nothing changed: not built again")
        model.wide = true
        let after = tree.elementTree.split(separator: "\n").map { String($0.drop { $0 == " " }) }
        c.expect(after.contains("GeometryReader (0, 30, 100x40)") && after.contains { $0.hasPrefix("Color (0, 30, 50x20)") },
                 "a new size builds the content again:\n\(after.joined(separator: "\n"))")
        c.expect(ViewTree(GeometryReader { _ in Color.white }).elementTree.hasPrefix("GeometryReader (0, 0, 10x10)"), "offered nothing, 10 by 10 as in SwiftUI")
    },
]

extension String {
    var trimmingSpaces: String {
        var s = Substring(self)
        while s.last == " " { s.removeLast() }
        while s.first == " " { s.removeFirst() }
        return String(s)
    }
}
