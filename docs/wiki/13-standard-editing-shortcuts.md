# Phase 10 — Standard editing commands and shortcuts

> Status: **Remediated; independent re-review pending**
> Owner/builder: `/root`
> Last updated: 2026-09-03
> Parity scope: `C3.F01` plus the keyboard path for `C1.F01`

## User outcome

Duckpad now exposes a native **Edit** menu for Undo, Redo, Cut, Copy, Paste,
Delete, and Select All. **File → New Scratch** creates and activates another
untitled document without asking for a path. Commands operate on the active
tab's editor and preserve each buffer's independent undo history.

The command meanings correspond to the pinned Notepad++ core Edit surface in
[`menuCmdID.h:87-93`](../../notepad-plus-plus/PowerEditor/src/menuCmdID.h#L87-L93)
and [`Notepad_plus.rc:488-495`](../../notepad-plus-plus/PowerEditor/src/Notepad_plus.rc#L488-L495).
Duckpad does not copy the Win32 routing or key model. It maps the same outcomes
to AppKit and the standard macOS modifier conventions.

## Shortcut contract

| Command | Duckpad shortcut | Reason |
| --- | --- | --- |
| New Scratch | `Cmd-N` | Standard macOS new-document command |
| Undo | `Cmd-Z` | Standard macOS undo |
| Redo | `Shift-Cmd-Z` | Standard macOS redo; intentionally replaces Notepad++ `Ctrl-Y` |
| Cut | `Cmd-X` | Standard macOS clipboard command |
| Copy | `Cmd-C` | Standard macOS clipboard command |
| Paste | `Cmd-V` | Standard macOS clipboard command |
| Select All | `Cmd-A` | Standard macOS selection command |
| Delete | editor-native Backspace/Delete | Preserves Scintilla and `NSTextView` direction, selection, and IME handling instead of intercepting a text-input key in the menu |

Automated menu acceptance checks the exact selector, key equivalent, and
modifier mask for these commands. It also rejects any duplicate non-empty
shortcut across the complete native menu. Delete remains visible and validated
but deliberately has no menu key equivalent; the focused editor continues to
own physical Backspace/Delete events.

## Architecture and safety

- Application owns `EditorStandardCommand` and `EditorStandardCommandPort`, a
  platform-neutral intent/capability boundary.
- `ScintillaEditorAdapter` maps that boundary through the narrow Objective-C++
  façade to Scintilla commands. No raw Scintilla symbol enters Presentation.
- `TextViewEditorAdapter` maps the same boundary to native `NSTextView`, its
  per-buffer undo manager, and the macOS text pasteboard.
- `DuckpadWindowController` owns selectors and validation. The same admission
  predicate requires workspace `.ready`, an active buffer, and no termination
  review before any standard command can run.
- Every accepted New Scratch request is registered synchronously. Termination
  closes admission and joins those registered tasks before dirty review and the
  final recovery archive, so a durable tab cannot appear after approval.
- Scintilla clipboard and undo actions use its Cocoa content responder. Active
  Korean marked text therefore disables Undo and is committed/discarded by the
  native Paste path before clipboard insertion.
- The `NSTextView` fallback tracks lifecycle input permission separately from
  revision capacity. At `UInt64.max` the document stays selectable for Copy but
  every mutation command is unavailable and leaves text, revision, and undo
  state unchanged.
- Copy and Select All do not change content. Mutating commands remain subject to
  the existing revision-checked editor callback, recovery scheduling, and input
  disable gates.
- Cmd-N uses the existing serialized workspace transaction and never creates a
  file binding or save prompt.

## Acceptance evidence

- Real Scintilla Cut, Delete, Undo, Redo, and Select All preserve monotonic
  revision ownership and the active buffer's undo history.
- The `NSTextView` fallback executes the same command contract with its owned
  undo stack.
- A blocked termination review makes direct selector calls inert as well as
  disabling menu validation; cancellation restores availability.
- Cmd-N adds and activates exactly one untitled tab after the durable workspace
  transaction.
- The complete native menu contains no duplicate non-empty shortcut chord.

Current post-remediation builder evidence: the three adversarial regressions
pass 3/3; full debug, full release, and empty fresh-scratch debug pass 195/195;
and macOS 13 x86_64 release build/link passes. A production-composition tab
smoke hosts Scintilla and exits after creating 50 wrapped tabs. Fresh builds
report only the pre-existing vendored Scintilla Cocoa deprecations. The first
parallel release run observed one pre-existing viewport-state flake; its
isolated retry and the complete release rerun both passed. Independent
re-review and an exact signed receipt remain mandatory before commit.

## Work log

- **Investigation/implementation:** `/root` directly inspected the versioned
  parity inventory, current menu/editor boundaries, vendored Scintilla Cocoa
  responder behavior, and the pinned Notepad++ Edit commands. No implementation
  subagent was added.
- **macOS decision:** use Command-based native shortcuts and `Shift-Cmd-Z`; do
  not reproduce Windows-only alternate Insert/Delete clipboard chords.
- **Review remediation:** `/root` directly closed P10-01/P10-02/P10-03 with a
  tracked New Scratch termination join, Scintilla Cocoa responder routing for
  marked-text-aware Undo/Paste, and revision-exhausted fallback read-only
  enforcement. No implementation agent was added.
- **Scope boundary:** configurable keybindings, command palette unification,
  advanced line editing, clipboard history, whitespace visualization, README,
  and the ignored Notepad++ checkout remain outside this commit.
- **Repository safety:** the reference checkout was read-only and remains clean.
  Existing unstaged `docs/wiki/04-implementation-foundation.md` and
  `scripts/vendor_scintilla_5_6_6.sh` remain unrelated and preserved.
