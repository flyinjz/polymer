import PolymerBase
import PolymerPlatform
import PolymerText
import PolymerRender
import PolymerUI

// MARK: Sample screens (also used by `polymer render` and `polymer tree`)

/// A static sample screen.
public struct SampleAlbumsView: View {
    let mono: Font, sans: Font
    public init(mono: Font, sans: Font) { self.mono = mono; self.sans = sans }

    let albums = [("Album One", "Artist A", "12 tracks"), ("Second Record", "Artist B", "9 tracks"),
                  ("Third Volume", "Artist C", "14 tracks")]

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Albums").font(sans)
                Spacer()
                Text("3 of 48").font(mono).foregroundStyle(Color(white: 0.6))
            }
            .padding(horizontal: 16, vertical: 12)
            Divider()
            ForEach(albums.indices) { i in
                HStack(spacing: 12) {
                    Rectangle().foregroundStyle(Color(white: 0.22)).frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(albums[i].0).font(sans)
                        Text(albums[i].1).font(mono).foregroundStyle(Color(white: 0.6))
                    }
                    Spacer()
                    Text(albums[i].2).font(mono).foregroundStyle(Color(white: 0.6))
                }
                .padding(horizontal: 16, vertical: 8)
            }
        }
        .frame(width: 360)
        .background(Color(white: 0.063))
        .border(Color(white: 1, opacity: 0.14))
    }
}

@MainActor
public func sampleAlbums(root: String) throws -> SampleAlbumsView {
    SampleAlbumsView(mono: Font(try TextReference.font(root: root, "GeistMono-Regular.otf"), size: 11),
                     sans: Font(try TextReference.font(root: root, "Geist-Regular.otf"), size: 13))
}

/// State for the counter sample: an observable object shared by several views.
@Observable
public final class CounterModel {
    public var count = 0
    public var title = "Counter"
    public var unrelated = 0
    public init() {}
}

struct TitleLabel: View {
    let model: CounterModel
    var body: some View { Text(model.title) }
}

struct CountLabel: View {
    let model: CounterModel
    var body: some View { Text("Count \(model.count)").foregroundStyle(Color(white: 0.6)) }
}

/// A row with state of its own.
struct StepRow: View {
    @State private var steps = 0
    var body: some View {
        HStack(spacing: 12) {
            Text("Steps \(steps)")
            Button("Step") { steps += 1 }
        }
    }
}

/// A small interactive sample: an observable model, a view with its own state, two buttons.
public struct SampleCounterView: View {
    let model: CounterModel
    let font: Font
    public init(model: CounterModel, font: Font) { self.model = model; self.font = font }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TitleLabel(model: model)
            CountLabel(model: model)
            Button(action: { model.count += 1 }) {
                Text("Add").padding(horizontal: 12, vertical: 6).border(Color(white: 1, opacity: 0.14))
            }
            StepRow()
        }
        .font(font)
        .padding(16)
        .frame(width: 240, alignment: .leading)
        .background(Color(white: 0.063))
    }
}

@MainActor
public func sampleCounter(root: String, model: CounterModel = CounterModel()) throws -> SampleCounterView {
    SampleCounterView(model: model, font: Font(try TextReference.font(root: root, "Geist-Regular.otf"), size: 13))
}

struct TrackRow: View {
    let index: Int
    @State private var picked = false
    var body: some View {
        Button(action: { picked.toggle() }) {
            Text(picked ? "Track \(index + 1) (picked)" : "Track \(index + 1)")
                .padding(horizontal: 16, vertical: 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A list longer than its window: a header over a scroll view of forty rows.
public struct SampleListView: View {
    let font: Font
    public init(font: Font) { self.font = font }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Tracks").padding(horizontal: 16, vertical: 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<40) { TrackRow(index: $0) }
                }
            }
        }
        .font(font)
        .frame(width: 240, height: 200)
        .background(Color(white: 0.063))
    }
}

@MainActor
public func sampleList(root: String) throws -> SampleListView {
    SampleListView(font: Font(try TextReference.font(root: root, "Geist-Regular.otf"), size: 13))
}

/// A long list in a lazy stack: only the rows in view are built.
public struct SampleLibraryView: View {
    let font: Font, title: String, count: Int
    public init(font: Font, title: String = "Library", count: Int = 20_000) {
        self.font = font; self.title = title; self.count = count
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).padding(horizontal: 16, vertical: 10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<count) { TrackRow(index: $0) }
                }
            }
        }
        .font(font)
        .frame(width: 240, height: 200)
        .background(Color(white: 0.063))
    }
}

@MainActor
public func sampleLibrary(root: String, title: String = "Library", count: Int = 20_000) throws -> SampleLibraryView {
    SampleLibraryView(font: Font(try TextReference.font(root: root, "Geist-Regular.otf"), size: 13), title: title, count: count)
}

/// The sample screens by name, as live trees.
@MainActor
public func sampleTree(_ name: String, root: String, scale: Double = 1) throws -> ViewTree? {
    var e = EnvironmentValues()
    e.displayScale = scale
    switch name {
    case "sample", "albums": return ViewTree(try sampleAlbums(root: root), environment: e)
    case "counter": return ViewTree(try sampleCounter(root: root), environment: e)
    case "list": return ViewTree(try sampleList(root: root), environment: e)
    case "library": return ViewTree(try sampleLibrary(root: root), environment: e)
    default: return nil
    }
}
public let sampleScreenNames = ["albums", "counter", "list", "library"]

// MARK: Views used by the identity checks

@Observable
final class ListModel {
    var items = ["a", "b", "c"]
    var flag = true
    var epoch = 0
}

struct ItemRow: View {
    let name: String
    @State private var taps = 0
    var body: some View {
        Button("\(name) \(taps)") { taps += 1 }
    }
}

struct ListScreen: View {
    let model: ListModel
    let font: Font
    var body: some View {
        VStack(alignment: .leading) {
            ForEach(model.items, id: \.self) { ItemRow(name: $0) }
            if model.flag { ItemRow(name: "branch") } else { ItemRow(name: "branch") }
            ItemRow(name: "keyed").id(model.epoch)
        }
        .font(font)
    }
}

// MARK: Views used by the focus check

enum FocusField: Hashable { case name, notes }

@Observable
final class FocusModel {
    var presses = 0
    var log: [String] = []
}

struct FocusScreen: View {
    let model: FocusModel
    let font: Font
    @FocusState private var field: FocusField?
    @State private var showNotes = true
    var body: some View {
        VStack(alignment: .leading) {
            Text("Field \(field.map { "\($0)" } ?? "none")")
            Button("Add") { model.presses += 1 }
            Text("Name").padding(4).focusable().focused($field, equals: .name)
            if showNotes { Text("Notes").padding(4).focusable().focused($field, equals: .notes) }
            Button("Focus notes") { field = .notes }
            Button("Hide notes") { showNotes = false }
        }
        .onKeyPress(.downArrow) { model.log.append("down"); return .handled }
        .font(font)
    }
}

struct LazyListScreen: View {
    let model: ListModel
    let font: Font
    var body: some View {
        LazyVStack(alignment: .leading) { ForEach(model.items, id: \.self) { ItemRow(name: $0) } }.font(font)
    }
}

struct FieldEditor: View {
    @Binding var value: Int
    var body: some View { Button("Raise") { value += 10 } }
}

struct BindingScreen: View {
    @State private var value = 1
    @Environment(\.lineLimit) private var limit
    var body: some View {
        VStack {
            Text("Value \(value) limit \(limit ?? 0)")
            FieldEditor(value: $value)
        }
    }
}

@MainActor let uiChecks: [Check] = [
    Check("ui.layout") { c in
        var r = ImageRenderer(content: try sampleAlbums(root: c.root))
        let tree = r.elementTree
        let lines = tree.split(separator: "\n")
        c.expect(lines.first?.hasPrefix("SampleAlbumsView (0, 0, 360x") == true, "the view itself is the root element: \(lines.first ?? "")")
        c.expect(lines.dropFirst().first?.hasPrefix("  Color (0, 0, 360x") == true, "the background comes first (drawing order)")
        c.expect(lines.contains { $0.hasPrefix("  VStack (0, 0, 360x") }, "its stack fills 360 points")
        c.expect(lines.last?.hasPrefix("  Border (0, 0, 360x") == true, "the border comes last")
        c.expect(tree.contains("Text (16, 12, ") && tree.contains("\"Albums\""), "title at the padding inset")
        c.expect(tree.contains("Divider (0, "), "divider spans the width")
        c.expect(lines.contains { $0.contains("Rectangle (16, ") && $0.contains("40x40") }, "artwork is 40x40 at the inset")
        // Deterministic: the same tree twice.
        c.expectEqual(r.elementTree, tree, "element tree is stable")
        r.scale = 2
        let bmp = r.bitmap
        c.expect(bmp.width == 720, "2x image is 720 pixels wide, got \(bmp.width)")
        try Platform.files.createDirectory(Path.join(c.outputDirectory, "ui"))
        try Platform.files.write(PNG.encode(bmp), to: Path.join(c.outputDirectory, "ui/sample-albums@2x.png"))
        try Platform.files.write(tree, to: Path.join(c.outputDirectory, "ui/sample-albums.txt"))
        c.note("sample screen and element tree in \(c.outputDirectory)/ui")
    },
    Check("ui.stack-distribution") { c in
        var r = ImageRenderer(content: HStack(spacing: 10) {
            Rectangle().frame(width: 50)
            Rectangle()
            Rectangle()
        })
        r.proposedSize = ProposedViewSize(width: 300, height: 20)
        let tree = r.elementTree
        // 300 - 2 gaps - 50 fixed = 230, split evenly between the flexible two.
        c.expect(tree.contains("Rectangle (60, 0, 115x20)") && tree.contains("Rectangle (185, 0, 115x20)"),
                 "flexible children share the rest:\n\(tree)")
    },
    Check("ui.state") { c in
        let model = CounterModel()
        let tree = ViewTree(try sampleCounter(root: c.root, model: model))
        c.expect(tree.elementTree.contains("\"Count 0\""), "starts at 0:\n\(tree.elementTree)")
        c.expectEqual(tree.bodyEvaluations, 4, "one evaluation per view with a body")

        // An observable property: only the view that reads it runs again.
        c.expect(tree.click(text: "Add"), "the Add button handles a click")
        c.expect(tree.needsUpdate, "a change the tree depends on asks for an update")
        c.expect(tree.update(), "update reports the change")
        c.expect(tree.elementTree.contains("\"Count 1\""), "count shown after the click")
        c.expectEqual(tree.bodyEvaluations, 5, "only CountLabel was evaluated again")

        // A property no view reads costs nothing.
        model.unrelated += 1
        c.expect(!tree.needsUpdate && !tree.update(), "an unread property does not invalidate anything")
        c.expectEqual(tree.bodyEvaluations, 5, "no evaluation for an unread property")

        // @State: kept between updates, and private to its view.
        c.expect(tree.click(text: "Step") && tree.click(text: "Step"), "the Step button handles clicks")
        c.expect(tree.elementTree.contains("\"Steps 2\""), "state counts two clicks")
        c.expectEqual(tree.bodyEvaluations, 7, "only StepRow was evaluated, once per click")

        // Several changes before an update are one evaluation.
        model.count += 1; model.count += 1; model.count += 1
        tree.update()
        c.expectEqual(tree.bodyEvaluations, 8, "three changes, one evaluation")
        c.expect(tree.elementTree.contains("\"Count 4\""), "all three changes shown")

        // A change elsewhere leaves a view's state alone.
        model.title = "Renamed"
        tree.update()
        c.expect(tree.elementTree.contains("\"Renamed\"") && tree.elementTree.contains("\"Steps 2\""), "title changed, steps kept")
        c.expectEqual(tree.bodyEvaluations, 9, "only TitleLabel was evaluated")

        // Evaluating everything again (a new root value) keeps state and leaves no stale dependencies behind.
        for _ in 0..<3 { tree.setRoot(try sampleCounter(root: c.root, model: model)); tree.update() }
        c.expectEqual(tree.bodyEvaluations, 21, "three full evaluations of four views")
        c.expect(tree.elementTree.contains("\"Steps 2\""), "state survives a new root value")
        model.count += 1
        tree.update()
        c.expectEqual(tree.bodyEvaluations, 22, "one change still means one evaluation")

        // Layout follows the new text.
        let before = tree.elementTree
        model.title = "A much longer title than before"
        tree.update()
        c.expect(tree.elementTree != before, "layout updated after a change")
        try Platform.files.createDirectory(Path.join(c.outputDirectory, "ui"))
        try Platform.files.write(PNG.encode(tree.render()), to: Path.join(c.outputDirectory, "ui/sample-counter.png"))
    },
    Check("ui.identity") { c in
        let model = ListModel()
        let font = Font(try TextReference.font(root: c.root, "Geist-Regular.otf"), size: 13)
        let tree = ViewTree(ListScreen(model: model, font: font))
        c.expect(tree.click(text: "b 0"), "row b handles a click")
        c.expect(tree.elementTree.contains("\"b 1\""), "row b counted the click")

        // ForEach: state follows the element's id through reordering and removal.
        model.items = ["c", "b", "a"]
        tree.update()
        let reordered = tree.elementTree
        c.expect(reordered.contains("\"b 1\"") && reordered.contains("\"a 0\"") && reordered.contains("\"c 0\""), "state follows ids:\n\(reordered)")
        let order = reordered.split(separator: "\n").filter { $0.contains("Text") }.prefix(3).map { String($0.split(separator: "\"")[1]) }
        c.expectEqual(order, ["c 0", "b 1", "a 0"], "rows are in the new order")
        model.items = ["c", "a"]
        tree.update()
        model.items = ["c", "a", "b"]
        tree.update()
        c.expect(tree.elementTree.contains("\"b 0\""), "a removed element comes back with fresh state")

        // if/else: each branch has its own state.
        c.expect(tree.click(text: "branch 0"), "branch row handles a click")
        c.expect(tree.elementTree.contains("\"branch 1\""), "branch row counted")
        model.flag = false
        tree.update()
        c.expect(tree.elementTree.contains("\"branch 0\""), "the other branch starts fresh")

        // .id: a new id rebuilds the view.
        c.expect(tree.click(text: "keyed 0"), "keyed row handles a click")
        c.expect(tree.elementTree.contains("\"keyed 1\""), "keyed row counted")
        model.epoch += 1
        tree.update()
        c.expect(tree.elementTree.contains("\"keyed 0\""), "a new id resets state")

        // @Binding writes through to the owner's @State; @Environment reads the value at the view's place.
        let b = ViewTree(BindingScreen().font(font).lineLimit(3))
        c.expect(b.elementTree.contains("\"Value 1 limit 3\""), "binding screen starts:\n\(b.elementTree)")
        c.expect(b.click(text: "Raise"), "the child button handles a click")
        c.expect(b.elementTree.contains("\"Value 11 limit 3\""), "the binding changed the owner's state")
    },
    Check("ui.input") { c in
        let font = Font(try TextReference.font(root: c.root, "Geist-Regular.otf"), size: 13)
        var presses = 0, taps = 0
        let tree = ViewTree(VStack(spacing: 20) {
            Button(action: { presses += 1 }) { Text("Press").padding(20) }
            Text("Tap").onTapGesture { taps += 1 }
        }.padding(10).font(font))
        tree.update()
        // The button's padding is part of the button; the stack's padding and the gap are not.
        c.expect(tree.click(at: Point(x: 14, y: 14)), "a click on the label's padding presses the button")
        c.expectEqual(presses, 1, "button action ran once")
        c.expect(!tree.click(at: Point(x: 2, y: 2)), "a click on empty space does nothing")
        c.expect(tree.click(text: "Tap"), "a tap handler runs when its text is clicked")
        c.expectEqual(taps, 1, "tap action ran once")
        c.expect(!tree.click(text: "Missing"), "clicking text that is not there reports false")
    },
    Check("ui.scroll") { c in
        let tree = ViewTree(try sampleList(root: c.root))
        // The y position of the element line that contains `text`: "Text (16, 44, ...".
        @MainActor func y(_ text: String) -> Double? {
            guard let line = tree.elementTree.split(separator: "\n").first(where: { $0.contains("\"\(text)\"") }) else { return nil }
            let parts = line.split(separator: ",")
            return parts.count > 1 ? Double(parts[1].drop(while: { $0 == " " })) : nil
        }
        let first = tree.elementTree
        c.expect(first.contains("ScrollView (0, ") && first.contains("offset 0,0"), "scroll view starts at the top:\n\(first.prefix(400))")
        let evaluations = tree.bodyEvaluations
        guard let y1 = y("Track 1"), let y11 = y("Track 11") else { c.fail("rows are missing from the element tree"); return }
        let row = (y11 - y1) / 10
        c.expect(row > 20, "rows are laid out one under another (\(row) points apart)")
        c.expect(!tree.click(text: "Track 30"), "a row outside the window can't be clicked")
        let before = tree.render()

        // Scrolling moves the content without evaluating or laying out anything.
        c.expect(tree.scroll(at: Point(x: 120, y: 120), dy: row * 10), "the list scrolls")
        c.expect(!tree.needsUpdate, "scrolling needs no update")
        c.expectEqual(tree.bodyEvaluations, evaluations, "scrolling evaluates no body")
        c.expectEqual(y("Track 11"), y1, "row 11 is now where row 1 was")
        c.expect(tree.render() != before, "the image changed")
        c.expect(tree.click(text: "Track 12"), "a row scrolled into view can be clicked")
        c.expect(tree.elementTree.contains("\"Track 12 (picked)\""), "the clicked row changed")
        c.expectEqual(tree.bodyEvaluations, evaluations + 1, "only the clicked row was evaluated")

        // Limits, and where scrolling applies.
        c.expect(tree.scroll(at: Point(x: 120, y: 120), dy: 100_000), "scrolls to the end")
        c.expect(!tree.scroll(at: Point(x: 120, y: 120), dy: 10), "stops at the end")
        c.expect(tree.elementTree.contains("\"Track 40\""), "the last row exists")
        c.expect((y("Track 40") ?? 0) < 200, "the last row is inside the window at the end")
        c.expect(!tree.scroll(at: Point(x: 120, y: 10), dy: 10), "the header does not scroll")
        try Platform.files.createDirectory(Path.join(c.outputDirectory, "ui"))
        try Platform.files.write(PNG.encode(tree.render()), to: Path.join(c.outputDirectory, "ui/sample-list-end.png"))
    },
    Check("ui.lazy") { c in
        // The same forty rows draw identically in a lazy stack and in a plain one, scrolled or not.
        let plain = ViewTree(try sampleList(root: c.root))
        let lazy40 = ViewTree(try sampleLibrary(root: c.root, title: "Tracks", count: 40))
        c.expect(lazy40.render() == plain.render(), "a lazy stack draws like a plain one at the top")
        for (dy, at) in [(290.0, "the middle"), (100_000.0, "the end")] {
            plain.scroll(at: Point(x: 120, y: 120), dy: dy)
            lazy40.scroll(at: Point(x: 120, y: 120), dy: dy)
            c.expect(lazy40.render() == plain.render(), "a lazy stack draws like a plain one at \(at)")
        }

        let tree = ViewTree(try sampleLibrary(root: c.root))
        @MainActor func y(_ text: String) -> Double? {
            guard let line = tree.elementTree.split(separator: "\n").first(where: { $0.contains("\"\(text)\"") }) else { return nil }
            let parts = line.split(separator: ",")
            return parts.count > 1 ? Double(parts[1].drop(while: { $0 == " " })) : nil
        }
        let first = tree.elementTree
        let start = tree.bodyEvaluations
        c.expect(start < 20, "only the rows in view are built (\(start) bodies evaluated for 20,000 rows)")
        c.expect(first.contains("of 20000"), "the lazy stack knows all 20,000 rows:\n\(first.prefix(600))")
        c.expect(first.contains("\"Track 1\"") && !first.contains("\"Track 20\""), "the element tree lists only rows in view")
        guard let y1 = y("Track 1"), let y2 = y("Track 2") else { c.fail("rows are missing from the element tree"); return }
        let row = y2 - y1
        c.expect(first.contains("content 240x\(Int(row * 20_000))"), "content length is every row's length:\n\(first.prefix(600))")

        // Scrolling builds only the rows that come into view.
        c.expect(tree.scroll(at: Point(x: 120, y: 120), dy: row * 10), "the list scrolls")
        c.expect(tree.needsUpdate, "rows coming into view need an update")
        c.expectEqual(y("Track 11"), y1, "row 11 is now where row 1 was")
        let scrolled = tree.bodyEvaluations
        c.expect(scrolled - start <= 10, "scrolling ten rows builds about ten rows (\(scrolled - start))")
        c.expect(tree.scroll(at: Point(x: 120, y: 120), dy: 1), "the list scrolls by a point")
        c.expect(!tree.needsUpdate, "a scroll that brings no other row into view needs no update")
        c.expect(tree.click(text: "Track 12"), "a row scrolled into view can be clicked")
        c.expect(tree.elementTree.contains("\"Track 12 (picked)\""), "the clicked row changed")

        // State survives scrolling away and back.
        tree.scroll(at: Point(x: 120, y: 120), dy: -100_000)
        c.expect(!tree.elementTree.contains("Track 12"), "row 12 left the view")
        tree.scroll(at: Point(x: 120, y: 120), dy: row * 10)
        c.expect(tree.elementTree.contains("\"Track 12 (picked)\""), "row 12 kept its state")

        // The end, without building what lies between.
        let beforeEnd = tree.bodyEvaluations
        c.expect(tree.scroll(at: Point(x: 120, y: 120), dy: 1_000_000), "scrolls to the end")
        c.expect(tree.elementTree.contains("\"Track 20000\""), "the last row is built")
        c.expect((y("Track 20000") ?? 1000) < 200, "the last row is inside the window at the end")
        c.expect(tree.bodyEvaluations - beforeEnd <= 10, "jumping to the end builds only the rows there (\(tree.bodyEvaluations - beforeEnd))")
        c.expect(!tree.scroll(at: Point(x: 120, y: 120), dy: 10), "stops at the end")
        try Platform.files.createDirectory(Path.join(c.outputDirectory, "ui"))
        try Platform.files.write(PNG.encode(tree.render()), to: Path.join(c.outputDirectory, "ui/sample-library-end.png"))

        // Identity: state follows an element when the data changes; removed elements go.
        let model = ListModel()
        let font = Font(try TextReference.font(root: c.root, "Geist-Regular.otf"), size: 13)
        let ids = ViewTree(LazyListScreen(model: model, font: font))
        c.expect(ids.click(text: "b 0"), "an element of a lazy ForEach can be clicked")
        model.items = ["c", "b"]
        let after = ids.elementTree
        c.expect(after.contains("\"b 1\"") && after.contains("\"c 0\"") && !after.contains("\"a "), "state follows the element:\n\(after)")
    },
    Check("ui.focus") { c in
        let model = FocusModel()
        let tree = ViewTree(FocusScreen(model: model, font: Font(try TextReference.font(root: c.root, "Geist-Regular.otf"), size: 13)))
        @MainActor func focused() -> String { tree.focusedElement ?? "nothing" }
        c.expect(!tree.elementTree.contains("focused") && tree.elementTree.contains("\"Field none\""), "nothing has focus at first")

        // Tab, buttons and keys that travel outward.
        c.expect(tree.key("tab"), "Tab moves focus")
        c.expect(focused().hasPrefix("Button") && tree.elementTree.contains("focused"), "the first button has focus: \(focused())")
        c.expect(tree.key("space") && tree.key("return"), "Space and Return press the focused button")
        c.expectEqual(model.presses, 2, "button presses")
        c.expect(tree.key("tab"), "Tab again")
        c.expect(focused().contains("\"Name\""), "the focusable text has focus: \(focused())")
        c.expect(tree.elementTree.contains("\"Field name\""), "@FocusState follows focus moved by Tab")
        c.expect(tree.key("down"), "an arrow key reaches the stack's handler")
        c.expectEqual(model.log, ["down"], "keys go from the focused view outward")
        c.expect(!tree.key("x"), "a key nothing handles reports false")
        c.expect(tree.key("shift+tab"), "Shift-Tab moves back")
        c.expect(focused().hasPrefix("Button"), "back on the first button: \(focused())")
        c.expect(tree.elementTree.contains("\"Field none\""), "@FocusState is cleared when focus leaves its views")

        // @FocusState moves focus; clicks focus focusable views but not buttons.
        c.expect(tree.click(text: "Focus notes"), "the button runs")
        c.expect(focused().contains("\"Notes\""), "setting @FocusState moved focus: \(focused())")
        c.expect(tree.elementTree.contains("\"Field notes\""), "the screen shows the new focus")
        c.expect(tree.click(text: "Name"), "a click on a focusable view focuses it")
        c.expect(focused().contains("\"Name\""), "the clicked view has focus: \(focused())")
        for _ in 0..<4 { tree.key("tab") }
        c.expect(focused().contains("\"Add\""), "Tab wraps around to the first view: \(focused())")

        // Focus leaves a view that leaves the tree.
        tree.click(text: "Focus notes")
        c.expect(tree.click(text: "Hide notes"), "the notes view is removed")
        c.expectEqual(tree.focusedElement, nil, "nothing has focus once the focused view is gone")
        c.expect(tree.elementTree.contains("\"Field none\""), "@FocusState is cleared with it")
    },
    Check("ui.text-wrapping") { c in
        let face = try TextReference.font(root: c.root, "Geist-Regular.otf")
        let text = "The quick brown fox jumps over the lazy dog and keeps running"
        let one = TextLayout.lines(text, font: face, pixelSize: 13)
        c.expectEqual(one.count, 1, "no width, one line")
        let wrapped = TextLayout.lines(text, font: face, pixelSize: 13, maxWidth: 120)
        c.expect(wrapped.count > 2, "wraps at 120: \(wrapped.count) lines")
        c.expect(wrapped.allSatisfy { $0.width <= 120 }, "no line is wider than the limit")
        c.expectEqual(wrapped.reduce(0) { $0 + $1.glyphs.count }, text.unicodeScalars.count - (wrapped.count - 1),
                      "every character is kept except the space at each break")
        let limited = TextLayout.lines(text, font: face, pixelSize: 13, maxWidth: 120, lineLimit: 2)
        c.expectEqual(limited.count, 2, "line limit respected")
        c.expect(limited[1].truncated && limited[1].width <= 120, "the last line is cut with an ellipsis inside the width")
        c.expectEqual(limited[1].glyphs.last?.glyph, face.glyph(for: "\u{2026}"), "ellipsis glyph at the end")
        c.expectEqual(TextLayout.lines("one\ntwo\n", font: face, pixelSize: 13).count, 3, "explicit line breaks, with an empty last line")
        let long = TextLayout.lines("Incomprehensibilities", font: face, pixelSize: 13, maxWidth: 40)
        c.expect(long.count > 1 && long.allSatisfy { $0.width <= 40 }, "a word wider than the line breaks between characters")
        c.expectEqual(TextLayout.lines("well-known fact", font: face, pixelSize: 13, maxWidth: 40).first?.glyphs.count, 5,
                      "a line may break after a hyphen")

        // In a view: the text takes the lines it needs, and they are evenly spaced.
        let font = Font(face, size: 13)
        var r = ImageRenderer(content: Text(text).font(font).frame(width: 120).background(Color(white: 0.063)))
        let tree = r.elementTree
        let single = ImageRenderer(content: Text("x").font(font)).elementTree
        // Height from an element line: "Text (0, 0, 120x85) ...".
        func height(_ line: String) -> Int {
            guard let open = line.firstIndex(of: "("), let close = line.firstIndex(of: ")") else { return 0 }
            return Int(line[line.index(after: open)..<close].split(separator: "x").last ?? "") ?? 0
        }
        c.expectEqual(height(String(tree.split(separator: "\n")[0])), height(single) * wrapped.count, "height is lines times line height:\n\(tree)")
        r.scale = 2
        try Platform.files.createDirectory(Path.join(c.outputDirectory, "ui"))
        try Platform.files.write(PNG.encode(r.bitmap), to: Path.join(c.outputDirectory, "ui/text-wrapping@2x.png"))
        let centred = ImageRenderer(content: Text(text).font(font).lineLimit(2).multilineTextAlignment(.center).frame(width: 120))
        c.expectEqual(height(String(centred.elementTree.split(separator: "\n")[0])), height(single) * 2, "lineLimit(2) gives two lines")
    },
]
