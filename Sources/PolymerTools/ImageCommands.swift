import Observation
import PolymerBase
import PolymerPlatform
import PolymerText
import PolymerRender
import PolymerUI
import PolymerApp
import PolymerDesign
import PolymerChecks
import I2S

@MainActor
let toolScreenNames = sampleScreenNames + ["design", "i2s"]

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

@MainActor
@Observable
private final class DesignShowcaseModel {
    var themeIndex = 0
    var notificationsOn = true
    var volume = 0.65
    var query = "Polymer"
    var status = "Ready"
    var selectedMode = "Grid"

    var activeTheme: Theme {
        switch themeIndex % 3 {
        case 0: .pgr
        case 1: .dark
        default: .light
        }
    }

    func cycleTheme() {
        themeIndex = (themeIndex + 1) % 3
        status = "Theme: \(activeTheme.name)"
    }
}

private struct DesignShowcaseView: View {
    let model: DesignShowcaseModel
    let font: Font

    var body: some View {
        let theme = model.activeTheme
        let commands = [
            Command(id: "theme.cycle", title: "Cycle Theme", category: "View", shortcut: KeyShortcut("cmd+t")) {
                model.cycleTheme()
            },
            Command(id: "status.reset", title: "Reset Status", category: "View") {
                model.status = "Reset"
            },
        ]
        VStack(alignment: .leading, spacing: theme.spacing.md) {
            HStack(spacing: theme.spacing.sm) {
                Text("Workspace")
                    .accessibilityIdentifier("workspace.title")
                PolymerBadge(theme.name, tone: .accent)
                Spacer()
                Text(model.status)
                    .foregroundStyle(theme.colors.textSecondary)
            }
            HairlineDivider()
            PolymerPanel {
                VStack(alignment: .leading, spacing: theme.spacing.sm) {
                    PolymerTextField("Search", text: Binding(get: { model.query }, set: { model.query = $0 }))
                        .accessibilityIdentifier("workspace.search")
                    HStack(spacing: theme.spacing.md) {
                        PolymerToggle("Notifications", isOn: Binding(get: { model.notificationsOn }, set: { model.notificationsOn = $0 }))
                            .layoutPriority(1)
                        Spacer()
                        PolymerSegmentedControl(
                            options: [("Grid", "Grid"), ("List", "List"), ("Compact", "Compact")],
                            selection: Binding(get: { model.selectedMode }, set: { model.selectedMode = $0 })
                        )
                        .layoutPriority(1)
                    }
                    PolymerSlider(value: Binding(get: { model.volume }, set: { model.volume = $0 }), in: 0...1, width: 220)
                    PolymerProgressBar(value: model.volume, label: "Level", showsPercentage: true)
                    HStack(spacing: theme.spacing.sm) {
                        Button("Cycle Theme") { model.cycleTheme() }
                            .buttonStyle(.polymerPrimary)
                        Button("Reset") { model.status = "Reset" }
                            .buttonStyle(.polymerSecondary)
                    }
                }
            }
            .accessibilityIdentifier("workspace.panel")
            .contextMenu {
                PolymerContextMenu(commands: commands)
            }
        }
        .padding(theme.spacing.md)
        .frame(width: 480, height: 340, alignment: .topLeading)
        .background(theme.colors.background)
        .font(font)
        .theme(theme)
    }
}

@MainActor
private func buildDesignScreen(root: String, scale: Double) throws -> ViewTree {
    let face = try TextReference.font(root: root, "Geist-Regular.otf")
    let model = DesignShowcaseModel()
    var env = EnvironmentValues()
    env.displayScale = scale
    return ViewTree(DesignShowcaseView(model: model, font: Font(face, size: 13)), environment: env)
}

/// A sample screen as a live tree, after the input steps have been applied in order.
@MainActor
func screenTree(_ name: String, scale: Double, steps: [(option: String, value: String)]) throws -> ViewTree {
    let tree: ViewTree
    if name == "design" {
        tree = try buildDesignScreen(root: ".", scale: scale)
    } else if name == "i2s" {
        tree = try buildI2SScreen(root: ".", scale: scale)
    } else if let sample = try sampleTree(name, root: ".", scale: scale) {
        tree = sample
    } else {
        print("Unknown screen \"\(name)\". Available: \(toolScreenNames.joined(separator: ", "))")
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
        } else if step.option == "--right-click" {
            let handled: Bool
            if step.value.hasPrefix("#") {
                handled = tree.rightClick(id: String(step.value.dropFirst()))
            } else {
                handled = tree.rightClick(text: step.value)
            }
            if !handled {
                print("--right-click \"\(step.value)\": no element with a .contextMenu matched \"\(step.value)\". `polymer tree \(name)` lists texts and #ids on the screen.")
                Platform.process.exit(1)
            }
        } else if step.option == "--right-click-id" {
            if !tree.rightClick(id: step.value) {
                print("--right-click-id \"\(step.value)\": no element with accessibilityIdentifier \"\(step.value)\" has a .contextMenu.")
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

@MainActor
private func buildI2SScreen(root: String, scale: Double) throws -> ViewTree {
    let font = try TextReference.font(root: root, "GeistMono-Regular.otf")
    let model = I2SModel(tracks: I2SSample.tracks())
    var env = EnvironmentValues()
    env.displayScale = scale
    return ViewTree(i2sRootView(model: model, sans: font, mono: font), environment: env)
}
