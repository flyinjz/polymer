# Handoff

Current state of the work. Every session updates this before it ends.

## State (2026-11-13)

- Design signed off: `Docs/DESIGN.md`. Nothing built yet.
- All sessions run on the owner's Windows PC (see AGENTS.md).
- CoreText reference images for text tuning: `Tests/Reference/Text`
  (4 fonts, 8 sizes, 1x and 2x, dark and light; fonts in
  `Tests/Fixtures/Fonts`, OFL licenses alongside).
- Repo: `github.com/flyinjz/polymer`, public, plain git, signed commits.
- i2s lives in a separate, encrypted repo (`flyinjz/meimei`, SwiftUI on the
  Mac, a Qt app on Windows that is now frozen). Its shared core (`Core/`:
  library rules, history, equalizer maths, lyrics, Customize state) moves
  onto Polymer's base later as `I2SCore`. Polymer itself must not depend on
  i2s.

## Order of work (dependencies, not a schedule)

1. `Package.swift` with the module layout from `Docs/DESIGN.md` §3; builds
   on macOS and Windows (Swift 6.2). A `polymer` command with `check`.
2. `PolymerBase`: geometry, colour (linear and sRGB), small collections,
   IDs, logging, our own JSON. No Foundation.
3. `PolymerText`: OpenType parsing (TrueType and CFF outlines), the
   analytic-coverage rasteriser, Mac-style rendering (no hinting,
   fractional positioning, stem darkening, gamma-correct blending), and
   a check comparing our output with the CoreText images in
   `Tests/Reference/Text` (`Docs/DESIGN.md` §4).
   Text quality is a headline feature: get this excellent early.
4. `PolymerRender` with a CPU reference renderer for headless images
   (identical on every OS), then `PolymerGPU` (Metal on Mac; D3D12 on
   Windows).
5. `PolymerUI`: views, result builders, observation-based state, layout,
   scrolling, animation; element tree dump and input driving in the
   `polymer` command.
6. `PolymerDesign`: tokens, components, Customize and right-click menus
   built in.
7. `PolymerPlatform` Mac and Windows backends: window, input, glass,
   display refresh pacing (unlocked frame rate).
8. The i2s Albums page on Polymer; then `PolymerAudio`.

## Windows side (where all sessions run)

- Set up: Swift 6.2 toolchain for Windows, `swift build` and the checks
  passing; note any toolchain gaps here.
- Shared modules in the order above, then `PolymerPlatformWindows` (Win32
  window, input, per-monitor DPI and refresh rate, DWM glass),
  `PolymerGPUD3D12`, and WASAPI output.

## Mac side (for a later Mac session)

- `PolymerPlatformMac`, `PolymerGPUMetal`, CoreAudio output.
- Check that headless images match the Windows ones exactly.
- Regenerate `Tests/Reference/Text` if fonts or cases change.

## Decisions log

- 2026-11-13: name Polymer; public repo without encryption; no number
  targets; no milestones; own text rasteriser instead of FreeType; no
  Foundation; MP3 decoder our own.
