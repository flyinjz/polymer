# Handoff

Current state of the work. Every session updates this before it ends.

## State (2026-11-14, Windows session 4)

- Design signed off: `Docs/DESIGN.md`. Differences from SwiftUI:
  `Docs/DIFFERENCES.md`.
- Committed, not pushed until the owner says so: sessions 1 to 4. The
  session 4 backlog (JPEG, Image, grids, DESIGN 11, shapes and effects,
  layers, glass container, glass sample, animation) was committed as
  separate signed commits at the start of session 5.
- Session 5 runs two agents at once (A: rendering and platform, B:
  PolymerUI), coordinating in `out/coordination.md` (not committed).
  `BUILD_DIR=.build-b bash Tools/check.sh` builds in another folder.
- Signing needs the owner's passphrase cached on this PC; test
  without opening a prompt:
  `echo x | gpg --pinentry-mode error --clearsign -u 8FDBF5E546CF3D68`.
  If it fails, ask the owner to run (PowerShell)
  `"x" | & "C:\Program Files\GnuPG\bin\gpg.exe" --clearsign -u 8FDBF5E546CF3D68 | Out-Null`.
- Builds with `swift build` (debug and release) on Windows; `polymer check`
  passes (36 checks: base, text, render, ui, effects).

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
- Windows (session 5): `PlatformWindow`, `WindowEvent` and `WindowSystem` in
  `PolymerPlatform`; the Win32 backend (`Win32Window.swift`); `PolymerApp`
  with `WindowHost`; `polymer demo [screen]`. See "Windows" below.
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
  Session 5: `JPEG.decode(data, scale: .half/.quarter/.eighth)` uses libjpeg's
  reduced IDCTs and per-component sizes, identical to `djpeg -scale` (check
  `render.jpeg-scaled`; no fancy upsampling at 1/8, as in turbo); EXIF
  orientation is applied by default (`JPEG.orientation(of:)`,
  `Bitmap.applyingOrientation`); `JPEG.scale(imageWidth:imageHeight:covering:)`
  picks the reduction for a thumbnail. The "Not yet" below is now arithmetic
  coding and 12-bit only.
  Not yet: EXIF orientation, decoding at 1/2, 1/4, 1/8 size (libjpeg's
  scaled IDCT, for thumbnails), arithmetic coding, 12-bit. CMYK and YCCK
  follow the Adobe convention (inverted) but have no reference fixture yet.
- `PolymerGPU` (session 5): the GPU renderer, shared, and `PolymerGPUD3D12`
  (Direct3D 12, offscreen, hardware or WARP). Draws display lists to match
  the CPU canvas within 1/255; see "GPU renderer" below.
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
  - `Grid`, `GridRow`, `.gridCellColumns` (Agent B, session 5;
    `Grid.swift`): not lazy. Rows are the grid's flattened content; a
    `GridRowNode`'s flattened content are its cells (a `GridSpanNode` says
    how many columns one spans). Column widths: unoffered, the widest
    single-column cell; offered a width, the stack rule (columns sorted by
    flexibility, each measured at an even share of what is left, a column's
    width being its widest cell at that width); spanning cells then widen
    their columns evenly if they need more. Rows the same way vertically.
    Cells sit in their slot by the grid's alignment (a row's own vertical
    alignment wins). Check: `ui.grid-plain` (positions, spans, a row across
    the grid, flexible columns, same pixels as cells placed by hand).
  - `GeometryReader` (Agent B, session 5; `GeometryReader.swift`): takes
    the proposal (10x10 when none); the content closure runs during
    `placeChildren` with a `GeometryProxy` (size, global frame) whenever the
    proxy differs from the last one, and at resolve time with the last
    proxy (tracked through the host, like `ForEach`). Check: `ui.geometry`.
  - `DragGesture` (Agent B, session 5; `Gestures.swift`): `.gesture(_:)`
    makes a `DragGestureNode` (pass-through). `pointerDown` remembers the
    nearest enabled one above the hit node; `pointerMoved` feeds it; once
    it has moved `minimumDistance` it calls `onChanged` and the press is
    cancelled (`cancelPress`); `pointerUp` calls `onEnded` and no tap runs.
    Locations are in the view's coordinates (`screenFrame` origin) or
    global. Velocity from the samples of the last 0.1 s of `ViewTree.time`.
    `ViewTree.drag(from:to:steps:)` for headless use (a `--drag` option for
    the `polymer` command is for whoever next edits PolymerTools). Check:
    `ui.drag`.
  - Accessibility tree (Agent B, session 5; `Accessibility.swift`, DESIGN
    D11): `ViewTree.accessibilityTree` (an `AccessibilityElement`: role,
    label, value, hint, traits, screen frame, enabled, focused, children),
    `accessibilityDescription` (as text) and `accessibilityPress(label:)`.
    Built on request by walking the nodes (`Node.accessibilityElements`), so
    it costs nothing until asked; leaving views and lazy rows out of view
    are not in it. Roles from `ownAccessibility`: `TextNode` text, button
    `TapNode` (children combined into its label with ", "), `ImageNode`,
    `ScrollNode` (contains), `FocusableNode` (combines). Modifiers are
    `AccessibilityNode` pass-throughs collected on the way down (the one
    nearest the view wins); on a node that is not an element they apply to
    the elements inside. Check: `ui.accessibility`. Next: hand it to UI
    Automation / NSAccessibility (window backends), text fields as
    editable text, a `--a11y` option for `polymer tree` (PolymerTools).
  - `TextField`, `TextEditor` (Agent B, session 5; `TextField.swift`,
    `TextEditing.swift`): one `TextInputNode` (focusable, takes focus on
    click) over a `TextEditing` value (characters, anchor and head, marked
    range, undo and redo stacks; a run of typing or deleting is one undo
    step). Layout: a paragraph per line break; each paragraph's glyphs come
    from `TextLayout.line` (clusters kept) and an editor wraps them with
    `TextInputNode.wrap`, the same rule as `Text` (PolymerText's wrapped
    lines drop clusters; if it ever exposes break ranges, use those).
    `EditorLine.carets` gives the x before each character (ligatures split
    evenly). A field scrolls sideways and an editor down to keep the caret
    in view. The binding is read through the host's tracking (it is read
    while resolving, not in the body) and written after each edit. Keys:
    see DIFFERENCES. Pointer: `ViewTree.pointerDown(at:clickCount:)` gives
    the press to the text field under it (caret, word, all) and
    `pointerMoved` extends the selection. Input methods:
    `ViewTree.setMarkedText` and friends (characters, not UTF-16). The
    clipboard is `ViewTree.clipboard` (`Clipboard`, `MemoryClipboard`, in
    PolymerUI until Agent A agrees to move it to PolymerPlatform, and
    `TextEditing` to PolymerText). The look (1-point caret that doesn't
    blink, selection in the text colour at 25%, placeholder at 40%) is a
    placeholder (`TextInputLook`). Check: `ui.text-input` (typing, moving,
    words, selection, clipboard, undo and redo, deleting, submit, clicks,
    double and triple clicks, drag selection, scrolling a long line, marked
    text and its rectangle, the editor's lines, wrapping, a disabled field,
    accessibility, partial frames equal whole draws);
    `out/checks/ui/text-input@2x.png` shows the look.
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
    `glassEffect`, `background(_ material:in:)`, `opacity`, `clipShape`,
    `blur(radius:)` (layers, session 4), `offset(x:y:)`,
    `GlassEffectContainer` (session 4), `animation(_:value:)` and
    `withAnimation` (session 4; see "Animation"), `.transition(_:)` and
    `.scaleEffect(_:anchor:)` (Agent B, session 5),
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
  - Not yet: scroll bars, element names, pressed looks for
    tap gestures, a focus ring (a PolymerDesign look), scrolling the focused view
    into view.
- `polymer` command: `check [filter] [--list] [--verbose]`,
  `render <screen> <out.png> [--scale N] [--click "text"] [--scroll N]...`,
  `tree <screen> [--click "text"] [--scroll N] [--key K]...` (steps are applied in
  the order given), `zoom <in> <out> x y w h factor`.
  Screens: `albums` (static), `counter` (state and buttons), `list` (a
  scroll view of forty rows), `library` (a lazy stack of 20,000 rows), `glass`
  (session 4: an album grid under glass bars and a material panel; try
  `polymer render glass out.png --scale 2 --scroll 140`). They live in
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
- **Scaling** (session 5): `DisplayList.scaled(by:about:)` records its body
  scaled about an anchor at recording time (`zoom`): rects, images, paths,
  glyph runs (drawn at the new size from outlines, so text stays sharp),
  layer areas, masks and blur, backdrop shapes and glass distances. Items
  keep their usual form, so renderers and damage need nothing new. Check:
  `render.scaled`.
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
- **Layers.** `DisplayList.layer(effect, area:) { ... }` records
  `beginLayer(LayerEffect)` ... `endLayer` (opacity, a `RoundedRect` mask,
  blur). On replay the layer's items are drawn offscreen over the part
  being drawn plus the blur's reach (transparent background), blurred,
  masked by the distance field and composited with the opacity, so group
  opacity is right (overlaps don't show through). A backdrop inside a
  layer sees only the layer's own content so far (`from`). A blurred layer
  has `reach`, so damage spreads through it like an effect. `.opacity(0)`
  records nothing and isn't clickable; `.clipShape` clicks miss outside the
  shape. Check: `effects.layers`.
- **Merging glass.** `GlassEffectContainer(spacing:)` puts a weak reference
  to itself in the environment; glass views inside skip drawing and the
  container records one backdrop with `BackdropShape.union` (a polynomial
  smooth minimum of the shapes' distances, k = spacing) behind its content,
  in the first glass's style. A merged outline's normal is a central
  difference over a quarter of the bezel, and refraction fades where that
  gradient is weak (the midline of a narrow neck), which removes the crease
  a sharp normal leaves at joins. Check: `effects.glass-container`.
- **Interactive glass** (Agent B, session 5; `InteractiveGlass.swift`):
  `Glass.interactive()`. `.glassEffect` wraps its view in an
  `InteractiveGlassNode` (a plain pass-through when not interactive). The
  tree keeps a list of them; `pointerDown` presses those whose glass shape
  is under the pointer (without taking the click), `pointerUp` releases
  all. The press is a spring (`InteractiveGlassLook`: 0.3 s, damping 0.6)
  from 0 to 1: the view and its glass are drawn scaled about their centre
  so the longer side grows 4 points, and the tint moves 12% toward white.
  Inside a `GlassEffectContainer` the container scales that shape and tint
  itself. The element tree shows "interactive" and "pressed". The amounts
  are placeholders for design tokens. Check: `effects.glass-interactive`
  (alone and in a container: press off the glass does nothing, growth and
  brightening on the way, 84x42 held, the button still runs, back to rest;
  partial frames equal whole draws).
- Next: GPU versions, glass with different styles in one container
  (today the first one's style is used),
  shadows if the design system wants them, speed (the CPU blur is
  direct; a box-filter approximation or downsampling for large radii).

### GPU renderer (session 5)

- **Shape.** `PolymerGPU/GPU.swift` is the whole backend interface:
  `GPUBackend` makes textures (`rgba16Float` targets, `rgba8` images, `r8`
  masks), runs a `GPUBatch` and reads a target back. A batch is uploads,
  then commands in order: clear, copy, draw. Every draw is instanced quads
  (`GPUInstance`, six float4s) with one of six programs (`GPUProgram`: rect
  coverage, atlas mask, image, one blur pass, backdrop, layer composite).
  The entry point installs the backend (`GPU.install(D3D12Backend.make)`),
  as with `Platform.install`. Metal will implement the same protocol.
- **GPURenderer** (shared) walks the display list exactly as
  `Canvas.draw(_:in:range:)`: the same clips, the same offscreen areas for
  layers and backdrops (copied from the target when the region covers the
  reach, else the items before drawn again), the same blur weights
  (`Blur.kernel`), glyph and path coverage from our rasteriser packed into a
  2048x2048 r8 atlas (emptied when full), images resampled on the CPU by
  `RasterImage` and kept as textures (dropped after 120 unused frames).
  Scratch targets come from a pool. Consecutive quads with the same program,
  target, clip and texture are one draw. `draw(list, into:, regions:)` clears
  and draws only the damage.
- **D3D12 backend.** HLSL in `Shaders.swift` (the CPU maths, compiled at
  start with D3DCompile, IEEE strict); one root signature (8 constants,
  instances and data as root SRVs, one texture table); premultiplied
  source-over, dual-source blending for backdrops (colour times coverage
  plus target times one minus coverage); textures track their state for
  barriers. Each `execute` submits and waits (simple and safe; frames in
  flight come with the window). Never opens a window.
- **Check** `render.gpu`: a scene with everything (fractional rects, a path,
  text, an image, opacity/mask/blur layers, material, glass, merged glass
  with dispersion, a backdrop in a layer) and the glass sample screen, on
  the system GPU and on WARP, against the CPU: tolerance in `GPUTolerance`
  (mean 0.1, 0.1% of values over 2, max 4; measured max 1, mean 0.035).
  A redraw of only the damage equals a whole draw. Images:
  `out/checks/gpu/` (CPU, GPU, difference x8).
- **Speed** (release, RTX 5070): the test scene (480x320) 1.9 ms per frame
  including CPU encoding, submit and wait; WARP about 50 ms.
- **Large blurs** (session 5): above sigma 4 px, `Blur.apply` averages f x f
  cells (f = 2, 4 or 8) on a grid aligned to image pixels, blurs them with a
  Gaussian of sqrt(sigma^2 - f^2/4)/f and interpolates back (bilinear); the GPU
  does the same (`.downsample`, `.upsample`). `Blur.reach` grows to
  (taps + 2) * f, so a part drawn alone still equals the whole. CPU, 512x384:
  sigma 16 px 73 -> 3.5 ms, sigma 40 px 200 -> 4 ms, mean difference from the
  Gaussian at most 0.002 (check `render.blur`). GPU test scene 1.9 -> 0.22 ms.
- Next: frames in flight (no wait per batch), compiled shaders cached,
  glyph masks of the same glyph at
  nearby fractions shared if the atlas churns, the Metal backend.

### Windows (session 5)

- **Interface** (`PolymerPlatform/Window.swift`): a `WindowSystem` makes
  windows and runs the loop; a `PlatformWindow` gives its native handle, size
  in pixels and scale, and sends `WindowEvent`s (pointer, wheel, keys with
  layout characters, resize, close) in points to its `WindowDelegate`, which
  also draws frames (`frame(time:)` returns whether to keep going).
  `setNeedsFrame()` is safe from any thread. Installed by the entry point:
  `Platform.install(windows: Win32WindowSystem())`.
- **Win32** (`PolymerPlatformWindows/Win32Window.swift`): per-monitor DPI v2
  (scale = dpi/96, `WM_DPICHANGED` moves to the suggested rectangle),
  `WS_EX_NOREDIRECTIONBITMAP` (the swap chain is the only content), dark title
  bar and Mica on the frame (DWM attributes 20 and 38), mouse capture while a
  button is held, `TrackMouseEvent` for leaving, wheel notches times 40
  points, keys through `ToUnicode` without disturbing dead keys. The loop
  sleeps in `MsgWaitForMultipleObjectsEx` until input or a frame request;
  while a window animates it draws every refresh. During a live resize
  Windows runs its own loop, so `WM_SIZE` and `WM_PAINT` draw directly.
  Translations are pure functions (`Win32Input`) checked by `selfCheck()`.
- **Presenting** (`PolymerGPUD3D12/D3D12Presenter.swift`): a flip-sequential
  swap chain (two BGRA8 buffers, frame latency 1 with its waitable object, so
  `waitForFrame` paces drawing to the display at any refresh rate). Each
  buffer keeps the damage it has missed; a frame copies only that from the
  half-float target (`.present` program) and passes this frame's damage as
  dirty rectangles to `Present1`, so DWM recomposites only that. Handle 0
  gives an offscreen presenter with the same buffers, for checks.
- **Host** (`PolymerApp/WindowHost.swift`): events to `ViewTree` (pointer,
  wheel, keys as `KeyPress`), resize to `proposedSize` and `displayScale`;
  a frame waits for the display, sets `tree.time`, records, draws only the
  damage into a kept target and presents only that; nothing changed means
  nothing presented. It still calls `tree.render` (CPU) to get the list and
  damage until ViewTree can record without drawing (asked of Agent B in
  `out/coordination.md`); switch `WindowHost.record()` when it lands.
- **Check** `platform.window`: the backend's `selfCheck` (DPI, signed
  positions, buttons, wheel direction and amount, keys); the host on a test
  window with the real GPU presenting offscreen: first frame, a click through
  events (only its damage presented), Tab and Space, an unchanged frame not
  presented, a resize to scale 1.5, close; every image equals the CPU.
- **Never opened by agents.** `polymer demo [screen] [--software]` is for
  the owner (default screen: glass).
- Next: text input (IME, `WM_CHAR` for composed text) with Agent B's text
  editing, the cursor shape, right-click menus, scroll by moving pixels
  (`pScrollRect`), frames in flight, a see-through window (owner's call).

### Animation (session 4)

- **API** (`Animation.swift`): `Animation` (`.linear`, `.easeIn`, `.easeOut`,
  `.easeInOut` with or without `duration:`, `.spring(response:dampingFraction:)`,
  `.default` = a spring of 0.55 s that doesn't overshoot), `withAnimation`,
  `.animation(_:value:)`. Bézier curves are solved by Newton then bisection;
  springs are the closed-form damped oscillator (damping above 1 is treated
  as 1), finished when within 0.1%. Only `Math` and basic arithmetic.
- **Time** is `ViewTree.time` (seconds), set by the window per frame or by
  checks; `ViewTree.isAnimating` says whether to keep drawing.
- **Transactions.** `withAnimation` sets `Transaction.current` (a `Mutex`)
  while its body runs; an invalidation queued then carries the animation,
  and `updateOnce` makes the first one it finds `TreeState.passAnimation`
  for the whole update (cleared after layout). `.animation(_:value:)` puts
  its animation in `ResolveContext.animation` when the value changed;
  `reconcile` stamps nodes with it and the pass number (before resolving an
  existing node, so its own changes can animate).
- **What animates.** `Animated<T: Interpolatable>` keeps target, start
  value, start time, animation and (for springs) a starting velocity.
  `Interpolatable` is a small vector space (`adding`, `scaled(by:)`,
  `magnitudeSquared`, `shown`), like SwiftUI's `VectorArithmetic`; colours
  move as an unclamped `ColorVector` and are clamped when shown. A change
  with an animation starts from the value shown now; a spring also starts
  with the speed the value had (`speed(at:)`, closed-form derivatives), so
  an interruption bends the motion instead of stopping it, and its settle
  time is worked out from displacement and velocity (`settleTime`). A
  timing curve starts again at rest (SwiftUI adds curves instead; see
  DIFFERENCES). `Node.frame` is the shown frame; `layoutFrame` is where
  layout put it. Animated (session 4 and Agent B, session 5): frames
  (`Node.place`, which also covers `.offset`), `.opacity`, `Color` fills,
  shape fill and stroke colours, text colour, `.scaleEffect`. New nodes
  never animate. Text keeps its final line breaks and moves with its
  frame's centre. Hit testing and the element tree use the shown frames.
- **Drawing.** `Node.draw` is final: it applies a running transition, then
  calls `drawContent`, which nodes override (renamed from `draw`).
- **Transitions** (`Transition.swift`): `AnyTransition` (`.identity`,
  `.opacity`, `.move(edge:)`, `.offset(x:y:)`, `.scale`,
  `.scale(scale:anchor:)`, `.slide`, `.push(from:)`, `.asymmetric`,
  `.combined(with:)`) is an `Effect` for each direction (opacity, offset in
  points and in the view's own size, scale about a `UnitPoint`).
  `Node.setChild`, `removeChildren` and `ForEachNode.update` call
  `arrive`/`depart`. Only when the parent already existed (`resolvedOnce`,
  set when its first resolve ends) and an animation is current: an arriving
  node's leaves (`flattened`, so a stack's own items) get an
  `ActiveTransition` whose phase goes 0 to 1; a departing node is unmounted
  at once (state, focus and hover gone, no clicks) but kept in the parent's
  `ghosts` with its old index, its leaves' phase going to 0. Ghosts are
  drawn among the children at that index (`drawContent`, and
  `drawnFlattened` for stacks and lazy stacks, used only while
  `TreeState.ghostOwners` is not empty), take no space, are listed in the
  element tree marked "leaving", and are dropped by `pruneGhosts` at the
  start of `update()` once their phase ends. Groups and views with a body
  can keep ghosts; anything else removes at once. The transition is the
  nearest `.transition` between a leaf and the inserted node, else
  `.opacity` (SwiftUI's default). Re-inserting a leaving view makes a new
  one, as in SwiftUI. Lazy stack rows built on scrolling never transition.
- **Scale.** `.scaleEffect(_:anchor:)` and the scale transitions record
  through `DisplayList.scaled(by:about:)` (Agent A, session 5): exact at
  record time, text from outlines. Layout and the element tree keep the
  unscaled frame; hit testing maps the point back.
- Checks: `ui.animation` (curves, a frame half way, interruption, no
  animation without a transaction, opacity and colour, `.animation(value:)`,
  spring overshoot, partial frames equal whole draws while animating),
  `ui.animation-velocity` (a spring keeps its speed through an
  interruption and settles; a curve restarts at rest), `ui.transition`
  (fade on removal while the rest moves up, no clicks on leaving views,
  `.move`, ForEach removal and insertion with `.offset` drawn in order,
  re-insertion while leaving, no animation no transition, shape and text
  colours, `.scale` both ways, `.scaleEffect`, partial frames equal whole
  draws).
- Next: animated scroll positions (`ScrollViewReader.scrollTo` in
  `withAnimation`); `Animatable`,
  `.delay`, `.speed`, `.repeatForever` when screens need them. Known
  limits: a button inside `.scaleEffect` counts its unscaled area for
  release; a leaving view moved in from outside a scroll view's clip is
  culled by its layout frame.

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
   DESIGN 11.6), ~~`Grid` (not lazy), `GeometryReader`, drag gestures~~ (session 5), scroll bars
   and scroll physics, element names (stable paths for
   Customize and for driving input), a focus ring, ~~animation~~ (frames,
   opacity, colours; session 4; transitions and spring velocity, session 5), ~~skipping bodies of unchanged `Equatable`
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
  in debug. Both pass (36 checks) as of Windows session 4.

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

- Interactive glass (Agent B, session 5): pressed, the glass and its view
  grow 4 points on the longer side on a lively spring (0.3 s, damping 0.6)
  and the tint moves 12% toward white. Say if it should be subtler, also
  respond to hover, or light up where it is pressed (SwiftUI does; it would
  be a painted highlight, close to "glow").
- Transitions (Agent B, session 5): views inserted or removed under an
  animation fade by default, as in SwiftUI. If the pgr look wants
  something else by default (no transition, or a short move), say so.
- Text fields (Agent B, session 5): a 1-point caret in the text colour that
  doesn't blink (blinking needs a timer wake-up twice a second; say if you
  want it), the selection as the text colour at 25% behind the text, the
  placeholder at 40%, no border or background. See
  `out/checks/ui/text-input@2x.png`.

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
- Windows (session 5): the title bar is dark with Mica on the frame; the
  content is opaque. Mica or Acrylic behind the content itself needs
  DirectComposition (a premultiplied swap chain) and would make every
  window see-through where the app draws nothing: say if you want it.
  A wheel notch scrolls 40 points (a placeholder).
- Sample screens: `polymer render albums out.png --scale 2`,
  `polymer render counter out.png --scale 2 --click Add --click Step`,
  `polymer render list out.png --scale 2 --scroll 290 --click "Track 12"`.
