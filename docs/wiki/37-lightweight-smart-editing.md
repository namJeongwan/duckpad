# Phase 30 — Lightweight smart editing

Status: **Delivered and maintained**

## Outcome

Duckpad now provides the high-frequency editing assistance expected from a
language-aware scratchpad without introducing an IDE-scale parser, language
server, background worker, or new dependency. When a brace-capable language is
active, direct keyboard input of `{`, `[`, `(`, `'`, `"`, or backtick inserts
the matching closer and leaves the caret between the pair.

Return preserves the current line's leading whitespace. It adds one configured
indent unit after `{`, `[`, or `(`, and after `:` in Python. When Return is
pressed before a JSON-style closing delimiter, the inner line keeps its sibling
indent and the closer is placed on an aligned following line. The behavior uses
the language configuration's tab width and tabs-versus-spaces setting.

## Native Scintilla contract

The bridge enables `SC_MOD_INSERTCHECK` only for views whose active language
allows smart editing, and replaces only the pending insertion through
`SCI_CHANGEINSERTION`. Primary views retain document-edit publication; shared
split views receive only insertion-check notifications, preventing duplicate
revision publication while keeping the caret in the pane that received input.
`SCN_CHARADDED` then moves that caret to the calculated inner position. The
pair or expanded newline therefore remains one native Scintilla edit: one Undo
removes it, and the workspace recovery journal advances by one revision.
Typing `)`, `]`, `}`, `'`, `"`, or backtick immediately before the identical
character changes the checked insertion to zero bytes and advances only the
initiating caret. Skip-over therefore creates no document revision or Undo
entry, including in a shared split pane.

The decision reads only the current line's leading whitespace and adjacent
characters. It does not scan or parse the document. Existing Lexilla language
selection and the brace-matching capability are the feature gate, so Plain Text
and the large-file styling fallback do not run smart editing.

## Input safety boundaries

Smart editing applies only to direct input. Paste remains byte-for-byte and IME
composition remains under Scintilla's `NSTextInputClient` implementation. A
narrow delegate signal identifies direct, tentative, and IME-commit insertion
boundaries before Scintilla mutates the document. `SCN_CHARADDED` accepts only
direct input for the caret adjustment. Command, Control, and Option modified key
events are not treated as smart insertions. Return handled directly by Scintilla
uses a synchronous input preflight, while keyboard paste remains outside that
signal. Every smart transformation requires one empty stream selection with no
virtual space. Selection surround remains deferred; `<` and `>` remain literal
edits so comparison operators are never captured as pairs.

## Verification contract

Focused tests cover all six pairs, quote-like pairing in Python, one-step Undo,
zero-edit closer skip-over, literal angle brackets, JSON Return between an empty
pair, sibling indentation before a closer, Python colon indentation using the
configured width, one-edit recovery propagation, Plain Text and paste
non-interference, real Command-V with smart delimiters/newline, selected and
multi-caret Return, and queued AppKit key events delivered to the actual
Scintilla first responder. A shared-document regression proves that pairing and skip-over
leave both split views synchronized and keep the caret in the initiating pane.
Additional regressions cover CRLF/CR preservation, IME initial/update/commit
boundaries including quotes, invalid lexer rollback, stale split-pane caret
state, and a 4 MiB paste without smart transformation.

The current maintenance candidate passes all 668 tests in 12 suites in serial
Debug and Release runs. Focused coverage includes the complete language suite,
shared split panes, real AppKit key events, and a regression proving that a
multi-character insertion containing CRLF remains byte-for-byte unchanged.
Fresh hidden Release-app language and 50-tab/6-row smokes pass. Debug and
Release Scintilla bridge builds also pass with deprecated declarations promoted
to errors. The default parallel whole suite remains outside the release gate
because process-global AppKit tests are not parallel-safe.

## Scope protection

The maintained implementation modifies the Duckpad-owned bridge, focused
adapter tests, two narrow Scintilla input delegate seams, and two narrow Cocoa
compatibility sites. Tab seam and trailing-gutter corrections remain in the
AppKit presentation layer and its focused tests. `PROVENANCE.md` records every
vendor patch. No dependency, preference schema, language registry schema, or
background service is added. Pre-existing user changes in
`docs/wiki/04-implementation-foundation.md` and
`scripts/vendor_scintilla_5_6_6.sh` remain outside this phase.

## Independent review remediation

The initial independent review reported 0 Critical, 4 Important, and 2 Minor
findings. The candidate now limits insertion inspection to two bytes before
copying, caps only leading/trailing whitespace traversal at 4,096 bytes while
keeping adjacent opener detection active on longer lines, routes explicit
direct/tentative/IME-commit source metadata through the Cocoa delegate, infers
the active Scintilla EOL mode on document load, keys pending caret state to the
initiating view, clears it across load/invalidation/language transitions, and
commits lexer state only after successful creation. Focused Debug and Release
gates, the production language smoke, and all five frozen performance budgets
pass after remediation. Final independent re-review approved the exact
candidate for commit and push with 0 Critical, 0 Important, and 0 Minor
findings.

The 2026-09-08 maintenance extension adds quote, double-quote, and backtick
pairing plus exact adjacent skip-over for every supported closer. It also gates
all smart transformations on a single-character direct-input transaction, so
paste, IME, and programmatic multi-character CRLF insertion remain native.

## Delivery evidence

Commit `3c718efb1291229d8deb5d61c64de5186398e394` was created through the
verified local commit wrapper, passed post-commit audit, and was pushed to
`origin/feature/smart-editing`. Its canonical review receipt SHA-256 is
`2249e4e041175d1dd2b27a390fbb6eac46d725e0a498b180f466b8842cc3b0c2`.
