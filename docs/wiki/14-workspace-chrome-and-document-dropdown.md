# Phase 11 — Workspace Chrome and Document Dropdown

- **Status:** Approved, committed, audited, and pushed to `origin/main`
- **Owner/agent:** `/root` direct builder
- **Last updated:** 2026-09-03
- **Related:** [Multiline tab workspace](08-multiline-tabs.md), [Language support](10-language-support.md), [Standard editing shortcuts](13-standard-editing-shortcuts.md)

## Goal

The first functional UI exposed the editor engine, but it did not yet present a
cohesive macOS workspace. A hidden persistence banner still reserved 36 points,
the tab row started at 42 points, status labels floated over the editor, the
line-number gutter ignored the dark palette, and open documents or language
selection were discoverable only through menus.

This phase makes those existing capabilities visible without adding a document
organizer or changing scratch-first behavior.

## Implemented interface

- The empty persistence banner now collapses to zero height and expands only
  when an actionable persistence failure is presented.
- The multiline tab row is 34 points high with 28-point tabs, tighter spacing,
  restrained semantic colors, a two-point active indicator, SF Symbol pin/close
  controls, and close affordances shown only for the active or hovered tab.
- The right side of the tab strip contains native New Scratch and Open Documents
  buttons. Phase 11 originally used a flat native menu with active, edited,
  pinned/file/scratch and path state. [Phase 12](15-searchable-document-switcher.md)
  supersedes that menu with the current searchable keyboard-first popover while
  preserving stable-`TabID` routing.
- A real 24-point status bar owns extension and language controls outside the
  editor frame. Extension status opens the manager. Language status opens a
  grouped native dropdown containing Automatic Detection and every bundled
  language; the current automatic/manual choice is checked.
- Scintilla now styles the line-number and fold margins for light/dark palettes,
  uses a smaller coherent gutter, adds editor text padding and line spacing, and
  gives the caret line a low-alpha highlight. The `NSTextView` fallback uses
  native semantic text, background, caret, and selection colors.
- The bundled application icon now uses the replacement Duckpad duck-and-pencil
  artwork supplied on 2026-09-03. Its outside canvas is transparent, and the
  artwork is centered at 84% scale to match the visual footprint of neighboring
  macOS Dock icons. The standard ten PNG representations are packaged into the
  runtime `.icns`.

Untitled arbitrary text remains Plain Text by design. Saving a recognized file,
pasting content with a supported detector signature, or choosing a language in
the new status dropdown activates the existing Lexilla syntax styling.

## Architecture and performance

`DocumentSwitcherButton` is a Presentation adapter over immutable
`TabSnapshot` values. It forwards only `TabID`; workspace mutation remains in
`ScratchWorkspaceUseCase`. Structural tab changes rebuild its native menu, while
ordinary buffer edits update exactly one menu item. This preserves the existing
500-tab hot-path contract and avoids rebuilding hundreds of document rows on
every keystroke. Active-tab changes configure only the previous/current pair,
and explicit inspection metrics verify the same constant work at 500 and 5,000
open tabs.

Termination admission is acquired synchronously by the shared native
coordinator before its async review task begins. It disables tab, document,
language, and extension chrome, guards queued actions, and remains closed across
later ready-state publications. Only a denied termination restores interaction;
an approved termination stays locked through application exit.

Palette work remains in the Scintilla Objective-C++ boundary. No AppKit or
Scintilla types moved into Domain or Application, and UI changes do not mutate
text revision, undo history, dirty state, file binding, or recovery data.

## Validation

- Focused document-dropdown, 500/5,000-tab constant-work, termination-admission,
  compact-chrome, Scintilla palette, and exact icon representation/alpha/ICNS
  round-trip tests pass. The 16/32-point 1x legacy `ic04`/`ic05` chunks have a
  bounded `iconutil` edge quantization; all modern PNG chunks are pixel exact.
- Debug and Release full suites pass with 200 tests each. An earlier parallel
  Debug run exposed one pre-existing persistence timing flake; its isolated test
  and clean full rerun passed.
- A clean macOS 13 x86_64 release build/link and the production Scintilla
  50-tab multiline smoke pass. Exact independent review remains required before
  candidate freeze.
- README files, the ignored Notepad++ checkout, and the pre-existing unstaged
  implementation-foundation/vendor-script files are outside this change.

## Independent review remediation

- P11-01: removed the full document-menu state scan and the tab-strip selection
  scan from the ordinary edit path. One edit configures one authoritative item;
  active change configures at most two.
- P11-02: moved termination UI admission ahead of task scheduling, preserved the
  lock through ready events, guarded direct/queued chrome actions, and restored
  controls only after a denied review.
- P11-03: expanded icon coverage to all four corners, centered 84% alpha bounds,
  and every `iconutil`-extracted representation with exact or platform-bounded
  RGBA comparison according to ICNS chunk encoding.

## Commit evidence

- Candidate ID: `9e371fd9103b5106e785db6ec23800b8f073b7b5dc3f1e3869ce576ba5370938`
- Independent review: approved — 0 Blocker, 0 Major, 0 Minor
- Local receipt SHA-256: `60bcabb07d116c86e1a5095ecc8aace53b1fb31abc46ed43d11487bc4abd4637`
- Commit: `fff6c1cc1b3b27ab28f98f45c8ade92b16d46d08`
- Delivery: `origin/main`
