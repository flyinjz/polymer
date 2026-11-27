// Checks for PolymerDesign: the tokens, every component's behaviour and
// look (pixels read from offscreen renders), the command system, Customize
// and its saved form, element names, and the `components` sample screen.
import PolymerBase
import PolymerPlatform
import PolymerText
import PolymerRender
import PolymerUI
import PolymerDesign

// MARK: Sample screen (`polymer render components`)

/// What the components sample changes when it is used.
@Observable
public final class ComponentsModel {
    public var shuffle = true
    public var volume = 0.6
    public var view = "albums"
    public var sort = "artist"
    public var query = ""
    public var selected = "albums"
    public var showSheet = false
    public var log: [String] = []
    public init() {}
}

/// Every PolymerDesign component in one window: a toolbar, a sidebar of
/// rows, a panel of controls, buttons, a picker and a scroll bar.
public struct SampleComponentsView: View {
    let model: ComponentsModel
    let theme: Theme
    let customize: CustomizeModel?
    let commands: CommandRegistry?
    let registry: DesignRegistry?

    public init(model: ComponentsModel, theme: Theme, customize: CustomizeModel? = nil,
                commands: CommandRegistry? = nil, registry: DesignRegistry? = nil) {
        self.model = model; self.theme = theme; self.customize = customize
        self.commands = commands; self.registry = registry
    }

    public var body: some View {
        let m = model
        let t = theme
        VStack(alignment: .leading, spacing: 0) {
            PToolbar {
                PButton(symbol: "+", help: "New playlist") { m.log.append("new-playlist") }
                    .tooltip("New playlist")
                PSegmentedControl("View", selection: Binding(get: { m.view }, set: { m.view = $0 }), options: [
                    PickerOption("Albums", value: "albums"),
                    PickerOption("Artists", value: "artists"),
                    PickerOption("Songs", value: "songs"),
                ])
                Spacer()
                PTextField("Search", text: Binding(get: { m.query }, set: { m.query = $0 }))
                    .frame(width: 160)
                PButton("Import", kind: .primary, shortcut: KeyboardShortcut("i")) { m.log.append("import") }
            }
            PSidebarLayout {
                VStack(alignment: .leading, spacing: 0) {
                    PSectionHeader("Library")
                    ForEach(["Albums", "Artists", "Recently added"], id: \.self) { title in
                        PListRow(title, detail: title == "Albums" ? "48" : title == "Artists" ? "12" : "9",
                                 isSelected: m.selected == ElementPath.slug(title)) {
                            m.selected = ElementPath.slug(title)
                        }
                    }
                    PSectionHeader("Playlists")
                    ForEach(["Focus", "Late night"], id: \.self) { title in
                        PListRow(title, isSelected: m.selected == ElementPath.slug(title)) {
                            m.selected = ElementPath.slug(title)
                        }
                    }
                }
            } detail: {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: t.space.l) {
                        PPanel("Playback") {
                            PToggle("Shuffle", isOn: Binding(get: { m.shuffle }, set: { m.shuffle = $0 }))
                            PSlider("Volume", value: Binding(get: { m.volume }, set: { m.volume = $0 }))
                            PProgressBar("Import progress", value: 0.4)
                        }
                        .frame(width: 280)
                        HStack(spacing: t.space.s) {
                            PButton("Play", kind: .primary) { m.log.append("play") }
                            PButton("Queue") { m.log.append("queue") }
                            PButton("Details", kind: .plain) { m.showSheet = true }
                        }
                        PPicker("Sort by", selection: Binding(get: { m.sort }, set: { m.sort = $0 }), options: [
                            PickerOption("Artist", value: "artist"),
                            PickerOption("Title", value: "title"),
                            PickerOption("Year", value: "year"),
                        ])
                        .frame(width: 160)
                    }
                    .padding(t.space.l)
                    Spacer(minLength: 0)
                    PScrollBar(visible: 0.3, position: 0.2)
                        .padding(EdgeInsets(top: t.space.xs, leading: 0, bottom: t.space.xs, trailing: t.space.xs))
                }
            }
        }
        .frame(width: 720, height: 480)
        .panelSheet(isPresented: Binding(get: { m.showSheet }, set: { m.showSheet = $0 }), title: "Details") {
            Text("Three albums, 41 tracks.").textStyle(.body, t.gray.secondaryText, theme: t)
            PButton("Done", kind: .primary) { m.showSheet = false }
        }
        .commands {
            Command("library.play", "Play", shortcut: KeyboardShortcut("p")) { m.log.append("play") }
            Command("library.new-playlist", "New playlist", shortcut: KeyboardShortcut("n")) { m.log.append("new-playlist") }
        }
        .designRoot(theme: t, customize: customize, commands: commands, registry: registry)
    }
}

/// The house theme with the bundled fonts.
@MainActor
public func designTheme(root: String) throws -> Theme {
    Theme(sans: try TextReference.font(root: root, "Geist-Regular.otf"),
          mono: try TextReference.font(root: root, "GeistMono-Regular.otf"))
}

@MainActor
public func sampleComponents(root: String, model: ComponentsModel = ComponentsModel(),
                             customize: CustomizeModel? = CustomizeModel(), commands: CommandRegistry? = CommandRegistry(),
                             registry: DesignRegistry? = DesignRegistry()) throws -> SampleComponentsView {
    SampleComponentsView(model: model, theme: try designTheme(root: root), customize: customize,
                         commands: commands, registry: registry)
}

// MARK: Helpers

/// State the design checks drive.
@Observable
final class DesignProbe {
    var on = false
    var value = 0.0
    var choice = "albums"
    var sort = "artist"
    var show = true
    var log: [String] = []
}

/// What a `LookProbe` saw in the environment it was built in.
final class LookBox {
    var panel: PanelLook?
    var input: TextInputLook?
    func update(_ panel: PanelLook, _ input: TextInputLook) { self.panel = panel; self.input = input }
}

/// Records the panel and text-input looks of the environment around it.
struct LookProbe: View {
    @Environment(\.panelLook) var panel
    @Environment(\.textInputLook) var input
    let box: LookBox
    var body: some View {
        let _ = box.update(panel, input)
        Color.clear
    }
}

/// Holds the proxy a `ScrollViewReader` hands its content.
final class ScrollBox { var proxy: ScrollViewProxy? }

/// Thirty 20-point rows in a 200-point window, with the bar following the reader.
struct ScrollProbe: View {
    let box: ScrollBox
    var body: some View {
        ScrollViewReader { proxy in
            let _ = box.proxy = proxy
            HStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(0..<30) { i in
                            Text("Row \(i)").frame(height: 20).id(i)
                        }
                    }
                }
                PScrollBar(proxy)
            }
            .frame(width: 300, height: 200)
        }
    }
}

/// A window for one check: the components top-left on the window grey.
struct DesignHarness<Content: View>: View {
    let theme: Theme
    let customize: CustomizeModel?
    let commands: CommandRegistry?
    let registry: DesignRegistry?
    let width: Double
    let height: Double
    let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(8)
            .frame(width: width, height: height, alignment: .topLeading)
            .background(Rectangle().fill(theme.gray.background))
            .designRoot(theme: theme, customize: customize, commands: commands, registry: registry)
    }
}

@MainActor
func designTree<Content: View>(_ theme: Theme, customize: CustomizeModel? = nil, commands: CommandRegistry? = nil,
                               registry: DesignRegistry?, width: Double = 480, height: Double = 320,
                               @ViewBuilder _ content: () -> Content) -> ViewTree {
    ViewTree(DesignHarness(theme: theme, customize: customize, commands: commands, registry: registry,
                           width: width, height: height, content: content()))
}

/// The element tree's lines, without indentation.
@MainActor
func designLines(_ tree: ViewTree) -> [String] {
    tree.elementTree.split(separator: "\n").map { String($0.drop { $0 == " " }) }
}

/// True when some text in the tree (a menu item, a label) reads exactly `text`.
@MainActor
func designShows(_ tree: ViewTree, _ text: String) -> Bool {
    designLines(tree).contains { $0.hasPrefix("Text (") && $0.hasSuffix("\"\(text)\"") }
}

/// The red, green and blue (0-255) of the pixel under `p` (in points).
func designPixel(_ b: Bitmap, _ p: Point, scale: Double = 1) -> [Int] {
    guard b.width > 0, b.height > 0 else { return [0, 0, 0] }
    let x = min(max(Int(p.x * scale), 0), b.width - 1), y = min(max(Int(p.y * scale), 0), b.height - 1)
    let i = (y * b.width + x) * 4
    return [Int(b.pixels[i]), Int(b.pixels[i + 1]), Int(b.pixels[i + 2])]
}

func designNear(_ px: [Int], _ c: Color, tolerance: Int = 4) -> Bool {
    let want = [c.red, c.green, c.blue].map { Int(($0 * 255).rounded()) }
    return zip(px, want).allSatisfy { abs($0 - $1) <= tolerance }
}

func designBrightness(_ px: [Int]) -> Int { px.reduce(0, +) }

func designLuminance(_ c: Color) -> Double { c.red + c.green + c.blue }

/// A point inside a frame, `dx` and `dy` points from its top-left corner.
func designInside(_ f: Rect?, _ dx: Double, _ dy: Double) -> Point {
    guard let f else { return Point(x: -1, y: -1) }
    return Point(x: f.minX + dx, y: f.minY + dy)
}

func designLeftMiddle(_ f: Rect?, _ dx: Double) -> Point {
    guard let f else { return Point(x: -1, y: -1) }
    return Point(x: f.minX + dx, y: f.midY)
}

/// The frames of every element of `role` in the tree, top to bottom.
@MainActor
func designFrames(_ tree: ViewTree, _ role: String) -> [Rect] {
    designLines(tree).compactMap { line in
        guard line.hasPrefix(role + " ("), let open = line.firstIndex(of: "("),
              let close = line.firstIndex(of: ")") else { return nil }
        let body = line[line.index(after: open)..<close]
        let n = body.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "x" }).compactMap { Double($0) }
        guard n.count == 4 else { return nil }
        return Rect(x: n[0], y: n[1], width: n[2], height: n[3])
    }
}

// MARK: Checks

@MainActor let designChecks: [Check] = [
    Check("design.tokens") { c in
        let g = Grays()
        c.expect(designLuminance(g.background) < designLuminance(g.surface)
                 && designLuminance(g.surface) < designLuminance(g.raised)
                 && designLuminance(g.raised) < designLuminance(g.text),
                 "surfaces get lighter: background, surface, raised, text")
        c.expect(designLuminance(g.tertiaryText) < designLuminance(g.secondaryText)
                 && designLuminance(g.secondaryText) < designLuminance(g.text), "text greys get lighter by importance")
        for col in [g.background, g.surface, g.raised, g.text, g.secondaryText, g.tertiaryText] {
            c.expect(col.red == col.green && col.green == col.blue, "\(col) is a grey")
        }

        let plain = Theme()
        c.expect(plain.font(.body) == nil, "a theme without fonts has no fonts")
        c.expectEqual(plain.line, 1, "lines are 1 point")
        c.expectEqual(plain.cornerRadius, 0, "the grid look is square")
        let big = plain.scaled(by: 2)
        c.expectEqual(big.space.s, 16, "spacing scales")
        c.expectEqual(big.size.control, 48, "control sizes scale")
        c.expectEqual(big.line, 1, "lines stay 1 point")
        c.expectEqual(big.scale, 2, "the theme knows its scale")
        c.expectEqual(plain.with(accent: .white).accent, .white, "the accent can change")

        c.expectEqual(DesignRules.problems(inTitle: "Play next"), [], "sentence case passes")
        c.expectEqual(DesignRules.problems(inTitle: "OK").count, 0, "short capitals pass")
        c.expectEqual(DesignRules.problems(inTitle: "PLAY NEXT").count, 1, "capitals are flagged")
        c.expectEqual(DesignRules.problems(inTitle: "// Play").count, 1, "a // prefix is flagged")
        c.expectEqual(DesignRules.problems(inTitle: " ").count, 1, "an empty title is flagged")

        c.expectEqual(ElementPath.slug("Play Next"), "play-next")
        c.expectEqual(ElementPath.slug("  Hello, World! "), "hello-world")
        c.expectEqual(ElementPath.slug("Track 12"), "track-12")
        c.expectEqual(ElementPath.slug("%%"), "element")
        c.expectEqual(ElementPath.join("", "toolbar"), "toolbar")
        c.expectEqual(ElementPath.join("toolbar", "play"), "toolbar/play")

        // The accent comes from the environment.
        let t = try designTheme(root: c.root)
        let red = Color(red: 0.85, green: 0.2, blue: 0.2)
        let r = DesignRegistry()
        let tree = designTree(t, registry: r) {
            PButton("Go", kind: .primary) {}
            PButton("Stay", kind: .primary) {}.accent(red)
        }
        let img = tree.render(background: .black)
        c.expect(designNear(designPixel(img, designLeftMiddle(r.frame(of: "go"), 3)), t.accent),
                 "a primary button is the accent: \(designPixel(img, designLeftMiddle(r.frame(of: "go"), 3)))")
        c.expect(designNear(designPixel(img, designLeftMiddle(r.frame(of: "stay"), 3)), red),
                 ".accent changes it: \(designPixel(img, designLeftMiddle(r.frame(of: "stay"), 3)))")
    },

    Check("design.buttons") { c in
        let t = try designTheme(root: c.root)
        let m = DesignProbe()
        let r = DesignRegistry()
        let tree = designTree(t, registry: r) {
            PButton("Queue") { m.log.append("queue") }
            PButton("Delete") { m.log.append("delete") }.disabled(true)
            PButton("Save", shortcut: KeyboardShortcut("s")) { m.log.append("save") }
            PButton(symbol: "+", help: "Add") { m.log.append("add") }
        }
        let rest = tree.render(background: .black)
        c.expect(tree.click(element: "queue", in: r), "the button takes the click")
        c.expectEqual(m.log, ["queue"], "a click runs it")
        tree.click(element: "delete", in: r)
        c.expectEqual(m.log, ["queue"], "a disabled button does nothing")
        tree.key("cmd+s")
        c.expectEqual(m.log.last, "save", "its shortcut runs it")
        tree.click(element: "add", in: r)
        c.expectEqual(m.log.last, "add", "the icon button runs")
        if let f = r.frame(of: "add") {
            c.expectEqual(f.width, t.size.control, "an icon button is square")
            c.expectEqual(f.height, t.size.control, "at the control height")
        } else { c.fail("the icon button has no frame:\n\(r.description)") }
        c.expectEqual(r.frame(of: "queue")?.height, t.size.control, "buttons are the control height")

        // Hover, then pressed, each lighter than the last.
        let corner = designInside(r.frame(of: "queue"), 3, 3)
        let atRest = designPixel(rest, corner)
        c.expect(designNear(atRest, t.gray.raised), "a secondary button is raised grey: \(atRest)")
        tree.pointerMoved(to: Point(x: corner.x + 10, y: corner.y + 6))
        let hovered = designPixel(tree.render(background: .black), corner)
        c.expect(designBrightness(hovered) > designBrightness(atRest), "hover lightens it: \(hovered) after \(atRest)")
        tree.pointerDown(at: Point(x: corner.x + 10, y: corner.y + 6))
        let pressed = designPixel(tree.render(background: .black), corner)
        c.expect(designBrightness(pressed) > designBrightness(hovered), "pressing lightens it more: \(pressed) after \(hovered)")
        tree.pointerUp(at: Point(x: corner.x + 10, y: corner.y + 6))
        c.expectEqual(m.log.last, "queue", "and letting go runs it")
        tree.pointerMoved(to: Point(x: 470, y: 310))

        // Keyboard focus draws the accent ring at the edge.
        let edge = designLeftMiddle(r.frame(of: "queue"), 0.5)
        c.expect(!designNear(designPixel(tree.render(background: .black), edge), t.accent), "no ring before focus")
        tree.key("tab")
        c.expect(tree.focusedElement != nil, "Tab focuses the first button")
        let ring = designPixel(tree.render(background: .black), edge)
        c.expect(designNear(ring, t.accent), "the focus ring is the accent: \(ring)")
        tree.key("space")
        c.expectEqual(m.log.last, "queue", "Space presses the focused button")
        c.expectEqual(m.log.count, 5, "(each action ran once)")
    },

    Check("design.controls") { c in
        let t = try designTheme(root: c.root)
        let m = DesignProbe()

        // Toggle: a click anywhere on the row, or Space once focused.
        let r1 = DesignRegistry()
        let toggles = designTree(t, registry: r1) {
            PToggle("Shuffle", isOn: Binding(get: { m.on }, set: { m.on = $0 })).frame(width: 200)
        }
        _ = toggles.render(background: .black)
        toggles.click(element: "shuffle", in: r1)
        c.expect(m.on, "a click turns it on")
        let track = designInside(r1.frame(of: "shuffle"), 200 - t.size.toggleWidth + 1.5, t.size.control / 2)
        c.expect(designNear(designPixel(toggles.render(background: .black), track), t.accent),
                 "on is the accent: \(designPixel(toggles.render(background: .black), track))")
        toggles.key("tab")
        toggles.key("space")
        c.expect(!m.on, "Space turns it off")
        c.expect(toggles.accessibilityDescription.contains("value \"Off\""), "its value is spoken:\n\(toggles.accessibilityDescription)")

        // Slider: dragging sets the value under the pointer; keys move it.
        let r2 = DesignRegistry()
        let sliders = designTree(t, registry: r2) {
            PSlider("Volume", value: Binding(get: { m.value }, set: { m.value = $0 })).frame(width: 200)
        }
        _ = sliders.render(background: .black)
        if let f = r2.frame(of: "volume") {
            sliders.drag(from: Point(x: f.minX + t.size.thumb / 2, y: f.midY), to: Point(x: f.midX, y: f.midY))
            c.expectClose(m.value, 0.5, tolerance: 0.01, "dragging to the middle")
        } else { c.fail("the slider has no frame:\n\(r2.description)") }
        sliders.key("tab")
        sliders.key("end")
        c.expectClose(m.value, 1, tolerance: 1e-9, "End")
        sliders.key("left")
        c.expectClose(m.value, 0.95, tolerance: 1e-9, "Left moves a twentieth")
        sliders.key("home")
        c.expectClose(m.value, 0, tolerance: 1e-9, "Home")
        sliders.key("left")
        c.expectClose(m.value, 0, tolerance: 1e-9, "it stops at the end of the range")

        // Progress: the accent up to the value, the raised grey after it.
        let r3 = DesignRegistry()
        let bars = designTree(t, registry: r3) { PProgressBar("Import", value: 0.4).frame(width: 200) }
        let barImage = bars.render(background: .black)
        c.expect(designNear(designPixel(barImage, designLeftMiddle(r3.frame(of: "import"), 40)), t.accent), "done is the accent")
        c.expect(designNear(designPixel(barImage, designLeftMiddle(r3.frame(of: "import"), 160)), t.gray.raised), "the rest is raised grey")
        c.expectEqual(r3.frame(of: "import")?.height, t.size.progress, "a progress bar is the progress height")

        // Segmented control: each segment is a named part.
        let r4 = DesignRegistry()
        let segments = designTree(t, registry: r4) {
            PSegmentedControl("View", selection: Binding(get: { m.choice }, set: { m.choice = $0 }), options: [
                PickerOption("Albums", value: "albums"), PickerOption("Artists", value: "artists"),
            ])
        }
        _ = segments.render(background: .black)
        c.expect(r4.entry("view/artists")?.role == "Segment", "segments are parts:\n\(r4.description)")
        segments.click(element: "view/artists", in: r4)
        c.expectEqual(m.choice, "artists", "a click on a segment chooses it")
        let chosen = designPixel(segments.render(background: .black), designLeftMiddle(r4.frame(of: "view/artists"), 3))
        c.expect(designNear(chosen, t.accent), "the chosen segment is the accent: \(chosen)")

        // Picker: a menu of the options.
        let r5 = DesignRegistry()
        let pickers = designTree(t, registry: r5) {
            PPicker("Sort by", selection: Binding(get: { m.sort }, set: { m.sort = $0 }), options: [
                PickerOption("Artist", value: "artist"), PickerOption("Title", value: "title"), PickerOption("Year", value: "year"),
            ])
            .frame(width: 160)
        }
        c.expect(designShows(pickers, "Artist"), "it shows the choice")
        pickers.click(element: "sort-by", in: r5)
        c.expect(designLines(pickers).contains { $0.hasPrefix("Menu (") }, "a click opens the menu:\n\(pickers.elementTree)")
        pickers.click(text: "Year")
        c.expectEqual(m.sort, "year", "an item chooses it")
        c.expect(!designLines(pickers).contains { $0.hasPrefix("Menu (") }, "and the menu closes")
        c.expect(designShows(pickers, "Year"), "the picker shows the new choice")
    },

    Check("design.commands") { c in
        let m = DesignProbe()
        let reg = CommandRegistry {
            Command("doc.save", "Save", shortcut: KeyboardShortcut("s")) { m.log.append("save") }
            Command("doc.close", "Close", isEnabled: false) { m.log.append("close") }
        }
        c.expect(reg.run("doc.save"), "run by id")
        c.expect(!reg.run("doc.close"), "a disabled command doesn't run")
        c.expect(!reg.run("doc.nothing"), "an unknown id doesn't run")
        if let press = KeyPress("cmd+s") { c.expect(reg.handle(press), "run by shortcut") } else { c.fail("cmd+s is a key") }
        c.expectEqual(m.log, ["save", "save"], "each ran once")
        reg.register(Command("doc.save", "Save now") { m.log.append("save now") })
        c.expectEqual(reg.commands.count, 2, "registering an id again replaces it")
        c.expectEqual(reg.command("doc.save")?.title, "Save now")
        c.expectEqual(reg.problems, [], "no problems")
        c.expect(reg.description.contains("doc.close \"Close\" disabled"), "described:\n\(reg.description)")

        let bad = CommandRegistry {
            Command("a.save", "Save", shortcut: KeyboardShortcut("s")) {}
            Command("a.save-all", "SAVE ALL", shortcut: KeyboardShortcut("s")) {}
        }
        c.expectEqual(bad.problems.count, 2, "capitals and a shared shortcut: \(bad.problems)")

        // Right-click menus: the component's commands, then those around it, then Customize.
        let t = try designTheme(root: c.root)
        let r = DesignRegistry()
        let app = CommandRegistry()
        let tree = designTree(t, commands: app, registry: r) {
            VStack(alignment: .leading, spacing: 8) {
                PButton("Play", commands: [Command("track.like", "Like") { m.log.append("like") }]) { m.log.append("play") }
            }
            .commands {
                Command("doc.export", "Export", shortcut: KeyboardShortcut("e")) { m.log.append("export") }
            }
        }
        _ = tree.render()
        c.expect(app.command("doc.export") != nil, ".commands registers its commands:\n\(app.description)")
        c.expect(tree.contextClick(element: "play", in: r), "right-click opens a menu")
        let lines = designLines(tree)
        let like = lines.firstIndex { $0.hasSuffix("\"Like\"") }
        let export = lines.firstIndex { $0.hasSuffix("\"Export\"") }
        let customize = lines.firstIndex { $0.hasSuffix("\"Customize\"") }
        if let like, let export, let customize {
            c.expect(like < export && export < customize, "own commands, then inherited, then Customize:\n\(tree.elementTree)")
        } else { c.fail("the menu lacks Like, Export or Customize:\n\(tree.elementTree)") }
        c.expect(lines.contains { $0.hasSuffix("\"cmd+e\"") }, "items show their shortcuts")
        tree.click(text: "Export")
        c.expectEqual(m.log.last, "export", "an item runs its command")
        c.expect(!designLines(tree).contains { $0.hasPrefix("Menu (") }, "and the menu closes")
        c.expect(tree.key("cmd+e", commands: app), "a command's shortcut runs through the registry")
        c.expectEqual(Array(m.log.suffix(2)), ["export", "export"], "it ran again")
        c.expect(!tree.key("cmd+j", commands: app), "an unused shortcut does nothing")
    },

    Check("design.customize") { c in
        let t = try designTheme(root: c.root)
        let model = CustomizeModel()
        let r = DesignRegistry()
        let m = DesignProbe()
        let tree = designTree(t, customize: model, registry: r) {
            PButton("Play") { m.log.append("play") }
            PButton("Queue") { m.log.append("queue") }
        }
        _ = tree.render(background: .black)

        // Hide, then show again from another component's menu.
        tree.contextClick(element: "play", in: r)
        c.expect(tree.click(text: "Customize"), "Customize opens")
        c.expect(designShows(tree, "Size") && designShows(tree, "Style") && designShows(tree, "Reset"),
                 "Customize offers size, style and reset:\n\(tree.elementTree)")
        tree.click(text: "Hide")
        c.expect(model["play"].hidden, "Hide records it")
        c.expect(!designShows(tree, "Play"), "and the button is gone:\n\(tree.elementTree)")
        c.expectEqual(model.hiddenPaths, ["play"])
        tree.contextClick(element: "queue", in: r)
        tree.click(text: "Customize")
        c.expect(designShows(tree, "Show hidden items"), "a menu offers to show hidden items")
        tree.click(text: "Show hidden items")
        c.expect(model.hiddenPaths.isEmpty && designShows(tree, "Play"), "Play is back")

        // Size and style.
        tree.contextClick(element: "queue", in: r)
        tree.click(text: "Customize")
        tree.click(text: "Size")
        tree.click(text: "150%")
        c.expectEqual(model["queue"].scale, 1.5, "the size is recorded")
        _ = tree.render(background: .black)
        c.expectEqual(r.frame(of: "queue")?.height, t.size.control * 1.5, "and the button is larger")
        tree.contextClick(element: "queue", in: r)
        tree.click(text: "Customize")
        tree.click(text: "Style")
        tree.click(text: "Primary")
        c.expectEqual(model["queue"].style, "primary", "the style is recorded")
        let styled = designPixel(tree.render(background: .black), designLeftMiddle(r.frame(of: "queue"), 3))
        c.expect(designNear(styled, t.accent), "and drawn: \(styled)")
        tree.contextClick(element: "queue", in: r)
        tree.click(text: "Customize")
        tree.click(text: "Reset")
        c.expect(model["queue"].isDefault && model.elements.isEmpty, "Reset clears it")
        _ = tree.render(background: .black)
        c.expectEqual(r.frame(of: "queue")?.height, t.size.control, "back to its size")
        c.expect(m.log.isEmpty, "no menu click reached the buttons: \(m.log)")

        // Saved form.
        let saved = CustomizeModel()
        saved.setHidden("sidebar", true)
        saved.setScale("toolbar/play", 1.25)
        saved.setStyle("detail/queue", "plain")
        saved.setScale("left/alone", 1)
        let text = saved.json.serialized
        let back = try CustomizeModel(json: JSON.parse(text))
        c.expectEqual(back.elements, saved.elements, "JSON round trip: \(text)")
        c.expectEqual(back.elements.count, 3, "defaults are left out")
        do {
            _ = try CustomizeModel(json: JSON.parse("{\"version\": 1, \"elements\": {\"toolbar/play\": {\"scale\": \"big\"}}}"))
            c.fail("a scale that is not a number must not load")
        } catch {
            c.expect("\(error)".contains("toolbar/play") && "\(error)".contains("scale"), "the error says where: \(error)")
        }
        do {
            _ = try CustomizeModel(json: JSON.parse("{\"version\": 2}"))
            c.fail("another version must not load")
        } catch {
            c.expect("\(error)".contains("version"), "the error names the version: \(error)")
        }

        // Without a model: no Hide, but size still works for the session.
        let r2 = DesignRegistry()
        let loose = designTree(t, registry: r2) { PButton("Play") {} }
        _ = loose.render()
        loose.contextClick(element: "play", in: r2)
        loose.click(text: "Customize")
        c.expect(!designShows(loose, "Hide") && designShows(loose, "Size"), "no Hide without a model:\n\(loose.elementTree)")
        loose.click(text: "Size")
        loose.click(text: "125%")
        _ = loose.render()
        c.expectEqual(r2.frame(of: "play")?.height, t.size.control * 1.25, "the size is kept in the view")
    },

    Check("design.names") { c in
        let r = DesignRegistry()
        let model = ComponentsModel()
        let tree = ViewTree(try sampleComponents(root: c.root, model: model, registry: r))
        _ = tree.render()
        let expected = ["toolbar", "toolbar/new-playlist", "toolbar/view", "toolbar/view/albums", "toolbar/search",
                        "toolbar/import", "sidebar", "sidebar/library", "sidebar/albums", "sidebar/recently-added",
                        "sidebar/playlists", "sidebar/late-night", "detail", "detail/playback", "detail/playback/shuffle",
                        "detail/playback/volume", "detail/playback/import-progress", "detail/play", "detail/queue",
                        "detail/details", "detail/sort-by", "detail/scroll-bar"]
        for p in expected {
            c.expect(r.entry(p) != nil, "\(p) is named:\n\(r.description)")
            c.expect(r.frame(of: p) != nil, "\(p) has a frame")
        }
        c.expectEqual(r.duplicates, [], "every path is unique")
        c.expectEqual(r.entry("detail/playback/volume")?.role, "Slider")
        let line = r.description.split(separator: "\n").first { $0.hasPrefix("toolbar/import ") }.map(String.init) ?? ""
        c.expect(line.hasPrefix("toolbar/import Button \"Import\" (") && line.hasSuffix("styles: secondary, primary, plain"),
                 "a line says path, role, title, frame and styles: \(line)")
        c.expect(tree.click(element: "toolbar/import", in: r), "a component can be clicked by name")
        c.expectEqual(model.log, ["import"])
        tree.click(element: "toolbar/view/artists", in: r)
        c.expectEqual(model.view, "artists", "a segment can be clicked by name")
        tree.click(element: "sidebar/focus", in: r)
        c.expectEqual(model.selected, "focus", "a row can be clicked by name")

        // Two siblings with one name are reported.
        let twice = DesignRegistry()
        let t = try designTheme(root: c.root)
        _ = designTree(t, registry: twice) {
            PButton("Play") {}
            PButton("Play") {}
        }.render()
        c.expectEqual(twice.duplicates, ["play"], "two buttons named play")
        c.expect(!tree.click(element: "no/such/thing", in: r), "an unknown name clicks nothing")
    },

    Check("design.render") { c in
        var e = EnvironmentValues()
        e.displayScale = 2
        let r = DesignRegistry()
        let model = ComponentsModel()
        let app = CommandRegistry()
        let tree = ViewTree(try sampleComponents(root: c.root, model: model, commands: app, registry: r), environment: e)
        let img = tree.render(background: .black)
        c.expectEqual(img.width, 1440, "720 points at 2x")
        c.expectEqual(img.height, 960, "480 points at 2x")
        try Platform.files.createDirectory(Path.join(c.outputDirectory, "design"))
        try Platform.files.write(PNG.encode(img), to: Path.join(c.outputDirectory, "design/components@2x.png"))

        // Rules: every title in sentence case, no clashing shortcuts.
        for p in r.paths {
            if let entry = r.entry(p) {
                for problem in DesignRules.problems(inTitle: entry.title) { c.fail("\(p): \(problem)") }
            }
        }
        c.expectEqual(app.problems, [], "the sample's commands")
        c.expect(app.command("library.play") != nil, "the sample's commands are registered")

        // A partial frame equals a whole draw after each interaction.
        let point = { (p: String) -> Point in r.center(of: p) ?? Point(x: 1, y: 1) }
        let thumb = try designTheme(root: c.root).size.thumb
        let steps: [(String, @MainActor () -> Void)] = [
            ("toggle", { tree.click(element: "detail/playback/shuffle", in: r) }),
            ("drag", {
                if let f = r.frame(of: "detail/playback/volume") {
                    let at = f.minX + thumb / 2 + 0.25 * (f.width - thumb)
                    tree.drag(from: Point(x: f.minX + thumb / 2, y: f.midY), to: Point(x: at, y: f.midY))
                }
            }),
            ("hover", { tree.pointerMoved(to: point("detail/queue")) }),
            ("tooltip", { tree.pointerMoved(to: point("toolbar/new-playlist")) }),
            ("menu", { tree.contextClick(element: "detail/play", in: r) }),
            ("customize", { tree.click(text: "Customize") }),
            ("escape", { tree.key("escape"); tree.key("escape") }),
            ("row", { tree.click(element: "sidebar/artists", in: r) }),
            ("tab", { tree.key("tab"); tree.key("tab") }),
            ("sheet", { tree.click(element: "detail/details", in: r) }),
            ("done", { tree.click(text: "Done") }),
        ]
        for (name, step) in steps {
            step()
            let frame = tree.render(background: .black)
            var whole = Canvas(width: frame.width, height: frame.height, scale: 2, background: .black)
            if let l = tree.displayList { whole.draw(l) }
            c.expect(frame == whole.bitmap, "after \(name), a partial frame equals a whole draw")
        }
        c.expect(!model.shuffle, "the toggle was clicked")
        c.expectClose(model.volume, 0.25, tolerance: 0.02, "the slider was dragged")
        c.expectEqual(model.selected, "artists", "the row was chosen")
        c.expect(!model.showSheet, "the sheet closed")
        try Platform.files.write(PNG.encode(tree.render(background: .black)), to: Path.join(c.outputDirectory, "design/components-used@2x.png"))
    },

    Check("design.theme.looks") { c in
        // A theme whose looks differ from the defaults, so a missing injection shows.
        var t = try designTheme(root: c.root)
        t.gray.raised = Color(red: 0.2, green: 0.35, blue: 0.55)
        t.accent = Color(red: 0.9, green: 0.1, blue: 0.1)
        t.line = 2
        let box = LookBox()
        let r = DesignRegistry()
        let tree = designTree(t, registry: r) {
            VStack(alignment: .leading, spacing: 4) {
                LookProbe(box: box)
                Menu("File") { Button("New") {} }
            }
        }
        _ = tree.render(background: .black)
        guard let panel = box.panel, let input = box.input else {
            c.fail("the probe saw no look: is designRoot injecting them?")
            return
        }
        c.expectEqual(panel, t.panelLook, "menus take panelLook from the active theme")
        c.expectEqual(input, t.textInputLook, "text fields take textInputLook from the active theme")
        c.expect(panel != PanelLook(), "the active look is not the default")
        c.expect(input != TextInputLook(), "nor is the text-input look")
        c.expectEqual(input.caretWidth, 2, "the caret is a line wide, from the theme")

        // And it reaches a real panel: the menu is drawn with the theme's raised grey.
        tree.click(text: "File")
        _ = tree.render(background: .black)
        guard let menu = designFrames(tree, "Menu").first else {
            c.fail("the menu did not open:\n\(tree.elementTree)")
            return
        }
        let inMenu = designPixel(tree.render(background: .black), Point(x: menu.minX + 3, y: menu.minY + 3))
        c.expect(designNear(inMenu, t.panelLook.background, tolerance: 2),
                 "the menu panel is the theme's panel grey: \(inMenu)")
    },

    Check("design.commands.unmount") { c in
        struct CommandUnmountProbe: View {
            let m: DesignProbe
            var body: some View {
                VStack(alignment: .leading, spacing: 4) {
                    if m.show {
                        VStack(alignment: .leading, spacing: 4) {
                            PButton("Inner") { m.log.append("inner") }
                        }
                        .commands {
                            Command("wave2.inner", "Inner action", shortcut: KeyboardShortcut("k")) { m.log.append("command") }
                        }
                    }
                    PButton("Outer") { m.log.append("outer") }
                }
            }
        }
        let t = try designTheme(root: c.root)
        let m = DesignProbe()
        let app = CommandRegistry()
        let r = DesignRegistry()
        let tree = designTree(t, commands: app, registry: r) {
            CommandUnmountProbe(m: m)
        }
        _ = tree.render()
        c.expect(app.command("wave2.inner") != nil, ".commands joins the registry:\n\(app.description)")
        c.expect(tree.key("cmd+k", commands: app), "its shortcut runs while the view is in the tree")
        c.expectEqual(m.log, ["command"], "once")

        // The owning view leaves: its commands go with it.
        m.show = false
        _ = tree.render()
        c.expect(app.command("wave2.inner") == nil, "leaving the tree unregisters it:\n\(app.description)")
        c.expectEqual(app.commands.count, 0, "nothing else was registered")
        c.expect(!tree.key("cmd+k", commands: app), "the shortcut no longer runs")
        c.expectEqual(m.log, ["command"], "no stale command fired")
        c.expect(tree.click(element: "outer", in: r), "the rest of the window still works")
        c.expectEqual(m.log, ["command", "outer"], "the outer button still runs")
        c.expectEqual(app.description, "", "the registry is empty again")

        // Back in the tree, it registers again.
        m.show = true
        _ = tree.render()
        c.expect(app.command("wave2.inner") != nil, "coming back registers it again")
        c.expectEqual(app.commands.count, 1, "just once")
    },

    Check("design.scroll.reader") { c in
        let t = try designTheme(root: c.root)
        let box = ScrollBox()
        let r = DesignRegistry()
        let tree = designTree(t, registry: r) { ScrollProbe(box: box) }
        _ = tree.render(background: .black)
        guard let proxy = box.proxy else {
            c.fail("the reader gave no proxy")
            return
        }
        c.expect(proxy.isAttached, "the reader attaches its scroll view")
        c.expectClose(proxy.metrics.contentSize.height, 600, tolerance: 0.01, "30 rows of 20 points")
        c.expectClose(proxy.metrics.viewportSize.height, 200, tolerance: 0.01, "a 200-point window")
        c.expectClose(proxy.visibleFraction(), 1.0 / 3, tolerance: 0.01, "a third of the content fits")
        c.expectClose(proxy.position(), 0, tolerance: 1e-9, "at the start")

        guard let bar = r.frame(of: "scroll-bar") else {
            c.fail("the bar has no frame:\n\(r.description)")
            return
        }
        c.expectEqual(bar.width, t.size.scrollBar, "the bar is a scroll bar wide")
        let atTop = tree.render(background: .black)
        let topThumb = designPixel(atTop, Point(x: bar.midX, y: bar.minY + 2))
        let topBelow = designPixel(atTop, Point(x: bar.midX, y: bar.minY + 70))
        c.expect(designBrightness(topThumb) > designBrightness(topBelow),
                 "the thumb starts at the top: \(topThumb) above \(topBelow)")

        // scrollTo(anchor:) moves the offset.
        c.expect(proxy.scrollTo(10, anchor: .top), "scrollTo scrolls")
        c.expectClose(proxy.metrics.offset.y, 200, tolerance: 0.01, "row 10 sits at 200 points")
        c.expectClose(proxy.position(), 0.5, tolerance: 0.01, "halfway")
        c.expectClose(proxy.visibleFraction(), 1.0 / 3, tolerance: 1e-9, "the visible fraction stays the same")
        let moved = tree.render(background: .black)
        let movedTop = designPixel(moved, Point(x: bar.midX, y: bar.minY + 2))
        c.expect(designBrightness(movedTop) < designBrightness(topThumb),
                 "the thumb moved down: \(movedTop) after \(topThumb)")
        let half = designPixel(moved, Point(x: bar.midX, y: bar.minY + 70))
        c.expect(designBrightness(half) > designBrightness(movedTop),
                 "the thumb now sits halfway: \(half) at 70")

        // Already visible, or unknown: no move.
        c.expect(!proxy.scrollTo(10, anchor: .top), "scrolling to where it already is does nothing")
        c.expect(!proxy.scrollTo(99), "an unknown id does nothing")
        c.expectClose(proxy.metrics.offset.y, 200, tolerance: 0.01, "the offset is unchanged")
    },

    Check("design.spacer.minLength") { c in
        let t = try designTheme(root: c.root)
        let tree = designTree(t, registry: DesignRegistry()) {
            HStack(spacing: 0) {
                Rectangle().fill(t.accent).frame(width: 90, height: 20)
                Spacer(minLength: 24)
                Spacer()
            }
            .frame(width: 100, height: 20)
            VStack(spacing: 0) {
                Rectangle().fill(t.accent).frame(width: 20, height: 30)
                Spacer(minLength: 24)
                Spacer()
            }
            .frame(width: 20, height: 40)
        }
        _ = tree.render()
        let spacers = designFrames(tree, "Spacer")
        guard spacers.count == 4 else {
            c.fail("expected four spacers:\n\(tree.elementTree)")
            return
        }
        // Only 10 points are left over: the minimum wins over the default.
        c.expectEqual(spacers[0].width, 24, "a 24-point spacer keeps 24 in a tight HStack")
        c.expectEqual(spacers[1].width, 8, "a plain spacer takes what is left")
        c.expectEqual(spacers[2].height, 24, "a 24-point spacer keeps 24 in a tight VStack")
        c.expectEqual(spacers[3].height, 8, "a plain spacer takes what is left")
    },

    Check("design.customize.size") { c in
        let t = try designTheme(root: c.root)
        let model = CustomizeModel()
        let r = DesignRegistry()
        let tree = designTree(t, customize: model, registry: r) {
            PButton("Play") {}
            PButton("Queue") {}
        }
        _ = tree.render(background: .black)
        let natural = r.frame(of: "play")?.width ?? 0
        c.expect(natural > 0, "the button is laid out at first: \(natural)")

        model.setWidth("play", 120)
        model.setHeight("play", 36)
        _ = tree.render(background: .black)
        c.expectEqual(r.frame(of: "play")?.width ?? 0, 120, "the custom width wins")
        c.expectEqual(r.frame(of: "play")?.height ?? 0, 36, "the custom height wins")
        c.expectEqual(r.frame(of: "queue")?.height ?? 0, t.size.control, "other components keep their size")
        c.expectEqual(model["play"].width ?? 0, 120)
        c.expectEqual(model["play"].height ?? 0, 36)

        // Saved form: width and height survive JSON.
        let text = model.json.serialized
        let back = try CustomizeModel(json: JSON.parse(text))
        c.expectEqual(back.elements, model.elements, "width and height round trip: \(text)")
        c.expectEqual(back["play"].width ?? 0, 120, "the width is read back")
        c.expectEqual(back["play"].height ?? 0, 36, "the height is read back")

        // Sizes of zero or less are refused, saying where.
        for bad in ["{\"version\": 1, \"elements\": {\"play\": {\"width\": 0}}}",
                    "{\"version\": 1, \"elements\": {\"play\": {\"height\": -8}}}"] {
            do {
                _ = try CustomizeModel(json: JSON.parse(bad))
                c.fail("an invalid size must not load: \(bad)")
            } catch {
                let message = "\(error)"
                c.expect(message.contains("play") && (message.contains("width") || message.contains("height")),
                         "the error says where and which size: \(message)")
            }
        }

        // Clearing an override goes back to the app's size.
        model.setWidth("play", nil)
        model.setHeight("play", nil)
        c.expect(model.elements.isEmpty, "nil clears both overrides")
        _ = tree.render(background: .black)
        c.expectEqual(r.frame(of: "play")?.width ?? 0, natural, "back to the app's width")
    },
]
