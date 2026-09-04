# Phase 31 — Fold State Recovery and Accessible Controls Design

Status: **Approved by the user on 2026-09-04; implementation planned**

## Goal

Preserve each editor pane's contracted code blocks across Duckpad recovery and
make folding usable from the keyboard, VoiceOver, the native menu, and the
Command Palette without adding a parser, language server, background worker,
or dependency.

## Product boundary

Lexilla and Scintilla remain the only folding engines. Duckpad persists and
commands Scintilla's existing fold state; it does not infer syntax or build a
second outline. Folding is available only when the active language enables it
and the document is below the existing large-file styling threshold. Plain
Text and large-file fallback remain fully editable with folding commands
disabled.

Macro recording, arbitrary fold-level presets, named fold sets, minimaps, and
AST-stable block identities are outside this phase. Fold state is recovery
metadata, not file content, and never changes text, document revision, dirty
state, Undo, or Redo.

## Chosen approach

Each Scintilla pane owns an independent list of contracted header line
numbers. This matches the existing per-pane cursor, selection, scroll, wrap,
display, and zoom model: one pane can retain an overview while the other
focuses on a contracted section of the same shared document.

The bridge enumerates contracted headers with `SCI_CONTRACTEDFOLDNEXT`, so
capture cost is proportional to the number of contracted folds rather than
the document's total line count. Recovery restores each line only at a
post-fold boundary and after `SCI_GETENDSTYLED` has advanced beyond that
line's end. At that point Lexilla's synchronous `Lex` then `Fold` pass has
returned, so a non-header result is authoritative. A line that is out of range
or is proven not to be a fold header is ignored.

The rejected alternatives are:

- A document-global fold list. It is simpler but breaks the existing split
  pane contract by forcing both views to use the same visibility state.
- Scanning every line with `SCI_GETFOLDLEVEL` during each recovery capture. It
  makes autosave cost scale with large documents.
- A separate syntax tree or parser. It could preserve block identity across
  structural rewrites, but duplicates Lexilla and violates Duckpad's
  lightweight product direction.

## Components and interfaces

### Recovery state

Create `Sources/DuckpadApplication/FoldRecoveryState.swift` with one focused
`FoldRecoveryState` value. It stores canonical, sorted, unique,
nonnegative `contractedHeaderLines` and caps them at 10,000 entries.

`EditorViewState` and `SecondaryEditorViewState` each gain a `foldState`
property. Decoding an older archive defaults to an empty fold state. Decoding
rejects a negative line or an encoded array larger than 10,000 entries.
Sanitization removes lines outside the recovered document's line count.

### Application port

Create `Sources/DuckpadApplication/FoldingEditorPort.swift` with the focused
`FoldingEditorPort` interface. It exposes:

- whether folding is supported for the active pane;
- whether the current block can be collapsed or expanded;
- whether any fold is contracted;
- collapse/expand-current and collapse/expand-all commands; and
- one `onFoldStateChange` callback for real user-visible fold changes.

The plain `NSTextView` fallback does not conform, so its menu commands remain
disabled rather than pretending to support syntax folding.

### Scintilla bridge

The Objective-C++ façade adds narrow typed operations instead of exposing
numeric Scintilla messages to Swift:

- enumerate at most a caller-supplied number of contracted header lines;
- restore a bounded list of contracted header lines without publishing a
  user-change callback, returning the subset that is not yet styled;
- enable a temporary fold-recovery progress signal while unresolved lines
  exist;
- identify the current fold header, using the caret line when it is a header
  and otherwise its nearest fold parent;
- collapse or expand the current block;
- collapse or expand all blocks; and
- publish `onFoldStateChange` after a successful margin or command change.

The Swift adapter, not the bridge, owns pending recovered line numbers. The
bridge first retries them immediately after a synchronous `SCI_COLOURISE`
call returns. For deeper idle styling, it marks progress as needed. While that
flag is set, an `SCN_UPDATEUI` observed at the start of Scintilla's idle tick
schedules one coalesced main-queue callback. The callback runs only after the
same `Idle()` call completes `IdleStyle()`, whose `LexInterface::Colourise`
performs `Lex` and then `Fold` synchronously. This guarantees a post-fold retry
for every idle chunk, including the final chunk. The flag is cleared as soon
as no pending line remains, so ordinary caret movement and typing schedule no
fold-recovery work.

No `SC_MOD_CHANGEFOLD` subscription is added to `SCI_SETMODEVENTMASK`:
Scintilla emits it once per changed fold line and it is unnecessary for the
coalesced post-idle boundary above. The existing insert/delete and smart-input
mask remains unchanged. Duckpad does not force a full-document colourise.

Explicit Expand All clears adapter-owned pending recovery, while Collapse All
supersedes it with the new native state. Current-block commands leave unrelated
pending lines intact.

Current-block commands are no-ops when no applicable header exists or the
requested state already matches. Collapse All uses
`SC_FOLDACTION_CONTRACT_EVERY_LEVEL`, so nested headers are contracted rather
than only top-level blocks. Collapse/expand-all may do native Scintilla line
work only after an explicit user command; no such scan runs on typing or
autosave.

The bridge enables `SC_AUTOMATICFOLD_CHANGE`. When an ordinary text edit
removes or reshapes a contracted header, Scintilla repairs line visibility so
descendants cannot remain inaccessible. The existing document-edit recovery
signal captures the resulting fold state; this automatic repair does not emit
a second fold callback or create an autosave loop.

### Adapter and presentation

`ScintillaEditorAdapter` conforms to `FoldingEditorPort`, captures primary and
secondary contracted headers separately, and restores them after each pane's
language configuration. It forwards fold-change callbacks without creating a
document edit. Per-view pending recovery is unioned with native contracted
headers during capture, so an autosave between idle chunks cannot discard it.
A single adapter helper discards pending recovery for both panes only after
the application has accepted a direct edit, programmatic replacement,
multi-range batch, Undo, or Redo. The three existing revision-commit points
call that helper. A rejected edit keeps pending recovery; the authoritative
rejection reload reapplies the stored fold state instead of allowing stale
native mutation state to decide it.

The adapter also remembers the last focused primary/secondary pane through a
narrow native focus callback. If a menu or Command Palette takes first
responder status, folding validation and execution use that stable pane
identity instead of falling back to primary. A successful folding command
returns focus to the same pane.

`DuckpadWindowController` connects that callback to
`SessionRecoveryUseCase.editorViewStateDidChange()`. The same path handles
gutter clicks and commands, making recovery signaling single-source. The
callback is cleared during controller teardown.

## User experience and accessibility

The existing fold gutter remains mouse-accessible. A native `View > Folding`
submenu adds:

| Command | Shortcut | Availability |
| --- | --- | --- |
| Collapse Current Block | Option-Command-[ | Current header or fold parent is expanded |
| Expand Current Block | Option-Command-] | Current header or fold parent is contracted |
| Collapse All | none | Folding is enabled; contracts every nested level |
| Expand All | none | At least one fold is contracted |

The bracket shortcuts do not collide with the existing Shift-Command-[ and
Shift-Command-] tab-movement commands. Each native menu item has an explicit
accessibility label. VoiceOver can navigate and invoke the submenu, while the
existing recursive menu index makes all four commands searchable in the
Command Palette. Menu validation and execution reflect the initiating split
pane even after the palette search field temporarily owns focus.

After a successful command, focus stays in the initiating editor pane. When a
parent block is collapsed while the caret is inside it, Scintilla's native
fold command owns caret visibility; Duckpad does not synthesize text or move
the selection independently.

## Data flow

1. Lexilla configures fold levels for the active language.
2. A gutter click, shortcut, menu item, or Command Palette action invokes one
   typed bridge operation on the focused or most-recently-focused pane.
3. The bridge publishes a fold-state callback only if visible fold state
   changed.
4. The controller schedules the existing debounced recovery autosave.
5. Recovery capture asks each live pane for at most 10,000 contracted headers
   and unions them with adapter-owned pending headers before encoding the
   existing editor view state.
6. Recovery loads text and language configuration, restores styled valid
   headers immediately, and stores the bridge's unresolved return value until
   a coalesced post-idle callback proves their line ends styled. Neither path
   emits another autosave signal.

Buffer switches still synchronously capture outgoing view state. Split close
continues to discard secondary pane state. A language change that disables
folding expands all lines without a user-change callback, leaves no active
fold commands, and makes subsequent capture record an empty fold state. A
switch between fold-capable languages retains only line numbers that remain
valid headers after the new lexer computes its fold levels.

## Error and compatibility behavior

- Older recovery archives decode with no contracted folds.
- Oversized or negative encoded fold state rejects the recovery archive using
  the existing corrupt-recovery boundary.
- Duplicate or unsorted valid entries canonicalize to sorted unique lines.
- Out-of-range and no-longer-header lines are ignored during restore.
- Not-yet-styled lines remain pending and are still encoded by an intervening
  autosave. Only an application-accepted direct/programmatic/batch/Undo/Redo
  mutation clears unresolved pending line numbers. A rejected edit retains and
  reapplies them rather than treating rejected native bytes as authoritative.
- Lexer creation failure retains the previous language and fold capability,
  matching the existing language rollback contract.
- Plain Text and large-file fallback expand any old contractions and expose no
  actionable folding commands, so content cannot remain hidden without a way
  to reveal it.
- Restore operations never invoke the user-change callback and cannot create
  an autosave loop.

## Verification

Implementation follows strict red-green-refactor cycles. Automated coverage
must prove:

- recovery state backward decoding, validation, canonicalization, and the
  10,000-entry bound;
- bridge enumeration uses contracted-fold iteration and respects its cap;
- a valid primary and secondary header beyond the 262,144-byte synchronous
  styling prefix remains pending, survives an intervening capture, and is
  contracted by the post-fold callback after its line becomes styled in the
  final idle chunk;
- current-block commands use a header or nearest parent and reject no-op or
  unsupported cases;
- gutter, current, and all-fold changes publish exactly one callback;
- restore publishes no callback and ignores invalid/non-header lines;
- editing away a contracted header reveals its descendants through
  `SC_AUTOMATICFOLD_CHANGE` without an extra fold callback;
- accepted direct, programmatic, batch, Undo, and Redo mutations clear pending
  recovery for both panes, while rejected native edits retain and reapply it;
- primary and secondary panes capture and restore independent fold states;
- fold operations leave UTF-8 bytes, revision, dirty ownership, selection,
  Undo, and Redo unchanged;
- Plain Text and large-file fallback keep all commands disabled;
- native menu titles, shortcuts, validation, accessibility labels, focused
  pane routing, Command Palette discovery/execution, and secondary-pane focus
  restoration are correct;
- controller teardown removes the callback; and
- legacy recovery fixtures continue to decode.

Phase 31 extends the frozen Release performance inventory with
`fold_recovery_10000`. The fixture contains 10,000 nested and sibling C++ fold
headers, contracts them, captures their canonical recovery state, restores it
into a second pane, and verifies exact count and independence. Its maximum is
250 milliseconds for the complete contract/capture/restore sequence on the
same reference profile used by Phase 28. A separate correctness stress places
recoverable headers beyond the 262,144-byte synchronous styling prefix and
requires eventual restoration within two seconds without an eager
full-document colourise.

The final gate includes focused Debug and Release tests, relevant recovery and
presentation suites, production language/folding smoke, `git diff --check`,
the extended frozen six-budget Release benchmark, and an independent review
with all findings remediated before any push. Existing repository-wide AppKit
baseline failures remain disclosed rather than misreported as passing.

## Delivery and branch scope

Work proceeds on `feature/fold-state-recovery`, based on the delivered Phase
30 branch tip. Only Phase 31 source, tests, provenance if the bridge seam
changes, dashboard, design, plan, and wiki evidence may enter its commits.
Pre-existing user changes in `docs/wiki/04-implementation-foundation.md` and
`scripts/vendor_scintilla_5_6_6.sh` remain unstaged and unmodified.
