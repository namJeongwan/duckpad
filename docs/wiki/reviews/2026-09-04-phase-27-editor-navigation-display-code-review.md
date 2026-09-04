# Phase 27 editor navigation and display — independent code review

- **Reviewer:** `/root/phase1_code_review` (independent; no implementation)
- **Date:** 2026-09-04
- **Baseline:** `9a4c856e00258ffa2aa8f6225f1d7288714d5e49`
- **Reviewed staged tree:** `831ada267a5b8a5d480220089fb6a71ba4f162bf`
- **Final verdict:** **APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor**

## Scope

The review covered the exact 15-path product/test/work-document manifest in
Application ports and recovery state, the Scintilla and NSTextView adapters,
the narrow Objective-C++ bridge, native navigation panel, controller/menu
routing, Phase 27 tests, the Phase 26 delivery-status correction, and the Phase
27 work document. The mixed-authority wiki index is evidence rather than part
of that product manifest.

The user-owned unstaged `docs/wiki/04-implementation-foundation.md`, untracked
`scripts/vendor_scintilla_5_6_6.sh`, every README, and the ignored Notepad++
checkout were excluded and preserved. Product/source/test/work-document bytes,
the index, stage, commit, push, and receipt were not modified by the code-review
pass; only this review record and the reviewer row/work log are subsequently
changed.

## Findings

- **P27-01 Major — CLOSED** — `Sources/DuckpadPresentation/DuckpadWindowController.swift:1003-1034`, `Sources/DuckpadEditorAdapter/ScintillaEditorAdapter.swift:335-371`: the initial sheet completion rediscovered the focused pane after AppKit had moved first responder to the sheet, so a request captured from the secondary split could navigate the primary pane; carry an opaque pane context through the Application port, reject retired contexts, perform the move on that exact pane, and restore focus there. The final bytes do this and the real split regression steals focus to primary before submission, then proves the secondary caret, `hasEditorFocus`, and adapter active view all return to secondary.

There are no open findings. `TextViewEditorAdapter` intentionally preserves
independent whitespace/EOL state but renders their glyphs through AppKit's one
combined `showsInvisibleCharacters` flag. The code and Phase 27 document now
state this non-production fallback limitation explicitly; production Scintilla
uses separate `SCI_SETVIEWWS` and `SCI_SETVIEWEOL` controls, so it is a recorded
scope note rather than a product defect.

## Evidence

- Read every staged hunk plus surrounding editor retirement/split restoration,
  menu validation, termination admission, and recovery capture paths.
- `git diff --cached --check`: PASS; staged set before reviewer evidence was
  exactly 16 paths, with only doc04 unstaged and the vendor script untracked.
- Independent Debug focused tests: 6/6 PASS — native UTF-8/line navigation,
  split exact-pane focus, stale-buffer presentation, legacy recovery decode,
  incremental recovery/view-state restoration, and global shortcut/menu checks.
- Independent Release focused tests: the same 6/6 PASS.
- The commands leave text/revision/undo untouched; UTF-8 interior offsets and
  invalid lines fail closed; display state is pane- and buffer-specific,
  recovery-compatible, and zoom-clamped to `-10...20`.
- Builder evidence, treated as supporting evidence: exact Debug and Release
  modules 353/353, packaged signature/resource verification, and 50-tab native
  smoke PASS.

## Exact manifest

For the final 15-path product/test/work-document set (review record and wiki
index excluded), the sorted NUL-delimited path digest is
`7638eed62f1bc5e6dae1b419f93fa657daa17c399fd890a46c0db61233da6aed`.
The sorted `path NUL bytes NUL` digest is
`c428bccfd609e95cd9a64a1f1f1754fcb6a7552f1a2a1a19cd2744e4afdfea72`.

## Verdict

**APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** P27-01 is closed
and no data-loss, lifecycle, stale-authority, Unicode-boundary, recovery,
shortcut, or architecture defect remains in the reviewed scope. Adding this
review/index evidence invalidates the current staged candidate; the exact
candidate must be refrozen and independently verified before any receipt.

## Agent Work Log

- Recomputed staged scope/tree and exclusion state, inspected the complete
  staged diff and surrounding ownership/lifecycle paths, and ran focused Debug
  and Release tests independently.
- Reproduced the initial split-pane responder defect, rejected the first partial
  remediation, and verified the final opaque-context plus exact-focus closure.
- Recorded the AppKit fallback rendering limitation without expanding the
  production acceptance scope or changing implementation/test bytes.
