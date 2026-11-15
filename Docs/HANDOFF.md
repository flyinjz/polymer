# Handoff

Current state of the work. Every session updates this before it ends.

## State (2026-11-14, Windows session 4)

- Design signed off: `Docs/DESIGN.md`. Differences from SwiftUI:
  `Docs/DIFFERENCES.md`.
- Committed (2026-11-14), not pushed until the owner says so: sessions 1
  to 3, and from session 4 text cut to height, Equatable skipping and the
  display list.
- **Not committed yet** (signing locked again during session 4): the JPEG
  decoder (staged in the index), then the `Image` view, then lazy grids
  with exact layout (both in the working tree). Commit them in that order
  once signing works. If they can't be separated cleanly, commit the JPEG
  decoder from the index, then the rest as one commit.
- Signing needs the owner's passphrase cached on this PC; test
  without opening a prompt:
  `echo x | gpg --pinentry-mode error --clearsign -u 8FDBF5E546CF3D68`.
  If it fails, ask the owner to run (PowerShell)
  `"x" | & "C:\Program Files\GnuPG\bin\gpg.exe" --clearsign -u 8FDBF5E546CF3D68 | Out-Null`.
- Builds with `swift build` (debug and release) on Windows; `polymer check`
  passes (33 checks: base, text, render, ui, effects).

### Done

- `Package.swift`: modules `PolymerBase`, `PolymerPlatform` (+ `…Windows`,
  `…Mac` backends), `PolymerText`, `PolymerRender`, `PolymerUI`, `Polymer`
  (umbrella), `PolymerChecks`, and the `polymer` command (`PolymerTools`).
  Modules are added as they get real code. macOS floor is 15 (see
  "For the owner's review").
- `PolymerBase`: geometry (`Point`, `Size`, `Rect`, `EdgeInsets`,
  `PixelRect`, `AffineTransform`), `Path` with flattening, `Color` with
  exact sRGB transfer and pure-Swift `Math.log/exp` (identical on every
  OS), `StableID`/`StableHasher` (FNV-1a + splitmix, pinned value in a
  check), `Logger`, `ByteReader`, `JSON` (strict parser with line/column
  errors, deterministic output), zlib inflate/deflate, CRC-32, Adler-32.
- `PolymerPlatform`: `FileSystem` and `Process` interfaces, installed by the
  entry point; Windows backend (Win32, UTF-16 paths) and Mac backend
  (POSIX; written but **not yet compiled on a Mac**).
- `PolymerText`:
  - OpenType parser (`FontFace`): table directory and collections, cmap
    4/12, hmtx, `glyf` (simple and composite), CFF with a Type 2
    charstring interpreter (subroutines, flex, CID fonts).
  - Kerning: GPOS pair kerning (formats 1 and 2, extension lookups) with
    legacy `kern` fallback.
  - Substitution (`Substitution.swift`): GSUB single, multiple, ligature,
    context and chaining-context lookups (formats 1 to 3), extension
    lookups; the default features `ccmp locl rlig liga clig calt rclt`.
  - Rasteriser: analytic coverage (signed-area accumulation, curves
    flattened to 0.01 px), outline emboldening.
  - Layout: `TextLayout.line` (shaping, advances, kerning) and
    `TextLayout.lines` (wrapping at spaces and hyphens, explicit line
    breaks, long words broken between characters, `lineLimit` with an
    ellipsis).
  - `GlyphCache`: outlines and coverage masks kept between draws, keyed by
    the exact fractional pixel offset (same pixels cached or not).
- `PolymerRender`: `Bitmap`, PNG decode/encode (our own), `Canvas` (CPU
  reference renderer: rects, paths, glyph runs, rectangular clipping),
  `DisplayList` with damage (session 4; see "Display list and damage"),
  JPEG decoding (session 4): baseline and progressive, any sampling,
  restarts, grey/YCbCr/RGB/CMYK/YCCK; pixels identical to libjpeg-turbo's
  default output (same integer IDCT, fancy upsampling and colour tables),
  checked against `djpeg` decodes in `Tests/Fixtures/Images` (`render.jpeg`).
  About 1.3 ms for a 320x240 progressive file in release (no SIMD yet).
  Not yet: EXIF orientation, decoding at 1/2, 1/4, 1/8 size (libjpeg's
  scaled IDCT, for thumbnails), arithmetic coding, 12-bit. CMYK and YCCK
  follow the Adobe convention (inverted) but have no reference fixture yet.
- `PolymerUI`:
  - `View` (@MainActor, like SwiftUI), `ViewBuilder` (parameter packs,
    if/else, optionals), `Group`, `ForEach` (by `id:` key path,
    `Identifiable`, or an index range), `.id(_:)`.
  - Views: `Text` (wrapping, `lineLimit`, `multilineTextAlignment`, cut
    to the height it is offered with an ellipsis on the last line that fits),
    `Color`, shapes (`Rectangle`, `RoundedRectangle`, `Capsule`, `Circle`,
    custom `Shape`s; `.fill`, `.stroke`, `.strokeBorder`; session 4),
    `Spacer`, `Divider`, `HStack`, `VStack`,
    `ZStack`, `Button`, `ScrollView` (vertical, horizontal or both),
    `Image` (session 4: a `Bitmap` at its own size or `resizable()`; drawn
    through `RasterImage`, which keeps scaled copies so an unchanged image
    is resampled once; Lanczos-3 in premultiplied values, widened when
    shrinking; corners on whole pixels).
  - `LazyVGrid` and `LazyHGrid` (session 4) with `GridItem` `.fixed`,
    `.flexible` and `.adaptive`: built on the lazy stack machinery (the same
    lazy `ForEach`, average-size estimates, viewport tracking through the
    `LazyViewport` protocol); rows are the lazy unit, a row is as tall as its
    tallest cell, cells sit in their slot by `GridItem.alignment` (centre by
    default). Each `ForEach` element is one cell. Column sizes: fixed first,
    the rest shared evenly within each item's bounds, an adaptive item
    fitting as many columns of its minimum as it can (`gridTracks`). Check:
    `ui.grid` (sizes, cell order, 10,000 album cells building only the rows
    in view, state kept across scrolling, partial frames equal whole draws).
  - `LazyVStack` and `LazyHStack` (session 3): a `ForEach` inside builds,
    lays out and draws only the elements in view; see "How lazy stacks
    work" below.
  - Keyboard and focus (session 3): `.focusable()`, `@FocusState` with
    `.focused($b)` and `.focused($v, equals:)`, `.onKeyPress(...)`,
    `KeyEquivalent`, `EventModifiers`, `KeyPress`; `ViewTree.key(_:)`,
    `focusedElement`; see "How focus works" below.
  - Pointer (session 3): `ViewTree.pointerMoved/Down/Up/Exited`; buttons
    run on release over them; `ButtonStyle` with `isPressed` and
    `.buttonStyle(_:)` (`PlainButtonStyle` is the default); `.onHover`.
  - `.disabled(_:)` and `.isEnabled` (session 3): disabled buttons and tap
    handlers do nothing and swallow the press, leave the Tab order, give up
    focus, and show "disabled" in the element tree. Button styles can use
    `@Environment` and `@State` (`LinksNestedProperties`).
  - Modifiers: `padding`, `frame` (fixed and flexible), `aspectRatio`,
    `glassEffect`, `background(_ material:in:)`,
    `scaledToFit`, `scaledToFill`, `background`,
    `overlay`, `border`, `clipped`, `font`, `foregroundStyle`,
    `lineLimit`, `multilineTextAlignment`, `environment(_:_:)`,
    `onTapGesture`.
  - State: `@State`, `@Binding`, `@Bindable`, `@Environment`,
    `EnvironmentKey`, and Swift's `@Observable` classes. A change
    re-evaluates only the views that read the value.
  - `ViewTree`: a live tree of a root view. `update()` re-evaluates
    invalidated views and lays out; `render()` gives a `Bitmap`;
    `elementTree` gives the tree as text; `click(at:)`, `click(text:)`
    and `scroll(at:dx:dy:)` drive input; `onInvalidate` is the hook a
    window uses to schedule a frame; `bodyEvaluations` counts work for
    checks.
  - `ImageRenderer` (SwiftUI's name) for one-shot images and trees.
  - Not yet: scroll bars, animation, element names, pressed looks for
    tap gestures, a focus ring (a PolymerDesign look), scrolling the focused view
    into view.
- `polymer` command: `check [filter] [--list] [--verbose]`,
  `render <screen> <out.png> [--scale N] [--click "text"] [--scroll N]...`,
  `tree <screen> [--click "text"] [--scroll N] [--key K]...` (steps are applied in
  the order given), `zoom <in> <out> x y w h factor`.
  Screens: `albums` (static), `counter` (state and buttons), `list` (a
  scroll view of forty rows), `library` (a lazy stack of 20,000 rows). They live in
  `PolymerChecks/UIChecks.swift`; a real screen registry comes with
  PolymerApp.

### How the view tree works (session 2)

Read this before changing `PolymerUI`.

- **Nodes persist.** Each view resolves to a `Node` (`Node.swift`). When a
  body runs again, `reconcile(view, existing, context)` updates the node
  already in that place if it is the same kind of view, otherwise makes a
  new one and unmounts the old. Built-in views implement
  `PrimitiveView.resolve(existing, context)`; containers call
  `node.setChild(index, view, context)` and `removeChildren(from:)`.
- **Views with a body** get a `HostNode<V>` (`State.swift`). It keeps the
  view's `@State` storage, links `@State`/`@Environment` properties of
  each new view value to it (found with `Mirror`, only for view types that
  have such properties; the answer is cached per type), and evaluates
  `body` inside `withObservationTracking`.
- **Invalidation.** When something a body read changes, its host is put
  on the tree's queue (safe from any thread). `ViewTree.update()` drains
  the queue, evaluates outer hosts first (which brings inner ones up to
  date), then lays out. Several changes before an update are one
  evaluation.
- **No stale registrations.** Swift's Observation has no public way to
  cancel a tracking. Every tracking of a host therefore also reads the
  host's `Epoch`; before each evaluation (and on unmount) the epoch is
  changed, which fires the old trackings and removes them from every
  object they watched. A generation number makes those firings no-ops.
- **Deferred closures.** `ForEach` runs its content closure during
  reconciliation, not inside the enclosing body, so it tracks its reads
  through `context.host?.track`.
- **Identity.** Structural by default. `ForEach` matches children by id
  (duplicate ids log an error that says how to fix it). `if`/`else`
  branches and `.id(_:)` changes start with fresh state.
- **Layout.** `Node.measure(proposal)` remembers answers; `place` skips a
  subtree placed in the same rectangle with no changes below. Children are
  placed in the exact (unrounded) rectangle and each frame is rounded to
  pixels on its own (session 4), so equal views in fractional columns get
  equal sizes, as in SwiftUI; `placedRect` keeps the exact one. A changed
  host invalidates itself and its ancestors only. Stacks lay out the
  flattened list of their content, so groups, `ForEach` and views with a
  body contribute their children directly.
- **Scrolling.** A `ScrollView`'s content keeps the frames it would have
  unscrolled. The offset (whole pixels) is applied when drawing
  (`DisplayList.translated`, inside `.clipped`) and when hit-testing, so
  a scroll step evaluates and lays out nothing. Stacks, text and fills
  skip drawing what is outside the clip. Every row is still built and
  laid out once; lazy stacks are the next step for long lists. The
  element tree and `click(text:)` use on-screen positions
  (`Node.screenFrame`).
- **Element tree.** Views with a body appear by type name
  (`SampleAlbumsView`), built-in elements by role; padding, frames and
  groups are left out. Order is drawing order, back to front.
- **Input.** `hitTest` finds the front-most drawn node; the click goes to
  the nearest enclosing `Button` or tap handler. A `Button` is clickable
  across its whole label area, a tap handler only where something is
  drawn.

### Display list and damage (session 4)

Read this before changing drawing in `PolymerUI` or `PolymerRender`.

- **Nodes record, renderers draw.** `Node.draw(_ list: inout DisplayList)`
  records operations with the calls `Canvas` has (`fill` for rects and
  paths, `drawGlyphs`, `clipped`, `translated`, `isVisible`). Each
  `DisplayItem` keeps its operation in local points plus the origin and
  pixel clip in force, and `bounds`: the pixels it may change (rects and
  paths rounded outward; glyph runs from the font's `head` glyph box plus
  2 pixels for darkening). Items that would draw nothing are left out.
  `Canvas.draw(list, in: region)` replays the items touching a region
  with the very same arithmetic, so a region drawn alone matches the
  whole image there. The GPU renderer will consume the same list.
- **Damage.** `DisplayList.damage(since:)` trims the common start and end,
  then matches the middle items by value in order (greedy, through a
  dictionary); unmatched items damage their bounds, old and new. A pixel
  outside the damage is covered by the same items in the same order in
  both frames, so it can't differ. Rectangles that touch are joined;
  past eight, the pair whose union adds least area is joined.
- **ViewTree.render** records a list each frame (two lists are reused in
  turn, so no allocation once warm), compares it with the last, clears and
  redraws only the damage in the kept canvas, and exposes `damage` and
  `displayList`. A size, scale or background change redraws everything.
  `render()` still converts the whole canvas to a `Bitmap` (headless
  output); a window will present only the damage.
- Known limits: scrolling damages the whole viewport (moving the
  pixels that stay visible comes later); a changed text run damages the
  whole run; the kept CPU canvas is 16 bytes per pixel.
- Checks: `render.display-list` (recording, damage cases, partial equals
  whole), `ui.damage` (an Add click redraws about 4% of the counter image;
  every frame while scrolling the plain and lazy lists equals a whole
  draw; every drawn pixel lies in some item's bounds).

### Effects and materials (session 4)

DESIGN section 11 is the design; this is how the CPU reference does it.

- **Shapes** (`Shapes.swift`): `Shape` with `path(in:)`; `InsettableShape`;
  the built-ins conform to `RoundedRectShape` and give a PolymerBase
  `RoundedRect` (rect, corner radius), which has the path (cubic corners)
  and an exact signed distance and edge normal. Built-ins resolve straight
  to a `ShapeNode` (no host). A plain rectangle fills exactly as `Color`.
  Strokes are rings (outer path plus the inset path reversed, non-zero
  winding), so a 1-point border on a pixel-aligned frame is crisp. Custom
  shapes can be filled, not stroked yet (a warning says so).
- **Backdrop items.** `DisplayList.drawBackdrop(shape, effect)` records a
  `.backdrop` item with `reach` (pixels around a point it reads: 3 sigma of
  blur, plus refraction and 2). `Canvas` can now cover part of an image
  (`Canvas(bounds:)`, pixel origin). On replay the effect copies the pixels
  behind it from the canvas when the region being drawn covers its reach;
  otherwise it draws the items before it again offscreen over just that
  area, so partial and whole draws give identical pixels.
- **Damage.** `DisplayList.spreadThroughEffects`: a damaged rectangle within
  an effect's reach damages the effect's pixels within reach of it,
  repeated (effects over effects).
- **Maths** (`Effects.swift`): separable Gaussian (sigma = radius in
  pixels, 3 sigma, edges repeated) in premultiplied sRGB-encoded values;
  coverage from the distance field (0.5 - d); glass pulls content from
  outside by `refraction * (1 - u)^2` along the normal, u the depth over
  the bezel; bilinear sampling; tint over; rim light from the normal's
  angle to the light, squared, over `rimWidth`; dispersion bends red and
  blue apart. Only basic arithmetic and our `Math`, so pixels are the same
  on every OS.
- **API** (`PolymerUI/Effects.swift`): `Glass` (`.regular`, `.clear`,
  `.identity`, `.tint`), `.glassEffect(_:in:)` (capsule by default),
  `Material` (`.ultraThinMaterial` ... `.ultraThickMaterial`, dark tints),
  `.background(_:in:)`; both are a background layer (`BackdropNode`, shown
  as "Glass" or "Material" in the element tree).
  `EnvironmentValues.accessibilityReduceTransparency` draws opaque fills.
  The default values are placeholders for PolymerDesign tokens (DESIGN 11.8).
- Checks: `effects.shapes` (exact areas, crisp borders, distance field),
  `effects.blur` (flat stays flat, light kept, outside untouched),
  `effects.glass` (rim refraction, untouched middle, rim light, glass over
  a scrolling list redraws partially with identical pixels, reduced
  transparency). `out/checks/effects/glass-showcase@2x.png` shows the look.
- Next: GPU versions, `GlassEffectContainer` (smooth union of distance
  fields), `interactive()`, `.blur(radius:)` on a view's own content (needs
  layers), shadows if the design system wants them, speed (the CPU blur is
  direct; a box-filter approximation or downsampling for large radii).

### Skipping unchanged views (session 4)

- A view type that conforms to `Equatable` is compared with its last value
  when its parent runs again (`HostNode.update`). Equal, not invalidated
  by its own reads (`isDirty`), same environment: its body is not run and
  nothing below it is touched (`reconcile` returns the node without
  invalidating its layout).
- **Environment.** `EnvironmentValues.isSame(as:)` compares every value;
  custom values count as the same when `Equatable` and equal or the same
  class instance, button styles also when of one type with no stored
  properties. Anything else counts as changed (safe: the work is done). When
  only the environment changed, the host hands its last body down again
  with the new values, so text inside picks up a new font, without running
  the body; the body runs only if the view has `@Environment` properties
  (or nests a value that may, `LinksNestedProperties`).
- The last body is kept only for `Equatable` views. Per-type facts
  (properties to link, reads the environment, `Equatable`) are worked out
  once per type (`ViewTypeInfo`).
- With Swift 6 a hand-written `==` on a view must be `nonisolated` (views
  are `@MainActor`), as with SwiftUI.
- Non-`Equatable` views run whenever their parent does (SwiftUI also
  compares those field by field; see DIFFERENCES.md).
- Check: `ui.equatable` (counts with `bodyEvaluations`; after a font and
  line-limit change the tree and pixels equal a tree built anew).

### How lazy stacks work (session 3)

Read this before changing `LazyStacks.swift`.

- **Which ForEach is lazy.** `ResolveContext.lazyItems` is set by a lazy
  stack and passed on only by nodes a stack sees through (groups, views
  with a body, `if`/`else`, `.id`, tap handlers: `childrenAreLazy`); any
  other node clears it in `setChild`. A `ForEach` that sees the flag
  resolves to a `LazyForEachNode` instead of a `ForEachNode`.
- **LazyForEachNode** keeps every element's id, a closure that builds an
  element from the latest view values, and every element built so far.
  Its `children` are only the elements in view, so drawing, hit-testing,
  the element tree and `click(text:)` see only those. Built elements out
  of view are kept (not unmounted), so their state survives scrolling, as
  in SwiftUI; they are updated with new view values when they come back
  into view (a version number says which are current). Memory therefore
  grows with how much has been scrolled through; a recycling `List` can
  come later if that matters.
- **Sizes.** Items get their ideal size along the axis; across it the
  stack fills what it is offered (SwiftUI's lazy stacks do the same), so
  only built elements are measured. An element never measured counts as
  the average of those that were (one is built up front if none was).
  `starts` holds every item's position; it is worked out again (O(items),
  about 20k additions for the library) only when a measured size differs
  from the one used.
- **Placement.** The visible part is the nearest `ScrollNode.viewport`
  (or the whole tree without one), found by walking up. Items in it are
  found by binary search on `starts`, then built and measured; if real
  sizes moved things, that repeats (up to four rounds). When the total
  length differs from what the parent was told, the stack invalidates
  upward and sets `TreeState.layoutRequested`; `ViewTree.layout` then runs
  another pass (up to eight, with an error that says how to fix rows whose
  size never settles).
- **Scrolling.** Lazy stacks register with their scroll view while
  placed. After a scroll the scroll view calls `viewportMoved()`; only
  when other items come into view does the stack ask for placement
  (`setNeedsPlacementUpward`, which keeps every remembered size), so most
  scroll steps still evaluate and lay out nothing. The scroll view now
  clamps its offset before placing its content, because lazy stacks read
  it then.
- Known limits: rows above the view that were estimated move the content
  when they are first measured (no anchoring yet); only the nearest scroll
  view limits what is built; no `pinnedViews`. Check: `ui.lazy` (draws
  pixel-identical to a plain stack, builds about ten rows per ten scrolled,
  jumps to row 20,000 building only the rows there, keeps state, follows
  identity).

### How focus works (session 3)

- **Who can hold focus.** Nodes answer `acceptsFocus`: buttons (`TapNode`
  for `Button`) and `.focusable()` (`FocusableNode`). `TreeState.focused`
  is the focused node (weak). Tab and Shift-Tab, when nothing handled
  them, move through focusable nodes in drawing order (a depth-first walk
  of `children`, so a lazy stack offers only its rows in view), wrapping.
- **Clicks.** `click(at:)` focuses the nearest `focusesOnClick` node:
  `.focusable()` views yes, buttons no (macOS behaviour).
- **Keys.** `ViewTree.key(_:)` calls `handle(_:)` on the focused node and
  then each parent until one returns `.handled`. A focused button handles
  Space and Return. `.onKeyPress` is a `KeyPressNode` (passthrough).
  With nothing focused, only Tab does anything (as in SwiftUI, keys need
  focus).
- **@FocusState** wraps a `@State` (same storage linking). `.focused(...)`
  makes a `FocusBindingNode` that registers with the tree and holds two
  closures: "is the binding set to me" and "set or clear it". Moving focus
  (`TreeState.setFocus`) clears the bindings not around the focused node,
  then sets those around it, so an optional shared by several fields ends
  on the new one. After every evaluation `ViewTree.update` runs
  `syncFocus`: a binding set to its view by code focuses the first
  focusable node inside it; a cleared binding around the focused node
  drops focus; a focused node that left the tree drops focus. Writes made
  there re-evaluate the views that read them (up to four rounds). A
  `FocusBindingNode` that leaves the tree clears its binding on unmount,
  because the node can be freed before the tree looks again.
- Every node now has `isMounted` (false after `unmount`).
- Check: `ui.focus`.

### How pointer states work (session 3)

- `click(at:)` is `pointerMoved` + `pointerDown` + `pointerUp`. Down
  focuses a `focusesOnClick` view and remembers the nearest node with a
  tap action (`pressedNode`). Up runs it only if the pointer is still
  over it: a button's whole label area (`isUnderPointer`, which also
  respects enclosing scroll views and `.clipped()` via `clipsContent`),
  a tap handler only where something is drawn.
- **Button styles.** `TapNode.pressed` is a `StateStorage<Bool>`. With the
  default `PlainButtonStyle` the label is the button's child directly
  (no extra node). Any other style puts a `StyledButtonBody<S>` (a view
  with a body, hidden from the element tree) between them; it reads
  `pressed`, so pressing re-evaluates only that body. The label reaches
  the style as `ButtonStyleConfiguration.Label`, a primitive view that
  reconciles the original label.
- **Hover.** `.onHover` makes a `HoverNode` registered with the tree.
  `TreeState.updateHover` runs on every pointer move, on `pointerExited`,
  and after a scroll moves content under the pointer: exits first, then
  enters. Its area is the view's frame (padding included).
- A style's `@Environment` and `@State` are linked through the body that
  draws it (`StyledButtonBody` conforms to `LinksNestedProperties`).
- Known limit: hover is not recomputed when layout alone moves views.
- Check: `ui.pointer`.

### Text: how close to CoreText

`polymer check text.coretext` renders all 128 reference cases and writes
stacked comparison images (CoreText, ours, 4x difference) and
`report.json` to `out/checks/text/`.

Mean absolute error went 11.6 → 1.22 (session 1) → 1.12 (session 2, with
substitutions); worst image 1.93. The regression bound in the check is
1.2. What was measured (CoreGraphics with font smoothing, macOS):
- Line widths match CoreText exactly once GPOS kern lookups are counted
  once (Inter lists them twice).
- Stem darkening is an outline growth of `ppem * slope` pixels, capped at
  0.6 px, where `slope = 0.0118 + 0.0191 * L` and L is the linear
  luminance of the text colour (light text grows about twice as much as
  dark text). No ppem cut-off up to 72 ppem.
- Growth is the same horizontally and vertically, but vertical growth
  goes upward only: the bottom edge stays put. (Fitted per image: offset
  = half the growth, in every case.)
- Coverage is blended as plain source-over in sRGB-encoded values, as CG
  does.
- CoreText applies contextual alternates by default (Inter raises the
  colon in "3:42"); so do we now.

Next tuning ideas: the remaining difference is mostly inside curves and
counters; try growing by a Minkowski sum with a rectangle instead of the
mitred offset; check against mid-grey text (needs new references, see Mac
side) to confirm the luminance rule between the two measured colours.

### Session 2 review: what was changed and why

- **Text on a transparent canvas came out dark at the edges.** `drawText`
  blended against the un-premultiplied background, which is black where
  nothing is drawn. Text now goes through the same source-over as
  everything else (identical on opaque backgrounds). Check:
  `render.transparent`.
- **Glyph pixels depended on the distance from the origin.** Positions
  were narrowed to Float before subtracting the mask origin. Glyphs are
  now rasterised at the fractional part of their position and the mask
  moved by the whole part. Check: `text.cache`.
- **Every glyph was parsed, flattened and rasterised on every draw.**
  Added `GlyphCache`.
- **Layout measured children over and over** (each stack level asked each
  child three times, so cost grew exponentially with nesting). Sizes are
  now remembered per node.
- **The node tree was rebuilt from scratch for every image**, with no
  place to keep state. Replaced by the retained tree described above.
- `TextRenderingOptions.blend` and `darkening(x:y:)` removed: blending
  was measured to be plain source-over and growth is one number
  (`growth(ppem:luminance:)`). One way to do each thing.
- `ForEach(data, content:)` without ids replaced by SwiftUI's three
  forms. `.environment { }` (a closure) replaced by SwiftUI's
  `.environment(\.keyPath, value)`.
- The element tree lists a background before its content instead of as
  the content's last child.
- Checks run on the main actor (`Check.run` is `@MainActor`).
- `polymer` arguments are parsed properly (options with values).

## Order of work (dependencies, not a schedule)

1. ~~`Package.swift` and `polymer check`.~~ Done.
2. ~~`PolymerBase`.~~ Done (logging is minimal).
3. `PolymerText`: ~~parsing, rasteriser, Mac-style rendering, CoreText
   check, glyph cache, substitutions, line breaking~~ done; still to do:
   GDEF (skipping marks in lookups), CFF2 and variable fonts, colour
   emoji, full Unicode line breaking (UAX #14; today spaces and hyphens),
   font fallback, HarfBuzz behind our interface for complex scripts,
   quantised subpixel positions if the cache needs a higher hit rate.
4. `PolymerRender`: CPU renderer (rects, paths, glyph runs, clipping),
   ~~display list with damage regions~~ (session 4);
   next images, blur, scrolling by moving pixels; then
   `PolymerGPU` (D3D12 here).
5. `PolymerUI`: ~~views, result builders, observation-based state,
   identity, layout, text wrapping, buttons and clicks~~ done; next:
   ~~lazy stacks~~, ~~lazy grids~~, ~~images~~ and ~~keyboard and focus~~
   (done), effects (blur, materials, liquid glass on the CPU: session 4;
   GPU, merging glass, interactive glass and `.blur` on layers to come,
   DESIGN 11.6), `Grid` (not lazy), scroll bars
   and scroll physics, element names (stable paths for
   Customize and for driving input), a focus ring, animation, ~~skipping bodies of unchanged `Equatable`
   views~~, ~~text cut to the height it is given~~ (both done, session 4).
6. `PolymerDesign`: tokens, components, Customize and right-click menus.
7. `PolymerPlatform` window backends: Win32 window, input, DPI, refresh
   pacing, DWM glass. `ViewTree.onInvalidate` is where a window asks for
   a frame.
8. The i2s Albums page on Polymer; then `PolymerAudio`.

## Windows side (where all sessions run)

- Toolchain: Swift 6.4.2 (newer than the 6.2 floor) with VS Build Tools,
  at `%LOCALAPPDATA%\Programs\Swift`. Works for debug and release,
  `InlineArray`, `ContinuousClock`, SIMD, WinSDK, the `@Observable`
  macro, `Synchronization` (`Mutex`, `Atomic`), `Mirror`.
- Toolchain gaps: SwiftPM can't create the `.build/debug` and
  `.build/release` symlinks (no symlink privilege), so products are at
  `.build/out/Products/Debug-windows-x86_64/polymer.exe` (and
  `Release-…`). The WinSDK module prints a harmless `wchar_t` warning.
  `_wfopen` is marked deprecated (we use Win32 `CreateFileW` instead).
  There is no Python on this PC; use the shell or Swift for scripts.
- Quiet run (errors, failed checks and the summary only): `bash Tools/check.sh [debug|release] [filter]`.
- Run checks from the repo root:
  `swift build -c release` then
  `.build/out/Products/Release-windows-x86_64/polymer.exe check`.
  The text check takes about 2 s in release; all checks take about 23 s
  in debug. Both pass (33 checks) as of Windows session 4.

## Mac side (for a later Mac session)

- Compile `PolymerPlatformMac` (written blind) and run `polymer check`.
- `PolymerPlatformMac`, `PolymerGPUMetal`, CoreAudio output.
- Check that headless images match the Windows ones exactly.
- Add reference cases with mid-grey and coloured text, with `liga`/`calt`
  turned off, and with wrapped text (line spacing), to
  `Tools/Reference/coretext_reference.swift`, then regenerate
  `Tests/Reference/Text`.

## Decisions log

- 2026-11-13: name Polymer; public repo without encryption; no number
  targets; no milestones; own text rasteriser instead of FreeType; no
  Foundation; MP3 decoder our own.
- 2026-11-13 (Windows 1): modules enter `Package.swift` only once they have
  code. Platform backends are picked once, in the entry point
  (`Platform.install`); the only `#if os` outside backends is there.
  Checks are our own runner (`polymer check`), not XCTest (which needs
  Foundation). Geometry types are named `Point`/`Size`/`Rect` (listed in
  DIFFERENCES.md). The font face type is `FontFace`, leaving `Font` free
  for the SwiftUI-style font description in PolymerUI. Canvas blends in
  sRGB-encoded values (as CoreGraphics and browsers do), so colours and
  glass match the Mac look; text uses the measured CoreText rule above.
- 2026-11-13 (Windows 1): `View` and `ViewBuilder` are `@MainActor`, as in
  SwiftUI; checks run on the main actor. Shapes take 10x10 points when
  offered no size, Spacer's minimum length and stack spacing default to
  8 points (SwiftUI's values).
- 2026-11-13 (Windows 2): observable state is Swift's own Observation
  library (`@Observable`, `withObservationTracking`), so models are
  written exactly as for SwiftUI. Observation and Synchronization ship
  with the Swift toolchain like the standard library; they are not
  Foundation. `import Polymer` re-exports Observation.
- 2026-11-13 (Windows 2): `@State` and `@Environment` are found with
  `Mirror`, as the only use of reflection: once per view type to learn
  whether it has such properties, then per evaluation only for the types
  that do. DESIGN §5 says "no reflection" about start-up; this is noted
  here because it touches that sentence. The alternative (linking state on
  first read) loses state that a body never reads.
- 2026-11-13 (Windows 2): no body is skipped when its view value is
  unchanged; a parent's evaluation evaluates the views inside it. Fine
  grain comes from observation (a change reaches only the readers).
  (Session 4: `Equatable` views are now skipped; see "Skipping unchanged
  views".)
- 2026-11-13 (Windows 2): text lines are spaced by the line height
  rounded up to whole pixels, each baseline on a pixel row, so wrapped
  lines are evenly spaced at any scale.
- 2026-11-14 (Windows 3): lazy stacks keep built elements (state survives
  scrolling, as in SwiftUI) rather than recycling them; they estimate
  unbuilt rows by the average measured size; they fill the space offered
  across their axis. Laziness is decided while resolving (a context flag)
  rather than by deferring every `ForEach`, so plain stacks behave exactly
  as before.
- 2026-11-14 (Windows 4): effects are ours on every OS (owner's request,
  DESIGN 11 and D12): every effect shape is a rounded rectangle so one
  exact distance field serves coverage, normals and depth; the CPU is the
  reference the GPU will be compared with. SwiftUI's default glass shape
  (capsule) is kept until the design system says otherwise.
- 2026-11-14 (Windows 4): layout passes exact rectangles to children and
  rounds only each node's own frame (it used to lay children out in the
  rounded frame, so a 157.33-point column gave its art 157 or 157.5 points
  by position). Found by the album grid; `ui.grid` now checks it.
- 2026-11-14 (Windows 4): images are resampled with Lanczos-3 (as image
  editors do for quality) in premultiplied sRGB-encoded values, the space
  the canvas blends in; image rectangles snap to whole pixels so a 1:1
  image is drawn exactly. `Math.sin` and `Math.cos` are our own (fdlibm
  kernels) so weights are identical on every OS.
- 2026-11-14 (Windows 4): the JPEG decoder matches libjpeg-turbo bit for
  bit rather than just "closely": the same integer IDCT and upsampling, so
  a check can compare exactly, and album art looks the same as in apps
  built on libjpeg. Test images are synthetic (ffmpeg patterns), encoded
  and decoded with the MSYS2 libjpeg-turbo tools; see the fixtures README.
- 2026-11-14 (Windows 4): views record a display list instead of drawing
  into a canvas; the CPU canvas replays it. One drawing path for the CPU
  reference, damage and the coming GPU renderer. Damage matching is
  greedy rather than a full longest-common-subsequence (linear, and wrong
  only towards drawing more).
- 2026-11-14 (Windows 4): text offered too little height keeps the whole
  lines that fit (never fewer than one) and ends the last in an ellipsis,
  measured against its line height rounded to pixels; `lineLimit` and the
  height together give the smaller count.
- 2026-11-13 (Windows 2): the glyph cache keys on exact fractional
  positions rather than quantised ones, so nothing changes in the
  CoreText comparison. It empties itself when it reaches its limit (no
  LRU yet).

## For the owner's review (design-visible, not blocking)

- `Divider` is 1 point thick and uses a separator colour of white at 14%
  opacity until PolymerDesign tokens exist. On 2x screens that is 2
  physical pixels; say if "1px lines" should mean 1 physical pixel.
- Text frames are rounded up to whole pixels and baselines snapped to the
  pixel grid vertically (glyph positions stay fractional horizontally).
- `Button` has no look of its own yet (it draws its label). Styles can
  now be written with `ButtonStyle` and `isPressed`; the house style
  belongs to PolymerDesign.
- Keyboard focus has no visible ring yet. Buttons take focus from Tab
  (as with macOS full keyboard access, and on Windows) but not from a
  click. The ring's look is a PolymerDesign decision.
- Element names: today input is driven by visible text
  (`--click "Add"`). Stable names and paths for Customize are not
  designed yet; that is a PolymerDesign decision.
- macOS floor is 15, because view invalidation uses `Mutex` and `Atomic`
  from Swift's Synchronization module. If i2s must run on older macOS,
  say so and the lock moves behind the platform layer instead.
- Sample screens: `polymer render albums out.png --scale 2`,
  `polymer render counter out.png --scale 2 --click Add --click Step`,
  `polymer render list out.png --scale 2 --scroll 290 --click "Track 12"`.
