import PolymerBase
import PolymerPlatform
import PolymerRender
import PolymerUI
import PolymerChecks

/// `polymer zoom <in.png> <out.png> x y width height factor`: crop and enlarge (nearest neighbour), for inspecting pixels.
func zoomCommand(_ a: [String]) throws {
    guard a.count == 7, let x = Int(a[2]), let y = Int(a[3]), let w = Int(a[4]), let h = Int(a[5]), let f = Int(a[6]) else {
        print("usage: polymer zoom <in.png> <out.png> x y width height factor")
        Platform.process.exit(2)
    }
    let src = try PNG.decode(try Platform.files.read(a[0]))
    var out = Bitmap(width: w * f, height: h * f)
    for oy in 0..<h * f {
        for ox in 0..<w * f {
            let sx = min(src.width - 1, x + ox / f), sy = min(src.height - 1, y + oy / f)
            let s = (sy * src.width + sx) * 4, o = (oy * w * f + ox) * 4
            for c in 0..<4 { out.pixels[o + c] = src.pixels[s + c] }
        }
    }
    try Platform.files.write(PNG.encode(out), to: a[1])
}

/// A sample screen as a live tree, after the `--click` and `--scroll` steps have been applied in order.
@MainActor
func screenTree(_ name: String, scale: Double, steps: [(option: String, value: String)]) throws -> ViewTree {
    guard let tree = try sampleTree(name, root: ".", scale: scale) else {
        print("Unknown screen \"\(name)\". Available: \(sampleScreenNames.joined(separator: ", "))")
        Platform.process.exit(2)
    }
    for step in steps {
        tree.update()
        if step.option == "--click" {
            if !tree.click(text: step.value) {
                print("--click \"\(step.value)\": no visible, clickable text reads exactly that. `polymer tree \(name)` lists the texts on the screen; scroll first if it is outside its scroll view.")
                Platform.process.exit(1)
            }
        } else if step.option == "--click-id" {
            if !tree.click(id: step.value) {
                print("--click-id \"\(step.value)\": no element has accessibilityIdentifier \"\(step.value)\". `polymer tree \(name)` lists #ids on the screen.")
                Platform.process.exit(1)
            }
        } else if step.option == "--hover" || step.option == "--press" {
            guard let p = tree.point(ofText: step.value) else {
                print("\(step.option) \"\(step.value)\": no visible text reads exactly that. `polymer tree \(name)` lists the texts on the screen.")
                Platform.process.exit(1)
            }
            if step.option == "--hover" { tree.pointerMoved(to: p) } else { tree.pointerDown(at: p) }
        } else if step.option == "--key" {
            guard KeyPress(step.value) != nil else {
                print("--key \"\(step.value)\" is not a key. Use a character or tab, space, return, escape, delete, up, down, left, right, home, end, pageup, pagedown; add shift+, ctrl+, alt+ or cmd+ in front.")
                Platform.process.exit(2)
            }
            if !tree.key(step.value) {
                print("--key \"\(step.value)\": nothing on the screen handled it. `polymer tree \(name)` shows which element is focused.")
                Platform.process.exit(1)
            }
        } else {
            guard let dy = Double(step.value) else {
                print("--scroll needs a number of points, got \"\(step.value)\".")
                Platform.process.exit(2)
            }
            if !tree.scroll(at: Point(x: tree.size.width / 2, y: tree.size.height / 2), dy: dy) {
                print("--scroll \(step.value): nothing under the middle of the screen can scroll that way.")
                Platform.process.exit(1)
            }
        }
    }
    tree.update()
    return tree
}
