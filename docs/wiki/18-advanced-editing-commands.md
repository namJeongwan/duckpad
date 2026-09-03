# Phase 15 — Advanced Editing Commands

- **Status:** Content approved; exact receipt pending
- **Owner/agent:** `/root` direct investigator and builder
- **Last updated:** 2026-09-03
- **Related:** [Standard editing shortcuts](13-standard-editing-shortcuts.md), [Scintilla integration](05-scintilla-integration.md)

## User outcome

Duckpad's native Edit menu now exposes the high-frequency line and text
operations expected from a programmer's scratchpad:

- Duplicate Line (`Command-D`)
- Move Line Up / Down (`Option-Up` / `Option-Down`)
- Delete Line (`Command-Shift-K`)
- Join Lines (`Control-J`)
- Indent / Unindent Line(s)
- Make Uppercase / Make Lowercase
- Trim Trailing Whitespace

Commands without a stable, collision-free macOS convention intentionally have
no default key equivalent. They remain available through the native menu and
macOS menu search. The complete menu is acceptance-tested for duplicate key
equivalents.

## Architecture and mutation safety

Application owns a platform-neutral `EditorCommand` intent and
`EditorCommandPort`. Presentation validates the same command before dispatch,
using the shared ready/active-buffer/no-termination admission boundary.

The production adapter maps advanced commands to a narrow
`DPScintillaEditingCommand`; no raw `SCI_*` message escapes the Objective-C++
facade. Scintilla continues to own live bytes, selection, native undo, and edit
notifications. Every actual insertion/deletion advances the existing UTF-8
revision journal and recovery path. Revision-exhausted or input-disabled
documents reject every mutating advanced command.

Before dispatch, the bridge reserves a conservative whole-command revision
budget of twice the current byte length plus two. This upper-bounds synchronous
native edit notifications for these commands; if the remaining `UInt64`
revision space is smaller, the command is disabled before its first mutation.

The `NSTextView` adapter remains a behaviorally compatible emergency fallback.
Its transformations use UTF-16 ranges only at the AppKit boundary, publish
through the existing UTF-8 incremental edit delegate, and group each command as
one native undo action.

Trim Trailing Whitespace scans line endings inside the native bridge and
applies reverse-order target replacements in one undo group. A non-null empty
buffer is passed for zero-byte Scintilla replacements, satisfying Scintilla's
debug contract without exposing or copying the full document into Swift.

## Validation

- Native acceptance covers duplicate, move, delete, join, case conversion,
  indent/unindent, trailing-space removal, exact UTF-8 text, revision updates,
  and grouped undo.
- Fallback acceptance covers the same transformation families and one-step
  undo behavior.
- Revision exhaustion proves all ten advanced mutations remain inert in both
  adapters.
- AppKit menu acceptance verifies exact selectors, key equivalents, modifier
  masks, and whole-menu shortcut uniqueness.
- Final remediated Debug and Release suites each pass 224/224.

## Independent review remediation

The initial review found three Majors. The current remediation:

- applies the same endpoint-at-next-line-start correction to Join execution as
  validation, with exact LF and Unicode CRLF boundary coverage;
- rejects an advanced command before mutation when its conservative full
  revision budget cannot fit, including a `UInt64.max - 1` multi-line trim
  fixture that remains byte-for-byte unchanged and undo-empty;
- models the virtual terminal empty line during fallback moves and derives the
  moved selection from the rendered destination chunks, covering unequal line
  lengths, follow-up Delete Line, terminal empty lines, CRLF, and Unicode.

Independent focused Debug and Release re-review each pass 5/5. The reviewer
reproduced the original failures externally, then confirmed exact closure with
0 Blocker, 0 Major, and 0 Minor. Exact staged-candidate receipt remains pending.

## Product boundary and next slice

Macro recording/playback remains deliberately excluded from Duckpad. Phase 16
moves to folder search, structured results, bookmarks, and external-file
change resolution with Reload / Keep / Compare.

## Commit evidence

- Candidate ID: pending exact stage freeze
- Independent review: content approved, 0 Blocker / 0 Major / 0 Minor
- Local receipt: pending
- Commit: pending
