# Status

Updated 2026-11-26. Debug and release both pass 97 framework checks + 8 tool checks on Windows with zero warnings. CoreText parity holds at 1.122/255 mean. Added PolymerText extras (GDEF, UAX#14, fallback, variable fonts, COLR/CPAL, 1/4-px GlyphCache quantization), PolymerAudio extras (ALAC, AIFF, 64-bit DSP, MP4/ReplayGain metadata), PolymerUI/Design polish (ViewTree.record, ScrollViewReader + PScrollBar, onDisappear + CommandRegistry unmount, theme-driven PanelLook/TextInputLook, CustomizeModel size persistence), and CLI tooling (polymer diff, polymer bench, --customize, design.glassContrast).

This page is made from `Docs/status.json` by `polymer status --write`; change that file, not this one.

## Done

- **Text**: Polymer reads fonts and draws text itself (CoreText mean 1.122/255), with GDEF, UAX#14 line breaking, fallback chains, variable fonts, COLR/CPAL color emoji, and optional 1/4-px GlyphCache quantization.
- **Drawing**: Shapes, images (PNG and JPEG), blur and glass, drawn on the processor and on the graphics card with the same result, plus automated WCAG contrast-on-glass checks (DESIGN 11.4).
- **Views and layout**: Stacks (including Spacer minLength), grids, lists of any length, ScrollViewReader + ScrollViewProxy, .allowsHitTesting, .onDisappear, PointerStyle, written the same way as Apple's SwiftUI.
- **Input**: Clicks, double and triple clicks, dragging, keyboard, text fields (including Ctrl+Y redo), right-click & keyboard context menus, popovers, sheets (no auto-focus), and keyboard shortcuts.
- **Animation**: Smooth movement, fading and springs.
- **Accessibility**: Every screen can describe itself, the way a screen reader sees it.
- **Real windows**: Polymer opens real windows on Windows, drawn by the graphics card via ViewTree.record() without CPU rasterization, with system clipboard and IME.
- **Tools for agents**: polymer render, describe, diff, bench (release layout+record p50 0.03 ms, software raster p50 8.68 ms), --customize, check, check-tools, status, log, activity, help.

## In progress

- **Design system**: The pgr look as ready-made parts wired to theme tokens (PanelLook/TextInputLook, live PScrollBar, CommandRegistry unmount cleanup, CustomizeModel width/height persistence). Light-mode Material presets still need owner sign-off.
- **Audio engine**: Pure-Swift WAV, FLAC, MP3, AIFF/AIFC, ALAC/M4A with tags/cover art/ReplayGain, 64-bit DSP (EQ, BS.1770 loudness, true peak, limiter, crossfader, crossfeed, dither), and gapless playback. WASAPI output still needs live-speaker verification.
- **Windows integration**: Screen readers in real windows, wiring PointerStyle to Win32 cursor shapes, and keyboard context menu hook in Win32Window.

## Next

- **The i2s Albums page**: The first real screen of the music player, built on Polymer.
- **Playback end to end**: Play music in i2s through the speakers, checked against real MP3 files.
- **Mac**: Compile and check the Mac parts on a Mac, and draw and play sound there.
- **Apps in the polymer command**: Let the command draw and drive an app's own screens, not only the samples.

## Waiting for the owner

- **Look of the design system**: Please approve or change the proposed look: blue accent, three dark greys, square corners, solid panels instead of glass, a thin blue focus outline, and the control, row, toolbar and sidebar sizes (plus light-mode Material presets).
- **How menus behave**: Right-click menus open as soon as the button is pressed (as on a Mac), at the pixel under the pointer. Say if you prefer them on release (as on Windows).
- **Look of other new parts**: Menus, popovers, sheets, text fields and pressed glass still use placeholder looks; Docs/HANDOFF.md lists the questions.
