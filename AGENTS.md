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
  Commits are not signed (owner decision, 2026-11-28; `commit.gpgsign` is
  off). Commit messages describe behaviour.
- **Before each push:** `swift build` and the checks pass on the OS you
  are on.
- **Ask the owner only when truly blocked.** Otherwise decide by the
  principles above and note the decision in `Docs/HANDOFF.md`.
  Design-visible decisions (look, feel, layout) go to the owner first.

## Sessions and handoff

- **Work runs on the owner's Windows PC.** Every session works there,
  shared code included, and every session it starts stays there (start it
  locally on that machine). Mac-only steps (the Mac backends, refreshing the
  CoreText reference images) are listed in `Docs/HANDOFF.md` under "Mac
  side" for a later Mac session.
- Keep `Docs/HANDOFF.md` current: what is done, what is in progress,
  decisions made, what comes next.
- When your context gets high, update `Docs/HANDOFF.md`, commit and push,
  then start a new session on the same machine with a short brief pointing
  at this file and the handoff, and stop. Do not wait to be told.
- Text quality is tuned against the CoreText images in
  `Tests/Reference/Text` (made on a Mac by
  `Tools/Reference/coretext_reference.swift`; `manifest.json` gives font,
  size, scale, colours, origin and baseline for each). Polymer's output
  for the same inputs must match them closely on every OS.
- **Tell the owner what you did.** After each piece of work, run
  `polymer log "one plain sentence"` (name yourself with `--by` or
  `POLYMER_AGENT`); it adds a line to `Docs/ACTIVITY.md`, which is never
  edited by hand. When something is done, started or waiting for the
  owner, update `Docs/status.json` and run `polymer status --write`. Both
  are for the owner: plain words, no code names. Building an app on
  Polymer: `Docs/AGENT_GUIDE.md`.
