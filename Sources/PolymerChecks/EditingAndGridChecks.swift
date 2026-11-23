import PolymerBase
import PolymerPlatform
import PolymerText
import PolymerRender
import PolymerUI

// MARK: Views used by EditingAndGridChecks

@Observable
final class TextFieldModel {
    var query = ""
    var notes = "First line\nSecond line"
    var submits = 0
}

struct TextFieldCheckScreen: View {
    let model: TextFieldModel
    let font: Font
    var body: some View {
        let m = Bindable(model)
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search...", text: m.query, onSubmit: { model.submits += 1 })
                .accessibilityIdentifier("search-field")
                .frame(width: 180)
                .padding(4)
                .border(Color(white: 1, opacity: 0.2))
            TextEditor(text: m.notes)
                .accessibilityIdentifier("notes-editor")
                .frame(width: 180, height: 60)
                .padding(4)
                .border(Color(white: 1, opacity: 0.2))
        }
        .font(font)
        .padding(8)
        .background(Color(white: 0.08))
    }
}

struct StatefulGridCell: View {
    let index: Int
    @State private var selected = false
    var body: some View {
        Button(action: { selected.toggle() }) {
            Text(selected ? "Cell \(index)*" : "Cell \(index)")
                .frame(height: 24)
        }
        .accessibilityIdentifier("cell-\(index)")
    }
}

struct LazyVGridLibraryScreen: View {
    let font: Font
    let count: Int
    var body: some View {
        ScrollView(.vertical) {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 4),
                    GridItem(.flexible(), spacing: 4),
                    GridItem(.flexible(), spacing: 4),
                ],
                spacing: 4
            ) {
                ForEach(0..<count) { i in
                    StatefulGridCell(index: i)
                }
            }
        }
        .font(font)
        .frame(width: 240, height: 120)
        .background(Color(white: 0.06))
    }
}

@Observable
final class ContextMenuModel {
    var log: [String] = []
    var bgTaps = 0
}

struct ContextMenuScreen: View {
    let model: ContextMenuModel
    let font: Font
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Target Item")
                .padding(8)
                .background(Color(white: 0.16))
                .accessibilityIdentifier("menu-target")
                .contextMenu {
                    Button("Copy") { model.log.append("copy") }
                    Button("Delete") { model.log.append("delete") }
                }
            Button("Background Action") { model.bgTaps += 1 }
                .accessibilityIdentifier("bg-button")
        }
        .font(font)
        .padding(16)
        .frame(width: 240, height: 160, alignment: .topLeading)
        .background(Color(white: 0.06))
    }
}

@Observable
final class A11yModel {
    var name = "Polymer"
    var locked = true
}

struct A11yScreen: View {
    let model: A11yModel
    let font: Font
    var body: some View {
        let m = Bindable(model)
        VStack(alignment: .leading, spacing: 6) {
            Text("Heading").accessibilityIdentifier("heading")
            Divider()
            Button("Save") {}
                .accessibilityIdentifier("save-btn")
                .contextMenu { Button("Save As") {} }
            Button("Locked") {}
                .disabled(model.locked)
                .accessibilityIdentifier("locked-btn")
            TextField("Name", text: m.name)
                .accessibilityIdentifier("name-field")
            Rectangle()
                .foregroundStyle(.white)
                .frame(width: 40, height: 12)
                .gesture(DragGesture(minimumDistance: 0))
                .accessibilityIdentifier("drag-box")
            ScrollView {
                LazyVGrid(columns: [GridItem(.fixed(40)), GridItem(.fixed(40))], spacing: 4) {
                    ForEach(0..<4) { i in Text("G\(i)") }
                }
            }
            .frame(width: 100, height: 40)
        }
        .font(font)
        .padding(8)
        .frame(width: 220, height: 220, alignment: .topLeading)
    }
}

// MARK: Checks

@MainActor
public let editingAndGridChecks: [Check] = [
    Check("text.editing") { c in
        // Grapheme clusters: combining marks and multi-scalar ZWJ emoji count as 1 grapheme.
        let family = "👨\u{200D}👩\u{200D}👧\u{200D}👦"
        let accented = "e\u{0301}"
        var buf = TextBuffer("a\(accented)\(family)z")
        c.expectEqual(buf.graphemeCount, 4, "4 grapheme clusters")
        c.expectEqual(buf.slice(TextRange(1, 3)), "\(accented)\(family)", "slice preserves grapheme clusters")

        // UTF-8 / UTF-16 / scalar round-trips.
        for g in 0...buf.graphemeCount {
            let u8 = buf.utf8Offset(at: g)
            let u16 = buf.utf16Offset(at: g)
            let sc = buf.scalarOffset(at: g)
            c.expectEqual(buf.graphemeOffset(forUTF8Offset: u8), g, "utf8 round-trip at \(g)")
            c.expectEqual(buf.graphemeOffset(forUTF16Offset: u16), g, "utf16 round-trip at \(g)")
            c.expectEqual(buf.graphemeOffset(forScalarOffset: sc), g, "scalar round-trip at \(g)")
        }

        buf.insert("X", at: 2)
        c.expectEqual(buf.graphemeCount, 5, "insert adds 1 grapheme")
        buf.replace(TextRange(1, 3), with: "Q")
        c.expectEqual(buf.text, "aQ\(family)z", "replace works on grapheme bounds")
        buf.delete(TextRange(2, 3))
        c.expectEqual(buf.text, "aQz", "delete removes ZWJ emoji atomically")

        // Word & line boundaries.
        let multi = TextBuffer("hello world\nfoo_bar.baz\nshort")
        c.expectEqual(multi.previousWordBoundary(from: 11), 6, "prev word from end of 'world'")
        c.expectEqual(multi.previousWordBoundary(from: 6), 0, "prev word across space")
        c.expectEqual(multi.nextWordBoundary(from: 0), 5, "next word from start")
        c.expectEqual(multi.nextWordBoundary(from: 5), 11, "next word across space")
        c.expectEqual(multi.lineCount, 3, "3 lines")
        c.expectEqual(multi.lineStart(from: 15), 12, "lineStart on line 1")
        c.expectEqual(multi.lineEnd(from: 15), 23, "lineEnd on line 1")
        c.expectEqual(multi.lineIndex(of: 15), 1, "lineIndex on line 1")
        c.expectEqual(multi.offset(line: 2, column: 3), 27, "offset(line:2, col:3)")

        // Directional selection & multi-line vertical navigation.
        var st = TextEditorState("hello world\nab\n123456")
        st.setCaret(5)
        st.moveLeft(extendingSelection: true)
        st.moveLeft(extendingSelection: true)
        c.expectEqual(st.selection, TextSelection(anchor: 5, head: 3), "directional selection preserves anchor")
        c.expectEqual(st.selectedText, "lo", "selected text")
        st.moveRight(extendingSelection: true)
        c.expectEqual(st.selection, TextSelection(anchor: 5, head: 4), "extending back shrinks selection")
        st.moveLeft(extendingSelection: false)
        c.expectEqual(st.selection, TextSelection(caret: 4), "non-extending left collapses to lowerBound")

        // Up/Down preserves preferred column across shorter middle line.
        st.setCaret(5)
        st.moveDown()
        c.expectEqual(st.selection.caret, 14, "clamped to end of short line 'ab'")
        st.moveDown()
        c.expectEqual(st.selection.caret, 20, "restores column 5 on line 2 ('12345|6')")
        st.moveUp()
        c.expectEqual(st.selection.caret, 14, "back to end of 'ab'")
        st.moveUp()
        c.expectEqual(st.selection.caret, 5, "back to column 5 on line 0")

        // Undo/redo coalescing for single-char typing bursts.
        var edit = TextEditorState("")
        for ch in "hello" { edit.insertText(String(ch)) }
        c.expectEqual(edit.text, "hello", "typed hello")
        c.expect(edit.canUndo, "can undo")
        edit.undo()
        c.expectEqual(edit.text, "", "contiguous typing burst coalesced into one undo")
        c.expect(edit.canRedo, "can redo")
        edit.redo()
        c.expectEqual(edit.text, "hello", "redo restores hello")

        // Moving caret breaks coalescing.
        edit.moveToLineEnd()
        for ch in " world" { edit.insertText(String(ch)) }
        edit.undo()
        c.expectEqual(edit.text, "hello", "second burst undoes separately")
        edit.undo()
        c.expectEqual(edit.text, "", "first burst undoes next")

        // Clipboard helpers.
        edit.insertText("alpha beta")
        edit.selectWord(at: 1)
        c.expectEqual(edit.copy(), "alpha", "copy returns selected word")
        c.expectEqual(edit.cut(), "alpha", "cut removes selected word")
        c.expectEqual(edit.text, " beta", "buffer updated after cut")
        edit.paste("gamma")
        c.expectEqual(edit.text, "gamma beta", "paste inserts text")

        // IME marked text: set -> update -> cancel, then set -> commit -> undo.
        var ime = TextEditorState("hi ")
        ime.setMarkedText("ni")
        c.expectEqual(ime.text, "hi ni", "marked text inserted into buffer")
        c.expectEqual(ime.markedText?.range, TextRange(3, 5), "marked range tracked")
        ime.setMarkedText("nihao")
        c.expectEqual(ime.text, "hi nihao", "marked text updated in place")
        ime.cancelMarkedText()
        c.expectEqual(ime.text, "hi ", "cancel restores original buffer")
        c.expectEqual(ime.markedText, nil, "marked text cleared on cancel")

        ime.setMarkedText("ni")
        ime.commitMarkedText("你")
        c.expectEqual(ime.text, "hi 你", "commit replaces marked range")
        c.expectEqual(ime.markedText, nil, "marked text cleared on commit")
        ime.undo()
        c.expectEqual(ime.text, "hi ", "committed IME composition undoes in one step")

        // ShapedLine caret hit-testing with a real font.
        let face = try TextReference.font(root: c.root, "Geist-Regular.otf")
        let shaped = ShapedLine.shape("Polymer", font: face, pixelSize: 14)
        c.expectEqual(shaped.caretPositions.count, 8, "7 chars -> 8 caret positions")
        for i in 0..<7 {
            c.expect(shaped.caretPositions[i + 1] > shaped.caretPositions[i], "caret positions strictly increase")
        }
        let xAt3 = shaped.caretPosition(at: 3)
        c.expectEqual(shaped.caretOffset(forX: xAt3), 3, "exact caret x round-trips to offset 3")
        c.expectEqual(shaped.caretOffset(forX: -10), 0, "negative x clamps to 0")
        c.expectEqual(shaped.caretOffset(forX: 1000), 7, "large x clamps to end")
    },

    Check("ui.textfield") { c in
        let font = Font(try TextReference.font(root: c.root, "Geist-Regular.otf"), size: 13)
        let model = TextFieldModel()
        let tree = ViewTree(TextFieldCheckScreen(model: model, font: font))
        tree.update()

        // Focus TextField by click and type text.
        c.expect(tree.click(id: "search-field"), "click focuses TextField")
        c.expect(tree.focusedElement?.contains("TextField") == true, "TextField is focused: \(tree.focusedElement ?? "nil")")

        for ch in ["h", "e", "l", "l", "o", "space", "w", "o", "r", "l", "d"] {
            c.expect(tree.key(ch), "key \(ch) handled")
        }
        tree.update()
        c.expectEqual(model.query, "hello world", "typed into TextField")

        // Word backspace & undo/redo.
        c.expect(tree.key("alt+delete"), "alt+delete deletes last word")
        tree.update()
        c.expectEqual(model.query, "hello ", "word deleted")

        c.expect(tree.key("cmd+z"), "cmd+z undoes word delete")
        tree.update()
        c.expectEqual(model.query, "hello world", "word restored via undo")

        c.expect(tree.key("cmd+shift+z"), "cmd+shift+z redoes word delete")
        tree.update()
        c.expectEqual(model.query, "hello ", "word deleted again via redo")

        // Select all & replace via typing.
        c.expect(tree.key("cmd+a"), "cmd+a selects all")
        c.expect(tree.key("x"), "typing replaces selection")
        tree.update()
        c.expectEqual(model.query, "x", "selection replaced")

        // Arrow movement + Shift selection + delete.
        _ = tree.key("y")
        _ = tree.key("z")
        tree.update()
        c.expectEqual(model.query, "xyz", "now xyz")
        _ = tree.key("left")
        _ = tree.key("shift+left")
        _ = tree.key("delete")
        tree.update()
        c.expectEqual(model.query, "xz", "shift+left + delete removed middle char")

        // Return invokes onSubmit.
        c.expect(tree.key("return"), "return handled by TextField")
        c.expectEqual(model.submits, 1, "onSubmit called once")

        // Click caret positioning near left edge of TextField puts caret at offset 0.
        let fieldNode = tree.accessibilityTree().find(id: "search-field")
        c.expect(fieldNode != nil, "search-field in accessibility tree")
        if let frame = fieldNode?.frame {
            _ = tree.click(at: Point(x: frame.minX + 1, y: frame.midY))
            _ = tree.key("A")
            tree.update()
            c.expectEqual(model.query, "Axz", "clicking left edge inserted at index 0")

            // Drag selection from right to left selects all text and deletes it.
            tree.pointerDown(at: Point(x: frame.maxX - 2, y: frame.midY))
            tree.pointerMoved(to: Point(x: frame.minX + 1, y: frame.midY))
            _ = tree.pointerUp(at: Point(x: frame.minX + 1, y: frame.midY))
            _ = tree.key("delete")
            tree.update()
            c.expectEqual(model.query, "", "pointer drag selection + delete cleared text")
        }

        // Narrow TextField with Binding<TextEditorState> and IME marked text renders cleanly.
        var narrowState = TextEditorState("0123456789abcdefghij")
        narrowState.setMarkedText("ime")
        let imeBinding = Binding(get: { narrowState }, set: { narrowState = $0 })
        let narrowTree = ViewTree(
            TextField("Type", state: imeBinding)
                .font(font)
                .frame(width: 60)
                .background(Color.black)
        )
        let narrowImg = narrowTree.render(background: .black)
        c.expect(narrowImg.width == 60 && narrowImg.height > 0, "narrow TextField with IME marked text rendered")

        // Render check (ensures TextField and TextEditor draw cleanly).
        let img = tree.render(background: .black)
        c.expect(img.width > 0 && img.height > 0, "rendered TextField + TextEditor")

        // Multi-line TextEditor: click to focus, press End, Return, type line 3, moveUp.
        c.expect(tree.click(id: "notes-editor"), "click focuses TextEditor")
        c.expect(tree.focusedElement?.contains("TextEditor") == true, "TextEditor is focused")
        _ = tree.key("cmd+down")
        _ = tree.key("return")
        _ = tree.key("3")
        tree.update()
        c.expectEqual(model.notes, "First line\nSecond line\n3", "Return inserted newline in TextEditor")
        _ = tree.key("up")
        _ = tree.key("home")
        _ = tree.key("!")
        tree.update()
        c.expectEqual(model.notes, "First line\n!Second line\n3", "Up + Home moved to start of line 2")
        _ = tree.key("cmd+z")
        tree.update()
        c.expectEqual(model.notes, "First line\nSecond line\n3", "Undo works in TextEditor")
    },

    Check("ui.grid") { c in
        let font = Font(try TextReference.font(root: c.root, "Geist-Regular.otf"), size: 13)

        // 1. LazyVGrid with fixed + flexible columns: 300 width = 60 + 10 + 110 + 10 + 110.
        let vGrid = ViewTree(
            LazyVGrid(
                columns: [
                    GridItem(.fixed(60), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible()),
                ],
                spacing: 8
            ) {
                Rectangle().frame(height: 20).accessibilityIdentifier("c0")
                Rectangle().frame(height: 20).accessibilityIdentifier("c1")
                Rectangle().frame(height: 20).accessibilityIdentifier("c2")
                Rectangle().frame(height: 30).accessibilityIdentifier("c3")
            }
            .frame(width: 300)
        )
        let vTree = vGrid.accessibilityTree()
        c.expectEqual(vTree.find(id: "c0")?.frame, Rect(x: 0, y: 0, width: 60, height: 20), "fixed col 0")
        c.expectEqual(vTree.find(id: "c1")?.frame, Rect(x: 70, y: 0, width: 110, height: 20), "flex col 1")
        c.expectEqual(vTree.find(id: "c2")?.frame, Rect(x: 190, y: 0, width: 110, height: 20), "flex col 2")
        c.expectEqual(vTree.find(id: "c3")?.frame, Rect(x: 0, y: 28, width: 60, height: 30), "row 1 col 0")

        // 2. LazyVGrid with adaptive columns: width 260, min 80, spacing 10 -> 3 columns of 80.
        let adaptive = ViewTree(
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 10)], spacing: 6) {
                ForEach(0..<4) { i in
                    Rectangle().frame(height: 16).accessibilityIdentifier("a\(i)")
                }
            }
            .frame(width: 260)
        )
        let aTree = adaptive.accessibilityTree()
        c.expectEqual(aTree.find(id: "a0")?.frame, Rect(x: 0, y: 0, width: 80, height: 16), "adaptive col 0")
        c.expectEqual(aTree.find(id: "a1")?.frame, Rect(x: 90, y: 0, width: 80, height: 16), "adaptive col 1")
        c.expectEqual(aTree.find(id: "a2")?.frame, Rect(x: 180, y: 0, width: 80, height: 16), "adaptive col 2")
        c.expectEqual(aTree.find(id: "a3")?.frame, Rect(x: 0, y: 22, width: 80, height: 16), "adaptive wraps to row 1")

        // 3. LazyHGrid with fixed + flexible rows: height 110 = 30 + 10 + 70.
        let hGrid = ViewTree(
            LazyHGrid(
                rows: [GridItem(.fixed(30), spacing: 10), GridItem(.flexible())],
                spacing: 8
            ) {
                Rectangle().frame(width: 40).accessibilityIdentifier("h0")
                Rectangle().frame(width: 40).accessibilityIdentifier("h1")
                Rectangle().frame(width: 50).accessibilityIdentifier("h2")
            }
            .frame(height: 110)
        )
        let hTree = hGrid.accessibilityTree()
        c.expectEqual(hTree.find(id: "h0")?.frame, Rect(x: 0, y: 0, width: 40, height: 30), "hgrid row 0 col 0")
        c.expectEqual(hTree.find(id: "h1")?.frame, Rect(x: 0, y: 40, width: 40, height: 70), "hgrid row 1 col 0")
        c.expectEqual(hTree.find(id: "h2")?.frame, Rect(x: 48, y: 0, width: 50, height: 30), "hgrid row 0 col 1")

        // 4. Lazy materialization & state preservation across 10,000 items inside ScrollView.
        let big = ViewTree(LazyVGridLibraryScreen(font: font, count: 10_000))
        let initialDump = big.elementTree
        let initialEvals = big.bodyEvaluations
        c.expect(initialEvals < 40, "only visible grid cells built (\(initialEvals) for 10,000 items)")
        c.expect(initialDump.contains("of 10000"), "grid tracks all 10,000 items:\n\(initialDump.prefix(400))")
        c.expect(initialDump.contains("\"Cell 0\"") && !initialDump.contains("\"Cell 100\""), "only visible cells in tree")

        // Scroll down ~10 rows (each row is 24 + 4 = 28pt).
        c.expect(big.scroll(at: Point(x: 120, y: 60), dy: 280), "grid scroll view scrolls")
        c.expect(big.needsUpdate, "scrolling new grid rows into view requests update")
        let scrolledDump = big.elementTree
        c.expect(scrolledDump.contains("\"Cell 33\""), "row 11 cells now visible:\n\(scrolledDump.prefix(400))")
        c.expect(big.bodyEvaluations - initialEvals < 40, "scrolling only built newly visible cells")

        // Click Cell 33 to toggle its @State, scroll away and back, verify state preserved.
        c.expect(big.click(id: "cell-33"), "click visible grid cell")
        c.expect(big.elementTree.contains("\"Cell 33*\""), "cell 33 toggled state")
        _ = big.scroll(at: Point(x: 120, y: 60), dy: -1000)
        c.expect(!big.elementTree.contains("Cell 33"), "cell 33 left viewport")
        _ = big.scroll(at: Point(x: 120, y: 60), dy: 280)
        c.expect(big.elementTree.contains("\"Cell 33*\""), "cell 33 preserved its @State after scrolling away and back")
    },

    Check("ui.gestures") { c in
        // 1. DragGesture with default minimumDistance (10).
        var changedValues: [DragGesture.Value] = []
        var endedValues: [DragGesture.Value] = []
        let dragTree = ViewTree(
            Rectangle()
                .foregroundStyle(.white)
                .frame(width: 100, height: 100)
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { changedValues.append($0) }
                        .onEnded { endedValues.append($0) }
                )
        )
        dragTree.update()
        // Move only 5pt (< 10): neither onChanged nor onEnded fires.
        dragTree.pointerDown(at: Point(x: 20, y: 20))
        dragTree.pointerMoved(to: Point(x: 25, y: 20))
        _ = dragTree.pointerUp(at: Point(x: 25, y: 20))
        c.expect(changedValues.isEmpty && endedValues.isEmpty, "below minimumDistance does not activate drag")

        // Move 15pt (>= 10): activates drag, fires onChanged then onEnded.
        dragTree.pointerDown(at: Point(x: 20, y: 20))
        dragTree.pointerMoved(to: Point(x: 35, y: 24))
        _ = dragTree.pointerUp(at: Point(x: 40, y: 30))
        c.expectEqual(changedValues.count, 2, "onChanged fired on threshold crossing and up-move")
        c.expectEqual(changedValues.first?.startLocation, Point(x: 20, y: 20), "startLocation recorded")
        c.expectEqual(changedValues.first?.translation, Size(width: 15, height: 4), "translation matches delta")
        c.expectEqual(endedValues.count, 1, "onEnded fired once")
        c.expectEqual(endedValues.first?.translation, Size(width: 20, height: 10), "end translation matches total delta")

        // 2. Scrubber with minimumDistance: 0 activates immediately on pointerDown.
        var scrubChanges: [DragGesture.Value] = []
        var scrubEnded = 0
        let scrubber = ViewTree(
            Rectangle()
                .foregroundStyle(.white)
                .frame(width: 200, height: 20)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { scrubChanges.append($0) }
                        .onEnded { _ in scrubEnded += 1 }
                )
        )
        scrubber.update()
        scrubber.pointerDown(at: Point(x: 50, y: 10))
        c.expectEqual(scrubChanges.count, 1, "minimumDistance: 0 fires onChanged immediately on pointerDown")
        c.expectEqual(scrubChanges.first?.translation, .zero, "initial translation is zero")
        scrubber.pointerMoved(to: Point(x: 120, y: 10))
        c.expectEqual(scrubChanges.last?.translation, Size(width: 70, height: 0), "scrubber tracks horizontal drag")
        scrubber.pointerExited()
        c.expectEqual(scrubEnded, 1, "pointerExited ends active drag")

        // 3. Disabled view ignores drag gesture.
        var disabledDrags = 0
        let disabledTree = ViewTree(
            Rectangle()
                .foregroundStyle(.white)
                .frame(width: 100, height: 100)
                .gesture(DragGesture(minimumDistance: 0).onChanged { _ in disabledDrags += 1 })
                .disabled(true)
        )
        disabledTree.update()
        disabledTree.pointerDown(at: Point(x: 50, y: 50))
        disabledTree.pointerMoved(to: Point(x: 80, y: 50))
        _ = disabledTree.pointerUp(at: Point(x: 80, y: 50))
        c.expectEqual(disabledDrags, 0, "disabled view ignores drag gestures")
    },

    Check("ui.modifiers-extra") { c in
        let font = Font(try TextReference.font(root: c.root, "Geist-Regular.otf"), size: 13)

        // 1. .clipShape: Circle and RoundedRectangle clip hit-testing accurately.
        var circleTaps = 0
        let clipped = ViewTree(
            Rectangle()
                .foregroundStyle(.white)
                .frame(width: 100, height: 100)
                .onTapGesture { circleTaps += 1 }
                .clipShape(Circle())
        )
        clipped.update()
        c.expect(!clipped.click(at: Point(x: 5, y: 5)), "corner outside Circle clip does not hit")
        c.expectEqual(circleTaps, 0, "no tap on corner outside circle")
        c.expect(clipped.click(at: Point(x: 50, y: 50)), "center inside Circle clip hits")
        c.expectEqual(circleTaps, 1, "tap registered inside circle")

        var rrTaps = 0
        let rrClipped = ViewTree(
            Rectangle()
                .foregroundStyle(.white)
                .frame(width: 100, height: 100)
                .onTapGesture { rrTaps += 1 }
                .clipShape(RoundedRectangle(cornerRadius: 24))
        )
        rrClipped.update()
        c.expect(!rrClipped.click(at: Point(x: 2, y: 2)), "corner outside RoundedRectangle radius does not hit")
        c.expect(rrClipped.click(at: Point(x: 50, y: 2)), "top edge midpoint inside RoundedRectangle hits")
        c.expectEqual(rrTaps, 1, "tap registered inside rounded rect")

        // 2. .zIndex: draw order (pixel color) AND hit-testing order.
        var topHits = 0
        var backHits = 0
        let zTree = ViewTree(
            ZStack {
                Rectangle()
                    .foregroundStyle(Color(red: 1, green: 0, blue: 0))
                    .frame(width: 40, height: 40)
                    .onTapGesture { topHits += 1 }
                    .zIndex(2)
                Rectangle()
                    .foregroundStyle(Color(red: 0, green: 0, blue: 1))
                    .frame(width: 40, height: 40)
                    .onTapGesture { backHits += 1 }
                    .zIndex(1)
            }
        )
        let zImg = zTree.render(background: .black)
        c.expectEqual(zImg[20, 20].r, 255, "higher zIndex (red) draws on top of later sibling (blue)")
        c.expectEqual(zImg[20, 20].b, 0, "lower zIndex (blue) is covered")
        c.expect(zTree.click(at: Point(x: 20, y: 20)), "click hits overlapping zIndex stack")
        c.expectEqual(topHits, 1, "higher zIndex receives hit test first")
        c.expectEqual(backHits, 0, "lower zIndex does not steal hit")

        // 3. .layoutPriority: higher priority child gets space before lower priority siblings.
        let prioH = ViewTree(
            HStack(spacing: 0) {
                Rectangle().frame(minWidth: 20, maxWidth: .infinity).accessibilityIdentifier("low")
                Rectangle().frame(minWidth: 20, maxWidth: 150).layoutPriority(1).accessibilityIdentifier("high")
            }
            .frame(width: 200, height: 20)
        )
        let prioA11y = prioH.accessibilityTree()
        c.expectEqual(prioA11y.find(id: "high")?.frame.width, 150, "high priority child claims its desired 150pt")
        c.expectEqual(prioA11y.find(id: "low")?.frame.width, 50, "low priority child gets remaining 50pt")

        let prioV = ViewTree(
            VStack(spacing: 0) {
                Rectangle().frame(minHeight: 10, maxHeight: .infinity).accessibilityIdentifier("vlow")
                Rectangle().frame(minHeight: 10, maxHeight: 80).layoutPriority(2).accessibilityIdentifier("vhigh")
            }
            .frame(width: 40, height: 100)
        )
        let prioVA11y = prioV.accessibilityTree()
        c.expectEqual(prioVA11y.find(id: "vhigh")?.frame.height, 80, "VStack high priority gets 80pt")
        c.expectEqual(prioVA11y.find(id: "vlow")?.frame.height, 20, "VStack low priority gets 20pt")

        // 4. .contextMenu: open via rightClick, click item, dismiss via Escape and outside click.
        let cmModel = ContextMenuModel()
        let cmTree = ViewTree(ContextMenuScreen(model: cmModel, font: font))
        cmTree.update()
        c.expect(!cmTree.hasOpenContextMenu, "no menu open initially")
        c.expect(cmTree.rightClick(id: "menu-target"), "rightClick opens context menu")
        c.expect(cmTree.hasOpenContextMenu, "context menu is open")
        c.expect(cmTree.elementTree.contains("\"Copy\"") && cmTree.elementTree.contains("\"Delete\""),
                 "menu items appear in tree")
        let withMenuImg = cmTree.render(background: .black)
        c.expect(withMenuImg.width > 0, "rendered with context menu overlay")

        c.expect(cmTree.click(text: "Copy"), "clicking menu item runs action")
        c.expectEqual(cmModel.log, ["copy"], "Copy action ran")
        c.expect(!cmTree.hasOpenContextMenu, "menu dismissed after item click")

        // Re-open and dismiss with Escape.
        c.expect(cmTree.rightClick(text: "Target Item"), "rightClick(text:) re-opens context menu")
        c.expect(cmTree.hasOpenContextMenu, "menu open again")
        c.expect(cmTree.key("escape"), "Escape dismisses context menu")
        c.expect(!cmTree.hasOpenContextMenu, "menu dismissed by Escape")

        // Re-open and dismiss by clicking outside (without pressing underlying button).
        c.expect(cmTree.rightClick(id: "menu-target"), "open menu for outside-click test")
        c.expect(cmTree.click(at: Point(x: 230, y: 150)), "outside click consumes event to dismiss")
        c.expect(!cmTree.hasOpenContextMenu, "menu dismissed by outside click")
        c.expectEqual(cmModel.bgTaps, 0, "outside dismiss click did not press background button")
    },

    Check("ui.accessibility") { c in
        let font = Font(try TextReference.font(root: c.root, "Geist-Regular.otf"), size: 13)
        let model = A11yModel()
        let tree = ViewTree(A11yScreen(model: model, font: font))
        _ = tree.click(id: "name-field")

        let a11y = tree.accessibilityTree()
        c.expectEqual(a11y.role, .application, "root role is application")

        let heading = a11y.find(id: "heading")
        c.expectEqual(heading?.role, .text, "heading role is text")
        c.expectEqual(heading?.label, "Heading", "heading label")

        let saveBtn = a11y.find(id: "save-btn")
        c.expectEqual(saveBtn?.role, .button, "save-btn role is button")
        c.expectEqual(saveBtn?.label, "Save", "save-btn label")
        c.expectEqual(saveBtn?.isEnabled, true, "save-btn enabled")
        c.expect(saveBtn?.actions.contains("press") == true && saveBtn?.actions.contains("contextMenu") == true,
                 "save-btn exposes press and contextMenu actions: \(saveBtn?.actions ?? [])")

        let lockedBtn = a11y.find(id: "locked-btn")
        c.expectEqual(lockedBtn?.role, .button, "locked-btn role is button")
        c.expectEqual(lockedBtn?.isEnabled, false, "locked-btn is disabled")

        let field = a11y.find(id: "name-field")
        c.expectEqual(field?.role, .textField, "name-field role is textField")
        c.expectEqual(field?.label, "Name", "name-field placeholder as label")
        c.expectEqual(field?.value, "Polymer", "name-field text as value")
        c.expectEqual(field?.isFocused, true, "name-field reports focused")
        c.expect(field?.actions.contains("edit") == true && field?.actions.contains("focus") == true,
                 "name-field exposes edit & focus actions")

        let dragBox = a11y.find(id: "drag-box")
        c.expectEqual(dragBox?.role, .shape, "drag-box role is shape")
        c.expect(dragBox?.actions.contains("drag") == true, "drag-box exposes drag action")

        c.expect(a11y.first { $0.role == .divider } != nil, "divider role exported")
        c.expect(a11y.first { $0.role == .scrollArea }?.actions.contains("scroll") == true, "scrollArea exposes scroll")
        c.expect(a11y.first { $0.role == .grid } != nil, "grid role exported")

        // Deterministic JSON export across two independent trees.
        let json1 = a11y.toJSON().serialized
        let tree2 = ViewTree(A11yScreen(model: A11yModel(), font: font))
        _ = tree2.click(id: "name-field")
        let json2 = tree2.accessibilityTree().toJSON().serialized
        c.expectEqual(json1, json2, "accessibility JSON export is deterministic across trees")

        // Parsed JSON has expected fields.
        let parsed = try JSON.parse(json1)
        c.expectEqual(parsed["role"]?.string, "application", "JSON root role")
        c.expect(parsed["children"]?.array?.isEmpty == false, "JSON has children")

        let desc = a11y.describeTree()
        c.expect(desc.contains("textField \"Name\" value=\"Polymer\"") && desc.contains("focused"),
                 "describeTree summarizes roles, values and focus:\n\(desc)")
    },
]
