// Live interactive window preview (`polymer preview <screen>`).
// Opens a native Win32 window on Windows or AppKit window on macOS via Platform.windowRunner.
import PolymerBase
import PolymerPlatform
import PolymerRender
import PolymerUI

@MainActor
func previewCommand(screen: String, scale: Double, steps: [(option: String, value: String)]) throws {
    guard let runner = Platform.windowRunner else {
        print("No window runner is installed on this platform.")
        Platform.process.exit(1)
    }

    let tree = try screenTree(screen, scale: scale, steps: steps)
    tree.update()
    let initialWidth = max(480, Int(tree.size.width.rounded(.up)))
    let initialHeight = max(320, Int(tree.size.height.rounded(.up)))

    let options = WindowOptions(
        title: "Polymer — \(screen)",
        width: initialWidth,
        height: initialHeight,
        resizable: true,
        darkGlass: true,
        minWidth: 320,
        minHeight: 240
    )

    try runner.runWindow(
        options: options,
        onEvent: { event in
            switch event {
            case .resized(let size, let newScale):
                if newScale > 0 && abs(tree.environment.displayScale - newScale) > 1e-6 {
                    var env = tree.environment
                    env.displayScale = newScale
                    tree.environment = env
                }
                tree.proposedSize = ProposedViewSize(width: size.width, height: size.height)
                tree.update()
            case .pointerMoved(let point):
                tree.pointerMoved(to: point)
            case .pointerDown(let point, let button):
                if button == .right {
                    _ = tree.secondaryClick(at: point)
                } else if button == .left {
                    tree.pointerDown(at: point)
                }
            case .pointerUp(let point, let button):
                if button == .left {
                    _ = tree.pointerUp(at: point)
                }
            case .pointerExited:
                tree.pointerExited()
            case .scroll(let point, let dx, let dy):
                _ = tree.scroll(at: point, dx: dx, dy: dy)
            case .key(let keyEvent):
                guard keyEvent.isDown else { return }
                let text = keyEvent.keyPressText
                if KeyPress(text) != nil {
                    _ = tree.key(text)
                } else if !keyEvent.characters.isEmpty {
                    _ = tree.key(keyEvent.characters)
                }
            case .tick(let dt):
                _ = tree.tick(dt)
            case .closed:
                break
            }
        },
        renderFrame: {
            let bmp = tree.render(background: Color(hex: 0x0A0A0B))
            return FrameBuffer(width: bmp.width, height: bmp.height, pixels: bmp.pixels)
        },
        needsAnimation: {
            tree.hasActiveAnimations
        }
    )
}
