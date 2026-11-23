import Observation
import PolymerApp
import PolymerBase
import PolymerDesign
import PolymerPlatform
import PolymerRender
import PolymerText
import PolymerUI

// MARK: Support Models & Views for App & Design Checks

@MainActor
@Observable
private final class CommandProbe {
    var searches = 0
    var saves = 0
    var muted = false
    var canSave = true
    var dismissed = 0
}

@Observable
private final class ControlsModel {
    var primaryClicks = 0
    var disabledClicks = 0
    var toggleOn = false
    var sliderValue = 50.0
    var ringFocused = false
}

private struct ThemeShowcaseView: View {
    let font: Font
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.sm) {
            PolymerPanel {
                VStack(alignment: .leading, spacing: theme.spacing.xs) {
                    Text("Theme \(theme.name)")
                    HairlineDivider()
                    HStack(spacing: theme.spacing.sm) {
                        Button("Apply") {}
                            .buttonStyle(.polymerPrimary)
                        Button("Cancel") {}
                            .buttonStyle(.polymerSecondary)
                    }
                }
            }
        }
        .font(font)
        .padding(12)
        .frame(width: 220, alignment: .leading)
        .background(theme.colors.background)
    }
}

private struct ControlsShowcaseView: View {
    let model: ControlsModel
    let registry: CommandRegistry
    let group: CommandGroup
    let font: Font
    let onDismiss: @MainActor () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var m = model
        VStack(alignment: .leading, spacing: theme.spacing.sm) {
            PolymerPanel(useGlass: false) {
                VStack(alignment: .leading, spacing: theme.spacing.sm) {
                    HStack(spacing: theme.spacing.sm) {
                        Button("Run") { model.primaryClicks += 1 }
                            .buttonStyle(.polymerPrimary)
                        Button("Locked") { model.disabledClicks += 1 }
                            .buttonStyle(.polymerDestructive)
                            .disabled(true)
                        Button("Quiet") {}
                            .buttonStyle(.polymerGhost)
                    }
                    HairlineDivider()
                    PolymerToggle("Autoplay", isOn: $m.toggleOn)
                        .accessibilityIdentifier("autoplay-toggle")
                    PolymerSlider(value: $m.sliderValue, in: 0...100, step: 10, width: 160)
                        .accessibilityIdentifier("volume-slider")
                    Text("Focus Target")
                        .padding(4)
                        .focusRing(isFocused: model.ringFocused)
                        .accessibilityIdentifier("ring-target")
                    HStack(spacing: theme.spacing.sm) {
                        PolymerScrollBar(axis: .vertical, contentLength: 400, viewportLength: 80, offset: 120)
                            .accessibilityIdentifier("bar-overflow")
                        PolymerScrollBar(axis: .vertical, contentLength: 60, viewportLength: 80, offset: 0)
                            .accessibilityIdentifier("bar-fit")
                        PolymerScrollBar(axis: .vertical, contentLength: 400, viewportLength: 80, offset: 0)
                            .scrollIndicators(.hidden)
                            .accessibilityIdentifier("bar-hidden")
                    }
                }
            }
            PolymerContextMenu(group: group, registry: registry, minWidth: 200, onDismiss: onDismiss)
        }
        .font(font)
        .padding(12)
        .frame(width: 260, alignment: .leading)
        .background(theme.colors.background)
    }
}

private struct CustomizeDemoView: View {
    let font: Font
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Now Playing")
                .padding(6)
                .customizable("hero")
            Text("Lossless")
                .padding(4)
                .customizable("badge")
        }
        .font(font)
        .padding(12)
        .frame(width: 220, height: 120, alignment: .topLeading)
        .background(theme.colors.background)
    }
}

private struct CompliantPgrView: View {
    let font: Font
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.sm) {
            PolymerPanel {
                VStack(alignment: .leading, spacing: theme.spacing.xs) {
                    Text("Album library")
                    Text("FLAC")
                        .foregroundStyle(theme.colors.textSecondary)
                    HairlineDivider()
                    Button("Play album") {}
                        .buttonStyle(.polymerPrimary)
                }
            }
        }
        .font(font)
        .padding(12)
        .frame(width: 220, alignment: .leading)
        .background(theme.colors.background)
    }
}

private struct NonCompliantView: View {
    let font: Font
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TRACK SETTINGS")
            Text("// Queue status")
            RoundedRectangle(cornerRadius: 6)
                .foregroundStyle(Color(red: 0.9, green: 0.1, blue: 0.8))
                .frame(width: 60, height: 16)
            PolymerPanel(useGlass: true) {
                PolymerPanel(useGlass: true) {
                    Text("Stacked glass")
                }
            }
        }
        .font(font)
        .padding(8)
        .frame(width: 200, alignment: .leading)
        .background(theme.colors.background)
    }
}

// MARK: Exported Checks

@MainActor
public let appAndDesignChecks: [Check] = [
    Check("app.commands") { c in
        let probe = CommandProbe()
        let registry = CommandRegistry()

        guard let cmdK = KeyShortcut("cmd+k"), let ctrlS = KeyShortcut("ctrl+s") else {
            c.fail("failed to parse key shortcuts")
            return
        }
        c.expectEqual(cmdK.displayString, "Cmd+K", "shortcut display string")
        c.expectEqual(ctrlS.displayString, "Ctrl+S", "ctrl shortcut display string")

        registry.register([
            Command(
                id: "app.search",
                title: "Search Library",
                category: "Navigation",
                shortcut: cmdK,
                icon: "search",
                perform: { probe.searches += 1 }
            ),
            Command(
                id: "file.save",
                title: "Save Queue",
                category: "File",
                shortcut: ctrlS,
                isEnabled: { probe.canSave },
                perform: { probe.saves += 1 }
            ),
            Command(
                id: "audio.mute",
                title: "Mute Output",
                category: "Audio",
                shortcut: KeyShortcut("m"),
                isChecked: { probe.muted },
                perform: { probe.muted.toggle() }
            ),
        ])

        registry.registerGroup(CommandGroup(
            id: "main.context",
            title: "Actions",
            items: [.command("app.search"), .separator, .command("file.save"), .command("audio.mute")]
        ))

        // Shortcut dispatch and execute by ID.
        if let pressK = KeyPress("cmd+k") {
            c.expect(registry.handleKeyPress(pressK), "Cmd+K dispatches Search")
        }
        c.expectEqual(probe.searches, 1, "search ran once")

        if let pressS = KeyPress("ctrl+s") {
            c.expect(registry.handleKeyPress(pressS), "Ctrl+S dispatches Save when enabled")
        }
        c.expectEqual(probe.saves, 1, "save ran once")

        // Disabled command rejection via both execute and shortcut.
        probe.canSave = false
        c.expect(!registry.execute("file.save"), "disabled command rejected by execute")
        if let pressS = KeyPress("ctrl+s") {
            c.expect(!registry.handleKeyPress(pressS), "disabled command rejected by shortcut")
        }
        c.expectEqual(probe.saves, 1, "disabled save did not run")

        if let pressUnbound = KeyPress("cmd+z") {
            c.expect(!registry.handleKeyPress(pressUnbound), "unregistered shortcut ignored")
        }

        // Checked toggle command.
        c.expect(registry.execute("audio.mute"), "mute executes")
        c.expect(probe.muted, "mute toggled on")

        // Category, group, and describe metadata queries.
        c.expectEqual(registry.categories, ["Audio", "File", "Navigation"], "categories sorted")
        c.expectEqual(registry.commands(inCategory: "File").map(\.id), ["file.save"], "category filter")

        let menu = registry.menuItems(forGroup: "main.context")
        c.expectEqual(menu.count, 4, "menu contains 3 commands and 1 separator")
        c.expectEqual(menu[1], ResolvedMenuItem(.separator), "separator preserved in menu")
        if case .command(let id, _, let shortcut, _, let enabled, _) = menu[2].kind {
            c.expectEqual(id, "file.save", "menu item id")
            c.expectEqual(shortcut, "Ctrl+S", "menu item shortcut")
            c.expect(!enabled, "menu item reflects live disabled state")
        } else {
            c.fail("expected command at menu[2]")
        }

        let meta = registry.describe()
        c.expectEqual(meta.map(\.id), ["audio.mute", "file.save", "app.search"], "describe sorted by category then id")
        let described = registry.describeJSON()
        c.expectEqual(described["commands"]?.array?.count, 3, "describeJSON exports all commands")
        c.expectEqual(described["groups"]?.array?.count, 1, "describeJSON exports registered groups")

        // Unregister.
        registry.unregister("app.search")
        c.expect(registry.command(for: "app.search") == nil, "unregistered command removed")
        c.expectEqual(registry.allCommands.count, 2, "two commands remain")
    },

    Check("app.settings") { c in
        let dir = PolymerPlatform.Path.join(c.outputDirectory, "app")
        let path = PolymerPlatform.Path.join(dir, "settings-test.json")

        let store = SettingsStore(filePath: path, schemaVersion: 2)
        c.expect(!store.isDirty, "fresh store is clean")
        c.expectEqual(store.bool(forKey: "missing.bool", default: true), true, "bool default")
        c.expectEqual(store.int(forKey: "missing.int", default: 42), 42, "int default")
        c.expectEqual(store.string(forKey: "missing.str", default: "pgr"), "pgr", "string default")

        store.set(true, forKey: "audio.exclusive")
        store.set(96000, forKey: "audio.sampleRate")
        store.set(-1.5, forKey: "audio.preampDb")
        store.set("pgr", forKey: "ui.theme")
        store.set(["FLAC", "ALAC", "WAV"], forKey: "library.formats")
        store.set(.object(["nested": .bool(true)]), forKey: "custom.meta")
        store.set("temp", forKey: "ephemeral")
        store.remove("ephemeral")

        c.expect(store.isDirty, "mutations mark store dirty")
        c.expect(!store.contains("ephemeral"), "removed key gone")
        c.expectEqual(store.keys, ["audio.exclusive", "audio.preampDb", "audio.sampleRate", "custom.meta", "library.formats", "ui.theme"], "keys sorted deterministically")

        try store.save()
        c.expect(!store.isDirty, "save clears dirty flag")
        c.expect(Platform.files.exists(path), "settings file written to disk")

        let rawOnDisk = try Platform.files.readText(path)
        c.expectEqual(rawOnDisk, store.serialize(pretty: true), "serialized output is byte-deterministic")

        let reloaded = SettingsStore(filePath: path)
        try reloaded.load()
        c.expectEqual(reloaded.schemaVersion, 2, "schemaVersion preserved")
        c.expectEqual(reloaded.bool(forKey: "audio.exclusive"), true, "bool round-trip")
        c.expectEqual(reloaded.int(forKey: "audio.sampleRate"), 96000, "int round-trip")
        c.expectClose(reloaded.double(forKey: "audio.preampDb"), -1.5, tolerance: 1e-9, "double round-trip")
        c.expectEqual(reloaded.string(forKey: "ui.theme"), "pgr", "string round-trip")
        c.expectEqual(reloaded.stringArray(forKey: "library.formats"), ["FLAC", "ALAC", "WAV"], "string array round-trip")
        c.expectEqual(reloaded.json(forKey: "custom.meta"), .object(["nested": .bool(true)]), "raw JSON round-trip")
        c.expectEqual(reloaded.serialize(pretty: true), rawOnDisk, "reload serialization matches byte-for-byte")

        reloaded.reset()
        c.expectEqual(reloaded.count, 0, "reset clears all keys")
        c.expect(reloaded.isDirty, "reset marks dirty")

        // In-memory store works without disk I/O.
        let memory = SettingsStore()
        memory.set(7, forKey: "count")
        try memory.save()
        c.expectEqual(memory.int(forKey: "count"), 7, "in-memory value retained")
    },

    Check("app.screens") { c in
        let font = Font(try TextReference.font(root: c.root, "Geist-Regular.otf"), size: 13)
        let screens = ScreenRegistry()

        screens.register(name: "zebra", description: "Last alphabetically", defaultSize: Size(width: 180, height: 60)) {
            Text("Zebra Screen").font(font).padding(8).background(Color(white: 0.1))
        }
        screens.register(name: "alpha", description: "First alphabetically", defaultSize: Size(width: 180, height: 60), defaultScale: 2) {
            Text("Alpha Screen").font(font).padding(8).background(Color(white: 0.15))
        }
        screens.register(name: "middle", description: "Middle screen", defaultSize: Size(width: 180, height: 60)) {
            Text("Middle Screen").font(font).padding(8).background(Color(white: 0.2))
        }

        c.expectEqual(screens.names, ["alpha", "middle", "zebra"], "screen names sorted deterministically")
        c.expectEqual(screens.allScreens.map(\.name), ["alpha", "middle", "zebra"], "allScreens sorted deterministically")
        c.expect(screens.screen(named: "missing") == nil, "unknown screen returns nil")

        guard let dump = screens.elementTree(named: "alpha") else {
            c.fail("alpha element tree missing")
            return
        }
        c.expect(dump.contains("\"Alpha Screen\""), "elementTree contains screen content")

        guard let bmp = screens.render(named: "alpha", background: .black) else {
            c.fail("alpha render failed")
            return
        }
        c.expect(bmp.width > 0 && bmp.height > 0, "headless render produced non-empty bitmap")
        c.expectEqual(screens.describeJSON().array?.count, 3, "describeJSON lists all 3 screens")

        // WindowGroup & WindowConfig integration.
        let cmds = CommandRegistry()
        cmds.register(Command(id: "win.close", title: "Close", perform: {}))
        let group = WindowGroup(
            id: "main",
            title: "Player",
            initialSize: Size(width: 320, height: 180),
            backdrop: .darkGlass,
            scale: 2,
            commands: cmds
        ) {
            Text("Window Body").font(font)
        }
        let tree = group.makeTree()
        c.expectEqual(tree.environment.displayScale, 2, "window scale applied to tree")
        c.expect(tree.environment.commandRegistry === cmds, "window commands wired into environment")
        c.expect(tree.elementTree.contains("\"Window Body\""), "window tree builds content")
    },

    Check("design.themes") { c in
        let font = Font(try TextReference.font(root: c.root, "Geist-Regular.otf"), size: 13)

        c.expect(Theme.pgr.isDark && Theme.pgr.glass.enabled && Theme.pgr.radii.medium == 0 && Theme.pgr.borders.hairlineWidth == 0,
                 "pgr preset defines dark glass, sharp 0pt corners, and 1px physical hairlines")
        c.expect(Theme.dark.isDark && Theme.dark.radii.medium > 0, "dark preset is dark with rounded corners")
        c.expect(!Theme.light.isDark && Theme.light.radii.medium > 0, "light preset is light with rounded corners")

        let custom = Theme.pgr.with { t in
            t.name = "amber"
            t.colors.background = Color(hex: 0x18120B)
            t.colors.surface = Color(hex: 0x241B10)
            t.glass.enabled = false
        }.withAccent(Color(hex: 0xF59E0B), accentText: Color(hex: 0x111111))
        c.expectEqual(custom.name, "amber", "custom derived theme name")
        c.expectEqual(custom.colors.accent, Color(hex: 0xF59E0B), "custom accent applied")
        c.expectEqual(custom.focusRing.color, Color(hex: 0xF59E0B), "focus ring follows derived accent")

        let tokens = Theme.pgr.describeTokens()
        c.expectEqual(tokens["name"]?.string, "pgr", "describeTokens exports name")
        c.expect(tokens["colors"]?["accent"]?.string != nil, "describeTokens exports color tokens")

        @MainActor func render(with theme: Theme) -> Bitmap {
            let tree = ViewTree(ThemeShowcaseView(font: font).theme(theme))
            return tree.render(background: theme.colors.background)
        }

        let pgrBmp = render(with: .pgr)
        let darkBmp = render(with: .dark)
        let lightBmp = render(with: .light)
        let customBmp = render(with: custom)

        c.expect(pgrBmp != darkBmp, "pgr and dark presets render distinct pixels")
        c.expect(darkBmp != lightBmp, "dark and light presets render distinct pixels")
        c.expect(pgrBmp != lightBmp, "pgr and light presets render distinct pixels")
        c.expect(pgrBmp != customBmp, "custom derived theme renders distinct pixels")
        c.expect(pgrBmp == render(with: .pgr), "theme rendering is deterministic")

        let dir = PolymerPlatform.Path.join(c.outputDirectory, "design")
        try Platform.files.createDirectory(dir)
        try Platform.files.write(PNG.encode(pgrBmp), to: PolymerPlatform.Path.join(dir, "theme-pgr.png"))
        try Platform.files.write(PNG.encode(darkBmp), to: PolymerPlatform.Path.join(dir, "theme-dark.png"))
        try Platform.files.write(PNG.encode(lightBmp), to: PolymerPlatform.Path.join(dir, "theme-light.png"))
    },

    Check("design.controls") { c in
        let font = Font(try TextReference.font(root: c.root, "Geist-Regular.otf"), size: 13)
        let model = ControlsModel()
        let probe = CommandProbe()
        probe.canSave = false

        let registry = CommandRegistry()
        registry.register([
            Command(
                id: "ctx.search",
                title: "Search",
                shortcut: KeyShortcut("cmd+k"),
                perform: { probe.searches += 1 }
            ),
            Command(
                id: "ctx.save",
                title: "Save",
                shortcut: KeyShortcut("ctrl+s"),
                isEnabled: { probe.canSave },
                perform: { probe.saves += 1 }
            ),
            Command(
                id: "ctx.mute",
                title: "Mute",
                isChecked: { probe.muted },
                perform: { probe.muted.toggle() }
            ),
        ])
        let menuGroup = CommandGroup(
            id: "ctx",
            title: "Menu",
            items: [.command("ctx.search"), .separator, .command("ctx.save"), .command("ctx.mute")]
        )
        registry.registerGroup(menuGroup)

        let tree = ViewTree(
            ControlsShowcaseView(
                model: model,
                registry: registry,
                group: menuGroup,
                font: font,
                onDismiss: { probe.dismissed += 1 }
            )
            .theme(.pgr)
            .commandRegistry(registry)
        )
        tree.update()

        // Buttons: enabled runs, disabled does not.
        c.expect(tree.click(text: "Run"), "primary button clicks")
        c.expectEqual(model.primaryClicks, 1, "primary button action ran")
        c.expect(!tree.click(text: "Locked"), "disabled destructive button rejects clicks")
        c.expectEqual(model.disabledClicks, 0, "disabled button action did not run")

        // PolymerToggle: click and keyboard Space/Return.
        c.expect(!model.toggleOn, "toggle starts off")
        c.expect(tree.click(text: "Autoplay"), "clicking toggle switches it")
        c.expect(model.toggleOn, "toggle is now on")

        // Move focus to the toggle button via Tab and activate with Space and Return.
        var focusedToggle = false
        for _ in 0..<10 {
            _ = tree.key("tab")
            if tree.focusedElement?.contains("Autoplay") == true {
                focusedToggle = true
                break
            }
        }
        c.expect(focusedToggle, "Tab reaches PolymerToggle")
        c.expect(tree.key("space"), "Space toggles focused PolymerToggle")
        c.expect(!model.toggleOn, "toggle turned off via Space")
        c.expect(tree.key("return"), "Return toggles focused PolymerToggle")
        c.expect(model.toggleOn, "toggle turned back on via Return")

        // PolymerSlider: pointer click focuses and adjusts value, keyboard arrows step value.
        guard let sliderCenter = tree.point(ofID: "volume-slider") else {
            c.fail("volume-slider missing from element tree")
            return
        }
        // Click near right edge (~90% across 160pt track).
        let rightClick = Point(x: sliderCenter.x + 65, y: sliderCenter.y)
        c.expect(tree.click(at: rightClick), "clicking slider track focuses and updates value")
        c.expect(model.sliderValue > 70, "right-side click raised slider value (got \(model.sliderValue))")

        let beforeKey = model.sliderValue
        c.expect(tree.key("left"), "left arrow decrements focused slider")
        c.expectClose(model.sliderValue, beforeKey - 10, tolerance: 1e-6, "slider stepped down by 10")
        c.expect(tree.key("right"), "right arrow increments focused slider")
        c.expectClose(model.sliderValue, beforeKey, tolerance: 1e-6, "slider stepped back up by 10")
        c.expect(tree.key("home"), "Home jumps slider to minimum")
        c.expectClose(model.sliderValue, 0, tolerance: 1e-6, "slider at min")
        c.expect(tree.key("end"), "End jumps slider to maximum")
        c.expectClose(model.sliderValue, 100, tolerance: 1e-6, "slider at max")

        // PolymerScrollBar: overflow draws at viewport height, fitting/hidden bars collapse to 0x0.
        let dump = tree.elementTree
        let overflowLine = dump.split(separator: "\n").first { $0.contains("#bar-overflow") }.map(String.init) ?? ""
        let fitLine = dump.split(separator: "\n").first { $0.contains("#bar-fit") }.map(String.init) ?? ""
        let hiddenLine = dump.split(separator: "\n").first { $0.contains("#bar-hidden") }.map(String.init) ?? ""
        c.expect(overflowLine.contains("x80)"), "overflowing scroll bar spans viewport height: \(overflowLine)")
        c.expect(fitLine.contains("0x0)"), "non-overflowing automatic scroll bar collapses to 0x0: \(fitLine)")
        c.expect(hiddenLine.contains("0x0)"), "hidden scroll bar collapses to 0x0: \(hiddenLine)")

        // FocusRingModifier: visual pixels change when focused without shifting layout.
        let beforeRing = tree.render(background: Theme.pgr.colors.background)
        let beforeTargetPoint = tree.point(ofID: "ring-target")
        model.ringFocused = true
        let afterRing = tree.render(background: Theme.pgr.colors.background)
        let afterTargetPoint = tree.point(ofID: "ring-target")
        c.expect(beforeRing != afterRing, "focusRing visibly renders outline when focused")
        c.expectEqual(beforeTargetPoint, afterTargetPoint, "focusRing does not shift layout")

        // PolymerContextMenu wired to CommandRegistry.
        c.expect(dump.contains("\"Search\"") && dump.contains("\"Cmd+K\""), "context menu shows title and shortcut")
        c.expect(tree.click(text: "Search"), "clicking enabled context menu item executes command")
        c.expectEqual(probe.searches, 1, "context menu command ran")
        c.expectEqual(probe.dismissed, 1, "context menu invoked onDismiss")
        c.expect(!tree.click(text: "Save"), "disabled context menu command rejects click")
        c.expectEqual(probe.saves, 0, "disabled context menu command did not run")
        c.expect(tree.click(text: "Mute"), "checked command executes from context menu")
        c.expect(probe.muted, "mute toggled from context menu")

        let dir = PolymerPlatform.Path.join(c.outputDirectory, "design")
        try Platform.files.createDirectory(dir)
        try Platform.files.write(PNG.encode(tree.render(background: Theme.pgr.colors.background)),
                                 to: PolymerPlatform.Path.join(dir, "controls.png"))
    },

    Check("design.lint") { c in
        let font = Font(try TextReference.font(root: c.root, "Geist-Regular.otf"), size: 13)

        // Compliant pgr view passes all pgr lint rules cleanly.
        let cleanTree = ViewTree(CompliantPgrView(font: font).theme(.pgr))
        _ = cleanTree.render(background: Theme.pgr.colors.background)
        let cleanViolations = DesignLint.audit(tree: cleanTree, theme: .pgr, rules: DesignLint.pgrRules)
        c.expect(cleanViolations.isEmpty, "compliant pgr view has 0 violations, got: \(cleanViolations)")

        // Non-compliant view triggers every opted-in pgr rule.
        let dirtyTree = ViewTree(NonCompliantView(font: font).theme(.pgr))
        _ = dirtyTree.render(background: Theme.pgr.colors.background)
        let violations = DesignLint.audit(tree: dirtyTree, theme: .pgr, rules: DesignLint.pgrRules)
        let ruleIDs = Set(violations.map(\.rule))
        c.expect(ruleIDs.contains(DesignLintRule.noAllCaps.rawValue), "catches ALL CAPS copy: \(violations)")
        c.expect(ruleIDs.contains(DesignLintRule.noDoubleSlashPrefix.rawValue), "catches '//' prefix: \(violations)")
        c.expect(ruleIDs.contains(DesignLintRule.pgrSharpCorners.rawValue), "catches RoundedRectangle in pgr mode: \(violations)")
        c.expect(ruleIDs.contains(DesignLintRule.noStackedGlass.rawValue), "catches stacked BackdropBlur veils: \(violations)")
        c.expect(ruleIDs.contains(DesignLintRule.tokenColorsOnly.rawValue), "catches raw off-palette color: \(violations)")
        c.expect(violations.allSatisfy { !$0.fix.isEmpty }, "every violation includes an actionable fix")

        // Theme radii check catches rounded theme when pgrSharpCorners is opted into.
        let darkTree = ViewTree(Text("Hello").font(font).theme(.dark))
        let radiiViolations = DesignLint.audit(tree: darkTree, theme: .dark, rules: [.pgrSharpCorners])
        c.expectEqual(radiiViolations.count, 1, "rounded theme flagged when pgrSharpCorners is requested")

        // Opt-in subset only checks selected rules.
        let copyOnly = DesignLint.audit(tree: dirtyTree, theme: .pgr, rules: [.noDoubleSlashPrefix])
        c.expectEqual(copyOnly.map(\.rule), [DesignLintRule.noDoubleSlashPrefix.rawValue], "opt-in subset runs only requested rules")
    },

    Check("design.customize") { c in
        let font = Font(try TextReference.font(root: c.root, "Geist-Regular.otf"), size: 13)
        let state = CustomizeState()
        let tree = ViewTree(
            CustomizeDemoView(font: font)
                .theme(.pgr)
                .customizeState(state)
        )

        let baseline = tree.render(background: Theme.pgr.colors.background)
        let baselineDump = tree.elementTree
        c.expect(baselineDump.contains("#hero") && baselineDump.contains("#badge"), "customizable elements expose #ids")

        // Stable key resolution prefers #id, falls back to stablePath.
        let heroPath = tree.stablePath(ofID: "hero") ?? ""
        c.expectEqual(CustomizeState.targetKey(id: "hero", stablePath: heroPath), "#hero", "targetKey anchors on #id")
        c.expectEqual(CustomizeState.targetKey(id: nil, stablePath: "VStack[0]/Text[1]"), "VStack[0]/Text[1]", "targetKey falls back to stablePath")

        // Hide removes element from tree and changes rendered image.
        state.hide("badge")
        let hiddenImg = tree.render(background: Theme.pgr.colors.background)
        let hiddenDump = tree.elementTree
        c.expect(!hiddenDump.contains("Lossless") && !hiddenDump.contains("#badge"), "hidden element removed from element tree")
        c.expect(hiddenImg != baseline, "hiding element changes rendered pixels")

        // Unhide, move, scale, and restyle.
        state.unhide("badge")
        state.setOffset(x: 24, y: 12, for: "hero")
        state.setScale(1.5, for: "hero")
        state.setStyle(
            foreground: Color(hex: 0xF59E0B),
            background: Color(hex: 0x1E293B),
            accent: Color(hex: 0x22C55E),
            padding: EdgeInsets(all: 8),
            for: "hero"
        )
        let styledImg = tree.render(background: Theme.pgr.colors.background)
        c.expect(styledImg != baseline, "move/scale/style visibly alters rendered output")
        c.expect(tree.elementTree.contains("Lossless"), "unhidden badge restored")

        // Customize mode outline renders visibly.
        state.isCustomizing = true
        state.selectedTarget = "hero"
        let outlineImg = tree.render(background: Theme.pgr.colors.background)
        c.expect(outlineImg != styledImg, "customize mode draws selection outline")

        // Deterministic JSON round-trip persistence via SettingsStore.
        let settingsPath = PolymerPlatform.Path.join(c.outputDirectory, "design/customize-settings.json")
        let settings = SettingsStore(filePath: settingsPath)
        state.save(to: settings)
        try settings.save()

        let reloadedSettings = SettingsStore(filePath: settingsPath)
        try reloadedSettings.load()
        let restoredState = CustomizeState()
        restoredState.load(from: reloadedSettings)

        c.expectEqual(restoredState.allOverrides, state.allOverrides, "customizations round-trip identically via SettingsStore")
        c.expectEqual(restoredState.exportJSON().serialized, state.exportJSON().serialized, "exported customize JSON is byte-deterministic")

        // resetAll restores exact baseline pixels.
        state.isCustomizing = false
        state.resetAll()
        let resetImg = tree.render(background: Theme.pgr.colors.background)
        c.expect(resetImg == baseline, "resetAll restores original rendered pixels identically")
    },
]
