# Handoff

Keep this file short and current (no session essays; history lives in git log).
Design: `Docs/DESIGN.md`. SwiftUI deltas: `Docs/DIFFERENCES.md`.

## Status (2026-11-23, session 5)

- Builds cleanly in debug and release with zero warnings (`bash Tools/check.sh [debug|release] [filter]`).
- **34 checks pass** (`base`, `text`, `render`, `ui`). CoreText reference match: mean error **1.122/255**, worst **1.930/255** (regression bound 1.2) — identical on Windows and Linux.
- Modules in `Package.swift`: `PolymerBase`, `PolymerPlatform` (`…Windows`, `…Mac`, `…Linux`), `PolymerText`, `PolymerRender`, `PolymerUI`, `Polymer`, `PolymerChecks`, `PolymerTools` (`polymer` CLI).

## Implemented

- **`PolymerBase`**: `Point`, `Size`, `Rect`, `EdgeInsets`, `PixelRect`, `AffineTransform`, `Path` (rect, roundedRect, ellipseIn, flattening), `Color` (exact sRGB + pure-Swift `Math.log/exp/sin/cos`), `StableID`/`StableHasher` (pinned), `Logger`, `ByteReader`, strict deterministic `JSON`, zlib inflate/deflate, CRC-32, Adler-32.
- **`PolymerPlatform`**: `FileSystem` + `Process` installed once via `Platform.install(...)` in the entry point. Win32 UTF-16 (`…Windows`), POSIX Glibc (`…Linux`, verified), POSIX Darwin (`…Mac`, updated for Swift 6, not yet compiled on macOS).
- **`PolymerText`**: OpenType (`glyf` simple/composite, CFF Type 2 charstrings/subrs/flex/CID), GPOS pair kerning + `kern` fallback, GSUB (`ccmp locl rlig liga clig calt rclt`), exact analytic rasteriser with Mac-style stem darkening (`growth = min(0.6, ppem * (0.0118 + 0.0191 * L))`, vertical growth upward only, plain sRGB source-over), line/paragraph wrapping (`lineLimit`, height truncation + ellipsis), fractional-offset `GlyphCache`.
- **`PolymerRender`**: `Bitmap`, `RenderImage` (O(1) atomic-token identity), own PNG codec, CPU `Canvas` (rects, paths, glyphs, nearest/premultiplied-bilinear images, 3-pass separable Gaussian `backdropBlur`, in-place `scroll` blit, clipping), `DisplayList` with `withOpacity`, blur-safe damage expansion, and `damagePlan` scroll-blit diffing.
- **`PolymerUI`**: Retained `Node` tree (`reconcile`), `HostNode` (`@State`, `@Binding`, `@Bindable`, `@Environment`, `@Observable`, `Equatable` body skipping, `Epoch`-based observation cleanup, `Mirror` cached per type), `ViewBuilder`/`Group`/`ForEach`/`.id(_:)`, `Text`, `Color`, `Rectangle`, `RoundedRectangle`, `Circle`, `Capsule`, `Path`, `Image` (`.resizable()`, `.interpolation`), `BackdropBlur`, `Spacer`, `Divider`, `HStack`/`VStack`/`ZStack`, `Button`/`ButtonStyle` (`isPressed`), `ScrollView` (vertical/horizontal, scroll-into-view on focus), `LazyVStack`/`LazyHStack` (state-preserving, 20k-row tested), focus (`@FocusState`, `.focusable()`, `.onKeyPress`, Tab/Shift-Tab), pointer/hover/`.disabled(_:)`, modifiers (`padding`, `frame`, `aspectRatio`, `background`, `overlay`, `border`, `clipped`, `opacity`, `offset`, `font`, `foregroundStyle`, `lineLimit`, `multilineTextAlignment`, `environment`, `onTapGesture`, `onChange`, `accessibilityIdentifier`, `animation(_:value:)`), deterministic `Animation` (linear, cubic Bézier, analytical spring) + `withAnimation` + `ScrollPhysics` (`ViewTree.tick(_:)`, `hasActiveAnimations`, `fling`), `Node.stablePath`/`stableID`, `ImageRenderer`.
- **`PolymerTools`**: `polymer check`, `render`, `tree` (steps: `--click`, `--click-id`, `--scroll`, `--key`, `--hover`, `--press`, `--scale`), `zoom`. Sample screens: `albums`, `counter`, `list`, `library`.

## Key Architectural Invariants

- **Drawing & damage:** Views record a `DisplayList`; `Canvas` (and future GPU backends) replay it. `ViewTree.render()` applies `ScrollBlit`s in-place, then clears/redraws only `damage` rects; partial redraws must stay bit-for-bit identical to full draws. Any damage touching a `backdropBlur` expands to that blur's full bounds.
- **Node hierarchy:** Nodes that affect drawing/clipping/transforms (`ClipNode`, `OpacityNode`, `OffsetNode`, `PaddingNode`) inherit from `Node` (not `PassthroughNode`), because `StackNode` flattens `PassthroughNode`s.
- **Lazy stacks:** `ResolveContext.lazyItems` propagates only through transparent wrappers (`childrenAreLazy`). Built elements stay alive off-screen so state survives scrolling; unmeasured rows use the running average.
- **Animation:** `withAnimation` captures the active `Animation?` synchronously inside `InvalidationQueue.push`; `.opacity` and `.offset` step via `ViewTree.tick(dt)` with zero body evaluations and zero relayout.
- **Versatility (owner directive, 2026-11-23):** Polymer's core (`PolymerUI`, `PolymerRender`, `PolymerText`, `PolymerApp`, `PolymerGPU`, `PolymerAudio`) is **style-agnostic** — creators can build any visual aesthetic (dark/light, brutalist, glassmorphic, rounded, gradients, shadows, custom themes). `PolymerDesign` provides a composable `Theme` system where the **pgr look** is a built-in house preset (and pgr design-lint rules are opt-in per app/preset, not a framework-wide lock-in).

## Order of Work (next up)

1. **`PolymerText` + `PolymerUI` core completion:**
   - `TextBuffer` / `TextEditorState` (grapheme cursor, selection, undo/redo, IME composition span) + `TextField` / `TextEditor`.
   - `LazyVGrid` / `LazyHGrid`, `DragGesture` (sliders/scrubbers), `.clipShape(_:)`, `.zIndex(_:)`, `.layoutPriority(_:)`, `AccessibilityNode` tree export.
   - `PolymerText` extras: GDEF mark-skipping, CFF2/variable fonts, colour emoji, UAX #14 line breaking, font fallback, HarfBuzz adapter for complex scripts.
2. **`PolymerApp` + `PolymerTools`:**
   - Unified `Command` / `CommandRegistry` (menus, buttons, shortcuts, context menus), `.contextMenu` + secondary-click routing, overlay/popover layer, JSON settings store, screen registry, `polymer describe`.
3. **`PolymerDesign`:**
   - Composable `Theme` tokens (colors, radii, borders, glass, typography, spacing, icons, focus ring, scroll indicators) with `pgr` as a built-in preset + opt-in pgr style checks.
   - Styled components (`Button`, `TextField`, `Slider`, `Toggle`, `ScrollBar`, `ContextMenu`, `Popover`, `Panel`, keyboard focus ring) and built-in **Customize** engine keyed by `Node.stablePath` / `#id`.
4. **`PolymerGPU` + OS window backends:**
   - Shared `PolymerGPU` interface, glyph atlas, `DisplayList` batch compiler (verified against CPU `Canvas`).
   - `PolymerPlatformWindows` + `PolymerGPUD3D12` (Win32, DPI, input, DWM glass, DXGI refresh pacing).
   - `PolymerPlatformMac` + `PolymerGPUMetal` (AppKit host view + Metal layer).
5. **`PolymerAudio` & i2s:**
   - Shared 64-bit float real-time audio engine (lock-free SPSC queues, gapless decode/read-ahead, WAV/AIFF/FLAC/ALAC/MP3 decoders, sinc resampler, TPDF dither, EQ, ReplayGain/limiter, crossfade/crossfeed, null + THD+N checks), WASAPI & CoreAudio backends, then `I2SCore` + i2s Albums page.

## Decisions Log

- **Style & versatility (2026-11-23):** Polymer is versatile for any creator's style; `PolymerDesign` uses a swappable `Theme` system with `pgr` as a preset and opt-in design-lint rules.
- **Resolved open defaults (2026-11-23):**
  - **Hairlines (`Divider`):** 1 physical pixel (`1 / scale`) by default via `.hairline` / theme token (or explicit point thickness when specified).
  - **Text alignment:** Keep frames rounded up to whole pixels, baselines vertically pixel-snapped, glyph x fractional (matches CoreText best).
  - **Focus ring:** Shown on keyboard/programmatic focus (not mouse click on buttons); styled via active `Theme.focusRing` (crisp accent outline by default).
  - **Scroll bars:** Theme-styled overlay indicators drawn on overflow, configurable via `.scrollIndicators(.automatic/.visible/.hidden)`.
  - **Customize addressing:** Uses `.accessibilityIdentifier(_:)` (`#id`) + `Node.stablePath` / `StableID`, anchoring on `#id` when present so sibling edits don't break customizations.
  - **macOS floor:** Keep macOS 15 (`Synchronization` `Mutex`/`Atomic`); move behind `PolymerPlatform` only if older macOS support is later required.
- **Earlier key decisions:** Pure Swift stdlib only (no Foundation); own text parser/rasteriser (no FreeType) + HarfBuzz only for complex scripts; own PNG/JSON/zlib/MP3/FLAC/ALAC/WAV/AIFF; `@MainActor` `View`/`ViewBuilder`; sRGB-encoded blending matching CoreGraphics; `RenderImage` O(1) atomic token; `.opacity(_:)` per-leaf via `DisplayList.withOpacity`; deterministic `ViewTree.tick(dt)` animations; own headless `polymer check` runner.

## Platform Notes

- **Windows PC:** Swift 6.4.2 + VS Build Tools (`%LOCALAPPDATA%\Programs\Swift`). No symlink privilege (use `Tools/check.sh` or `swift build --show-bin-path`). No Python; use shell/Swift. GPG key `8FDBF5E546CF3D68` (test: `echo x | gpg --pinentry-mode error --clearsign -u 8FDBF5E546CF3D68`; unlock in PowerShell: `"x" | & "C:\Program Files\GnuPG\bin\gpg.exe" --clearsign -u 8FDBF5E546CF3D68 | Out-Null`).
- **Linux:** Swift 6.3+ runs all headless checks via `PolymerPlatformLinux` (`bash Tools/check.sh release`).
- **Mac side (deferred to Mac session):** Compile `PolymerPlatformMac`, build `PolymerGPUMetal` + AppKit host + CoreAudio, verify bit-identical headless PNGs, and add mid-grey/coloured/no-`liga`/wrapped cases to `Tools/Reference/coretext_reference.swift` to regenerate `Tests/Reference/Text`.
