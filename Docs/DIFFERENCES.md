# Differences from SwiftUI

Polymer matches SwiftUI names and meaning wherever they match. Every
deliberate difference is listed here, with the reason.

## Table of Contents

- [Base types](#base-types)
- [Views and state](#views-and-state)
- [Coordinates](#coordinates)
- [Windows and input](#windows-and-input)
- [Design components (PolymerDesign)](#design-components-polymerdesign)

## Base types

| SwiftUI / CoreGraphics | Polymer | Why |
|---|---|---|
| `CGPoint`, `CGSize`, `CGRect`, `CGAffineTransform` | `Point`, `Size`, `Rect`, `AffineTransform` (Double) | No CoreGraphics or Foundation; same fields and meaning (`origin`, `size`, `minX`, `maxY`, `intersection`, `union`, `insetBy` is `inset(by: EdgeInsets)`). |
| `EdgeInsets` | `EdgeInsets` | Same. |
| `Color` | `Color` (sRGB-encoded components plus opacity) | Same meaning; adds `Color(hex:)` and `.linear` for rendering. Apps use design tokens, not raw colours (enforced later by a check). |
| `Path` | `Path` (moves, lines, quad and cubic curves) | Same idea; built with `move(to:)`, `line(to:)`, `quad(to:control:)`, `cubic(to:control1:control2:)`, `close()`. |
| `Hasher` for identity | `StableID` | Swift's hasher is seeded per process; IDs must be identical across runs and OSes. |
| `JSONEncoder` / `JSONDecoder` | `JSON` value type with `parse` and `pretty` | No Foundation. Output is deterministic (sorted keys, shortest numbers). |

## Views and state

| SwiftUI | Polymer | Why |
|---|---|---|
| `Font.system(...)`, `.body`, ... | `Font(face, size:)` with a loaded `FontFace` | No system fonts: apps use the bundled faces. Named styles come with PolymerDesign tokens. |
| `Text` with attributed and localised strings | `Text(String)` | Plain strings for now. |
| `Image("name")`, `Image(systemName:)`, `Image(nsImage:)`, `Image(cgImage:scale:label:)` | `Image(bitmap, scale:)` with a decoded `Bitmap` (`PNG.decode`, `JPEG.decode`) | No asset catalogues or system symbols; icons come with PolymerDesign. `resizable()`, `aspectRatio`, `scaledToFit()`, `scaledToFill()` as in SwiftUI. `.interpolation`, `.renderingMode`, accessibility labels and resizing insets not yet. |
| `Button` with a default style | `Button` draws only its label (`PlainButtonStyle`) | The house style comes with PolymerDesign. |
| `ButtonStyle`, `ButtonStyleConfiguration` with `role` | Same, without `role` | `@Environment` and `@State` work inside a style. |
| Pointer events from the system | `ViewTree.pointerMoved(to:)`, `pointerDown(at:)`, `pointerUp(at:)`, `pointerExited()`, `point(ofText:)` | Windows and headless tools drive the same entry points. `.onHover` uses the view's frame. |
| `NSHostingView`, `UIHostingController` | `ViewTree` | The live tree of a root view: `update()`, `render()`, `record(background:)`, `elementTree`, `click(at:)`, `click(text:)`, `pointerStyle(at:)`. Windows and headless tools drive the same type. `render()` redraws only what changed; `record(background:)` returns `(DisplayList, [PixelRect])` directly for the GPU without CPU rasterization. |
| `ImageRenderer` | `ImageRenderer` | Same idea; adds `elementTree`, `proposedSize` as a `ProposedViewSize`, `background`. Gives a `Bitmap`. |
| `Rectangle`, `RoundedRectangle`, `Capsule`, `Circle`, `Shape`, `InsettableShape` | Same, plus `RoundedRectShape` (the built-ins: they give an exact `RoundedRect`) | Corners are circular only (no `.continuous` style yet). `.stroke` and `.strokeBorder` take a colour and work on the built-in shapes; custom shapes can be filled only. No `Ellipse`, `trim` or `StrokeStyle` yet. |
| `.glassEffect(_:in:)`, `Glass` (`.regular`, `.clear`, `.identity`, `.tint`) | Same; shapes must be `RoundedRectShape` | Drawn by Polymer on every OS (DESIGN 11). `GlassEffectContainer(spacing:)` merges shapes closer than `spacing` (one style per container: the first glass's). `.interactive()` makes the glass and its view swell and brighten on a spring while the pointer is down on it, without taking the click (SwiftUI also lights the glass where it is touched; not here: that would be a painted highlight). `glassEffectID` not yet. The defaults are darker than Apple's (pgr dark glass) until design tokens exist. |
| `.background(.thinMaterial)` and the other materials, `.background(_:in:)` | Same names, as values of `Material` | Blur plus a dark tint, drawn by Polymer. |
| `withAnimation`, `.animation(_:value:)`, `Animation` (`.linear`, `.easeIn`, `.easeOut`, `.easeInOut`, `.spring`, `.default`) | Same | Time is `ViewTree.time`. Frames (so `.offset` too), opacity, `Color` fills, shape fill and stroke colours, text colour and `.scaleEffect` animate. A spring carries its speed into the next change, as in SwiftUI; a timing curve interrupted in mid-flight starts again from where the view is, at rest (SwiftUI adds the curves together). `Animatable` and custom `VectorArithmetic` types, `.repeatForever`, `.delay`, `.speed` not yet. A spring's damping above 1 is treated as 1. |
| `.transition(_:)`, `AnyTransition` (`.identity`, `.opacity`, `.move(edge:)`, `.offset`, `.scale`, `.slide`, `.push(from:)`, `.asymmetric`, `.combined(with:)`), `Edge` | Same | A view without `.transition` fades, as in SwiftUI. A removed view keeps drawing where it was until its transition ends; it takes no space, can't be clicked and shows as "leaving" in the element tree. Rows a lazy stack builds while scrolling never transition. `.blurReplace`, `.symbolEffect`, custom `Transition` types not yet. |
| `.scaleEffect(_:anchor:)`, `UnitPoint` | Same, uniform scale only | Changes drawing and clicks, not layout or the element tree frame (as in SwiftUI). Text is drawn from its outlines at the new size. `.scaleEffect(x:y:)` not yet. |
| `.offset(x:y:)` | Same | Moves drawing, hit testing and the element tree frame; not the layout around it. |
| `.opacity`, `.clipShape`, `.blur(radius:)` | Same; `clipShape` takes a `RoundedRectShape` | Drawn as layers (offscreen, then composited). `.compositingGroup`, `.mask` and `.drawingGroup` not yet. |
| `accessibilityReduceTransparency` (read-only, set by the system) | Settable in `EnvironmentValues` | The platform layer (and checks) set it; glass and materials then draw opaque. |
| `@State`, `@Binding`, `@Bindable`, `@Environment`, `@Observable` | Same | Same meaning. `@Observable` is Swift's own macro. |
| Bodies skipped for unchanged views (`Equatable` ones by `==`, others compared field by field) | Only `Equatable` views are skipped; others run whenever their parent runs | No reflection on every update. A change still reaches only the views that read it (observation). Skipped views still get environment changes; their body runs again only if they read `@Environment`. No `EquatableView` or `.equatable()`: conforming is the one way. |
| `ObservableObject`, `@StateObject`, `@ObservedObject`, `@EnvironmentObject` | Not provided | One way to do each thing: `@Observable` classes. |
| `.environment(\.key, value)` | Same | `EnvironmentKey` and `EnvironmentValues` as in SwiftUI. |
| `.accessibilityLabel`, `.accessibilityValue`, `.accessibilityHint`, `.accessibilityHidden`, `.accessibilityAddTraits`, `.accessibilityElement(children:)`, `AccessibilityTraits` (`.isButton`, `.isHeader`, `.isSelected`, `.isImage`, `.isStaticText`, `.isLink`) | Same | The tree is built when asked for (`ViewTree.accessibilityTree`, `accessibilityDescription`, `accessibilityPress(label:)`), not kept in the background. Roles come from the views: text, buttons (their text combined into the label), images (no label: listed without one), scroll views, focusable views. `.accessibilityAction`, `.accessibilitySortPriority`, rotors and custom content not yet; handing the tree to UI Automation and NSAccessibility comes with the window backends. |
| `Menu`, `.contextMenu`, `.popover(isPresented:)`, `.sheet(isPresented:)`, `.keyboardShortcut(_:modifiers:)`, `@Environment(\.dismiss)` | Same, drawn by Polymer in the window | Menus, popovers and sheets are panels above the root view (the look is a placeholder until PolymerDesign: a dark panel with a 1-point line). Menu items are ordinary `Button`s; disabled ones are dimmed and skipped by the arrow keys; Right and Left open and close submenus. A click outside a menu or popover closes it and goes no further; nothing behind a sheet takes input, and Tab stays inside it. Escape closes menus and popovers, not sheets. Shortcuts run when nothing focused used the key, from the front-most sheet or else the whole root view (items of a closed menu are not reachable). Right-click is `ViewTree.contextClick(at:)`; a context menu opens when the button is pressed, not released, on every OS (as on macOS; Windows usually opens on release). No popover arrow, `.presentationDetents`, `.confirmationDialog`, `.alert`, `Picker` or `Toggle` in menus yet. |
| `.accessibilityIdentifier` for UI tests | `.element("name")` from PolymerDesign (see "Design components") | Input is still driven mostly by visible text; element names do not yet show in `elementTree`. |
| `TextField(_:text:)`, `TextEditor(text:)`, `.onSubmit` | Same, without `prompt:`, `axis:`, formatters or `.textFieldStyle` | A plain field (no border: the house style comes with PolymerDesign). Keys: arrows, Home and End, Shift to select; Option or Ctrl with arrows and Backspace for words; Cmd with arrows and Backspace for line ends; Cmd or Ctrl with A, C, X, V, Z (Shift for redo), and Ctrl-Y. Each does the same on every OS. One, two and three clicks place the caret, select a word, select all; a drag selects. Undo is per field (a run of typing is one step) and is cleared when the text changes from outside. Newlines pasted into a `TextField` become spaces. The caret does not blink yet. |
| `NSPasteboard` / the system clipboard | `Clipboard` protocol in PolymerPlatform, `ViewTree.clipboard` (a `MemoryClipboard` unless a window installs the system one; on Windows `Win32Clipboard`) | Headless trees never touch the real clipboard. The interface sits with the other platform services so every backend provides it the same way. |
| `.padding(.horizontal, 12)`, `.padding(.vertical, 4)` (`Edge.Set`) | `.padding(horizontal:vertical:)`, plus `.padding(_:)` with a length or `EdgeInsets` | One call for both axes; no `Edge.Set` yet. |
| `NSTextInputClient` (input methods) | `ViewTree.insertText`, `setMarkedText(_:selectedRange:)`, `unmarkText`, `markedTextRange`, `selectedTextRange`, `firstRect(forCharacterRange:)`, `acceptsTextInput`, `type(_:)` | Ranges are in characters (grapheme clusters); the platform layer converts to UTF-16. Marked text is underlined. |
| Lines break by Unicode rules | `UnicodeLineBreak` (UAX #14) in `PolymerText` | Shared pure-Swift line breaking with fallback chains, GDEF, variable fonts, COLR/CPAL emoji, and configurable `GlyphCache.subpixelSteps` (default `0` exact; `4` for 1/4-px caching). |
| `.truncationMode(.head / .middle / .tail)` | Text is always cut at the end | Cut by `lineLimit` or by a height too short for its lines (at least one line is shown, as in SwiftUI). Other modes come when a screen needs them. |
| Buttons focusable only with full keyboard access (macOS) | Buttons always take focus from Tab, never from a click | One behaviour on every OS. Space and Return press a focused button. |
| `.onKeyPress(characters:)`, `.focusSection()`, `.defaultFocus`, `.focusedValue` | Not yet | `.focusable()`, `@FocusState`, `.focused(...)` and `.onKeyPress(_:)`, `(keys:)`, `(phases:)` exist. |
| Focus ring drawn by the system | No ring yet | Its look comes with PolymerDesign. |
| Keys sent by the system | `ViewTree.key(_:)` with a `KeyPress` or text ("shift+tab") | Windows and headless tools drive the same entry point. |
| `LazyVGrid`, `LazyHGrid`, `GridItem` | Same, without `pinnedViews` | Each `ForEach` element is one cell (SwiftUI gives each view inside an element its own cell). Column sizes follow SwiftUI's rules as observed (fixed first, the rest shared evenly within bounds, adaptive fitting as many as it can); exact fractional splits may differ slightly. |
| `Grid`, `GridRow`, `.gridCellColumns(_:)` | Same | Columns are as wide as their widest cell; offered a width, columns share it as a stack's children do (least flexible first). A view outside any `GridRow` is a row across every column. `GridRow` shows in the element tree. `.gridColumnAlignment`, `.gridCellAnchor`, `.gridCellUnsizedAxes` not yet. |
| `GeometryReader`, `GeometryProxy` (`size`, `frame(in:)`) | Same, with `.local` and `.global` only | The content is built while laying out, when the size is known, and built again only when the size, the position or what it reads changes. `safeAreaInsets` and named coordinate spaces not yet. |
| `DragGesture` with `onChanged`/`onEnded`, `.gesture(_:)`, `DragGesture.Value` | Same; `translation`, `velocity`, `predictedEndTranslation` are `Size` | A drag starts after `minimumDistance` points (10 by default) and then takes the press: a button under it does not run. Velocity is measured over the last tenth of a second; the predicted end is half a second further at that speed. Only what the view draws starts a drag. `@GestureState`, `.simultaneousGesture`, `.highPriorityGesture`, `TapGesture`, `LongPressGesture`, `MagnifyGesture` and `.updating` not yet. `ViewTree.drag(from:to:steps:)` drives one headlessly. |
| `LazyVStack`, `LazyHStack` with `pinnedViews` | Same, without `pinnedViews` | Only a `ForEach` directly inside (through groups and views with a body) is lazy; anything else in the stack is built at once. Elements never built count as the average size of those that were, so the content length is an estimate until every row has been seen. Pinned headers come later. |

## Coordinates

y grows downward, origin top-left, as in SwiftUI. Font outlines are y-up
internally and flipped when drawn.

## Windows and input

| SwiftUI / AppKit | Polymer | Why |
|---|---|---|
| `NSWindow`, `WindowGroup` | `PlatformWindow` from `Platform.windows`, with `WindowHost` putting a `ViewTree` in it | Scenes come with PolymerApp; until then a host joins a tree, a window and the GPU. |
| `EventModifiers.command` (⌘) | On Windows, Ctrl gives `.command` and the Windows key `.control` | A shortcut means the same on both OSes: Ctrl-C on Windows is ⌘C on the Mac. |
| Wheel scrolling | 40 points per wheel notch on Windows | A placeholder for a design token; trackpads send exact distances. |
| `NSEvent.clickCount` | `WindowEvent` pointer presses carry `clickCount:`, passed to `ViewTree.pointerDown(at:clickCount:)` | The backend counts clicks with the system's double-click time and distance; headless callers pass the count themselves. |
| `NSTextInputClient` calls (`insertText`, `setMarkedText`) | `WindowEvent.text` and `.markedText` | The window turns typed and composed text (IME on Windows through Imm32) into events; the host feeds them to the tree. While a text input is focused, key presses that type text are dropped and the text arrives as `.text`, so nothing is typed twice. |

## Design components (PolymerDesign)

| SwiftUI | Polymer | Why |
|---|---|---|
| `Button`, `Toggle`, `Slider`, `ProgressView`, `Picker` (segmented and menu), `List` rows, `Section` headers, `NavigationSplitView`, `.toolbar`, `TextField`, `.help` tooltips, scroll indicators | `PButton`, `PToggle`, `PSlider`, `PProgressBar`, `PSegmentedControl`, `PPicker`, `PListRow`, `PSectionHeader`, `PSidebarLayout`, `PToolbar`, `PTextField`, `PPanel`, a tooltip, `PScrollBar` | The pgr look is built in (from `Theme` tokens), with the right-click menu and Customize on every one. The `P` prefix keeps them apart from the plain PolymerUI views of the same name, which stay unstyled. Catalogue: `Docs/COMPONENTS.md`. |
| `ScrollViewReader`, `ScrollViewProxy` | Same, plus live binding to `PScrollBar(proxy)` | `.id(...)` passthrough wrappers resolve to their laid-out child frame for `scrollTo(_:anchor:)`. |
| `.onDisappear`, `.allowsHitTesting`, `.pointerStyle` | Same (`PointerStyle` + `ViewTree.pointerStyle(at:)`) | `.onDisappear` fires synchronously when a node unmounts (used by `.commands` to unregister). |
| `.contextMenu`, `.commands` on a scene, menu bar commands | `.commands { ... }` (or `.commands([Command])`) on any view, with a `CommandRegistry` | One command system for right-click menus, shortcuts and the menu bar (DESIGN 7). Commands added to a view appear after each component's own commands inside it, run through the registry, and automatically unregister when their view unmounts. |
| `.accessibilityIdentifier` | `.element("name")` | Names a group so components inside get stable paths ("sidebar/library") for Customize and for driving input. |
