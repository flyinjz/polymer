# Differences from SwiftUI

Polymer matches SwiftUI names and meaning wherever they match. Every
deliberate difference is listed here, with the reason.

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
| `Button` with a default style | `Button` draws only its label (`PlainButtonStyle`) | The house style comes with PolymerDesign. |
| `ButtonStyle`, `ButtonStyleConfiguration` with `role` | Same, without `role` | `@Environment` and `@State` work inside a style. |
| Pointer events from the system | `ViewTree.pointerMoved(to:)`, `pointerDown(at:)`, `pointerUp(at:)`, `pointerExited()`, `point(ofText:)` | Windows and headless tools drive the same entry points. `.onHover` uses the view's frame. |
| `NSHostingView`, `UIHostingController` | `ViewTree` | The live tree of a root view: `update()`, `render()`, `elementTree`, `click(at:)`, `click(text:)`. Windows and the headless tools drive the same type. `render()` redraws only what changed; `damage` and `displayList` show what it drew. |
| `ImageRenderer` | `ImageRenderer` | Same idea; adds `elementTree`, `proposedSize` as a `ProposedViewSize`, `background`. Gives a `Bitmap`. |
| `@State`, `@Binding`, `@Bindable`, `@Environment`, `@Observable` | Same | Same meaning. `@Observable` is Swift's own macro. |
| Bodies skipped for unchanged views (`Equatable` ones by `==`, others compared field by field) | Only `Equatable` views are skipped; others run whenever their parent runs | No reflection on every update. A change still reaches only the views that read it (observation). Skipped views still get environment changes; their body runs again only if they read `@Environment`. No `EquatableView` or `.equatable()`: conforming is the one way. |
| `ObservableObject`, `@StateObject`, `@ObservedObject`, `@EnvironmentObject` | Not provided | One way to do each thing: `@Observable` classes. |
| `.environment(\.key, value)` | Same | `EnvironmentKey` and `EnvironmentValues` as in SwiftUI. |
| `.accessibilityIdentifier` for UI tests | `.accessibilityIdentifier(_:)` | Shown as `#id` in the element tree; drives `ViewTree.click(id:)`, `point(ofID:)`, `stablePath(ofID:)`, and `--click-id`. Customize builds on the same stable paths. |
| `.opacity(_:)` group compositing | Multiplies opacity of drawn leaves via `DisplayList.withOpacity` | Zero offscreen allocation and zero view re-evaluations while animating. Overlapping siblings inside one `.opacity` blend individually rather than as a flattened group (group layers come later if needed). |
| `Animation` driven by wall-clock frames | `Animation` + `withAnimation` + `.animation(_:value:)` stepped by `ViewTree.tick(_:)` | Deterministic across runs and OSes for headless checks; windows feed display-paced `dt` while `hasActiveAnimations` is true. |
| `Image("name")` from asset catalogs | `Image(RenderImage)` / `Image(Bitmap)` | No asset catalogs or Foundation; images are decoded via `PNG.decode` / `RenderImage.png`. Supports `.resizable()`, `.interpolation(_:)`, `.aspectRatio(_:contentMode:)`. |
| `.background(.ultraThinMaterial)` | `BackdropBlur(radius:)` composed with a tinted `Color` | Explicit dark glass building block; design-system glass tokens come with PolymerDesign. |
| Lines break by Unicode rules | Lines break after spaces and hyphens | Full UAX #14 comes later. |
| `.truncationMode(.head / .middle / .tail)` | Text is always cut at the end | Cut by `lineLimit` or by a height too short for its lines (at least one line is shown, as in SwiftUI). Other modes come when a screen needs them. |
| Buttons focusable only with full keyboard access (macOS) | Buttons always take focus from Tab, never from a click | One behaviour on every OS. Space and Return press a focused button. |
| `.onKeyPress(characters:)`, `.focusSection()`, `.defaultFocus`, `.focusedValue` | Not yet | `.focusable()`, `@FocusState`, `.focused(...)` and `.onKeyPress(_:)`, `(keys:)`, `(phases:)` exist. |
| Focus ring drawn by the system | Drawn via `PolymerDesign` `.focusRing(isFocused:)` using `Theme.focusRing` | Themeable across presets (`Theme.pgr`, `.dark`, `.light`). |
| Keys sent by the system | `ViewTree.key(_:)` with a `KeyPress` or text ("shift+tab") | Windows and headless tools drive the same entry point. |
| `LazyVStack`, `LazyHStack`, `LazyVGrid`, `LazyHGrid` with `pinnedViews` | Same (`GridItem` fixed/flexible/adaptive), without `pinnedViews` | Only a `ForEach` directly inside (through groups and views with a body) is lazy; anything else is built at once. Elements never built count as the average size of those that were, so content length is an estimate until every item has been seen. Pinned headers come later. |
| `TextField` / `TextEditor` backed by `NSTextView` | `TextField` / `TextEditor` backed by `PolymerText.TextBuffer` / `TextEditorState` | Pure-Swift grapheme cursor, directional selection, coalescing undo/redo, IME `MarkedText` composition span, identical across OSes. |
| `DragGesture` via `Gesture` protocol hierarchy | `DragGesture(minimumDistance:)` with `.onChanged` / `.onEnded` via `.gesture(_:)` | Covers scrubbing (`minimumDistance: 0`) and dragging with deterministic pointer routing in `ViewTree`. |
| `.clipShape(_:)` vector mask | Clips `DisplayList` to bounding rect and hit-testing to exact shape geometry | Path-level pixel masking comes with GPU/mask pass; hit testing respects `Circle`, `RoundedRectangle`, `Capsule`, and `Path`. |
| `.contextMenu` native OS menu | `.contextMenu { ... }` opens an overlay via `ViewTree.rightClick` / `secondaryClick` (and `--right-click`) | Deterministic headless inspection and theme-styled `PolymerContextMenu` backed by `PolymerApp.CommandRegistry`. |
| `Commands` / `@AppStorage` | `PolymerApp.CommandRegistry` and deterministic JSON `SettingsStore` | One command registry drives menus, shortcuts, context menus, and `polymer describe`; settings avoid Foundation `UserDefaults`. |
| System themes / dark mode | `PolymerDesign.Theme` (`Theme.pgr`, `.dark`, `.light`, `.with(...)`) + `CustomizeState` | Style-agnostic core with swappable themes, opt-in `DesignLint`, and per-element Customize keyed by `#id` / `Node.stablePath`. |
| Platform accessibility bridge | `ViewTree.accessibilityTree() -> AccessibilityNode` (`toJSON()`, `describeTree()`, `polymer tree --a11y`) | Headless, deterministic accessibility export ready for OS screen-reader bridges. |

## Coordinates

y grows downward, origin top-left, as in SwiftUI. Font outlines are y-up
internally and flipped when drawn.
