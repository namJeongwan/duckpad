# Phase 27 — Editor navigation and display controls

Status: **Content approved; exact receipt pending**

## User-facing result

Duckpad now exposes native editor navigation and display controls without
changing document bytes:

- **Search → Go to Line / Column…** uses `Control-G` and accepts `line` or
  `line:column` with one-based values.
- **Search → Go to UTF-8 Offset…** accepts a zero-based byte offset and rejects
  an offset inside a multibyte Unicode scalar.
- **View → Show Whitespace** and **Show Line Endings** are independent toggles.
- **View → Zoom In / Zoom Out / Actual Size** use `Command-+`, `Command--`, and
  `Command-0`, with a bounded Scintilla zoom range of `-10...20`.

The commands are also discoverable through the existing command palette,
because the palette consumes the validated native menu rather than a parallel
registry.

## State and authority

`EditorNavigationPort` owns one-based line/column and UTF-8-boundary navigation.
The Objective-C++ facade translates those intents to Scintilla messages and
does not expose raw engine handles. A navigation sheet captures both the active
`BufferID` and an opaque pane context. Submitting after the user switches tabs
is a no-op, while a split-pane submission moves and refocuses the exact pane
that opened the sheet even though the sheet temporarily owns first responder.

`EditorDisplayOptionsPort` owns whitespace, EOL, and zoom state. Each Scintilla
pane has its own display state. Primary and secondary split-pane values are
stored in the versioned recovery view state, clamped during decode, restored on
relaunch, and kept outside document revision, dirty state, and undo history.
Legacy archives omit the new keys and decode to hidden whitespace/EOL at actual
size. The `NSTextView` fallback preserves the independent option state for
isolated Presentation tests, but AppKit's single invisible-character flag makes
its visual rendering a combined approximation. Production composition remains
Scintilla and renders whitespace and EOL independently.

## Validation

- Debug modules: **353/353 PASS** — Application 114, Domain 14,
  Infrastructure 66, Editor 51, Presentation 108. Presentation tests ran in
  isolated helpers and passed 108/108.
- Release modules: **353/353 PASS** with the same target counts and isolated
  Presentation result.
- The known macOS 26.5 long-lived AppKit helper can still receive SIGSEGV while
  unrelated private windows retire concurrently; no exact isolated test
  failed.
- Unicode navigation proves one-based line/column movement across Korean and
  emoji text, valid UTF-8 boundaries, rejection of interior byte offsets,
  unchanged revision, and invalid-line rejection.
- Recovery tests prove whitespace, EOL, and zoom round-trip for primary state;
  schema tests prove bounded values and legacy defaults.
- Presentation and adapter tests prove input parsing, exact shortcuts with
  global collision freedom, checked menu state, zoom bounds, stale-panel
  `BufferID` rejection, and split-pane navigation/focus affinity.
- A fresh native packaged app passed static signature/resource/entitlement
  verification and LaunchServices tab smoke with 50 tabs wrapping across 7
  rows.

## Scope boundary

This slice completes the navigation/zoom/visible-character gaps from roadmap
Phase 4. It does not claim the final 90% parity release gate. Macros remain
excluded by product decision. README, the ignored Notepad++ checkout, the
user-owned Phase 1 foundation edit, and the untracked Scintilla vendor script
remain outside this change.

## Agent work log

- **Agent/role:** `/root`, direct implementation and verification.
- **Date:** 2026-09-04.
- **Implemented:** typed navigation/display ports, recovery-compatible view
  schema, narrow Scintilla facade, fallback adapter, native sheets, validated
  menu commands and shortcuts.
- **Verification:** Debug/Release 353/353 by module and isolated Presentation
  helpers, fresh native bundle verification, and LaunchServices tab smoke.
- **Next gate:** independent exact-candidate review, signed receipt, verified
  local commit, post-commit audit, and push to `origin/main`.
