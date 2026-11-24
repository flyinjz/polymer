# Handoff

Keep this file short and current (no session essays; history lives in git log).
Design: `Docs/DESIGN.md`. SwiftUI deltas: `Docs/DIFFERENCES.md`.

## Status (2026-11-24, session 6b)

- Builds cleanly in debug and release with zero warnings (`swift build -Xswiftc -warnings-as-errors`, `bash Tools/check.sh release`).
- **61 checks pass** across `base`, `text`, `render`, `ui`, `app`, `design`, `audio`, `gpu`, and `platform`. CoreText reference match: mean error **1.122/255**, worst **1.930/255** (regression bound 1.2) — identical on Windows and Linux.
- Pushed to both `cursor/polymer-core-design-audio-gpu-ea0b` and `main`.
- Modules in `Package.swift`: `PolymerBase`, `PolymerPlatform` (`…Windows`, `…Mac`, `…Linux`), `PolymerText`, `PolymerRender`, `PolymerGPU`, `PolymerUI`, `PolymerApp`, `PolymerDesign`, `PolymerAudio`, `Polymer`, `PolymerChecks`, `PolymerTools` (`polymer` CLI). Polymer stays strictly framework-only (no app code such as i2s inside Polymer binaries).

## Implemented

- **`PolymerBase`**: `Point`, `Size`, `Rect`, `EdgeInsets`, `PixelRect`, `AffineTransform`, `Path` (rect, roundedRect, ellipseIn, flattening), `Color` (exact sRGB + pure-Swift `Math.log/exp/sin/cos`), `StableID`/`StableHasher` (pinned), `Logger`, `ByteReader`, strict deterministic `JSON`, zlib inflate/deflate, CRC-32, Adler-32.
- **`PolymerPlatform`**: `FileSystem`, `Process`, `WindowRunner` (`WindowEvent`, `WindowOptions`, `FrameBuffer`, `HeadlessWindowRunner`), `Clipboard`, and `AudioOutputBackend` installed via `Platform.install(...)` + `Platform.installDesktop(...)`.
  - `…Windows`: Win32 UTF-16 files/process, `WindowsWindowRunner` (`CreateWindowExW`, DPI scaling, DWM dark title bar, `StretchDIBits` BGRA presentation, mouse/right-click/wheel/keyboard/resize/timer), `WindowsClipboard` (written, ready to compile/verify on Windows PC).
  - `…Mac`: POSIX files/process, `MacWindowRunner` (`NSWindow` + `NSView`/`CGImage` presentation + input loop), `MacClipboard` (written, deferred to Mac session).
  - `…Linux`: POSIX Glibc files/process, `LinuxWindowRunner` (headless scripted mode), `LinuxClipboard` (verified on Linux).
- **`PolymerText`**: OpenType (`glyf`, CFF Type 2/subrs/flex/CID), `GDEFTable` (`GlyphClassDef`, `MarkAttachClassDef`, `MarkGlyphSetsDef`) wired into GSUB `LookupFlag` mark-skipping, GPOS pair kerning + `kern`, GSUB (`ccmp locl rlig liga clig calt rclt`), pure-Swift UAX #14 `UnicodeLineBreak` integrated into `TextLayout.lines`, `FontFallbackChain`, variable fonts (`fvar`/`avar`/`gvar` + IUP interpolation), exact analytic rasteriser with Mac-style stem darkening, `GlyphCache`, and `TextBuffer`/`TextEditorState` (grapheme cursor, directional selection, word/line nav, coalescing undo/redo, IME `MarkedText`, caret hit-testing).
- **`PolymerRender`**: `Bitmap`, `RenderImage` (O(1) atomic-token identity), own PNG codec, CPU `Canvas` (rects, paths, glyphs, nearest/premultiplied-bilinear images, 3-pass separable Gaussian `backdropBlur`, in-place `scroll` blit, clipping), `DisplayList` with `withOpacity`, blur-safe damage expansion, and `damagePlan` scroll-blit diffing.
- **`PolymerGPU`**: Backend-agnostic `GPUDevice`/`GPUBuffer`/`GPUTexture`/`GPUPipeline`/`GPUCommandEncoder` + headless `RecordingGPUDevice`, skyline `GlyphAtlas` packer (`r8Unorm`, 1px padding), `DisplayListCompiler`, unified Metal MSL & D3D12 HLSL shader sources (`GPUShaderSources`), and `SoftwareGPURasterizer` verified at `0.04/255` mean error against CPU `Canvas`.
- **`PolymerUI`**: Retained `Node` tree, `HostNode` (`@State`, `@Binding`, `@Bindable`, `@Environment`, `@Observable`, `Equatable` skipping, `Epoch` cleanup), `ViewBuilder`/`Group`/`ForEach`/`.id(_:)`, `Text`, `TextField`, `TextEditor`, `Color`, `Shape` (`Rectangle`, `RoundedRectangle`, `Circle`, `Capsule`, `Path`), `Image`, `BackdropBlur`, `Spacer`, `Divider`, `HStack`/`VStack`/`ZStack`, `Button`/`ButtonStyle`, `ScrollView`, `LazyVStack`/`LazyHStack`, `LazyVGrid`/`LazyHGrid` (`GridItem`), `DragGesture`, focus (`@FocusState`, `.focusable()`, `.onKeyPress`, Tab/Shift-Tab), pointer/hover/`.disabled(_:)`, modifiers (`padding`, `frame`, `aspectRatio`, `background`, `overlay`, `border`, `clipped`, `clipShape`, `zIndex`, `layoutPriority`, `contextMenu`, `opacity`, `offset`, `font`, `foregroundStyle`, `lineLimit`, `multilineTextAlignment`, `environment`, `onTapGesture`, `onChange`, `accessibilityIdentifier`, `animation(_:value:)`), deterministic `Animation` + `ScrollPhysics` (`ViewTree.tick(_:)`, `fling`), `ViewTree.rightClick`/`secondaryClick`, `AccessibilityNode` export, `Node.stablePath`/`stableID`, `ImageRenderer`.
- **`PolymerApp`**: Unified `Command`/`CommandRegistry` (`KeyShortcut`, categories, groups, shortcut dispatch, JSON description), deterministic JSON `SettingsStore` on `PolymerPlatform.FileSystem`, `WindowConfig`/`Scene`/`WindowGroup`, and `ScreenRegistry`.
- **`PolymerDesign`**: Style-agnostic swappable `Theme` tokens with `Theme.pgr`, `Theme.dark`, and `Theme.light` presets; opt-in `DesignLint`; themed controls (`PolymerButtonStyle`, pill-shaped `PolymerToggle`, drag+click `PolymerSlider`, `PolymerScrollBar`, `PolymerPanel`, `FocusRingModifier`, `PolymerContextMenu`, `HairlineDivider`); and `CustomizeState` keyed by `#id` / `Node.stablePath`.
- **`PolymerAudio`**: Lock-free power-of-two `SPSCRingBuffer` (`Atomic`), 64-bit float zero-allocation `AudioGraph` + metering, pure-Swift WAV, AIFF (80-bit extended rate), FLAC (FIXED/LPC/mid-side/Rice + CRC-8/16), ALAC/M4A (adaptive Golomb-Rice + dynamic FIR LPC + stereo decorrelation, verified bit-exact against FFmpeg), and MPEG-1/2 Layer III MP3 decoders, Kaiser-windowed polyphase `SincResampler` (< -117 dB THD+N), `TPDFDither`, RBJ `BiquadFilter`/`ParametricEQ`, EBU R128 `LoudnessMeter`/ReplayGain, 4x oversampled `TruePeakLimiter`, `Crossfader`, `HeadphoneCrossfeed`, `GaplessPlaybackEngine` (`-200 dB` gapless boundary null), and `AudioMetrics`.
- **`PolymerTools`**: `polymer check`, `render`, `preview <screen>` (live Win32/AppKit interactive window), `tree [--a11y]` (steps: `--click`, `--click-id`, `--right-click`, `--right-click-id`, `--scroll`, `--key`, `--hover`, `--press`, `--scale`), `describe [section] [--json]`, `zoom`. Screens: `albums`, `counter`, `list`, `library`, `design`.

## Next Agent Log (Resume Here)

1. **Windows PC verification & native GPU/audio backends:**
   - Compile & test `PolymerPlatformWindows` (`Win32Window.swift`) on Windows with `polymer preview design`, fix any WinSDK Swift 6 signature quirks if encountered.
   - Implement `PolymerGPUD3D12` (D3D12 device/swapchain/DXGI refresh pacing using `GPUShaderSources.d3d12HLSL` + `DisplayListCompiler`) and WASAPI shared/exclusive `AudioOutputBackend` driving `GaplessPlaybackEngine.renderOutput`.
2. **Mac session (deferred until on macOS):**
   - Compile `PolymerPlatformMac` (`MacPlatform.swift`, `MacWindow.swift`), test `polymer preview design`.
   - Implement `PolymerGPUMetal` (using `GPUShaderSources.metalMSL`) and CoreAudio output backend; verify bit-identical headless PNGs vs Windows/Linux; add mid-grey/coloured/no-`liga`/wrapped cases to `Tools/Reference/coretext_reference.swift`.
3. **`PolymerText` remaining extras:**
   - Colour emoji (`COLR`/`CPAL` or `sbix`/`CBDT`), `CFF2` variable charstrings, and optional HarfBuzz adapter behind Polymer's interface for complex scripts (Arabic/Indic/Thai).
4. **`PolymerRender` / `PolymerUI` polish:**
   - Analytical path alpha-mask clipping for `.clipShape(_:)` in `Canvas` / GPU, native DWM glass/acrylic backdrop polish on Windows, and window-level `Scene` / `App` entry point helper in `PolymerApp`.

## Key Architectural Invariants & Decisions

- **Framework purity:** Polymer ships zero app-specific code (i2s lives in its own repository depending on Polymer as a Swift package).
- **Controls UX (owner directive, 2026-11-24):** `PolymerToggle` switches are always regular rounded pill switches (`Capsule` track + `Circle` thumb) across all themes including `Theme.pgr` (never square switches).
- **Style & versatility:** Polymer core is style-agnostic; `Theme.pgr` is a built-in `PolymerDesign` preset and `DesignLint` rules are strictly opt-in.
- **Standard library only:** Zero `Foundation` anywhere; `#if os(...)` and OS imports live only inside `PolymerPlatform*` / future GPU & audio backends and `Platform.install` in `PolymerTools/main.swift`.
- **Real-time audio:** Zero allocations, zero locks, and zero I/O on `SPSCRingBuffer` read/write, `AudioGraph.render`, `AudioNode.process`, and `GaplessPlaybackEngine.renderOutput`.
- **Drawing & damage:** `ViewTree.render()` applies `ScrollBlit`s in-place and redraws only `damage` rects (bit-identical to full draws); `DisplayListCompiler` + `SoftwareGPURasterizer` verify GPU batch parity against CPU `Canvas`.
