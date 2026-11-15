// Checks for the accessibility tree: roles, labels, values, and acting on it.
import PolymerBase
import PolymerRender
import PolymerPlatform
import PolymerUI

struct AccessibilityScreen: View {
    let model: CounterModel
    let font: Font
    let photo: Bitmap
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Library").accessibilityAddTraits(.isHeader)
            HStack {
                Button("Add") { model.count += 1 }
                Button { model.count = 0 } label: { HStack { Text("Reset"); Text("all") } }
                Button("Gone") {}.disabled(true)
            }
            Text("\(model.count) items").accessibilityValue("\(model.count)")
            Image(photo).resizable().frame(width: 20, height: 20).accessibilityLabel("Cover")
            Image(photo).resizable().frame(width: 20, height: 20)
            Text("hidden").accessibilityHidden(true)
            VStack { Text("Track"); Text("3:42") }.accessibilityElement(children: .combine)
            VStack { Text("A"); Text("B") }.accessibilityElement(children: .contain).accessibilityLabel("Pair")
            Color.white.frame(width: 10, height: 10).accessibilityElement().accessibilityLabel("Swatch").accessibilityHint("A colour")
        }
        .font(font)
    }
}

@MainActor let accessibilityChecks: [Check] = [
    Check("ui.accessibility") { c in
        let font = Font(try TextReference.font(root: c.root, "Geist-Regular.otf"), size: 13)
        let photo = try JPEG.decode(try Platform.files.read(Path.join(c.root, "Tests/Fixtures/Images/grey.jpg")))
        let model = CounterModel()
        let tree = ViewTree(AccessibilityScreen(model: model, font: font, photo: photo))
        let text = tree.accessibilityDescription
        let lines = text.split(separator: "\n").map { line -> String in
            // Frames are checked separately; compare roles and words.
            var s = String(line)
            if let open = s.firstIndex(of: "("), let close = s.firstIndex(of: ")") {
                // The frame and the space before it.
                s.removeSubrange(s.index(before: open)...close)
            }
            return s
        }
        c.expectEqual(lines, [
            "text \"Library\" [header]",
            "button \"Add\"",
            "button \"Reset, all\"",
            "button \"Gone\" disabled",
            "text \"0 items\" value \"0\"",
            "image \"Cover\"",
            "image",
            "group \"Track, 3:42\"",
            "group \"Pair\"",
            "  text \"A\"",
            "  text \"B\"",
            "group \"Swatch\" hint \"A colour\"",
        ], "the accessibility tree:\n\(text)")
        c.expect(text.hasPrefix("text (0, 0, "), "frames are screen points:\n\(text)")

        // Pressing through the tree runs the button, as a screen reader does.
        c.expect(tree.accessibilityPress(label: "Add"), "press Add")
        c.expect(tree.accessibilityDescription.contains("text (") && tree.accessibilityDescription.contains("\"1 items\" value \"1\""), "the value follows the state:\n\(tree.accessibilityDescription)")
        c.expect(!tree.accessibilityPress(label: "Gone"), "a disabled button can't be pressed")
        c.expect(!tree.accessibilityPress(label: "Nothing"), "no such button")

        // Focus shows on the focused element.
        tree.key("tab")
        c.expect(tree.accessibilityDescription.contains("button") && tree.accessibilityDescription.split(separator: "\n").first { $0.contains("focused") }?.contains("\"Add\"") == true,
                 "Tab focuses Add, and the tree says so:\n\(tree.accessibilityDescription)")
    },
]

