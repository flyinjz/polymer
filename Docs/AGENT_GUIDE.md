# Building on Polymer: a guide for agents

This is the fast path for an agent writing an app on Polymer. If you know
SwiftUI you already know most of it: read the ten points below, copy the
minimal app, and use the loop.

- Rules for working on Polymer itself: [`AGENTS.md`](../AGENTS.md)
- Ready-made design components (`PButton`, `PSlider`, `PScrollBar`, `Command`, `CustomizeModel`): [`Docs/COMPONENTS.md`](COMPONENTS.md)
- Every deliberate difference from SwiftUI: [`Docs/DIFFERENCES.md`](DIFFERENCES.md)

## Table of Contents

- [Project layout](#project-layout)
- [Ten things to know](#ten-things-to-know)
- [A complete minimal app](#a-complete-minimal-app)
- [Running headlessly](#running-headlessly)
- [The loop](#the-loop)
- [Common mistakes and their fixes](#common-mistakes-and-their-fixes)
- [Differences from SwiftUI, in short](#differences-from-swiftui-in-short)
- [Recipes](#recipes)
- [Status and activity](#status-and-activity)

## Project layout

| Where | What |
|---|---|
| `Sources/PolymerBase` | Geometry, colours, paths, `JSON`, `StableID`. No dependencies. |
| `Sources/PolymerText` | Fonts, shaping, GDEF, UAX #14 line breaking, fallback, variable fonts, COLR/CPAL emoji, `GlyphCache`. |
| `Sources/PolymerRender` | Software rasterizer, `DisplayList`, `Bitmap`, `PNG`, `JPEG`, blur, glass. |
| `Sources/PolymerGPU` and backends | Drawing on the graphics card (`PolymerGPUD3D12`). |
| `Sources/PolymerUI` | Views, layout, state, input, gestures, presentations, animation, accessibility, `ViewTree`. |
| `Sources/Polymer` | The one module an app imports. Re-exports Base, Text, Render, UI, and Design. |
| `Sources/PolymerDesign` | The pgr look as `Theme` tokens, `P*` components, `CommandRegistry`, `CustomizeModel`, `DesignRegistry`. |
| `Sources/PolymerAudio` | Pure-Swift codecs (WAV, FLAC, MP3, AIFF, ALAC), metadata/ReplayGain, 64-bit DSP, gapless playback. |
| `Sources/PolymerPlatform*` | The operating system: files, windows, clipboard, IME, audio output. Per-OS code lives only here. |
| `Sources/PolymerApp` | `WindowHost`: puts a `ViewTree` in a real window via `ViewTree.record()`. |
| `Sources/PolymerChecks` | The 97 framework checks and sample screens. |
| `Sources/PolymerTools` | The `polymer` command and 8 tool checks. |
| `Tests/Fixtures/Fonts` | Bundled fonts (Geist, Geist Mono, Inter, JetBrains Mono). |
| `Tests/Reference` | Reference images the checks compare against (CoreText, JPEG). |
| `Docs` | Design, components, differences, handoff, status, and activity. |

## Ten things to know

1. **Import `Polymer`.** One import gives views, state, layout, drawing
   and text. `@Observable` comes with it.
2. **Set a font.** There are no system fonts. Load a bundled face and put
   it on the root view: `.font(Font(face, size: 13))`. A `Text` or `TextField`
   without a font logs a warning: `has no font; set one with
   .font(Font(face, size:)) on it or an ancestor`.
3. **State is SwiftUI's.** `@State` inside a view, `@Observable` classes
   for shared models, `@Binding` and `@Bindable` to pass them down,
   `@Environment` for settings. There is no `ObservableObject`; use
   `@Observable`.
4. **Standard library only** in shared code. No Foundation, no AppKit, no
   Win32 types. Files go through `Platform.files`, the process through
   `Platform.process`, JSON through `JSON`. `#if os(...)` only in
   backends.
5. **Everything runs headlessly.** A `ViewTree` is a live screen with no
   window: update it, click it, type into it, render it to a `Bitmap`.
   Never open a window during a check.
6. **Drive screens by what they show (or by element path).** `click(text: "Add")` clicks the
   view showing "Add"; `point(ofText:)` finds it. With `PolymerDesign`, give groups
   `.element("name")` and drive components directly via `tree.click(element: "toolbar/import", in: registry)`.
7. **Points, top-left origin.** Frames are in points, y grows downward.
   `displayScale` in the environment sets pixels per point (2 for a
   Retina-style image).
8. **One way to do each thing.** If SwiftUI has two ways, Polymer usually
   keeps one. When something is missing, DIFFERENCES.md says so; don't
   work around it with private tricks. Add it to Polymer properly or note
   it.
9. **Checks are the tests.** `polymer check` runs them all. A change is
   not done until they pass on the OS you are on.
10. **Say what you did.** After each piece of work, `polymer log "one
    plain sentence"`. The owner reads `Docs/ACTIVITY.md` and
    `Docs/STATUS.md`, not the code.

## A complete minimal app

A screen with a model, a button and a text field, plus a headless check
that drives it and saves an image.

```swift
import Polymer
import PolymerPlatform

@Observable
final class GreeterModel {
    var name = ""
    var greetings = 0
}

struct GreeterView: View {
    @Bindable var model: GreeterModel
    let font: Font

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Greeter")
            TextField("Name", text: $model.name)
                .frame(width: 200)
                .onSubmit { model.greetings += 1 }
            Button("Greet") { model.greetings += 1 }
            Text(model.name.isEmpty ? "Nobody yet" : "Hello, \(model.name) (\(model.greetings))")
                .foregroundStyle(Color(white: 0.6))
        }
        .font(font)
        .padding(16)
        .frame(width: 260, alignment: .leading)
        .background(Color(white: 0.063))
    }
}

@MainActor
func greeterCheck(root: String) throws -> Bool {
    let bytes = try Platform.files.read(Path.join(root, "Tests/Fixtures/Fonts/Geist-Regular.otf"))
    let font = Font(try FontFace(data: bytes), size: 13)
    let model = GreeterModel()
    var environment = EnvironmentValues()
    environment.displayScale = 2
    let tree = ViewTree(GreeterView(model: model, font: font), environment: environment)
    tree.update()

    // Find the field the way a screen reader would, and click its middle:
    // text fields take focus on click.
    func field(in e: AccessibilityElement) -> AccessibilityElement? {
        if e.role == .textField { return e }
        for c in e.children { if let f = field(in: c) { return f } }
        return nil
    }
    guard let f = field(in: tree.accessibilityTree) else { return false }
    tree.click(at: Point(x: f.frame.midX, y: f.frame.midY))
    tree.type("Ada")
    tree.key("return")             // runs .onSubmit
    tree.click(text: "Greet")

    let image = tree.render()
    // The out folder must already exist.
    try Platform.files.write(PNG.encode(image), to: Path.join(root, "out/greeter.png"))
    return tree.point(ofText: "Hello, Ada (2)") != nil
}
```

What to notice:

- The font is loaded once and set on the root; every `Text` below uses it.
- The check uses the same calls the `polymer` command uses (`click`,
  `type`, `key`, `render`), so what passes headlessly works in a window.
- `tree.elementTree` and `tree.accessibilityDescription` give the screen
  as text, for assertions that don't depend on pixels.

To show the screen in a real window, use `WindowHost` from `PolymerApp`;
`demoCommand` in `Sources/PolymerTools/main.swift` shows the whole setup.
There is no `App` or `WindowGroup` yet. Only do this when the owner asks
for a window. Checks never open one.

## Running headlessly

All of these work on the sample screens (`albums`, `counter`, `list`,
`library`, `glass`, `controls`). `polymer help screens` lists them. Apps
can't be named here yet; until they can, drive your own screens from a
check as in the example above.

```bash
polymer render counter out/counter.png --scale 2          # draw it to an image
polymer render controls out/c.png --customize c.json      # apply saved CustomizeModel JSON
polymer tree counter                                      # element tree: every view and its frame
polymer tree counter --a11y                               # what a screen reader sees
polymer describe counter                                  # accessibility tree in plain sentences
polymer diff out/a.png out/b.png --out out/diff.png       # pixel-by-pixel comparison + visual diff
polymer bench --frames 20                                 # layout+record and software raster p50/p95/max
polymer check                                             # run all 97 framework + 8 tool checks
polymer check-tools                                       # run only the 8 CLI/tool checks
polymer check --list                                      # list check names
```

Steps change the screen before it is drawn, described, or listed, in the
order given:

```
--click Add              click the view showing "Add"
--click-at 40,12         click a point
--hover Add              move the pointer over the view showing "Add"
--press Add              hold the pointer down on it (shows the pressed look)
--key shift+tab          press a key (see `polymer help steps`)
--scroll 120             scroll the middle of the screen down by 120 points
--drag 20,30,120,30      drag from one point to another
--type "Ada"             type into the focused text field (click it first)
--context-click Options  right-click the view showing "Options"
```

Add `--json` to `render`, `tree`, `describe`, `diff`, `bench`, `status`,
`log`, `activity`, or `help` for deterministic sorted-key JSON. Examples:

```
polymer render controls out/c.png --key tab --type Ada
polymer describe controls --context-click Options --click Rename
polymer tree counter --click Add --click Add --json
```

## The loop

1. Write or change the view.
2. `swift build`.
3. `polymer describe <screen>` with the steps a user would take. Is
   everything named, in order, with the right values?
4. `polymer render <screen> out/x.png --scale 2` and look at the image.
   Check it against the pgr look (AGENTS.md, principle 4).
5. Put what you checked by hand into a check, so it stays true.
6. `polymer check`. Fix until it passes.
7. `polymer log "what changed, in one plain sentence"`.

## Common mistakes and their fixes

| You see | Why | Fix |
|---|---|---|
| `has no font; set one with .font(Font(face, size:)) ...` | No font on the view or any ancestor. | Load a face (`FontFace(data:)`) and set `.font(...)` on the root. |
| `--click "X": no visible, clickable text reads exactly that` | The text isn't on screen, or differs (case, punctuation, an earlier step changed it), or it is scrolled out of view. | Run `polymer tree <screen>` with the same steps and copy the text exactly; scroll first if needed. |
| `--type "X": no text field has focus` | No text field has focus. | Click the field first (`--click-at x,y` on its frame from `polymer tree`), or `--key tab`, then `--type`. |
| `--key "X" is not a key` | The key name isn't one Polymer knows. | Use a character or `tab`, `space`, `return`, `escape`, `delete`, arrows (`up` ...), `home`, `end`, `pageup`, `pagedown`, with `shift+`, `ctrl+`, `alt+` or `cmd+` in front. |
| `--context-click "X": the view under that text has no context menu` | Nothing there has `.contextMenu`. | Add `.contextMenu { Button(...) }` to the view. |
| A button doesn't take focus when clicked | By design: buttons take focus from Tab only. | Use Tab in checks that need a focused button. |
| A drag does nothing | Drags start after 10 points, and only on what the view draws. | Drag further, and start on a drawn part of the view (not empty space). |
| A click behind a sheet or menu does nothing | Sheets take all input; a click outside a menu only closes it. | Close the sheet or menu first, or click inside it. |
| `import Foundation` fails a check, or doesn't build on another OS | Shared code is standard library only. | Use `Platform.files`, `JSON`, `Path.join` and Swift's own types. |
| A view's body runs more than expected | Only `Equatable` views are skipped when unchanged. | Make leaf views `Equatable`, and keep reads of observable state inside the views that need them. |
| `ObservableObject` or `@StateObject` not found | Not provided. | Use an `@Observable` class, held in `@State` or passed in. |
| An image of the screen has a blank area | The frame is smaller than the content, or the content needs scrolling. | `polymer tree` shows the frames; use `ScrollView` or a larger `.frame`. |

Errors from the `polymer` command say how to fix them; read the whole
message before trying something else.

## Differences from SwiftUI, in short

- Base types are `Point`, `Size`, `Rect`, `Color` (no CoreGraphics), with
  the same fields.
- Fonts are loaded faces, never `.system` or `.body`. Images are decoded
  `Bitmap`s, never asset names or system symbols.
- `Button` draws only its label until PolymerDesign gives it the house
  style.
- Only `Equatable` views are skipped when unchanged. `@Observable` is the
  only model type.
- `ViewTree` stands in for a hosting view; `ImageRenderer` gives a
  `Bitmap`.
- `Menu`, `.contextMenu`, `.popover`, `.sheet`, `.keyboardShortcut` work
  as in SwiftUI and are drawn by Polymer.
- `TextField` and `TextEditor` work, without prompts, formatters or
  styles.
- `Ctrl` on Windows means `.command`, so a shortcut is the same key on
  both OSes.
- `PolymerDesign` provides the styled pgr controls (`PButton`, `PToggle`,
  `PSlider`, `PProgressBar`, `PSegmentedControl`, `PPicker`, `PTextField`,
  `PListRow`, `PSectionHeader`, `PSidebarLayout`, `PToolbar`, `PPanel`,
  `PScrollBar`), `CommandRegistry`, `CustomizeModel`, and `.element("name")`.
  See [`Docs/COMPONENTS.md`](COMPONENTS.md).
- Still not in `PolymerUI`: `List`, `Form`, `NavigationStack`, `.alert`,
  `TapGesture`, and `App`/`WindowGroup`.

The full table, with the reason for each, is in
[DIFFERENCES.md](DIFFERENCES.md). When you add or change a difference,
add it there in the same change.

## Recipes

These use only what exists today. Where a SwiftUI control is missing, the
recipe says what to use until PolymerDesign provides it.

### A list screen

```swift
struct TrackList: View {
    let tracks: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Tracks").padding(horizontal: 16, vertical: 10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(tracks.indices) { i in
                        Button(action: { /* play tracks[i] */ }) {
                            Text(tracks[i])
                                .padding(horizontal: 16, vertical: 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }
}
```

`LazyVStack` builds only the rows in view, so tens of thousands of rows
stay fast. The `ForEach` must sit directly inside it. There is no `List`
yet.

### A form

```swift
struct SignIn: View {
    @State private var name = ""
    @State private var sent = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Name")
            TextField("Name", text: $name).frame(width: 220).onSubmit { sent = true }
            Button("Continue") { sent = true }
            if sent { Text("Thanks, \(name)") }
        }
        .padding(16)
    }
}
```

Return in a field runs `.onSubmit`. Tab moves between fields and buttons.
There is no `Form` yet; a `VStack` is the form.

### A settings screen

```swift
@Observable final class Settings { var shuffle = false; var volume = 0.8 }

struct SettingsView: View {
    @Bindable var settings: Settings
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(settings.shuffle ? "Shuffle: on" : "Shuffle: off") { settings.shuffle.toggle() }
                .accessibilityAddTraits(settings.shuffle ? .isSelected : [])
            HStack(spacing: 8) {
                Button("Quieter") { settings.volume = max(0, settings.volume - 0.1) }
                Text("Volume \(Int((settings.volume * 100).rounded()))")
                Button("Louder") { settings.volume = min(1, settings.volume + 0.1) }
            }
        }
        .padding(16)
    }
}
```

There is no `Toggle`, `Slider` or `Picker` yet. Until PolymerDesign
provides them, use buttons as here, or a `DragGesture` on a drawn track
for a slider. Mark the chosen state with `.isSelected` so screen readers
and `polymer describe` report it.

### A media player bar

```swift
struct PlayerBar: View {
    let title: String, artist: String, artwork: Bitmap
    @Binding var playing: Bool
    var body: some View {
        HStack(spacing: 12) {
            Image(artwork, scale: 2).resizable().scaledToFill()
                .frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(artist).foregroundStyle(Color(white: 0.6))
            }
            Spacer()
            Button(playing ? "Pause" : "Play") { playing.toggle() }
                .keyboardShortcut(.space, modifiers: [])
        }
        .padding(horizontal: 16, vertical: 8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 8))
    }
}
```

Decode album art once with `JPEG.decode` or `PNG.decode`, not in `body`.
Audio playback comes with PolymerAudio.

### A sheet and a menu

```swift
struct AlbumActions: View {
    @State private var editing = false
    var body: some View {
        Text("Album One")
            .contextMenu {
                Button("Play") { }
                Button("Edit details") { editing = true }
            }
            .sheet(isPresented: $editing) { EditSheet() }
    }
}

struct EditSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Edit details")
            Button("Done") { dismiss() }.keyboardShortcut(.return)
        }
        .padding(16)
    }
}
```

`Menu("More") { ... }` gives a menu from a button. Every component should
have a right-click menu; `.contextMenu` is how. Headlessly:
`polymer describe <screen> --context-click "Album One" --click "Edit details"`.

### Animation

```swift
@Observable final class Panel { var open = false }

struct Drawer: View {
    let panel: Panel
    var body: some View {
        VStack(alignment: .leading) {
            Button(panel.open ? "Hide" : "Show") {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { panel.open.toggle() }
            }
            if panel.open {
                Text("Details").transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}
```

`.animation(.easeOut(duration: 0.2), value: x)` animates when `x`
changes. In a check, set `tree.time` and render again to see the
animation part-way (`tree.time = 0.2`, then `tree.render()`). There are
no timers on hot paths; time is the tree's.

## Status and activity

Two pages are for the owner, who does not read code:

- `Docs/STATUS.md`: what is done, in progress, next, and waiting for
  the owner. It is made from `Docs/status.json`. Edit the JSON, then run
  `polymer status --write`. Never edit STATUS.md by hand; a check fails
  if the two differ. `polymer status` prints it.
- `Docs/ACTIVITY.md`: one plain sentence per piece of work, newest last.
  Add to it only with `polymer log "Added the Albums page header."`
  (name yourself with `--by "ui agent"` or the `POLYMER_AGENT`
  environment variable). `polymer activity` shows the latest entries,
  `polymer activity 50` more, `--all` every one.

Write both for the owner: plain words, what it does for the app, no code
names.
