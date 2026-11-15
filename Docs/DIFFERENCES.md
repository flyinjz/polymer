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
| `Image("name")`, `Image(systemName:)`, `Image(nsImage:)`, `Image(cgImage:scale:label:)` | `Image(bitmap, scale:)` with a decoded `Bitmap` (`PNG.decode`, `JPEG.decode`) | No asset catalogues or system symbols; icons come with PolymerDesign. `resizable()`, `aspectRatio`, `scaledToFit()`, `scaledToFill()` as in SwiftUI. `.interpolation`, `.renderingMode`, accessibility labels and resizing insets not yet. |
| `Button` with a default style | `Button` draws only its label (`PlainButtonStyle`) | The house style comes with PolymerDesign. |
| `ButtonStyle`, `ButtonStyleConfiguration` with `role` | Same, without `role` | `@Environment` and `@State` work inside a style. |
| Pointer events from the system | `ViewTree.pointerMoved(to:)`, `pointerDown(at:)`, `pointerUp(at:)`, `pointerExited()`, `point(ofText:)` | Windows and headless tools drive the same entry points. `.onHover` uses the view's frame. |
| `NSHostingView`, `UIHostingController` | `ViewTree` | The live tree of a root view: `update()`, `render()`, `elementTree`, `click(at:)`, `click(text:)`. Windows and the headless tools drive the same type. `render()` redraws only what changed; `damage` and `displayList` show what it drew. |
| `ImageRenderer` | `ImageRenderer` | Same idea; adds `elementTree`, `proposedSize` as a `ProposedViewSize`, `background`. Gives a `Bitmap`. |
| `Rectangle`, `RoundedRectangle`, `Capsule`, `Circle`, `Shape`, `InsettableShape` | Same, plus `RoundedRectShape` (the built-ins: they give an exact `RoundedRect`) | Corners are circular only (no `.continuous` style yet). `.stroke` and `.strokeBorder` take a colour and work on the built-in shapes; custom shapes can be filled only. No `Ellipse`, `trim` or `StrokeStyle` yet. |
| `.glassEffect(_:in:)`, `Glass` (`.regular`, `.clear`, `.identity`, `.tint`) | Same; shapes must be `RoundedRectShape` | Drawn by Polymer on every OS (DESIGN 11). `GlassEffectContainer(spacing:)` merges shapes closer than `spacing` (one style per container: the first glass's). `.interactive()` and `glassEffectID` not yet. The defaults are darker than Apple's (pgr dark glass) until design tokens exist. |
| `.background(.thinMaterial)` and the other materials, `.background(_:in:)` | Same names, as values of `Material` | Blur plus a dark tint, drawn by Polymer. |
| `.offset(x:y:)` | Same | Moves drawing, hit testing and the element tree frame; not the layout around it. |
| `.opacity`, `.clipShape`, `.blur(radius:)` | Same; `clipShape` takes a `RoundedRectShape` | Drawn as layers (offscreen, then composited). `.compositingGroup`, `.mask` and `.drawingGroup` not yet. |
| `accessibilityReduceTransparency` (read-only, set by the system) | Settable in `EnvironmentValues` | The platform layer (and checks) set it; glass and materials then draw opaque. |
| `@State`, `@Binding`, `@Bindable`, `@Environment`, `@Observable` | Same | Same meaning. `@Observable` is Swift's own macro. |
| Bodies skipped for unchanged views (`Equatable` ones by `==`, others compared field by field) | Only `Equatable` views are skipped; others run whenever their parent runs | No reflection on every update. A change still reaches only the views that read it (observation). Skipped views still get environment changes; their body runs again only if they read `@Environment`. No `EquatableView` or `.equatable()`: conforming is the one way. |
| `ObservableObject`, `@StateObject`, `@ObservedObject`, `@EnvironmentObject` | Not provided | One way to do each thing: `@Observable` classes. |
| `.environment(\.key, value)` | Same | `EnvironmentKey` and `EnvironmentValues` as in SwiftUI. |
| `.accessibilityIdentifier` for UI tests | Not yet | Input is driven by visible text today; names come with PolymerDesign. |
| Lines break by Unicode rules | Lines break after spaces and hyphens | Full UAX #14 comes later. |
| `.truncationMode(.head / .middle / .tail)` | Text is always cut at the end | Cut by `lineLimit` or by a height too short for its lines (at least one line is shown, as in SwiftUI). Other modes come when a screen needs them. |
| Buttons focusable only with full keyboard access (macOS) | Buttons always take focus from Tab, never from a click | One behaviour on every OS. Space and Return press a focused button. |
| `.onKeyPress(characters:)`, `.focusSection()`, `.defaultFocus`, `.focusedValue` | Not yet | `.focusable()`, `@FocusState`, `.focused(...)` and `.onKeyPress(_:)`, `(keys:)`, `(phases:)` exist. |
| Focus ring drawn by the system | No ring yet | Its look comes with PolymerDesign. |
| Keys sent by the system | `ViewTree.key(_:)` with a `KeyPress` or text ("shift+tab") | Windows and headless tools drive the same entry point. |
| `LazyVGrid`, `LazyHGrid`, `GridItem` | Same, without `pinnedViews` | Each `ForEach` element is one cell (SwiftUI gives each view inside an element its own cell). Column sizes follow SwiftUI's rules as observed (fixed first, the rest shared evenly within bounds, adaptive fitting as many as it can); exact fractional splits may differ slightly. `Grid` and `GridRow` (not lazy) not yet. |
| `LazyVStack`, `LazyHStack` with `pinnedViews` | Same, without `pinnedViews` | Only a `ForEach` directly inside (through groups and views with a body) is lazy; anything else in the stack is built at once. Elements never built count as the average size of those that were, so the content length is an estimate until every row has been seen. Pinned headers come later. |

## Coordinates

y grows downward, origin top-left, as in SwiftUI. Font outlines are y-up
internally and flipped when drawn.
