# Phase 32 — Block Comments and Closing-Delimiter Indentation Design

Status: **Approved through the user's standing end-to-end delegation on 2026-09-04; implementation planning**

## Goal

Add the next high-value document-editing slice to Duckpad: language-aware block
comment toggling and direct-input closing-delimiter dedent. Reuse the existing
language manifest and Scintilla editing engine without adding a parser,
language server, background worker, or dependency.

The phase also proves that the existing Indent Line(s) and Unindent Line(s)
commands obey each active language's configured tab width and tabs/spaces mode.

## Product boundary

Duckpad remains a lightweight native scratchpad. The active bundled language
definition supplies literal comment delimiters and indentation settings;
Scintilla owns selection, byte positions, mutations, and Undo. Duckpad does not
parse nested comments, infer an AST, or try to format arbitrary expressions.

This phase includes:

- Toggle Block Comment for languages with a complete nonempty block pair;
- empty-selection insertion/removal of an adjacent comment pair;
- one-level dedent when `}`, `]`, or `)` is directly typed on an
  indentation-only line; and
- regression proof for language-configured explicit indent/outdent.

Quote pairing, selection surround for ordinary delimiters, closer skip-over,
whole-document formatting, indentation inference, macro recording, and
standalone reindent commands remain out of scope.

## Considered approaches

### Chosen: typed Scintilla façade with manifest literals

Extend the existing Duckpad-owned bridge with narrow block-comment and closer
dedent behavior. The adapter applies one validated language configuration and
the bridge mutates the engine that already owns UTF-8 byte ranges, IME
boundaries, selection, and Undo.

### Rejected: Application-level string transformation

Materializing the selected document fragment in Swift would make the command
easy to express, but byte positions could become stale and selection/Undo/
recovery behavior would duplicate Scintilla. The chosen bridge does make one
native copy for this explicit command so the whole transformation can be one
replacement and one acceptance unit; that transient cost is preferable to a
partially accepted two-edit command.

### Rejected: lexer/AST-aware comment and formatting service

A parser could reason about nested comments and language grammar, but would add
weight, background state, and per-language maintenance far beyond the intended
editing slice. Literal manifest capabilities are sufficient for deterministic
commands.

## Language capability and validation

`LanguageCommentSyntax` already carries `blockStart` and `blockEnd`, and the
bundled version-1 manifest already stores block pairs. The loader continues to
require exactly two array entries and additionally rejects an empty delimiter
or a delimiter longer than 64 UTF-8 bytes. Existing bundled definitions stay
valid.

`EditorLanguageConfiguration` gains the complete `LanguageCommentSyntax` so
the adapter has one applied source of truth for menu capability and native
behavior. Plain Text and languages without both block delimiters expose no
block-comment command. Large-file styling fallback does not remove the literal
comment capability: the command is an explicit bounded edit and does not
require Lexilla styling.

A failed lexer application retains the previous language configuration,
including comment and indentation capabilities.

## Block-comment semantics

The native Edit menu adds **Toggle Block Comment** with Option-Command-/ and
the accessibility label “Toggle block comment”. The existing recursive menu
index makes it available in the Command Palette. Validation requires a ready
workspace, an editable Scintilla language port, and a complete block pair.

The command supports exactly one stream selection with zero anchor and caret
virtual space. Rectangular, line, thin, multiple, or virtual-space selections
are intentionally unavailable and produce no mutation, callback, focus change,
or Undo record. This keeps selection semantics deterministic without adding an
IDE-grade multi-selection transformation layer.

For a nonempty primary selection:

1. If the selected bytes begin with `blockStart` and end with `blockEnd`, remove
   exactly those outer delimiters.
2. Otherwise insert `blockEnd` at the selection end and `blockStart` at the
   selection start.
3. After wrapping, select the complete wrapped range so invoking Toggle again
   unwraps it. After unwrapping, select the original payload.

The command does not search inside the selection or interpret nested delimiter
text. CR, LF, CRLF, non-ASCII text, and bytes outside the selection remain
literal and unchanged.

For an empty selection:

- if `blockStart` ends immediately before the caret and `blockEnd` begins
  immediately after it, remove that exact adjacent pair and move the caret to
  `oldCaret - blockStartUTF8ByteCount`;
- otherwise insert `blockStart + blockEnd` and leave the caret between them.

For identical start/end delimiters, a nonempty selection unwraps only when its
byte length is at least the sum of both delimiter lengths. This prevents the
same selected byte from being consumed twice. Empty-selection adjacent-pair
removal remains unambiguous because the two delimiters occupy disjoint ranges.

Wrapping, unwrapping, insertion, and adjacent-pair removal each use exactly one
`SCI_REPLACETARGET` over the complete affected range. The Objective-C++ bridge
materializes that range once, checks all length arithmetic for overflow, builds
the replacement bytes, and performs one native replacement while suppressing
Scintilla's internal delete/insert notifications. It then publishes one
aggregate `DPScintillaEdit` containing the original range, deleted bytes, and
replacement bytes, and consumes exactly one revision. The resulting selection
is installed before publication so synchronous acceptance observes the final
native state; rejection recovery supersedes it with the saved pre-command view
state. A partial block-comment state is therefore impossible. The native
replacement is one Undo action and preserves the selection direction after
selecting the resulting wrapped or unwrapped range.

The typed bridge rejects empty, invalid-UTF-8, or over-64-byte delimiters. A
command that cannot change the current selection is a no-op and publishes no
edit.

## Direct closing-delimiter dedent

The existing smart-input path is extended for `}`, `]`, and `)` only when all
of these conditions hold:

- the insertion source is direct keyboard input;
- no marked-text/IME composition is active;
- the active language has smart editing enabled;
- the inserted content is exactly one ASCII closer;
- there is exactly one empty stream selection with zero virtual space;
- the current line from its start to the insertion point contains only spaces
  and tabs;
- that prefix is at most 4,096 bytes; and
- the current indentation is greater than zero.

The bridge computes indentation columns with Scintilla's tab-stop rules and
sets the target to `max(0, currentColumns - tabWidth)`. It then canonicalizes
that target using the applied configuration: spaces only when `useTabs` is
false, or as many tabs as possible plus remainder spaces when it is true. This
gives mixed prefixes such as `"\t  "` and `" \t"` an exact one-level column
dedent. The bounded original prefix is replaced as one aggregate indentation
edit: internal delete/insert notifications are suppressed and one
`DPScintillaEdit` is published, just as for block comments.

When at least five revisions remain, the bridge opens one Scintilla Undo group
during the insert-check notification, allows the original closer insertion,
then performs the precomputed aggregate indentation replacement during
character-added and closes the group. The path emits exactly two published
edits: closer insertion first, indentation replacement second. Two revisions
are consumed forward and three more are reserved because native grouped Undo
may publish the closer deletion plus separate delete/insert components while
restoring the original mixed indentation. Thus one Undo can always restore both
forward changes when its component edits are accepted. Native Undo and Redo
continue using the existing per-component authority contract: each component
is offered sequentially, and rejection recovers exactly the already accepted
prefix while discarding the rejected component and everything after it. The
phase does not introduce a second transactional history layer. Tests reject
each possible Undo and Redo component and prove that no unaccepted bytes become
authoritative. If fewer than five revisions remain, auto-dedent declines
and the closer follows the existing single-edit revision-exhaustion behavior.
At exactly `max - 5`, the grouped edit ends at `max - 3`; one Undo restores the
pre-input text and may consume up to the three reserved revisions. The
worst-case mixed-prefix restoration ends at `max`; a delete-only replacement
ends earlier, and the existing read-only policy applies only if `max` is
reached.

Paste, programmatic replacement, IME composition/commit, multi-character
input, and a closer typed after any non-whitespace character do not trigger
automatic dedent. They retain existing editing behavior. The pending Undo group
is closed during invalidation or any abandoned smart-input path so teardown
cannot strand native Undo state.

The user input and indentation adjustment pass through normal revision, dirty,
recovery, split-pane synchronization, and rejection handling. If the closer
insertion is rejected, recovery cancels the pending aggregate indentation
replacement and restores the pre-input document. If only that replacement is
rejected, recovery retains the already accepted closer and discards the dedent;
this is a complete degradation of the optional convenience, not a partial user
input. When both are accepted, one Undo removes both. No document scan, lexer
query, or background task runs on the keystroke path.

## Explicit indent and outdent

The existing `SCI_TAB` and `SCI_BACKTAB` commands remain the implementation of
Indent Line(s) and Unindent Line(s). They already consume the applied
`tabWidth` and `useTabs` configuration. Phase 32 adds cross-language tests for:

- two-space and four-space definitions;
- a tab-using definition such as Makefile;
- single and multiline selections;
- mixed leading whitespace during outdent;
- one native Undo group; and
- exact selection, revision, dirty, and recovery publication.

Production behavior changes only if these tests expose a mismatch. The plain
Text fallback continues using its existing default indentation settings.

## Components and interfaces

### Domain and infrastructure

The existing `LanguageCommentSyntax` remains the sole comment model. The
manifest loader hardens block-pair length/nonempty validation; it does not add
a schema version or new language entries.

### Application

`EditorLanguageConfiguration.comments` is the sole applied comment authority.
`LanguageEditorPort` exposes `canToggleBlockComment` and a no-argument
`toggleBlockComment()` method. `LanguageWorkspaceUseCase` only verifies its
ready state and invokes that method; it does not resolve or pass a second copy
of the delimiters. Existing line-comment behavior is unchanged in this phase.

### Scintilla bridge and adapter

The Objective-C++ bridge adds a typed block-comment method whose public header
contains only Foundation values. It owns selection validation, affected-range
materialization, the single replacement, and post-command selection. The
existing smart-input notification handler owns closer dedent and its bounded
pending state.

Shared Scintilla documents retain the existing single-publisher rule: the
primary view is the document transaction publisher, while the focused primary
or secondary view is the selection and pending-input owner. `shareDocument`
records the publisher relationship. Every aggregate operation asks the primary
publisher to suppress its component notifications, mutates the shared document,
installs the result selection on the initiating view, and publishes exactly one
aggregate edit through the primary callback. The adapter records the exact
initiating view when closer-dedent pending state opens, so a rejected closer
cancels and closes that view's pending Undo group before recovery. Secondary
views never enable a second document-edit publisher.

`ScintillaEditorAdapter` derives block-comment capability from the successfully
applied language configuration and converts the native edits into the existing
`EditorEditOutcome`. It does not read the selected payload or implement a
second transformation.

### Presentation

`DuckpadWindowController` adds one selector, readiness/capability validation,
and editor focus restoration after a successful command. The menu uses the
existing recursive shortcut-collision and Command Palette infrastructure.

## Data flow

### Block comment

1. Successful language application stores the active definition's literal pair
   in `EditorLanguageConfiguration.comments`.
2. Menu, shortcut, or Command Palette invokes `LanguageWorkspaceUseCase`.
3. The adapter passes the focused selection owner and the pair from its last
   successfully applied configuration to the primary transaction publisher.
4. The publisher suppresses its replacement component notifications, mutates
   the shared document, updates the initiating selection, and publishes one
   aggregate incremental edit through the sole primary callback.
5. The existing incremental edit callback updates workspace revision, dirty state,
   recovery journal, and the shared secondary document.
6. The controller restores focus only after a successful command.

### Closer dedent

1. Scintilla reports a direct single-character insert check to the initiating
   primary or secondary view.
2. That selection owner verifies the bounded indentation-only prefix, reserves
   two forward plus three worst-case Undo revisions, and asks the primary
   document publisher to suppress shared component notifications before opening
   an Undo group.
3. Scintilla inserts the literal closer; the primary publisher emits its one
   aggregate insertion edit.
4. If accepted, character-added handling asks the same publisher to emit the
   aggregate indentation replacement, then closes the initiating Undo group.
   Rejection synchronously cancels that exact initiating pending state first.
5. Existing edit callbacks accept or reject each mutation using the degradation
   contract above; recovery always restores authoritative bytes.

## Error, recovery, and lifecycle behavior

- Unsupported languages disable Toggle Block Comment and never guess syntax.
- Malformed block pairs reject manifest loading before a command can use them.
- Invalid native delimiter data returns a no-op without mutation.
- A rejected single block-comment edit reloads the unchanged authoritative
  snapshot; no partial wrapped document can become authoritative.
- A rejected closer insertion cancels the pending aggregate indentation
  replacement and restores the pre-input snapshot. A rejected aggregate
  indentation replacement preserves the accepted closer and restores that
  authoritative closer-only snapshot.
- Revision exhaustion and disabled input keep the command unavailable.
- Split panes share accepted text but preserve their independent selections and
  focus routing.
- Adapter/controller invalidation clears comment/focus callbacks and closes any
  pending closer-dedent Undo group without applying its replacement.
- Block comments and closer dedent are document edits, so dirty and recovery
  state change normally; unlike folding, they are not view metadata.

## Performance boundary

Block-comment execution copies the affected selection once and allocates one
replacement buffer for an explicit user command. It adds no resident state,
background work, or keystroke-path cost. Empty selection inspects only adjacent
delimiter-sized ranges. Closer dedent inspects at most 4,096 bytes on the
current line. Explicit indent/outdent remains native Scintilla work over only
the selected lines.

The frozen performance inventory gains no new global-document benchmark. A
focused stress test toggles a large selected payload, asserts one incremental
notification and linear payload bytes, and enforces the existing explicit-
command latency envelope. A 4,097-byte indentation prefix proves closer dedent
declines without scanning further.

## Verification

Implementation follows strict red-green-refactor cycles and must prove:

- manifest acceptance for every existing bundled pair and rejection of empty,
  incomplete, over-64-byte, or wrong-cardinality pairs;
- supported/unsupported menu validation, exact Option-Command-/ shortcut,
  accessibility label, Command Palette discovery, uniqueness of every core
  shortcut, and fail-closed extension collision with Option-Command-/;
- selected UTF-8/CRLF wrap then unwrap with exact range restoration;
- empty-caret adjacent pair insertion then removal;
- literal nested delimiter handling without parser behavior;
- one Undo restores exact pre-command bytes and selection;
- one stream selection succeeds while rectangular, line, thin, multiple, and
  virtual-space selections produce no mutation, callback, focus change, or Undo;
- accepted block-comment edits advance workspace revision/dirty/recovery once,
  while rejection restores the unchanged authoritative snapshot;
- primary/secondary focus routes the command to the initiating pane while text
  remains shared;
- direct `}`, `]`, and `)` on indentation-only lines dedent one configured
  level for spaces and tabs;
- paste, IME, programmatic, multi-character, non-whitespace-line, zero-indent,
  and over-4,096-byte cases do not auto-dedent;
- one Undo removes both the closer and its automatic indentation adjustment;
- normally accepted Undo and Redo restore the complete grouped state, while
  rejection at every native component recovers exactly its accepted prefix;
- mixed-prefix fixtures `"\t  "` and `" \t"` dedent to the exact target column
  under both `useTabs` settings and emit the configured canonical prefix;
- exact two-published-edit behavior, both rejection points, invalidation
  cleanup, and revision-budget boundaries: `max - 5` dedents and remains
  undoable; `max - 4` through `max - 1` insert only the closer under existing
  exhaustion behavior; exhausted input remains disabled;
- two-space, four-space, and tab-based explicit indent/outdent behavior;
- UTF-8 bytes outside the target, revision sequencing, dirty state, recovery,
  selection, Undo, and Redo invariants;
- existing delimiter pairing, JSON/Python newline indentation, highlighting,
  folding, split recovery, and large-file behavior remain green;
- Debug and Release focused suites, builds, production AppKit smoke,
  `git diff --check`, and an independent final review all pass before push.

The monolithic AppKit suite remains an honest diagnostic gate. If its known
process-global `signal 11` or extension-host timeout recurs, the exact failing
command is reproduced against parent `4510f3a` and documented rather than
reported as a Phase 32 pass.
