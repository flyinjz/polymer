# Polymer: design

Status: signed off 2026-11-13. Changes to section 1 or 2 need the owner's OK.
Section 11 (effects and materials, liquid glass) and D12 added 2026-11-14 at
the owner's request; its open points are listed in 11.8.

## 0. What it is

Polymer is a native application framework for every pgr product (i2s
first). Apps are written in Swift, in the style of SwiftUI: views, result
builders, state, modifiers, environment, animation. Everything underneath
is Polymer's own: platform layer, GPU renderer, text, layout, state,
animation, the pgr design system with Customize built in, the app runtime,
and a studio-grade audio engine.

It runs natively on macOS and Windows (Linux later). A feature written once
works on every OS from the same change.

## 1. Philosophy

These come before any decision below. When a choice is unclear, decide by
them, in this order.

### 1.1 Self-sufficient

Polymer relies on nothing but itself for everything it can do itself:
outline parsing, rasterising, text layout, JSON, images, decoders, DSP,
layout, animation. Outside code is used only where writing our own is
unreasonable (an OS interface, a codec whose licensing belongs with the
OS, complex-script shaping for now). Each such piece is listed in section
2, sits behind a Polymer interface, and can be replaced without touching
anything above it. Nothing is added for convenience.

### 1.2 Built for agents

Polymer is a framework mostly for AI agents to write software with, not
humans; people direct and review. It is designed for how agents work:

1. **Familiar.** The API matches SwiftUI wherever the meaning matches, so
   what models already know carries over. Every deliberate difference is
   listed in one file.
2. **One way to do each thing.** No overlapping APIs, no legacy paths, no
   hidden behaviour.
3. **Rules enforced by the framework, not by memory.** Right-click menus
   and Customize (style, scale, move, hide) are on by default for every
   element, so they can't be forgotten. Design rules (tokens only, no raw
   colours, no gradients or glow, no ALL CAPS) are checks that fail the
   build.
4. **Everything observable without a screen.** A `polymer` command renders
   any screen to an image, prints the element tree as text (names, frames,
   styles, text), drives input by element name (click, type, scroll, keys),
   and records frame timing. Agents see and test an app the way a person
   would, headlessly, on every OS.
5. **Self-describing.** `polymer describe` prints every component,
   modifier, token and command with its signature and a short example,
   generated from the source. Agents look things up instead of guessing.
6. **Errors say how to fix them.**
7. **Deterministic.** The same code and input give the same pixels and the
   same element tree on every OS, and a check compares them. What an agent
   verified on the Mac is verified for Windows.
8. **Small modules, fast incremental builds,** short docs in the repo
   (`AGENTS.md` plus a contract per module).

### 1.3 Efficient, always

Rule for every agent working on Polymer or anything built with it. This
project is meant to show what software can be; efficiency is part of the
design, not a later pass.

- The machine's time is the user's time. Choose the approach that does
  the least work, then make that work fast.
- No fixed targets. Faster is always the goal; benchmark numbers exist to
  catch regressions, never as finish lines.
- **Frame rate is unlocked.** Polymer renders at whatever the display
  runs at (60, 144, 240, 500 Hz, variable refresh), paced to that display,
  with input read as late as possible before each frame. A frame's cost
  scales with what changed, so high refresh rates stay cheap. Idle costs
  nothing.
- **Size has no budget, but every byte is justified.** No dependency for
  convenience, no unused code shipped, no data loaded before it is needed.
- No allocation, locks or I/O on hot paths (frames, scrolling, audio).
- No work for anything not on screen.
- Measure, don't guess: hot paths have benchmarks on both OSes, and a
  regression is a bug.

### 1.4 Design first

The pgr look and feel, identical on every OS: brutalist grid, 1px lines,
dark glass, bundled mono fonts and icons, grays plus one accent. Text must
look as clean as on a Mac, on every screen (section 4).

## 2. Decisions

| # | Decision | Recommendation |
|---|---|---|
| D1 | Name | **Polymer**. One import for apps (`import Polymer`); internal modules `PolymerBase`, `PolymerUI`, and so on. |
| D2 | Repository | Its own public repo (`flyinjz/polymer`), plain git, signed commits. i2s depends on it as a Swift package. |
| D3 | GPU | Native **Metal** (Mac) and **Direct3D 12** (Windows) behind one small interface; shaders written once, compiled to both at build time. |
| D4 | Windows and input | Our own thin layer per OS (AppKit window on Mac, Win32 on Windows): native glass, menus and input timing. |
| D5 | Text | **Ours**: font parsing, rasteriser, glyph cache, layout, line breaking, editing (section 4). The one outside piece is **HarfBuzz** for complex-script shaping (Arabic, Indic, and so on), behind our interface. FreeType is not used. |
| D6 | Standard library | Swift standard library only; no Foundation. JSON, paths, dates and IDs are Polymer's own; files, time and randomness come through the platform layer. |
| D7 | Audio output | Native per OS: CoreAudio (exclusive and integer when bit-perfect), WASAPI exclusive and shared. |
| D8 | Decoders | Ours: FLAC, WAV, AIFF, ALAC, MP3 (patents expired), later Vorbis. AAC through each OS's decoder (licensing stays with the OS). Opus through libopus until ours exists. |
| D9 | Linux | Later; the platform interfaces stay ready for it. |
| D11 | Accessibility and IME | In the architecture from day one (accessibility tree, text input protocol); full screen-reader and IME support finished later. |
| D12 | Effects and materials | **Ours**, rendered by Polymer's own compositor on every OS: backdrop blur, materials and liquid glass (refraction, frost, rim light) as first-class effects (section 11). The OS supplies only what lies behind the window (DWM / NSVisualEffectView). |

## 3. Modules

```
PolymerBase        geometry, colour, collections, time, logging, IDs, JSON
PolymerPlatform    interfaces: window, events, clipboard, cursor, dialogs, glass,
                   files, secure storage, notifications, media controls, file watch
  …Mac / …Windows    AppKit, Metal layer, CoreAudio / Win32, DXGI, WASAPI   (per OS)
PolymerGPU         device, buffers, textures, pipelines, command encoding
  …Metal / …D3D12                                                          (per OS)
PolymerRender      display lists, layers, compositor, damage regions, images,
                   effects (blur, materials, liquid glass; section 11),
                   blur, clipping, offscreen rendering for tests
PolymerText        font parsing, rasteriser, shaping, line breaking, glyph cache,
                   layout, editing (caret, selection, undo, IME composition)
PolymerUI          views, result builders, state (observation), environment,
                   identity and diffing, layout, lazy lists, gestures, scrolling,
                   animation, focus, accessibility tree
PolymerDesign      pgr design system: tokens, components, Customize built in
PolymerApp         scenes, windows, commands (one system for menus, buttons,
                   shortcuts, right-click menus), settings, files and URLs
PolymerAudio       real-time engine, decoders, DSP, output (backends per OS)
PolymerTools       the `polymer` command: build, check, render, dump, drive, describe
---
I2SCore            today's Core/, on Polymer's base instead of Foundation
I2S                the i2s app
```

Per-OS code lives only in the platform, GPU and audio output backends:
about 5–6k lines per OS against 100k+ shared.

## 4. Text

Goal: text as clean as macOS on every screen, and identical on every OS.

Why Mac text looks clean:
- High-density screens, above all.
- No hinting: glyph shapes are kept exact instead of snapped to pixels.
- Subpixel positioning: each glyph sits at its exact fractional position,
  so spacing is even.
- Stem darkening: thin strokes are slightly thickened at small sizes, so
  text doesn't look washed out.
- Careful gamma, so light-on-dark and dark-on-light text keep the same
  weight.

Why Windows text often looks worse: ClearType hints shapes to the pixel
grid (distorted letters, uneven spacing), colour fringing, many screens
at 100% scaling, and apps mixing renderers with different gamma.

What Polymer does (all ours):
- **Font parser:** TrueType and CFF/CFF2 outlines, variable fonts, colour
  emoji tables.
- **Rasteriser:** exact analytic area coverage in floating point (no
  supersampling shortcuts), per glyph and per fractional offset.
- **Mac-style rendering everywhere:** no hinting, fractional positioning,
  stem darkening by size and pixel density, gamma-correct blending tuned
  for light text on dark glass (where most renderers go too thin or too
  bold).
- **Tuned against CoreText:** a check renders the same strings with
  CoreText and with Polymer on the Mac and measures the difference, and we
  tune until they match. Windows then draws the same pixels by
  construction. "As clean as on a Mac" is measured, not claimed.
- **Low-density screens:** per display, an optional subpixel (LCD) mode
  using the panel's RGB or BGR layout with a light filter against
  fringing, and optional vertical-only alignment of baseline and x-height
  at small sizes. No renderer, macOS included, makes a low-density screen
  as sharp as a high-density one; these modes get closest.
- **Scaling and animation:** text that scales (Customize, transitions) is
  drawn from outlines on the GPU while it moves, and from the cache once
  it settles, so it is sharp at every size and every frame.

## 5. Speed

How Polymer meets section 1.3:
- **Start:** static linking, no reflection, nothing loaded until needed;
  the library index is memory-mapped, not parsed.
- **Frames:** a retained render tree, redrawing only changed regions; GPU
  instancing for rectangles, lines and glyphs; one glyph cache; no
  allocation per frame.
- **State:** fine-grained observation, so a change re-renders only the
  views that read it.
- **Input:** handled on the frame it arrives; scrolling and drags never
  wait for layout of off-screen content.

## 6. Audio

- 64-bit float internal path, SIMD throughout.
- Real-time thread with no allocations, locks or file I/O; lock-free queues
  to and from the UI (spectrum, levels, position).
- Decoding and read-ahead on another thread; gapless at sample level.
- Bit-perfect mode (exclusive device, no mixing, resampling or volume when
  the track matches the device) and a shared mode.
- Polyphase windowed-sinc resampler; TPDF dither when reducing bit depth.
- DSP: today's equalizer maths with minimum- and linear-phase options;
  EBU R128 / ReplayGain with a true-peak limiter; crossfade; headphone
  crossfeed.
- Null tests and THD+N checks in the test suite, so quality is verified.

## 7. Customize and menus, built in

Every element the design system draws is addressable (a stable path plus a
role), so Customize works on anything without per-page hooks: style,
scale, move (order in its container, or free placement where allowed),
hide. Today's `CustomizeState` (styles, layout, page sections, tokens,
workspaces) carries over. Right-click menus come from the command system,
so every element has one by default.

## 8. Testing

- Headless rendering on both OSes produces identical images, compared
  against references.
- The element tree compared across OSes.
- Shared unit and behaviour tests; audio null and distortion tests.
- Every change built and tested on the Mac and on the owner's Windows PC as a
  self-hosted runner.

## 9. Moving i2s over

- On the Mac, Polymer draws inside a normal view, so pages move one at a
  time while the SwiftUI app keeps working. Albums first.
- On Windows, Polymer is the app.
- `Core/` moves to Polymer's base and becomes `I2SCore`.

No milestones: work follows what the rest depends on, and everything stays
running end to end as it grows.

## 10. Risks

- Text input, IME and accessibility are the hardest parts; designed in
  from the start, finished later.
- GPU driver differences on Windows; caught by the Windows runner.
- Swift on Windows has occasional compiler and library gaps; Polymer keeps
  to stable language features.
- Mac sessions can only run Mac code; Windows needs a session on the
  owner's Windows PC.

## 11. Effects and materials

Added 2026-11-14 at the owner's request: support for advanced effects such
as liquid glass, built into the framework rather than left to each app.

### 11.1 What there is

- **Backdrop blur.** A shape blurs whatever was drawn behind it (Gaussian,
  radius in points). The base of the pgr dark glass.
- **Materials.** Blur plus a tint, in a few strengths (SwiftUI's
  `Material`: ultra-thin to ultra-thick). Their colours and strengths are
  design tokens, so the dark glass stays clear and never murky, however
  many layers stack.
- **Liquid glass.** A shape that behaves like a thick piece of glass over
  the content behind it:
  - *Refraction*: near its edge the glass bends light, so the content
    under the rim is pulled in from just outside the shape, as through the
    curved edge of a lens; the flat middle shows the content undistorted.
  - *Frost*: a light blur of what is seen through it.
  - *Rim light*: a thin highlight along edges facing a light direction,
    from the shape's geometry, plus a fainter one opposite.
  - *Tint*: a colour laid over what is seen through it (the accent, or a
    grey).
  - Optional *dispersion*: red and blue bent slightly differently at the
    rim. Off by default.
  - Later: shapes that merge when close (a smooth union of their distance
    fields, SwiftUI's `GlassEffectContainer`), and glass that responds to
    the pointer (`interactive()`, with animation).
- **The window's own backdrop** (the desktop behind the window) comes from
  the OS: DWM acrylic or mica on Windows, `NSVisualEffectView` on the Mac.
  An app can't read other apps' pixels, so this is the one effect the OS
  draws; everything inside the window is Polymer's.

### 11.2 How it is drawn

- Effects are items in the display list, like rectangles and text. A
  backdrop effect reads the pixels drawn before it within its shape plus
  its reach (blur radius, refraction distance), filters them and draws the
  result inside its shape.
- Every effect shape is a rounded rectangle (rectangles, capsules and
  circles are special cases), so one exact signed distance field gives
  coverage, the edge normal and the distance from the edge for every pixel.
  Anti-aliasing comes from that distance, so edges are as clean as text.
- The CPU renderer is the reference: plain arithmetic, identical pixels on
  every OS, used by headless checks. The GPU renderers run the same maths
  in shaders and are compared with it.
- **Damage.** An effect depends on the pixels within its reach. When
  anything there changes, the parts of the effect within reach of the
  change are drawn again; nothing else is. Redrawing only damage gives the
  same pixels as drawing everything, as for every other item.
- **Cost.** Blur is separable (two one-dimensional passes); on the GPU a
  downsampled pyramid. Effects over unchanged content cost nothing,
  because nothing under them is damaged. The cost of each effect per frame
  is measured, and a regression is a bug (1.3).

### 11.3 API

SwiftUI's names, so models already know them:

- `.glassEffect()`, `.glassEffect(.regular.tint(color), in: shape)` with
  `Glass` (`.regular`, `.clear`, `.identity`, `.tint(_:)`; later
  `.interactive()`), and `GlassEffectContainer` when merging comes.
- `.background(.ultraThinMaterial)` and the other `Material`s, in a shape:
  `.background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))`.
- `.blur(radius:)` for blurring a view's own content (comes with layers).
- Shapes: `Rectangle`, `RoundedRectangle(cornerRadius:)`, `Capsule`,
  `Circle`, with `.fill`, `.stroke` and `.strokeBorder` (1px lines).

### 11.4 Accessibility

- With the OS's "reduce transparency" setting, glass and materials draw as
  an opaque tinted fill of the same shape. With "increase contrast", rims
  and borders get stronger.
- Text on glass must keep the contrast the design system asks for; a check
  measures it against what is actually behind the glass.

### 11.5 How it fits the pgr look

Section 1.4 rules out gradients and glow. Liquid glass is a material, not
decoration: its light and shading come from the shape and what is behind
it, never from painted gradients, and it never glows outward. Effects
follow the same tokens as everything else (one accent, greys), and the
design system decides where glass is used; apps don't tune it per view.

### 11.6 Order of work

1. Shapes with exact coverage, fills and 1px strokes.
2. Backdrop blur and materials in the CPU renderer, with damage.
3. Liquid glass: refraction, frost, rim light, tint; dispersion behind an
   option.
4. The same effects on the GPU (D3D12, then Metal), compared with the CPU
   reference.
5. Merging glass shapes, interactive glass, `.blur(radius:)` on layers.

### 11.7 Checks

- Blur keeps a flat colour flat and keeps the total light; materials and
  glass over flat content give exactly the tint over that content.
- Refraction moves content near the rim and leaves the middle untouched.
- Redrawing only the damage gives the same pixels as drawing everything,
  with effects over moving content (scrolling under glass).
- Reference images of glass over test patterns, compared exactly on the
  CPU and within a stated tolerance on the GPU.

### 11.8 For the owner's review

- The look of the defaults (refraction strength, frost, rim brightness,
  tint), and whether dispersion is ever on, are design decisions; they
  start as PolymerDesign tokens with conservative values.
- SwiftUI's default glass shape is a capsule; the pgr grid may want square
  or slightly rounded corners by default.
- Whether the rim light is allowed under "no glow" (it is a reflection on
  the glass edge, not light spilling outward).
