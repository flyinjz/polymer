# Polymer: design

Status: signed off 2026-11-13. Changes to section 1 or 2 need the owner's OK.

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
| D10 | The Windows Qt app | Frozen now, replaced by Polymer. |
| D11 | Accessibility and IME | In the architecture from day one (accessibility tree, text input protocol); full screen-reader and IME support finished later. |

## 3. Modules

```
PolymerBase        geometry, colour, collections, time, logging, IDs, JSON
PolymerPlatform    interfaces: window, events, clipboard, cursor, dialogs, glass,
                   files, secure storage, notifications, media controls, file watch
  …Mac / …Windows    AppKit, Metal layer, CoreAudio / Win32, DXGI, WASAPI   (per OS)
PolymerGPU         device, buffers, textures, pipelines, command encoding
  …Metal / …D3D12                                                          (per OS)
PolymerRender      display lists, layers, compositor, damage regions, images,
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
- On Windows, Polymer replaces the Qt app.
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
