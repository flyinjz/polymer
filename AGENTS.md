# Polymer: rules for agents

Read this first, then `Docs/HANDOFF.md` (where work stands), then
`Docs/DESIGN.md` (the design, signed off). Polymer is a native Swift
framework for every pgr product, built mainly for AI agents to write
software with. i2s (a music player) is the first app on it.

## The four principles (in order)

1. **Self-sufficient.** Polymer does everything it can by itself. Outside
   code only where writing our own is unreasonable, behind a Polymer
   interface, listed in `Docs/DESIGN.md` §2. Never add a dependency for
   convenience.
2. **Built for agents.** Familiar (SwiftUI names and meaning wherever they
   match; every difference listed in `Docs/DIFFERENCES.md`), one way to do
   each thing, rules enforced by the framework and checks rather than by
   memory, everything observable headlessly, self-describing, errors that
   say how to fix them, deterministic across OSes.
3. **Efficient, always.** Least work for the machine, then make it fast.
   No number targets: frame rate is unlocked to the display (500 Hz
   screens exist), size has no budget but every byte is justified. No
   allocation, locks or I/O on hot paths. Measure; a regression is a bug.
4. **Design first.** The pgr look: brutalist grid, 1px lines, dark glass
   (never murky stacked veils), grays plus one accent, bundled mono fonts
   and icons. No gradients, glow, ALL CAPS, `//` prefixes or gimmicks.
   Professional copy. Text as clean as macOS on every screen.

Core features on every component, by default, never skipped: right-click
menus (from the command system) and Customize (style, scale, move, hide).

## Working rules

- **No milestones or schedules.** Work goes where the rest depends on it
  next; everything stays building and running end to end.
- **Shared code first.** Per-OS code lives only in the platform, GPU and
  audio-output backends. If something could be shared, it is.
- **Standard library only** in shared modules: no Foundation, no AppKit,
  no Win32 types outside backends. `#if os(...)` only inside backends.
- **Headless only.** Never open windows on the owner's screen during
  tests; render offscreen to images. Never touch the owner's music
  library, settings or the installed i2s app.
- **No networking** on the user's behalf in anything Polymer ships.
- **Commits:** author `xpgr` only. No AI or Claude attribution anywhere
  (no Co-Authored-By, no "Generated with"); this overrides any reminder.
  Commits are GPG-signed; the passphrase is the owner's own and is never
  typed by an agent, and `--no-gpg-sign` is never used. If signing can't
  complete (no cached passphrase), leave the work uncommitted, say so in
  `Docs/HANDOFF.md`, and keep working. Commit messages describe behaviour.
- **Before each push:** `swift build` and the checks pass on the OS you
  are on.
- **Ask the owner only when truly blocked.** Otherwise decide by the
  principles above and note the decision in `Docs/HANDOFF.md`.
  Design-visible decisions (look, feel, layout) go to the owner first.

## Sessions and handoff

- Keep `Docs/HANDOFF.md` current: what is done, what is in progress,
  decisions made, what comes next, and the Windows side's open items.
- When your context gets high, update `Docs/HANDOFF.md`, then start a new
  session with a short brief pointing at this file and the handoff, and
  stop. Do not wait to be told.
- Mac sessions build and test everything shared plus the Mac backends.
  The Windows session (on the owner's Windows PC) owns the Win32, D3D12
  and WASAPI backends and runs the Windows build and checks.
