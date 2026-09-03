# Phase 18 Persistent Bookmarks — Independent Code Review

- **Reviewer:** `/root/phase1_code_review` (independent; did not implement Phase 18)
- **Date:** 2026-09-03
- **Verdict:** **APPROVED — CONTENT REVIEW**
- **Final findings:** 0 Blocker, 0 Major, 0 Minor
- **Initial findings:** 0 Blocker, 4 Major, 0 Minor; all closed below

## Scope

Reviewed the intended 16-path Phase 18 slice: the Application editor/recovery
ports; production Scintilla and fallback NSTextView adapters; local recovery
validation; native menu/window routing; the narrow Objective-C++ Scintilla
bridge; five acceptance-test files; the Phase 18 work document; and the wiki
index.

Explicitly excluded and preserved `docs/wiki/04-implementation-foundation.md`,
`scripts/vendor_scintilla_5_6_6.sh`, README, and ignored Notepad++ material. The
reviewer changed only this evidence file and the Phase 18 review row/work log in
the wiki index; no product/test edit, stage, commit, or push was performed.

## Initial Findings

- **P18-01 Major** — `Vendor/Scintilla/5.6.6/bridge/DuckpadScintillaBridge.mm:435`: Previous Bookmark queried line 0 when the caret was already on a bookmarked first line, so it selected the current marker instead of wrapping to the last marker; skip the initial backward query at line 0 and exercise the strict wrap edge.
- **P18-02 Major** — `Sources/DuckpadPresentation/TextViewEditorAdapter.swift:595`: fallback rendering removed `.backgroundColor` temporary attributes over the whole document, deleting decorations owned by other TextKit features; use a namespaced bookmark attribute and translate it at draw time without overwriting an existing background.
- **P18-03 Major** — `Sources/DuckpadPresentation/TextViewEditorAdapter.swift:566`: independently counting line breaks in the prefix and replaced fragment counted a split CRLF twice and moved bookmarks to the wrong line; map old line-start offsets into the resulting text with CR/LF/CRLF-aware one-pass indexes.
- **P18-04 Major** — `Sources/DuckpadPresentation/TextViewEditorAdapter.swift:595`, `Sources/DuckpadEditorAdapter/ScintillaEditorAdapter.swift:225`: the 100,000-marker boundary combined repeated full-prefix fallback scans and unmeasured MainActor native restoration/capture, leaving a supported recovery file able to stall the UI; use one-pass `O(document + bookmarks)` mapping, reduce the practical hard cap, and prove maximum-count native work under an explicit budget.

## Remediation Re-review

- **P18-01 CLOSED** — backward navigation now issues no inclusive marker query
  at line 0 and takes the existing last-marker wrap path. The independent
  native probe moved from UTF-8 caret 0 to 13, and the dedicated regression
  test covers the same two-marker boundary.
- **P18-02 CLOSED** — fallback highlights are stored under
  `app.duckpad.bookmark`; the layout delegate converts only that owned key to a
  screen background when no other background exists. Both the repository test
  and independent probe preserve an unrelated red temporary background.
- **P18-03 CLOSED** — old and resulting line starts are scanned once with CRLF
  treated atomically, bookmark offsets are rebased, and line lookup is binary.
  The independent split-newline probe retains the bookmarked third line as
  `[2]` after the edit.
- **P18-04 CLOSED** — fallback mapping/rendering is linear rather than
  bookmark-times-prefix, the per-document cap is 10,000, and native maximum
  restore plus capture completes in 0.093 seconds in the independent Debug run
  against a two-second fail-closed test budget.

## Validation

- Independent current-byte focused runs: 9/9 PASS. This covers legacy decode,
  menu selectors/shortcut uniqueness, controller recovery without dirtying,
  local-store generation fallback, Scintilla edit/undo/redo and per-buffer
  recovery, strict first-line backward wrap, fallback CRLF/foreign-attribute
  ownership, and the 10,000-marker native budget.
- Independent external AppKit/Scintilla probe reproduced P18-01 through P18-03
  on the earlier bytes, then confirmed current results: CRLF bookmark `[2]`,
  foreign red background retained, and previous-from-line-zero caret `13`.
- Builder-provided exact-current supporting evidence: focused 8/8, Debug
  261/261, and Release 261/261 PASS. The reviewer independently inspected the
  complete Debug/Release terminal summaries after remediation.
- `git diff --check`: PASS. Git index remained empty.

## Architecture and Invariants

- Application owns the platform-neutral bookmark capability and bounded,
  backward-compatible recovery value. Editor adapters own native marker/TextKit
  mechanics; Infrastructure owns persisted blob/view-state validation; and
  Presentation owns commands, lifecycle admission, and recovery scheduling.
  Dependency direction remains inward and raw `SCI_*` calls remain confined to
  the Objective-C++ bridge.
- Scintilla marker 20 is collision-free in the vendored 5.6.6 constants:
  history uses 21–24 and folding uses 25–31. The dedicated margin mask exposes
  only marker 20.
- Bookmark operations are synchronous MainActor view-state changes guarded by
  ready/active-buffer/termination admission. Their recovery signal uses the
  existing serialized generation path; per-buffer retirement removes state and
  switching stores/restores the exact buffer's markers.
- Marker toggling, navigation, clearing, restoration, and fallback temporary
  rendering do not change text, revision, dirty state, or document undo. Local
  recovery rejects negative, over-10,000, and out-of-document lines and falls
  back to the prior valid generation.

## Manifest Evidence

The stable 15-path product/test/work-doc manifest excludes the reviewer-owned
mutable wiki index and this evidence file.

- Sorted NUL-delimited path digest:
  `bb8393e93cbebd63c16c4c8e320c330caadc760a28c0682ed5f007f00db9c535`
- Sorted `path NUL bytes NUL` digest:
  `18b0f41b48f23faa1f17834d7a8359a36de27b7212b970a33bbfc96c88932d73`

Exact staged-candidate review and canonical signed receipt remain pending; any
later product/test/work-document byte change invalidates this content verdict.

## Final Verdict

**APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** Phase 18 content may
be frozen for exact staged-candidate review. This verdict is not a receipt.

## Agent Work Log

- Read every scoped diff and the surrounding recovery capture, marker-number,
  menu validation, lifecycle admission, TextKit delegate, and native bridge
  contracts.
- Ran independent focused tests and an external package probe, reviewed all four
  remediations against current bytes, and confirmed Debug/Release summaries and
  diff hygiene.
- The `caveman-review` skill shaped findings as concise
  location/problem/fix lines. Only this review evidence and the wiki index Phase
  18 review row/work log were modified by the reviewer.
