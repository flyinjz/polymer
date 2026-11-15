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
    init(width: Int, height: Int, scale: Double) { pixelWidth = width; pixelHeight = height; self.scale = scale }
    var nativeHandle: UInt { 0 }
    func show() {}
    func close() { closed = true }
    nonisolated func setNeedsFrame() { frameRequests.add(1, ordering: .relaxed) }
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
    },
]
