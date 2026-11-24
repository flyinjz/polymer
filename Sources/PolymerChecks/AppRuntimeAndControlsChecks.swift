// Headless deterministic checks for PolymerApp WindowHost/PolymerApplication
// and PolymerDesign extra controls (TextField, SegmentedControl, ProgressBar, Badge, Tabs, Popover).
import Observation
import PolymerApp
import PolymerBase
import PolymerDesign
import PolymerPlatform
import PolymerRender
import PolymerText
import PolymerUI

// MARK: Support Models & Views for WindowHost Check

@MainActor
@Observable
private final class HostProbe {
    var shortcutRuns = 0
    var buttonClicks = 0
    var contextItemRuns = 0
    var query = ""
    var sawInjectedCommands = false
    var sawInjectedSettings = false
}

private struct HostAppRootView: View {
    let probe: HostProbe
    let font: Font

    @Environment(\.theme) private var theme
    @Environment(\.commandRegistry) private var envCommands
    @Environment(\.settingsStore) private var envSettings

    var body: some View {
        @Bindable var p = probe
        let envSummary = "Env \(envCommands != nil ? "cmd" : "none")/\(envSettings?.string(forKey: "app.mode", default: "none") ?? "none")"
        VStack(alignment: .leading, spacing: theme.spacing.sm) {
            Text(envSummary)
                .foregroundStyle(theme.colors.textSecondary)
                .accessibilityIdentifier("env-summary")

            PolymerTextField("Search", text: $p.query)
                .frame(width: 200)
                .accessibilityIdentifier("host-query")

            HStack(spacing: theme.spacing.sm) {
                Button("Run Action") {
                    probe.buttonClicks += 1
                    probe.sawInjectedCommands = (envCommands != nil)
                    probe.sawInjectedSettings = (envSettings?.string(forKey: "app.mode") == "studio")
                }
                .buttonStyle(.polymerPrimary)
                .accessibilityIdentifier("host-action-btn")

                Text("Context Target")
                    .padding(horizontal: theme.spacing.md, vertical: theme.spacing.xs)
                    .background(theme.colors.surfaceElevated)
                    .border(theme.colors.border, width: 1)
                    .contextMenu {
                        Button("Inspect Track") {
                            probe.contextItemRuns += 1
                        }
                    }
                    .accessibilityIdentifier("host-ctx-target")
            }
        }
        .font(font)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.colors.background)
        .theme(.pgr)
    }
}

@MainActor
private struct DemoHostApplication: PolymerApplication {
    let windowConfig: WindowConfig
    let commands: CommandRegistry
    let settings: SettingsStore
    let probe: HostProbe
    let font: Font

    init(probe: HostProbe, font: Font) {
        self.probe = probe
        self.font = font
        self.windowConfig = WindowConfig(
            id: "host-check",
            title: "Polymer Host Check",
            initialSize: Size(width: 340, height: 220),
            backdrop: .darkGlass,
            scale: 1
        )
        let reg = CommandRegistry()
        reg.register(Command(
            id: "search.open",
            title: "Quick Search",
            shortcut: KeyShortcut("cmd+k"),
            perform: { probe.shortcutRuns += 1 }
        ))
        self.commands = reg

        let store = SettingsStore()
        store.set("studio", forKey: "app.mode")
        self.settings = store
    }

    func makeBody() -> some View {
        HostAppRootView(probe: probe, font: font)
    }
}

// MARK: Support Models & Views for ControlsExtra Check

private enum ViewMode: Hashable, Sendable {
    case list
    case grid
    case compact
}

private enum InspectorTab: Hashable, Sendable {
    case overview
    case audio
    case library
}

@MainActor
@Observable
private final class ControlsExtraModel {
    var searchText = ""
    var submitCount = 0
    var mode: ViewMode = .list
    var progress: Double = 0.5
    var tab: InspectorTab = .overview
    var showPopover = false
}

private struct ControlsExtraShowcaseView: View {
    let model: ControlsExtraModel
    let font: Font

    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var m = model
        VStack(alignment: .leading, spacing: theme.spacing.sm) {
            PolymerTextField(
                "Filter tracks",
                text: $m.searchText,
                onSubmit: { model.submitCount += 1 }
            )
            .frame(width: 220)
            .accessibilityIdentifier("extra-text-field")

            PolymerSegmentedControl(
                options: [
                    (ViewMode.list, "List"),
                    (ViewMode.grid, "Grid"),
                    (ViewMode.compact, "Compact"),
                ],
                selection: $m.mode
            )
            .accessibilityIdentifier("extra-segmented")

            PolymerProgressBar(
                value: model.progress,
                label: "Indexing",
                showsPercentage: true,
                width: 180,
                height: 6
            )
            .accessibilityIdentifier("extra-progress")

            HStack(spacing: theme.spacing.xs) {
                PolymerBadge("Idle", tone: .neutral)
                    .accessibilityIdentifier("badge-neutral")
                PolymerBadge("Live", tone: .accent)
                    .accessibilityIdentifier("badge-accent")
                PolymerBadge("Synced", tone: .success)
                    .accessibilityIdentifier("badge-success")
                PolymerBadge("Warm", tone: .warning)
                    .accessibilityIdentifier("badge-warning")
                PolymerBadge("Error", tone: .danger)
                    .accessibilityIdentifier("badge-danger")
            }

            PolymerTabs(
                tabs: [
                    (InspectorTab.overview, "Overview"),
                    (InspectorTab.audio, "Audio"),
                    (InspectorTab.library, "Library"),
                ],
                selection: $m.tab
            ) { selected in
                switch selected {
                case .overview:
                    Text("Overview Content")
                case .audio:
                    Text("Audio Content")
                case .library:
                    Text("Library Content")
                }
            }
            .accessibilityIdentifier("extra-tabs")

            Button("Open Popover") {
                model.showPopover = true
            }
            .buttonStyle(.polymerSecondary)
            .accessibilityIdentifier("open-popover-btn")
        }
        .padding(12)
        .frame(width: 340, height: 340, alignment: .topLeading)
        .background(theme.colors.background)
        .polymerPopover(isPresented: $m.showPopover, minWidth: 160, maxWidth: 185, alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: theme.spacing.xs) {
                Text("Popover Details")
                Text("Lossless signal path")
                    .foregroundStyle(theme.colors.textSecondary)
            }
        }
        .font(font)
    }
}

// MARK: Exported Checks

@MainActor
public let appRuntimeAndControlsChecks: [Check] = [
    Check("app.window-host") { c in
        let font = Font(try TextReference.font(root: c.root, "Geist-Regular.otf"), size: 13)
        let probe = HostProbe()
        let app = DemoHostApplication(probe: probe, font: font)

        // Probe laid-out target coordinates cleanly via a host before scripting the runner.
        let layoutHost = app.makeHost()
        layoutHost.handle(.resized(size: Size(width: 340, height: 220), scale: 1))
        guard let btnPt = layoutHost.tree.point(ofID: "host-action-btn"),
              let ctxPt = layoutHost.tree.point(ofID: "host-ctx-target"),
              let fieldPt = layoutHost.tree.point(ofID: "host-query") else {
            c.fail("expected host-action-btn, host-ctx-target, and host-query in element tree")
            return
        }

        // Scripted window event sequence driven through HeadlessWindowRunner.
        let scripted: [WindowEvent] = [
            .resized(size: Size(width: 340, height: 220), scale: 1),
            .key(WindowKeyEvent(key: "k", characters: "k", command: true, isDown: true)),
            .pointerMoved(btnPt),
            .pointerDown(btnPt, .left),
            .pointerUp(btnPt, .left),
            .pointerDown(ctxPt, .right),
            .tick(dt: 1.0 / 60.0),
            .closed,
        ]
        let runner = HeadlessWindowRunner(events: scripted, renderOnEveryEvent: true, maxAnimationTicks: 2)
        let host = try app.run(runner: runner)

        c.expect(host.tree.environment.commandRegistry === app.commands, "WindowHost injects CommandRegistry into ViewTree environment")
        c.expect(host.tree.environment.settingsStore === app.settings, "WindowHost injects SettingsStore into ViewTree environment")
        c.expect(host.tree.elementTree.contains("\"Env cmd/studio\""), "child views read injected CommandRegistry and SettingsStore")
        c.expectEqual(probe.shortcutRuns, 1, "Cmd+K executed registered Command via CommandRegistry")
        c.expectEqual(probe.buttonClicks, 1, "left pointerDown/pointerUp clicked button")
        c.expect(probe.sawInjectedCommands && probe.sawInjectedSettings, "button handler observed injected environment services")
        c.expect(host.isClosed, "closed event marks host closed")
        c.expect(runner.renderedFrames.count >= 6, "captured multiple frames during scripted run (got \(runner.renderedFrames.count))")
        c.expect(
            runner.renderedFrames.allSatisfy { !$0.isEmpty && $0.width == 340 && $0.height == 220 },
            "all rendered FrameBuffers are non-empty 340x220"
        )

        // Frame index 4 is after pointerUp (button clicked); index 5 is after right-click (context menu opened).
        if runner.renderedFrames.count >= 6 {
            let beforeMenu = runner.renderedFrames[4]
            let withMenu = runner.renderedFrames[5]
            c.expect(beforeMenu != withMenu, "right-click opened and visibly rendered context menu")
            let dir = PolymerPlatform.Path.join(c.outputDirectory, "app")
            try Platform.files.createDirectory(dir)
            let bmp = Bitmap(width: withMenu.width, height: withMenu.height, pixels: withMenu.pixels)
            try Platform.files.write(PNG.encode(bmp), to: PolymerPlatform.Path.join(dir, "window-host.png"))
        }

        // Direct WindowHost verification: context menu state, item execution, and shortcut-first priority over focused TextField.
        let liveHost = app.makeHost()
        liveHost.handle(.resized(size: Size(width: 340, height: 220), scale: 1))
        liveHost.handle(.pointerDown(ctxPt, .right))
        c.expect(liveHost.tree.hasOpenContextMenu, "right-click opens ViewTree context menu")
        c.expect(liveHost.tree.elementTree.contains("ContextMenu"), "elementTree exposes open ContextMenu")
        c.expect(liveHost.tree.elementTree.contains("\"Inspect Track\""), "context menu displays item label")

        if let menuItemPt = liveHost.tree.point(ofText: "Inspect Track") {
            liveHost.handle(.pointerDown(menuItemPt, .left))
            liveHost.handle(.pointerUp(menuItemPt, .left))
        } else {
            c.fail("Inspect Track context menu item missing")
        }
        c.expectEqual(probe.contextItemRuns, 1, "clicking context menu item executed action")
        c.expect(!liveHost.tree.hasOpenContextMenu, "context menu closed after item selection")

        // Focus TextField, verify Cmd+K hits CommandRegistry FIRST (without typing 'k'), while plain 'x' types into TextField.
        liveHost.handle(.pointerDown(fieldPt, .left))
        liveHost.handle(.pointerUp(fieldPt, .left))
        liveHost.handle(.key(WindowKeyEvent(key: "k", characters: "k", command: true, isDown: true)))
        liveHost.handle(.key(WindowKeyEvent(key: "x", characters: "x", isDown: true)))
        c.expectEqual(probe.shortcutRuns, 2, "Cmd+K routed to CommandRegistry before focused TextField")
        c.expectEqual(probe.query, "x", "non-shortcut key forwarded to focused TextField")

        // Static convenience entry point also runs cleanly.
        let staticRunner = HeadlessWindowRunner(events: [.closed])
        let staticHost = try DemoHostApplication.run(app, runner: staticRunner)
        c.expect(staticHost.isClosed && !staticRunner.renderedFrames.isEmpty, "static PolymerApplication.run renders and closes")

        c.note("frames=\(runner.renderedFrames.count), shortcuts=\(probe.shortcutRuns), clicks=\(probe.buttonClicks)")
    },

    Check("design.controls-extra") { c in
        let font = Font(try TextReference.font(root: c.root, "Geist-Regular.otf"), size: 13)
        let model = ControlsExtraModel()
        let tree = ViewTree(ControlsExtraShowcaseView(model: model, font: font).theme(.pgr))
        tree.update()

        // 1. PolymerTextField: focus styling, typing, and Return submit.
        let beforeFocusBmp = tree.render(background: Theme.pgr.colors.background)
        c.expect(tree.click(id: "extra-text-field"), "clicking PolymerTextField focuses it")
        let afterFocusBmp = tree.render(background: Theme.pgr.colors.background)
        c.expect(beforeFocusBmp != afterFocusBmp, "focusing PolymerTextField visibly renders accent border and focus ring")

        c.expect(tree.key("h"), "typing 'h' handled by PolymerTextField")
        c.expect(tree.key("i"), "typing 'i' handled by PolymerTextField")
        c.expectEqual(model.searchText, "hi", "PolymerTextField updates bound text")
        c.expect(tree.key("return"), "Return handled by PolymerTextField")
        c.expectEqual(model.submitCount, 1, "PolymerTextField invokes onSubmit on Return")

        // 2. PolymerSegmentedControl: click switching and keyboard Left/Right navigation.
        c.expectEqual(model.mode, .list, "segmented control starts on .list")
        let segBeforeBmp = tree.render(background: Theme.pgr.colors.background)
        c.expect(tree.click(text: "Grid"), "clicking Grid segment selects .grid")
        c.expectEqual(model.mode, .grid, "segmented control switched to .grid")
        let segAfterBmp = tree.render(background: Theme.pgr.colors.background)
        c.expect(segBeforeBmp != segAfterBmp, "active segment highlight changes rendered pixels")

        c.expect(tree.key("right"), "Right arrow advances focused segmented control")
        c.expectEqual(model.mode, .compact, "Right arrow selected .compact")
        c.expect(tree.key("left"), "Left arrow moves segmented control back")
        c.expectEqual(model.mode, .grid, "Left arrow selected .grid")

        // 3. PolymerProgressBar: fill geometry and readout at 0%, 50%, 100%.
        @MainActor func progressSnapshot(_ value: Double) -> (dump: String, bitmap: Bitmap) {
            let barTree = ViewTree(
                PolymerProgressBar(value: value, label: "Indexing", showsPercentage: true, width: 180, height: 6)
                    .font(font)
                    .padding(8)
                    .theme(.pgr)
            )
            let bmp = barTree.render(background: Theme.pgr.colors.background)
            return (barTree.elementTree, bmp)
        }

        let prog0 = progressSnapshot(0.0)
        let prog50 = progressSnapshot(0.5)
        let prog100 = progressSnapshot(1.0)

        c.expect(prog0.dump.contains("\"0%\""), "0% progress readout displayed")
        c.expect(prog50.dump.contains("\"50%\""), "50% progress readout displayed")
        c.expect(prog100.dump.contains("\"100%\""), "100% progress readout displayed")
        c.expect(prog50.dump.contains("Rectangle") && prog50.dump.contains("90x6)"), "50% progress bar fill width is 90x6: \(prog50.dump)")
        let rect180CountAt0 = prog0.dump.split(separator: "\n").filter { $0.contains("Rectangle ") && $0.contains("180x6)") }.count
        let rect180CountAt100 = prog100.dump.split(separator: "\n").filter { $0.contains("Rectangle ") && $0.contains("180x6)") }.count
        c.expectEqual(rect180CountAt0, 1, "0% progress bar draws only the 180x6 track")
        c.expectEqual(rect180CountAt100, 2, "100% progress bar draws both 180x6 track and 180x6 fill")
        c.expect(prog0.bitmap != prog50.bitmap && prog50.bitmap != prog100.bitmap, "0%, 50%, and 100% render distinct frames")

        // 4. PolymerBadge: all 5 tones render cleanly and distinctively.
        var badgeBitmaps: [PolymerBadge.Tone: Bitmap] = [:]
        for tone in PolymerBadge.Tone.allCases {
            let bTree = ViewTree(
                PolymerBadge("Status", tone: tone)
                    .font(font)
                    .padding(4)
                    .theme(.pgr)
            )
            badgeBitmaps[tone] = bTree.render(background: Theme.pgr.colors.background)
        }
        let uniqueBadgeFrames = Set(badgeBitmaps.values)
        c.expectEqual(uniqueBadgeFrames.count, PolymerBadge.Tone.allCases.count, "all 5 PolymerBadge tones render distinct pixels")

        // 5. PolymerTabs: clicking tabs switches active content.
        c.expect(tree.elementTree.contains("\"Overview Content\""), "initial tab displays Overview Content")
        c.expect(!tree.elementTree.contains("\"Audio Content\""), "inactive Audio tab content hidden")
        c.expect(tree.click(text: "Audio"), "clicking Audio tab switches tab")
        c.expectEqual(model.tab, .audio, "tab selection updated to .audio")
        c.expect(tree.elementTree.contains("\"Audio Content\""), "Audio tab displays Audio Content")
        c.expect(!tree.elementTree.contains("\"Overview Content\""), "previous Overview tab content replaced")
        c.expect(tree.click(text: "Library"), "clicking Library tab switches tab")
        c.expectEqual(model.tab, .library, "tab selection updated to .library")
        c.expect(tree.elementTree.contains("\"Library Content\""), "Library tab displays Library Content")

        // 6. polymerPopover: show via button, dismiss via Escape, reopen and dismiss via Close button.
        c.expect(!tree.elementTree.contains("\"Popover Details\""), "popover starts hidden")
        let withoutPopoverBmp = tree.render(background: Theme.pgr.colors.background)
        c.expect(tree.click(id: "open-popover-btn"), "clicking Open Popover shows overlay")
        c.expect(model.showPopover, "popover binding is true")
        c.expect(tree.elementTree.contains("\"Popover Details\""), "popover content mounted in overlay")
        let withPopoverBmp = tree.render(background: Theme.pgr.colors.background)
        c.expect(withPopoverBmp != withoutPopoverBmp, "popover overlay visibly renders over anchor")

        c.expect(tree.key("escape"), "Escape dismisses open polymerPopover")
        c.expect(!model.showPopover, "popover binding reset to false on Escape")
        c.expect(!tree.elementTree.contains("\"Popover Details\""), "popover content removed after Escape")

        c.expect(tree.click(id: "open-popover-btn"), "re-opening popover works")
        c.expect(tree.click(text: "Close"), "clicking popover Close button dismisses overlay")
        c.expect(!model.showPopover, "popover binding reset to false on Close")
        c.expect(!tree.elementTree.contains("\"Popover Details\""), "popover content removed after Close")

        // 7. Theme parity & pgr DesignLint compliance across Theme.pgr and Theme.light.
        @MainActor func renderShowcase(theme: Theme) -> (tree: ViewTree, bitmap: Bitmap) {
            let m = ControlsExtraModel()
            m.searchText = "Bach"
            m.mode = .grid
            m.progress = 0.65
            m.tab = .audio
            m.showPopover = true
            let t = ViewTree(ControlsExtraShowcaseView(model: m, font: font).theme(theme))
            let b = t.render(background: theme.colors.background)
            return (t, b)
        }

        let pgrResult = renderShowcase(theme: .pgr)
        let pgrRepeat = renderShowcase(theme: .pgr)
        let lightResult = renderShowcase(theme: .light)

        c.expect(pgrResult.bitmap.width > 0 && pgrResult.bitmap.height > 0, "Theme.pgr showcase bitmap non-empty")
        c.expect(lightResult.bitmap.width > 0 && lightResult.bitmap.height > 0, "Theme.light showcase bitmap non-empty")
        c.expect(pgrResult.bitmap != lightResult.bitmap, "Theme.pgr and Theme.light render distinct visuals")
        c.expect(pgrResult.bitmap == pgrRepeat.bitmap, "Theme.pgr showcase renders deterministically")

        let violations = DesignLint.audit(tree: pgrResult.tree, theme: .pgr, rules: DesignLint.pgrRules)
        c.expect(violations.isEmpty, "all extra controls pass pgr DesignLint with 0 violations, got: \(violations)")

        let dir = PolymerPlatform.Path.join(c.outputDirectory, "design")
        try Platform.files.createDirectory(dir)
        try Platform.files.write(PNG.encode(pgrResult.bitmap), to: PolymerPlatform.Path.join(dir, "controls-extra-pgr.png"))
        try Platform.files.write(PNG.encode(lightResult.bitmap), to: PolymerPlatform.Path.join(dir, "controls-extra-light.png"))
    },
]
