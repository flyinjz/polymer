# Polymer

**Polymer** is a self-sufficient, pure-Swift native application framework for building fast, deterministic desktop apps across Windows and macOS from a single codebase.

It replaces the usual stack of platform UI toolkits, third-party rendering engines, and audio libraries with one cohesive, zero-`Foundation` Swift codebase: text shaping and rasterization, 2D and GPU rendering, SwiftUI-shaped views and layout, input and accessibility, a built-in design system, and a lossless/lossy audio engine.

The first product built on Polymer is **i2s**, a native music player. Every pgr desktop app shares Polymer as its foundation so apps look, feel, and behave identically on every OS.

---

## Table of Contents

- [What Polymer Is (and Why It Exists)](#what-polymer-is-and-why-it-exists)
- [Who Polymer Is For](#who-polymer-is-for)
- [What Polymer Can Do Today](#what-polymer-can-do-today)
- [Architecture & Modules](#architecture--modules)
- [Quick Start](#quick-start)
- [CLI Reference](#cli-reference)
- [Verification & Performance](#verification--performance)
- [Documentation Map](#documentation-map)

---

## What Polymer Is (and Why It Exists)

Building a cross-platform native desktop app usually forces a bad trade-off:
- **Web wrappers (Electron, WebView)** ship a browser, burn RAM, and feel sluggish.
- **Platform-native toolkits (AppKit/SwiftUI, WinUI)** force you to write two apps that drift apart in layout, typography, and behaviour.
- **Cross-platform C++ toolkits** carry sprawling dependencies and awkward APIs.

Polymer takes a different path:

1. **Self-sufficient.** Polymer owns the full stack — font parsing and shaping, software and GPU rendering, layout, input, accessibility, UI components, and audio codecs/DSP — in pure Swift standard library code. External code is used only where unavoidable (OS windowing, GPU drivers, audio output) and strictly isolated behind platform backends.
2. **SwiftUI-shaped, deterministic everywhere.** Views, `@State`, `@Observable`, `@Environment`, stacks, grids, gestures, animations, transitions, and accessibility use familiar SwiftUI names and semantics. Every deliberate difference is documented in [`Docs/DIFFERENCES.md`](Docs/DIFFERENCES.md). Output is deterministic across runs and operating systems.
3. **Headless-first & inspectable.** Any screen can be driven, queried as an element or accessibility tree, rendered to PNG, diffed pixel-by-pixel, and benchmarked from the CLI without opening a window.
4. **Design built in.** The pgr design system (`PolymerDesign`) ships ready-made components with a cohesive brutalist-grid aesthetic, dark glass, keyboard navigation, right-click command menus, and user-facing **Customize** (hide, resize, restyle) on every component by default.

---

## Who Polymer Is For

| Audience | How They Use Polymer | Start Here |
|---|---|---|
| **AI coding agents** | Write, inspect, and verify apps without guessing. Familiar SwiftUI APIs, one canonical way to do each thing, actionable error messages, headless `render`/`tree`/`describe`/`diff`/`bench`, and `--json` output on every tool. | [`Docs/AGENT_GUIDE.md`](Docs/AGENT_GUIDE.md) · [`AGENTS.md`](AGENTS.md) |
| **App developers** | Build native Windows and macOS desktop apps in Swift 6 with a single `import Polymer`, zero `Foundation` overhead, and built-in design & audio modules. | [`Docs/AGENT_GUIDE.md`](Docs/AGENT_GUIDE.md) · [`Docs/COMPONENTS.md`](Docs/COMPONENTS.md) |
| **Framework contributors** | Extend the text engine, GPU/software renderer, layout engine, design system, audio DSP, or platform backends with strict verification (`polymer check`). | [`AGENTS.md`](AGENTS.md) · [`Docs/DESIGN.md`](Docs/DESIGN.md) · [`Docs/HANDOFF.md`](Docs/HANDOFF.md) |
| **Product owners** | Track progress in plain English without reading code. | [`Docs/STATUS.md`](Docs/STATUS.md) · [`Docs/ACTIVITY.md`](Docs/ACTIVITY.md) |

---

## What Polymer Can Do Today

- **Typography (`PolymerText`)** — Pure-Swift OpenType/TrueType parsing, GDEF, UAX #14 line breaking, font fallback chains, variable fonts, COLR/CPAL colour emoji, and optional 1/4-px `GlyphCache` quantization. Tuned to match macOS CoreText (**1.122 / 255** mean diff across 128 reference images).
- **2D & GPU Rendering (`PolymerRender`, `PolymerGPU`)** — Shapes, PNG/JPEG decode & encode (including scaled IDCT & EXIF), blur, and frosted/liquid glass drawn identically on CPU and Direct3D 12, with automated WCAG AA contrast-on-glass checks (`DESIGN.md §11.4`).
- **Views, Layout & Interaction (`PolymerUI`)** — Stacks (`VStack`, `HStack`, `ZStack`, `Spacer(minLength:)`), `Grid`, `LazyVStack`/`LazyHStack`/`LazyVGrid`, `ScrollView` + `ScrollViewReader`, `GeometryReader`, `@State`/`@Binding`/`@Observable`/`@Environment`, springs & timing animations, transitions, clicks/drags/scroll/pointer styles, `TextField`/`TextEditor` with undo/redo & IME, menus, context menus, popovers, sheets, `.onDisappear`, `.allowsHitTesting`, and an on-demand accessibility tree.
- **Design System (`PolymerDesign`)** — `Theme` tokens, `designRoot`, `PButton`, `PToggle`, `PSlider`, `PProgressBar`, `PSegmentedControl`, `PPicker`, `PTextField`, `PListRow`, `PSectionHeader`, `PSidebarLayout`, `PToolbar`, `PPanel`, `PScrollBar`, tooltips, `Command` + `CommandRegistry` (auto-unregisters on unmount), `DesignRegistry`, and JSON-persisted `CustomizeModel`.
- **Audio Engine (`PolymerAudio`)** — Pure-Swift WAV, FLAC, MP3, AIFF/AIFC, and ALAC/M4A decode/encode with metadata, cover art, and ReplayGain; 64-bit DSP (parametric EQ, BS.1770 loudness, true-peak meter & limiter, crossfader, crossfeed, TPDF dither); and gapless playback.
- **Real Windows (`PolymerApp`, `PolymerPlatformWindows`)** — Native Win32 windows driven by `WindowHost` + D3D12 via `ViewTree.record()` (zero CPU rasterization), with system clipboard and Imm32 IME support.
- **Headless CLI (`PolymerTools`)** — `render`, `tree`, `describe`, `diff`, `bench`, `zoom`, `check`, `check-tools`, `status`, `log`, `activity`, `help`, all scriptable with `--json`.

**What's next:** live-speaker WASAPI & real-world MP3 verification, `PointerStyle` and UI Automation hooks in `Win32Window`, macOS backend verification (`PolymerPlatformMac`), light-mode `Material` presets, and the first i2s app screen (Albums).

---

## Architecture & Modules

All shared modules depend **only on the Swift standard library** — no `Foundation`, no AppKit, no Win32 types, and no `#if os(...)` outside backends.

| Module | Path | Responsibility |
|---|---|---|
| `Polymer` | `Sources/Polymer` | Umbrella module apps import (re-exports Base, Text, Render, UI, Design). |
| `PolymerBase` | `Sources/PolymerBase` | `Point`, `Size`, `Rect`, `Color`, `Path`, `AffineTransform`, `JSON`, `StableID`. Zero dependencies. |
| `PolymerText` | `Sources/PolymerText` | Font parsing, shaping, GDEF, UAX #14 line breaking, fallback, variable fonts, COLR/CPAL emoji, `GlyphCache`. |
| `PolymerRender` | `Sources/PolymerRender` | Software rasterizer, `DisplayList`, `Bitmap`, `PNG`, `JPEG`, blur, glass. |
| `PolymerGPU` | `Sources/PolymerGPU` | GPU renderer interface + D3D12 backend (`PolymerGPUD3D12`). |
| `PolymerUI` | `Sources/PolymerUI` | SwiftUI-shaped views, layout, state, focus, input, gestures, presentations, animation, accessibility, `ViewTree`. |
| `PolymerDesign` | `Sources/PolymerDesign` | pgr `Theme` tokens, `P*` components, `CommandRegistry`, `CustomizeModel`, `DesignRegistry`. |
| `PolymerAudio` | `Sources/PolymerAudio` | Pure-Swift audio codecs (WAV, FLAC, MP3, AIFF, ALAC), metadata/ReplayGain, 64-bit DSP, gapless engine. |
| `PolymerPlatform` | `Sources/PolymerPlatform` | OS-agnostic protocols (`Files`, `Process`, `Window`, `Clipboard`, `AudioOutput`). |
| `PolymerPlatform*` | `Sources/PolymerPlatformWindows`, `PolymerPlatformMac` | Per-OS backends (Win32, Imm32, WASAPI, macOS). |
| `PolymerApp` | `Sources/PolymerApp` | `WindowHost`: connects a `ViewTree`, a `PlatformWindow`, and the GPU renderer. |
| `PolymerChecks` | `Sources/PolymerChecks` | 97 framework verification checks and sample screens. |
| `PolymerTools` | `Sources/PolymerTools` | The `polymer` CLI and 8 tool checks. |

---

## Quick Start

**Requirements:** Swift 6.2+ (on Windows, with Visual Studio C++ build tools).

```bash
# Build and run the full verification suite (97 framework checks + 8 tool checks)
bash Tools/check.sh debug
bash Tools/check.sh release

# Or drive the CLI directly
swift build
swift run polymer check
swift run polymer render counter out/counter.png --scale 2
swift run polymer describe counter
swift run polymer bench --frames 20
swift run polymer help
```

> **Windows note:** If `swift run` cannot locate the binary, invoke it directly from `$(swift build --show-bin-path)/polymer.exe` (typically `.build/out/Products/Debug-windows-x86_64/polymer.exe` or `Release-windows-x86_64/polymer.exe`).

---

## CLI Reference

Run `polymer help <topic>` for full flags and examples. Add `--json` to `render`, `tree`, `describe`, `diff`, `bench`, `status`, `log`, `activity`, or `help` for deterministic, sorted-key JSON.

| Command | Purpose |
|---|---|
| `polymer check [filter] [--list] [--verbose]` | Run all 97 framework checks + 8 tool checks (or a substring filter). |
| `polymer check-tools` | Run only the 8 CLI/tooling checks. |
| `polymer render <screen> <out.png> [--scale N] [--customize file.json] [steps]` | Render a screen headlessly to PNG after optional input steps. |
| `polymer tree <screen> [--a11y] [--json] [steps]` | Print the element tree (frames in points) or accessibility tree. |
| `polymer describe <screen> [--customize file.json] [--json] [steps]` | Describe a screen's accessibility tree in plain English. |
| `polymer diff <a.png> <b.png> [--out diff.png] [--threshold N]` | Compare two PNGs pixel-by-pixel and optionally write a visual diff. |
| `polymer bench [--frames N] [--width W] [--height H]` | Benchmark layout+record and software raster frame times (p50/p95/max). |
| `polymer zoom <in.png> <out.png> x y w h factor` | Crop and nearest-neighbour enlarge a region for pixel inspection. |
| `polymer status [--write] [--json]` | Print or regenerate `Docs/STATUS.md` from `Docs/status.json`. |
| `polymer log "plain sentence" [--by name]` | Append a plain-English entry to `Docs/ACTIVITY.md`. |
| `polymer activity [N] [--all]` | Show recent agent activity. |
| `polymer demo [screen] [--software]` | Open a live window (for humans; never used in automated checks). |

---

## Verification & Performance

Verified on Windows 11 (Swift 6.2, zero compiler warnings):

- **Checks:** **97 framework checks + 8 tool checks** passing in both `debug` and `release`.
- **CoreText text parity (`polymer check text.coretext --verbose`):** mean **1.122 / 255** across 128 images, worst **1.930** (bounds: 1.2 / 2.0).
- **Release benchmark (`polymer bench --frames 20`, 720×480 @ 1×, 13 rows / 34 items):**
  - `layout + record`: **0.03 ms** p50 · **0.04 ms** p95 · **0.04 ms** max
  - software `raster`: **8.68 ms** p50 · **9.11 ms** p95 · **9.32 ms** max

---

## Documentation Map

| Document | Audience | Read This When... |
|---|---|---|
| [`Docs/AGENT_GUIDE.md`](Docs/AGENT_GUIDE.md) | Agents & app developers | Building an app on Polymer: 10 rules, minimal app, headless loop, common errors, recipes. |
| [`Docs/COMPONENTS.md`](Docs/COMPONENTS.md) | Agents & app developers | Looking up `PolymerDesign` components (`PButton`, `PSlider`, `PScrollBar`, `Command`, `CustomizeModel`). |
| [`Docs/DIFFERENCES.md`](Docs/DIFFERENCES.md) | Agents & app developers | Checking every deliberate difference between Polymer and Apple's SwiftUI. |
| [`AGENTS.md`](AGENTS.md) | Framework agents | Working on Polymer itself: the 4 principles, purity rules, commit/signing rules, handoff protocol. |
| [`Docs/DESIGN.md`](Docs/DESIGN.md) | Everyone | Reading the signed-off architecture and visual specification (including §11 glass & contrast rules). |
| [`Docs/HANDOFF.md`](Docs/HANDOFF.md) | Framework agents | Checking exact session history, decisions made, and what comes next. |
| [`Docs/STATUS.md`](Docs/STATUS.md) | Owner & newcomers | Seeing current progress in plain English (generated from `Docs/status.json`). |
| [`Docs/ACTIVITY.md`](Docs/ACTIVITY.md) | Owner | Reading the chronological log of completed work (updated via `polymer log`). |
