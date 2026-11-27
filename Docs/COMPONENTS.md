# PolymerDesign Component Catalog

`PolymerDesign` provides the pgr look as ready-made SwiftUI-shaped components (re-exported by `import Polymer`).

Every component built on `Component` automatically gets:
- **Theme tokens** from `@Environment(\.theme)` (greys + one accent, brutalist 1-point grid, zero raw colours).
- **A stable element path** (e.g. `"toolbar/import"`) registered in `DesignRegistry` for headless automation.
- **A right-click menu** built from the component's own commands, ancestor `.commands { ... }` scopes, and **Customize**.
- **User customization** via `CustomizeModel` (hide, scale, custom width/height, style), persisted as deterministic JSON and previewable via `--customize <file.json>`.

Preview every component at once: `polymer render components out/components.png --scale 2`.

---

## Quick Index

| Symbol | Category | Purpose |
|---|---|---|
| `designRoot` | Setup | Wires `Theme`, `CustomizeModel`, `CommandRegistry`, `DesignRegistry`, `PanelLook`, and `TextInputLook`. |
| `Theme` / `accent` | Setup | Design tokens and scoped accent override. |
| `PButton` | Controls | Primary, secondary, plain, or icon button with optional shortcut. |
| `PToggle` | Controls | On/off switch row (click or Space). |
| `PSlider` | Controls | Continuous range slider (drag, arrows, Home/End). |
| `PProgressBar` | Controls | Determinate progress bar (`0...1`). |
| `PSegmentedControl` | Controls | Joined single-selection button strip. |
| `PPicker` | Controls | Dropdown menu picker showing the active choice. |
| `PTextField` | Controls | Styled single-line text field with `onSubmit`. |
| `PListRow` | Layout | Full-width selectable row with detail text and accent bar. |
| `PSectionHeader` | Layout | Sentence-case section heading over a group of rows. |
| `PSidebarLayout` | Layout | Sidebar + 1-point divider + detail pane. |
| `PToolbar` | Layout | Top control bar with bottom 1-point rule. |
| `PPanel` | Layout | Boxed surface container with optional title. |
| `PScrollBar` | Layout | Square-thumb scrollbar (live via `ScrollViewProxy` or manual). |
| `tooltip` | Overlays | Hover panel anchored below a view. |
| `panelSheet` | Overlays | Modal panel sheet (Escape closes). |
| `panelPopover` | Overlays | Anchored popover panel (outside click closes). |
| `focusRing` | Overlays | 1-point accent keyboard focus ring. |
| `Command` / `commands` / `CommandRegistry` | Commands | Unified menu + shortcut system; auto-unregisters on view unmount. |
| `Component` / `Part` / `element` | Customize | Primitives for custom components, named parts, and path scoping. |
| `CustomizeModel` / `DesignRegistry` | Customize | JSON persistence for user customizations and path-based UI inspection/clicking. |

---

## Setting up a window

**designRoot**: sets the `Theme`, `CustomizeModel`, `CommandRegistry`, and `DesignRegistry` for a window, and wires `PanelLook` and `TextInputLook` directly from the theme's tokens.

```swift
let theme = Theme(sans: geist, mono: geistMono)
Root().designRoot(theme: theme, customize: CustomizeModel(), commands: CommandRegistry(), registry: DesignRegistry())
```

**Theme**: every colour, size, font and line of the look. Components read
it from the environment; it is greys plus one accent, square, 1-point lines.

```swift
@Environment(\.theme) var theme
Text("Album").textStyle(.title, theme.gray.text, theme: theme)
```

**accent**: changes the one non-grey colour for a view and everything in it.

```swift
Settings().accent(Color(hex: 0x3FA34D))
```

## Buttons and controls

**PButton**: a button in one of four kinds: primary (the main action),
secondary, plain, or icon.

```swift
PButton("Save", kind: .primary, shortcut: KeyboardShortcut("s")) { save() }
PButton(symbol: "+", help: "New playlist") { newPlaylist() }
```

**PToggle**: an on/off switch with its title; click the row or press Space.

```swift
PToggle("Shuffle", isOn: $shuffle)
```

**PSlider**: a value in a range; drag it, or use the arrow keys, Home and End.

```swift
PSlider("Volume", value: $volume, in: 0...1)
```

**PProgressBar**: how far something has got, from 0 to 1.

```swift
PProgressBar("Import", value: 0.4)
```

**PSegmentedControl**: a row of joined buttons with one chosen.

```swift
PSegmentedControl("View", selection: $view, options: [PickerOption("Albums", value: .albums), PickerOption("Artists", value: .artists)])
```

**PPicker**: a button showing the current choice that opens a menu of all of them.

```swift
PPicker("Sort by", selection: $sort, options: [PickerOption("Artist", value: .artist), PickerOption("Year", value: .year)])
```

**PTextField**: a one-line text field; its title is the placeholder, Return runs `onSubmit`.

```swift
PTextField("Search", text: $query) { search() }
```

## Lists and layout

**PListRow**: a full-width row; the chosen one is raised with an accent bar.

```swift
PListRow("Blue Train", detail: "10:43", isSelected: chosen == id) { chosen = id }
```

**PSectionHeader**: the small grey title over a group of rows. Write it in sentence case.

```swift
PSectionHeader("Playlists")
```

**PSidebarLayout**: a sidebar, a 1-point line, and the detail filling the rest.

```swift
PSidebarLayout { SidebarRows() } detail: { AlbumGrid() }
```

**PToolbar**: a bar of controls across the top, with a line under it.

```swift
PToolbar { PButton("Back", kind: .plain) { back() }; Spacer(); PButton("Import", kind: .primary) { importFiles() } }
```

**PPanel**: a boxed group with an optional title, on the surface grey.

```swift
PPanel("Playback") { PToggle("Shuffle", isOn: $shuffle) }
```

**PScrollBar**: a square thumb on a 1-point track. Bind it directly to a
`ScrollViewProxy` from `ScrollViewReader` for live scroll tracking, or pass
explicit `(visible:position:)` fractions.

```swift
// Live (recommended): tracks scroll position automatically
ScrollViewReader { proxy in
    HStack(spacing: 0) {
        ScrollView { TrackRows() }
        PScrollBar(proxy)
    }
}

// Manual fractions
PScrollBar(visible: 0.3, position: offset / maxOffset)
```

## Overlays

**tooltip**: a small panel under a view while the pointer is on it.

```swift
PButton(symbol: "+", help: "New playlist") { add() }.tooltip("New playlist")
```

**panelSheet**: content in a panel in front of the window; Escape closes it.

```swift
Library().panelSheet(isPresented: $showExport, title: "Export") { ExportForm() }
```

**panelPopover**: content in a panel next to a view; a click outside closes it.

```swift
PButton("Info") { showInfo = true }.panelPopover(isPresented: $showInfo) { TrackInfo() }
```

**focusRing**: the 1-point accent ring of a control with keyboard focus (built into every component).

```swift
MyControl().focusRing(isFocused, theme: theme)
```

## Commands

**Command**: one action with an id, a title, an optional shortcut and whether it can run now.

```swift
Command("library.play", "Play", shortcut: KeyboardShortcut("p")) { player.play() }
```

**commands**: adds commands to a view; they appear in the right-click menu of
everything inside it, join the active `CommandRegistry`, and **automatically
unregister when the view unmounts** (via `.onDisappear`).

```swift
TrackList().commands { Command("library.play-next", "Play next") { queue.next(track) } }
```

**CommandRegistry**: the app's commands by id; runs them by id or shortcut and lists rule breaks.

```swift
registry.run("library.play"); tree.key("cmd+p", commands: registry); print(registry.problems)
```

## Customize and names

**Component**: the core every component is built on; use it for your own
to get a name, a right-click menu and Customize.

```swift
Component(name: "meter", role: "Meter", title: "Level") { info in LevelBars(theme: info.theme) }
```

**Part**: a named piece of a component (a segment, a region) that agents can find and click.

```swift
Part(name: "albums", role: "Segment", title: "Albums") { segment }
```

**element**: names a group, so the components inside get paths under it.

```swift
VStack { PButton("Play") { play() } }.element("transport")   // "transport/play"
```

**CustomizeModel**: stores per-path user overrides (`hidden`, `scale`, `width`,
`height`, `style`) and round-trips through deterministic `JSON`. Pass a saved
JSON file to `polymer render` or `polymer describe` with `--customize <file.json>`.

```swift
let saved = customize.json.serialized
let restored = try CustomizeModel(json: JSON.parse(saved))
```

**DesignRegistry**: every component by path, role, title and frame; agents
read `description` and drive components by name.

```swift
print(registry.description); tree.click(element: "toolbar/import", in: registry)
```
