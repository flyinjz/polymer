// Windows without opening any: the backend checks its own translations
// (input, DPI), and the shared host is driven by synthetic window events,
// drawing on the GPU and presenting offscreen through the same buffers and
// damage tracking a window uses. Its images must match the CPU.
import Synchronization
import PolymerBase
import PolymerPlatform
import PolymerRender
import PolymerGPU
import PolymerUI
import PolymerApp

/// A window that is never on screen.
@MainActor
final class TestWindow: PlatformWindow {
    var pixelWidth: Int
    var pixelHeight: Int
    var scale: Double
    var title = "test"
    weak var delegate: WindowDelegate?
    var closed = false
    nonisolated let frameRequests = Atomic<Int>(0)
    /// The last `setTextInput`, and how many there were.
    var textInput: Rect?
    var textInputCalls = 0
    init(width: Int, height: Int, scale: Double) { pixelWidth = width; pixelHeight = height; self.scale = scale }
    var nativeHandle: UInt { 0 }
    func show() {}
    func close() { closed = true }
    func setTextInput(_ caret: Rect?) { textInput = caret; textInputCalls += 1 }
    nonisolated func setNeedsFrame() { frameRequests.add(1, ordering: .relaxed) }
}

@Observable
final class HostInputModel {
    var name = ""
    var wide = false
    var log: [String] = []
}

/// A text field, a context menu and something to animate, driven through window events.
struct HostInputScreen: View {
    let model: HostInputModel
    let font: Font
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name", text: Binding(get: { model.name }, set: { model.name = $0 })).frame(width: 160)
            Text("Row").contextMenu { Button("Delete") { model.log.append("delete") } }
            Color.white.frame(width: model.wide ? 60 : 30, height: 10)
        }
        .font(font)
        .frame(width: 300, height: 150, alignment: .topLeading)
    }
}

/// The top-left `width` x `height` of an RGBA image `stride` pixels wide.
func crop(_ rgba: [UInt8], stride: Int, width: Int, height: Int) -> Bitmap {
    var out = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for i in 0..<(width * 4) { out[y * width * 4 + i] = rgba[y * stride * 4 + i] }
    }
    return Bitmap(width: width, height: height, pixels: out)
}

@MainActor let windowChecks: [Check] = [
    Check("platform.window") { c in
        if let windows = Platform.windows {
            for f in windows.selfCheck() { c.fail("window backend: \(f)") }
        } else {
            c.note("no window backend for this OS yet")
        }
        // Which key downs the host leaves to `.text` while a field has focus.
        c.expect(WindowHost.typesText("a", modifiers: []) && WindowHost.typesText("A", modifiers: [.shift]), "letters type")
        c.expect(WindowHost.typesText("@", modifiers: [.command, .option]), "AltGr (Ctrl and Alt on Windows) types")
        c.expect(WindowHost.typesText("å", modifiers: [.option]), "Option types")
        c.expect(!WindowHost.typesText("a", modifiers: [.command]) && !WindowHost.typesText("\u{1}", modifiers: [.command])
                 && !WindowHost.typesText("a", modifiers: [.control]), "shortcuts do not")
        c.expect(!WindowHost.typesText("\r", modifiers: []) && !WindowHost.typesText("\u{8}", modifiers: [])
                 && !WindowHost.typesText("", modifiers: []) && !WindowHost.typesText("\u{F700}", modifiers: []),
                 "control characters, nothing and function keys do not")
        guard GPU.isAvailable else { c.note("no GPU backend: the host is not checked"); return }

        let background = Color(white: 0.063)
        let window = TestWindow(width: 600, height: 500, scale: 2)
        let tree = try sampleTree("counter", root: c.root, scale: 2)!
        let host = try WindowHost(tree: tree, window: window, backend: try GPU.makeBackend(), background: background, offscreen: true)
        var t = 0.0
        host.clock = { t }
        c.expect(window.delegate === host, "the host is the window's delegate")
        // The same screen on the CPU, given the same input.
        let reference = try sampleTree("counter", root: c.root, scale: 2)!
        reference.proposedSize = ProposedViewSize(width: 300, height: 250)

        @MainActor func expectFrame(_ what: String) throws {
            t += 1 / 60
            let more = host.frame(time: t)
            c.expect(!more, "\(what): no more frames asked for when nothing animates")
            let cpu = reference.render(background: background)
            guard let shown = try host.presenter.readBack() else { c.fail("\(what): nothing presented"); return }
            let d = ImageDifference(crop(shown, stride: host.presenter.width, width: cpu.width, height: cpu.height), cpu)
            c.expect(d.max <= GPUTolerance.max && d.mean <= GPUTolerance.mean, "\(what): presented image differs from the CPU: \(d)")
        }

        try expectFrame("first frame")
        c.expectEqual(host.lastDamage, [PixelRect(x: 0, y: 0, width: 600, height: 500)], "the first frame presents everything")

        // A click through window events.
        guard let add = reference.point(ofText: "Add") else { c.fail("no Add button"); return }
        let before = window.frameRequests.load(ordering: .relaxed)
        for e: WindowEvent in [.pointerMoved(add), .pointerDown(add, .primary), .pointerUp(add, .primary)] { host.handle(e) }
        _ = reference.click(at: add)
        c.expect(window.frameRequests.load(ordering: .relaxed) > before, "input asks for a frame")
        try expectFrame("after a click")
        let area = host.lastDamage.reduce(0) { $0 + $1.width * $1.height }
        c.expect(area > 0 && area < 600 * 500 / 8, "a click presents only its damage (\(area) pixels)")

        // Keys: Tab focuses the first button, Space presses it.
        host.handle(.keyDown(.tab, characters: "\t", modifiers: [], isRepeat: false))
        host.handle(.keyDown(.space, characters: " ", modifiers: [], isRepeat: false))
        _ = reference.key(KeyPress(key: .tab)); _ = reference.key(KeyPress(key: .space))
        try expectFrame("after Tab and Space")

        // A frame with nothing changed presents nothing.
        let presented = host.framesPresented
        _ = host.frame(time: t + 1)
        c.expectEqual(host.framesPresented, presented, "an unchanged frame is not presented")

        // A new size and scale.
        window.pixelWidth = 450; window.pixelHeight = 375; window.scale = 1.5
        host.handle(.resized(width: 450, height: 375, scale: 1.5))
        reference.environment.displayScale = 1.5
        try expectFrame("after resizing to scale 1.5")
        c.expectEqual(host.presenter.width, 450, "the presenter follows the window's size")

        host.handle(.closeRequested)
        c.expect(window.closed, "asking to close closes")
        c.expectEqual(WindowHost.keyPress(.character("a"), characters: "A", modifiers: [.shift, .command], isRepeat: true).modifiers,
                      [.shift, .command], "modifiers carry over")

        // Text, clicks, context menus and animation through window events.
        let font = Font(try TextReference.font(root: c.root, "Geist-Regular.otf"), size: 13)
        let im = HostInputModel()
        let iw = TestWindow(width: 300, height: 150, scale: 1)   // the screen's size: nothing centres it
        let cb = MemoryClipboard("pasted")
        let ih = try WindowHost(tree: ViewTree(HostInputScreen(model: im, font: font)), window: iw, backend: try GPU.makeBackend(),
                                background: background, offscreen: true, clipboard: cb)
        var it = 0.0
        ih.clock = { it }
        @MainActor func step() -> Bool { it += 1 / 60; return ih.frame(time: it) }
        _ = step()
        c.expect(iw.textInputCalls > 0 && iw.textInput == nil, "no text input while no field has focus")
        c.expect(ih.tree.clipboard === cb, "the host gives the tree its clipboard")

        // Frames keep coming while something animates, and stop after.
        withAnimation(.linear(duration: 1)) { im.wide = true }
        c.expect(step(), "an animation asks for the next frame")
        it += 2
        _ = step()
        c.expect(!step(), "and stops asking once it ends")

        // A click focuses the field: text input goes on, at its caret.
        let inField = Point(x: 80, y: 8)
        for e: WindowEvent in [.pointerDown(inField, .primary), .pointerUp(inField, .primary)] { ih.handle(e) }
        c.expect(ih.tree.acceptsTextInput && iw.textInput != nil, "a click on a field turns text input on: \(String(describing: iw.textInput))")

        // A key that types comes again as text: inserted once, as the text says (dead keys, AltGr).
        ih.handle(.keyDown(.character("h"), characters: "h", modifiers: [], isRepeat: false))
        ih.handle(.text("h"))
        c.expectEqual(im.name, "h", "a typed key inserts once")
        ih.handle(.keyDown(.character("e"), characters: "e", modifiers: [], isRepeat: false))
        ih.handle(.text("é"))
        c.expectEqual(im.name, "hé", "the composed character, not the key's")
        ih.handle(.keyDown(.backspace, characters: "\u{8}", modifiers: [], isRepeat: false))
        c.expectEqual(im.name, "h", "keys that type nothing still edit")

        // Input method compositions.
        ih.handle(.markedText("ni", selectedRange: 2..<2))
        c.expect(im.name == "hni" && ih.tree.markedTextRange == 1..<3, "marked text in place: \(im.name) \(String(describing: ih.tree.markedTextRange))")
        c.expect(iw.textInput != nil, "the input method still has a rectangle")
        ih.handle(.text("\u{4F60}"))
        c.expect(im.name == "h\u{4F60}" && ih.tree.markedTextRange == nil, "the confirmed text replaces it: \(im.name)")
        ih.handle(.markedText("", selectedRange: 0..<0))
        c.expect(im.name == "h\u{4F60}" && ih.tree.selectedTextRange == 2..<2, "ending with nothing marked changes nothing")

        // Ctrl-V (Cmd-V) pastes from the clipboard the host was given.
        ih.handle(.keyDown(.character("v"), characters: "\u{16}", modifiers: [.command], isRepeat: false))
        c.expectEqual(im.name, "h\u{4F60}pasted", "paste from the host's clipboard")

        // Click counts from the window: a double click selects a word, a triple click everything.
        im.name = "one two"
        _ = step()
        let onOne = Point(x: 5, y: 8)
        ih.handle(.pointerDown(onOne, .primary, clickCount: 2)); ih.handle(.pointerUp(onOne, .primary))
        c.expectEqual(ih.tree.selectedTextRange, 0..<3, "a double click selects the word")
        ih.handle(.pointerDown(onOne, .primary, clickCount: 3)); ih.handle(.pointerUp(onOne, .primary))
        c.expectEqual(ih.tree.selectedTextRange, 0..<7, "a triple click selects everything")

        // The secondary button opens the context menu; its items run with the primary one.
        guard let row = ih.tree.point(ofText: "Row") else { c.fail("no Row text"); return }
        ih.handle(.pointerDown(row, .secondary)); ih.handle(.pointerUp(row, .secondary))
        _ = step()
        c.expect(ih.tree.elementTree.contains("Menu ("), "a right click opens the context menu:\n\(ih.tree.elementTree)")
        guard let delete = ih.tree.point(ofText: "Delete") else { c.fail("no Delete item:\n\(ih.tree.elementTree)"); return }
        ih.handle(.pointerDown(delete, .primary)); ih.handle(.pointerUp(delete, .primary))
        c.expectEqual(im.log, ["delete"], "a click on its item runs it")
    },
]
