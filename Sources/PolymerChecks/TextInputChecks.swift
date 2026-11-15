// Checks for TextField and TextEditor: typing, moving, selecting, the
// clipboard, undo, clicks and drags, input methods, and how they draw.
import PolymerBase
import PolymerPlatform
import PolymerRender
import PolymerUI

@Observable
final class TextInputModel {
    var name = ""
    var notes = "one two\nthree"
    var submitted = 0
    var locked = ""
}

struct TextInputScreen: View {
    let model: TextInputModel
    let font: Font
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name", text: Binding(get: { model.name }, set: { model.name = $0 }))
                .frame(width: 120)
                .onSubmit { model.submitted += 1 }
            TextEditor(text: Binding(get: { model.notes }, set: { model.notes = $0 }))
                .frame(width: 80, height: 60)
            TextField("Locked", text: Binding(get: { model.locked }, set: { model.locked = $0 }))
                .frame(width: 120)
                .disabled(true)
        }
        .font(font)
        .frame(width: 200, height: 140, alignment: .topLeading)
    }
}

@MainActor let textInputChecks: [Check] = [
    Check("ui.text-input") { c in
        let font = Font(try TextReference.font(root: c.root, "Geist-Regular.otf"), size: 13)
        let model = TextInputModel()
        let tree = ViewTree(TextInputScreen(model: model, font: font))
        @MainActor func field(_ role: String = "TextField", _ n: Int = 0) -> String {
            let ls = tree.elementTree.split(separator: "\n").map { String($0.drop { $0 == " " }) }.filter { $0.hasPrefix(role + " (") }
            return n < ls.count ? ls[n] : "none"
        }
        @MainActor func after(_ line: String) -> String { String(line.drop { $0 != ")" }.dropFirst(2)) }
        tree.time = 0
        _ = tree.render()
        c.expect(field().hasPrefix("TextField (0, 0, 120x") && field().hasSuffix("placeholder \"Name\""), "an empty field shows its title: \(field())")
        let placeholder = (tree.displayList?.items ?? []).compactMap { if case .glyphs(let g) = $0.operation { g.color.opacity } else { nil } }.first
        c.expectClose(placeholder ?? 0, 0.4, tolerance: 1e-9, "dimmed")

        // Click to focus, type.
        let nameRect = Rect(x: 0, y: 0, width: 120, height: 17)
        tree.click(at: Point(x: 60, y: nameRect.midY))
        c.expectEqual(after(field()), "placeholder \"Name\" caret 0 focused", "a click focuses it, caret at the start")
        tree.type("Hello")
        c.expectEqual(model.name, "Hello", "typing writes the binding")
        c.expectEqual(after(field()), "\"Hello\" caret 5 focused", "caret after the text")
        _ = tree.render()
        let caret = (tree.displayList?.items ?? []).contains { if case .rect(let r, _) = $0.operation { r.width == 1 && r.height == 17 } else { false } }
        c.expect(caret, "the caret is drawn, 1 point wide and a line tall")

        // Moving and selecting.
        tree.key("left"); tree.key("left")
        c.expect(after(field()).contains("caret 3"), "left twice: \(field())")
        tree.key("shift+left")
        c.expect(after(field()).contains("selection 2..3"), "shift-left selects: \(field())")
        tree.type("L")
        c.expectEqual(model.name, "HeLlo", "typing replaces the selection")
        model.name = "one two three"
        _ = tree.render()
        c.expect(after(field()).hasPrefix("\"one two three\" caret 3"), "the binding changed from outside: the caret stays: \(field())")
        tree.key("cmd+right"); c.expect(after(field()).contains("caret 13"), "cmd-right: line end")
        tree.key("alt+left"); c.expect(after(field()).contains("caret 8"), "option-left: start of the word")
        tree.key("ctrl+left"); c.expect(after(field()).contains("caret 4"), "ctrl-left (Windows): previous word too")
        tree.key("alt+right"); c.expect(after(field()).contains("caret 7"), "option-right: end of the word")
        tree.key("home"); c.expect(after(field()).contains("caret 0"), "home")
        tree.key("shift+end"); c.expect(after(field()).contains("selection 0..13"), "shift-end selects to the end")

        // Clipboard and undo.
        tree.key("cmd+c")
        c.expectEqual(tree.clipboard.string, "one two three", "copy")
        tree.key("right")
        tree.key("ctrl+v")
        c.expectEqual(model.name, "one two threeone two three", "paste at the caret (ctrl on Windows)")
        tree.key("cmd+z")
        c.expectEqual(model.name, "one two three", "undo the paste")
        tree.key("shift+cmd+z")
        c.expectEqual(model.name, "one two threeone two three", "redo it")
        tree.key("cmd+a"); tree.key("cmd+x")
        c.expectEqual(model.name, "", "cut everything")
        c.expectEqual(tree.clipboard.string, "one two threeone two three", "into the clipboard")
        tree.type("abc")
        tree.key("cmd+z")
        c.expectEqual(model.name, "", "a run of typing undoes as one step")
        tree.key("ctrl+y")
        c.expectEqual(model.name, "abc", "ctrl-y redoes")

        // Deleting.
        model.name = ""
        _ = tree.render()
        tree.type("hello world")
        tree.key("delete"); c.expectEqual(model.name, "hello worl", "backspace")
        tree.key("alt+delete"); c.expectEqual(model.name, "hello ", "option-backspace: a word")
        tree.key("home"); tree.key("deleteforward"); c.expectEqual(model.name, "ello ", "forward delete")
        tree.key("end"); tree.key("cmd+delete"); c.expectEqual(model.name, "", "cmd-backspace: to the line start")

        // Return submits.
        tree.key("return")
        c.expectEqual(model.submitted, 1, "return runs onSubmit")

        // Clicks and drags place the caret and select.
        model.name = "alpha beta gamma"
        _ = tree.render()
        let x6 = tree.firstRect(forCharacterRange: 6..<6)?.minX ?? -1
        let x10 = tree.firstRect(forCharacterRange: 10..<10)?.minX ?? -1
        c.expect(x6 > 20 && x10 > x6, "carets at 6 and 10 are along the line: \(x6), \(x10)")
        tree.click(at: Point(x: x6 + 0.4, y: nameRect.midY))
        c.expect(after(field()).contains("caret 6"), "a click puts the caret at the nearest gap: \(field())")
        tree.click(at: Point(x: x6 + 3, y: nameRect.midY), count: 2)
        c.expect(after(field()).contains("selection 6..10"), "a double click selects the word: \(field())")
        tree.click(at: Point(x: x6 + 3, y: nameRect.midY), count: 3)
        c.expect(after(field()).contains("selection 0..16"), "a triple click selects everything: \(field())")
        tree.drag(from: Point(x: x10 + 0.2, y: nameRect.midY), to: Point(x: x6 + 0.2, y: nameRect.midY))
        c.expect(after(field()).contains("selection 6..10"), "a drag selects what it passes over: \(field())")

        // A long line scrolls to keep the caret in view.
        model.name = String(repeating: "wide words ", count: 6)
        _ = tree.render()
        tree.key("end")
        _ = tree.render()
        let runX = (tree.displayList?.items ?? []).compactMap { i -> Double? in if case .glyphs(let g) = i.operation, g.position.y < 20 { g.position.x + i.origin.x } else { nil } }.first ?? 0
        c.expect(runX < 0, "scrolled: the line starts left of the field: \(runX)")
        c.expect((tree.firstRect(forCharacterRange: model.name.count..<model.name.count)?.minX ?? 999) <= 120, "and the caret is inside it")

        // Input methods: marked text replaces itself until confirmed.
        model.name = "pin"
        _ = tree.render()
        tree.key("end")
        c.expect(tree.acceptsTextInput, "a focused field takes text input")
        tree.setMarkedText("yi", selectedRange: 2..<2)
        c.expect(after(field()).hasPrefix("\"pinyi\" caret 5") && after(field()).contains("marked 3..5"), "marked text in place: \(field())")
        c.expectEqual(tree.markedTextRange, 3..<5, "its range")
        tree.setMarkedText("\u{4E00}", selectedRange: 1..<1)
        c.expectEqual(model.name, "pin\u{4E00}", "replaced by the next composition")
        let candidates = tree.firstRect(forCharacterRange: 3..<4)
        c.expect(candidates.map { $0.width > 0 && $0.height == 17 && $0.minY == 0 } == true, "a rectangle for the candidate window: \(String(describing: candidates))")
        tree.unmarkText()
        c.expect(tree.markedTextRange == nil && after(field()).contains("caret 4"), "confirmed: \(field())")
        _ = tree.render()
        let underline = (tree.displayList?.items ?? []).contains { if case .rect(let r, _) = $0.operation { r.height == 1 && r.width > 1 } else { false } }
        c.expect(!underline, "no underline once confirmed")

        // The editor: lines, Return, up and down.
        tree.key("tab")
        c.expect(field("TextEditor").hasSuffix("focused"), "tab moves to the editor: \(field("TextEditor"))")
        c.expect(after(field("TextEditor")).hasPrefix("\"one two\\nthree\""), "its text: \(field("TextEditor"))")
        tree.key("cmd+up")
        tree.key("down")
        c.expect(after(field("TextEditor")).contains("caret 8"), "down: the next line: \(field("TextEditor"))")
        tree.key("end"); tree.key("return"); tree.type("four")
        c.expectEqual(model.notes, "one two\nthree\nfour", "return starts a new line")
        model.notes = "a long line that has to wrap in eighty points"
        _ = tree.render()
        let lastLine = tree.firstRect(forCharacterRange: 40..<41)?.minY ?? 0
        let firstLine = tree.firstRect(forCharacterRange: 0..<1)?.minY ?? 0
        c.expect(lastLine > firstLine, "it wraps: \(firstLine) then \(lastLine)")

        // A disabled field takes nothing.
        tree.click(at: Point(x: 60, y: 100))
        c.expect(!field("TextField", 1).contains("focused"), "a disabled field doesn't take focus: \(field("TextField", 1))")
        c.expect(field("TextField", 1).hasSuffix("disabled"), "and says so")

        // Accessibility.
        c.expect(tree.accessibilityDescription.contains("text field") && tree.accessibilityDescription.contains("\"Name\" value \"pin\u{4E00}\""),
                 "a text field in the accessibility tree:\n\(tree.accessibilityDescription)")

        // Partial frames equal whole draws while editing.
        var e = EnvironmentValues()
        e.displayScale = 2
        let m2 = TextInputModel()
        let t2 = ViewTree(TextInputScreen(model: m2, font: font), environment: e)
        _ = t2.render(background: .black)
        t2.click(at: Point(x: 10, y: 8))
        for s in ["a", "b", "left", "shift+left", "x", "cmd+a", "tab", "end", "return"] {
            if s.count == 1 { t2.type(s) } else { t2.key(s) }
            let img = t2.render(background: .black)
            var whole = Canvas(width: img.width, height: img.height, scale: 2, background: .black)
            if let l = t2.displayList { whole.draw(l) }
            c.expect(img == whole.bitmap, "after \(s), a partial frame equals a whole draw")
            if s == "cmd+a" {
                // For review: a focused field with its text selected (out/checks/ui/text-input@2x.png).
                try Platform.files.createDirectory(Path.join(c.outputDirectory, "ui"))
                try Platform.files.write(PNG.encode(img), to: Path.join(c.outputDirectory, "ui/text-input@2x.png"))
            }
        }
    },
]
