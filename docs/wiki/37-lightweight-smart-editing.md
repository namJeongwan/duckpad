# Phase 30 — Lightweight smart editing

Status: **Approved, committed and pushed**

## Outcome

Duckpad now provides the high-frequency editing assistance expected from a
language-aware scratchpad without introducing an IDE-scale parser, language
server, background worker, or new dependency. When a brace-capable language is
active, direct keyboard input of `{`, `[`, or `(` inserts the matching closer
and leaves the caret between the pair.

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
events are not treated as smart insertions.

Quote pairing, selection surround, closing-character skip-over, and standalone
closing-delimiter reindent are deferred. Supporting them would require broader
pre-key interception and must first prove that Korean IME composition, UTF-8
selection boundaries, native undo, and revision admission remain unchanged.

## Verification contract

Focused tests cover JSON pair insertion and single Undo, JSON Return between an
empty pair, sibling indentation before a closer, Python colon indentation using
the configured width, one-edit recovery propagation, Plain Text and paste
non-interference, and a queued AppKit key event delivered to the actual
Scintilla first responder. A shared-document regression proves that typing in a
split pane leaves both views synchronized and keeps the caret in the initiating
pane. Additional regressions cover CRLF/CR preservation, IME initial/update/
commit boundaries, invalid lexer rollback, stale split-pane caret state, and a
4 MiB paste without smart transformation.

Debug and Release builds, the complete Debug and Release language suites, the
split-pane regression in both configurations, and the Release production
language smoke pass. The frozen Release performance gate also passes all five
budgets; the 100 MiB production open path including EOL detection completes in
1005.766292 ms against its 1500 ms maximum, and typing p95 is 0.015958 ms
against 0.5 ms. The repository-wide monolithic Debug run reproducibly
exits with `signal 11` while existing AppKit suites overlap. The isolated
Scintilla suite completes the Phase 30 cases but exposes one existing unrelated
replace-reservation failure. These are disclosed as review inputs rather than
reported as successful full-suite validation. Focused Phase 30 runs do not
reproduce the crash, but the process-global synthetic AppKit event test has not
been differentially excluded as a contributor.

## Scope protection

The implementation modifies the Duckpad-owned bridge, two narrow Scintilla Cocoa
delegate seams, and focused adapter tests. It also records the additional vendor
patch in `PROVENANCE.md`. No dependency, preference schema, language registry
schema, or background service is added. Pre-existing user changes in
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

## Delivery evidence

Commit `3c718efb1291229d8deb5d61c64de5186398e394` was created through the
verified local commit wrapper, passed post-commit audit, and was pushed to
`origin/feature/smart-editing`. Its canonical review receipt SHA-256 is
`2249e4e041175d1dd2b27a390fbb6eac46d725e0a498b180f466b8842cc3b0c2`.
