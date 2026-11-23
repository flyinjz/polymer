# Handoff

Keep this file short and current (no session essays; history lives in git log).
Design: `Docs/DESIGN.md`. SwiftUI deltas: `Docs/DIFFERENCES.md`.

## Status (2026-11-23, session 6)

- Builds cleanly in debug and release with zero warnings (`swift build -Xswiftc -warnings-as-errors`, `bash Tools/check.sh release`).
- **52 checks pass** across `base`, `text`, `render`, `ui`, `app`, `design`, `audio`, and `gpu`. CoreText reference match: mean error **1.122/255**, worst **1.930/255** (regression bound 1.2) — identical on Windows and Linux.
- Modules in `Package.swift`: `PolymerBase`, `PolymerPlatform` (`…Windows`, `…Mac`, `…Linux`), `PolymerText`, `PolymerRender`, `PolymerGPU`, `PolymerUI`, `PolymerApp`, `PolymerDesign`, `PolymerAudio`, `Polymer`, `PolymerChecks`, `PolymerTools` (`polymer` CLI).

## Implemented

- **`PolymerBase`**: `Point`, `Size`, `Rect`, `EdgeInsets`, `PixelRect`, `AffineTransform`, `Path` (rect, roundedRect, ellipseIn, flattening), `Color` (exact sRGB + pure-Swift `Math.log/exp/sin/cos`), `StableID`/`StableHasher` (pinned), `Logger`, `ByteReader`, strict deterministic `JSON`, zlib inflate/deflate, CRC-32, Adler-32.
- **`PolymerPlatform`**: `FileSystem` + `Process` installed once via `Platform.install(...)` in the entry point. Win32 UTF-16 (`…Windows`), POSIX Glibc (`…Linux`, verified), POSIX Darwin (`…Mac`, updated for Swift 6, not yet compiled on macOS).
- **`PolymerText`**: OpenType (`glyf`, CFF Type 2/subrs/flex/CID), GPOS pair kerning + `kern` fallback, GSUB (`ccmp locl rlig liga clig calt rclt`), exact analytic rasteriser with Mac-style stem darkening, line/paragraph wrapping (`lineLimit`, height truncation + ellipsis), fractional-offset `GlyphCache`, and `TextBuffer`/`TextEditorState` (grapheme cursor, directional selection, word/line navigation, coalescing undo/redo, IME `MarkedText`, caret hit-testing).
- **`PolymerRender`**: `Bitmap`, `RenderImage` (O(1) atomic-token identity), own PNG codec, CPU `Canvas` (rects, paths, glyphs, nearest/premultiplied-bilinear images, 3-pass separable Gaussian `backdropBlur`, in-place `scroll` blit, clipping), `DisplayList` with `withOpacity`, blur-safe damage expansion, and `damagePlan` scroll-blit diffing.
- **`PolymerGPU`**: Backend-agnostic `GPUDevice`/`GPUBuffer`/`GPUTexture`/`GPUPipeline`/`GPUCommandEncoder` protocols + headless `RecordingGPUDevice`, skyline `GlyphAtlas` packer (`r8Unorm` with 1px padding), and `DisplayListCompiler` (instanced batch coalescing verified against CPU `Canvas` coverage).
- **`PolymerUI`**: Retained `Node` tree (`reconcile`), `HostNode` (`@State`, `@Binding`, `@Bindable`, `@Environment`, `@Observable`, `Equatable` skipping, `Epoch` cleanup), `ViewBuilder`/`Group`/`ForEach`/`.id(_:)`, `Text`, `TextField`, `TextEditor`, `Color`, `Shape` (`Rectangle`, `RoundedRectangle`, `Circle`, `Capsule`, `Path`), `Image`, `BackdropBlur`, `Spacer`, `Divider`, `HStack`/`VStack`/`ZStack`, `Button`/`ButtonStyle`, `ScrollView`, `LazyVStack`/`LazyHStack`, `LazyVGrid`/`LazyHGrid` (`GridItem`), `DragGesture`, focus (`@FocusState`, `.focusable()`, `.onKeyPress`, Tab/Shift-Tab), pointer/hover/`.disabled(_:)`, modifiers (`padding`, `frame`, `aspectRatio`, `background`, `overlay`, `border`, `clipped`, `clipShape`, `zIndex`, `layoutPriority`, `contextMenu`, `opacity`, `offset`, `font`, `foregroundStyle`, `lineLimit`, `multilineTextAlignment`, `environment`, `onTapGesture`, `onChange`, `accessibilityIdentifier`, `animation(_:value:)`), deterministic `Animation` + `ScrollPhysics` (`ViewTree.tick(_:)`, `fling`), `ViewTree.rightClick`/`secondaryClick`, `AccessibilityNode` tree export, `Node.stablePath`/`stableID`, `ImageRenderer`.
- **`PolymerApp`**: Unified `Command`/`CommandRegistry` (`KeyShortcut`, categories, groups, shortcut dispatch, JSON description), deterministic JSON `SettingsStore` on `PolymerPlatform.FileSystem`, `WindowConfig`/`Scene`/`WindowGroup`, and `ScreenRegistry`.
- **`PolymerDesign`**: Style-agnostic swappable `Theme` tokens (`colors`, `radii`, `borders`, `glass`, `typography`, `spacing`, `focusRing`, `scrollIndicators`) with `Theme.pgr` (dark-glass brutalist), `Theme.dark`, and `Theme.light` presets; opt-in `DesignLint` (`noAllCaps`, `noDoubleSlashPrefix`, `pgrSharpCorners`, `noStackedGlass`, `tokenColorsOnly`); themed controls (`PolymerButtonStyle`, `PolymerToggle`, `PolymerSlider`, `PolymerScrollBar`, `PolymerPanel`, `FocusRingModifier`, `PolymerContextMenu`, `HairlineDivider`); and `CustomizeState` override engine keyed by `#id` / `Node.stablePath` with JSON/SettingsStore persistence.
- **`PolymerAudio`**: Lock-free power-of-two `SPSCRingBuffer` (`Atomic`), 64-bit float zero-allocation `AudioGraph` + metering, pure-Swift WAV/AIFF/FLAC decoders & round-trip encoders (80-bit extended AIFF rate, FLAC FIXED/LPC/mid-side/Rice + CRC-8/16), Kaiser-windowed polyphase `SincResampler` (< -117 dB THD+N), `TPDFDither`, RBJ `BiquadFilter`/`ParametricEQ`, EBU R128 `LoudnessMeter`/ReplayGain + 4x oversampled `TruePeakLimiter`, `Crossfader`, `HeadphoneCrossfeed`, and `AudioMetrics` (null + IEEE 1057 THD+N).
- **`PolymerTools`**: `polymer check`, `render`, `tree [--a11y]` (steps: `--click`, `--click-id`, `--right-click`, `--right-click-id`, `--scroll`, `--key`, `--hover`, `--press`, `--scale`), `describe [section] [--json]`, `zoom`. Screens: `albums`, `counter`, `list`, `library`, `design`.

## Key Architectural Invariants

- **Drawing & damage:** Views record a `DisplayList`; `Canvas` and `PolymerGPU.DisplayListCompiler` consume the same list. `ViewTree.render()` applies `ScrollBlit`s in-place, then clears/redraws only `damage` rects; partial redraws match full draws bit-for-bit. Damage touching a `backdropBlur` expands to its full bounds.
- **Node hierarchy:** Nodes affecting drawing/clipping/transforms inherit from `Node` (not `PassthroughNode`), because `StackNode` flattens `PassthroughNode`s. `StackNode` distributes space by descending `layoutPriority` and sorts drawing/hit-testing stably by `zIndex`.
- **Lazy containers:** `ResolveContext.lazyItems` propagates only through transparent wrappers (`childrenAreLazy`) into `LazyVStack`/`LazyHStack`/`LazyVGrid`/`LazyHGrid`. Built elements stay alive off-screen so state survives scrolling.
- **Real-time audio:** Zero allocations, zero locks, and zero I/O on `SPSCRingBuffer` read/write and `AudioGraph.render` / `AudioNode.process`.
- **Versatility:** Polymer core (`PolymerBase`, `PolymerText`, `PolymerRender`, `PolymerGPU`, `PolymerUI`, `PolymerApp`, `PolymerAudio`) is style-agnostic; `pgr` is a built-in `PolymerDesign.Theme` preset with opt-in `DesignLint` rules.
- **No external dependencies / stdlib only:** No `Foundation` anywhere; `#if os(...)` and OS imports live only inside platform/GPU/audio backends and the `Platform.install` entry point.

## Order of Work (next up)

1. **OS Window & GPU Backends:**
   - `PolymerPlatformWindows` windowing + `PolymerGPUD3D12` (Win32, DPI, input, DWM glass, DXGI refresh pacing).
   - `PolymerPlatformMac` windowing + `PolymerGPUMetal` (AppKit host view + Metal layer).
2. **`PolymerAudio` Expansion & Output Backends:**
   - Pure-Swift ALAC and MP3 decoders, gapless read-ahead playback controller, WASAPI (Windows) and CoreAudio (macOS) output backends.
3. **`PolymerText` Extras:**
   - GDEF mark-skipping, CFF2/variable fonts, colour emoji, UAX #14 line breaking, font fallback, HarfBuzz adapter for complex scripts.
4. **i2s on Polymer:**
   - `I2SCore` on `PolymerBase`/`PolymerPlatform` + i2s Albums page using `PolymerUI`, `PolymerDesign` (`Theme.pgr`), `PolymerApp`, and `PolymerAudio`.

## Decisions Log

- **Module dependency DAG (2026-11-23):** `PolymerGPU` depends on `PolymerBase`/`PolymerText`/`PolymerRender`; `PolymerApp` depends on `PolymerUI`+`PolymerPlatform`; `PolymerDesign` depends on `PolymerApp`+`PolymerUI` so `PolymerContextMenu` and `CustomizeState` wire directly to `CommandRegistry` and `SettingsStore`; `PolymerAudio` depends only on `PolymerBase`.
- **Style & versatility (2026-11-23):** Swappable `Theme` system (`pgr`, `dark`, `light`, custom derivation via `.with(...)`) with opt-in `DesignLint` rules.
- **Resolved defaults (2026-11-23):** Hairlines default to 1 physical pixel (`hairlineWidth == 0` -> `1 / scale`); text frames rounded up to whole pixels with pixel-snapped baselines and fractional glyph x; focus ring shown on keyboard/programmatic focus via `Theme.focusRing`; scroll indicators configured via `.scrollIndicators(_:)`; Customize anchors on `#id` then `Node.stablePath`; macOS 15 floor kept for `Synchronization` `Mutex`/`Atomic`.
- **Earlier key decisions:** Pure Swift stdlib only (no Foundation); own text parser/rasteriser + HarfBuzz only for complex scripts; own PNG/JSON/zlib/WAV/AIFF/FLAC/ALAC/MP3; `@MainActor` `View`/`ViewBuilder`; sRGB-encoded blending; `RenderImage` O(1) atomic token; `.opacity(_:)` per-leaf; deterministic `ViewTree.tick(dt)` animations; own headless `polymer check` runner.

## Platform Notes

- **Windows PC:** Swift 6.4.2 + VS Build Tools (`%LOCALAPPDATA%\Programs\Swift`). No symlink privilege (use `Tools/check.sh` or `swift build --show-bin-path`). No Python; use shell/Swift. GPG key `8FDBF5E546CF3D68`.
- **Linux:** Swift 6.4.3 runs all 52 headless checks via `PolymerPlatformLinux` (`bash Tools/check.sh release`).
- **Mac side (deferred to Mac session):** Compile `PolymerPlatformMac`, build `PolymerGPUMetal` + AppKit host + CoreAudio, verify bit-identical headless PNGs, and add mid-grey/coloured/no-`liga`/wrapped cases to `Tools/Reference/coretext_reference.swift` to regenerate `Tests/Reference/Text`.
