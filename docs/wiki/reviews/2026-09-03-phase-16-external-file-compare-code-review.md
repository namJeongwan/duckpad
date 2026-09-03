# Phase 16 External File Compare — Independent Code Review

- **Reviewer:** `/root/phase1_code_review` (independent; did not implement Phase 16)
- **Date:** 2026-09-03
- **Verdict:** **APPROVED — CONTENT REVIEW**
- **Final findings:** 0 Blocker, 0 Major, 0 Minor
- **Initial findings:** 0 Blocker, 2 Major, 0 Minor; both closed below

## Scope

Reviewed the final expanded nine-path Phase 16 scope: `ScratchSession`,
`ScratchWorkspaceUseCase`, `FileDocumentUseCase`, native file panels, window
routing, two acceptance-test files, the Phase 16 work document, and the wiki
index. The Domain/Application additions were required to place revision and file
binding validation inside the authoritative workspace transaction.

Stable eight-path product/test/work-doc path+byte manifest digest, excluding the
reviewer-owned mutable index/evidence, is
`1da6b25d4d7cf5826863e07bdd8a9d3afe36729cf4a6700dbd6189f85487509e`.
The final nine-path digest including the updated wiki index is
`7649a8b41c05097dc5ba764ce9fe34770df4f16b73a5dad8244d5476eedcccc6`.

Explicitly excluded and preserved: `docs/wiki/04-implementation-foundation.md`,
`scripts/vendor_scintilla_5_6_6.sh`, README, and ignored Notepad++ material. No
product/test edit, staging, commit, or push was performed by the reviewer.

## Initial Findings

- **P16-01 Major** — `Sources/DuckpadApplication/FileDocumentUseCase.swift:239`: `pendingExternalComparison()` captured local text before asynchronous disk read and returned it without post-read ownership validation, so an accepted edit or close during the read produced a stale `.ready`; revalidate exact tab/buffer/revision/binding and editor snapshot after the read, preserving the pending conflict on failure.
- **P16-02 Major** — `Sources/DuckpadApplication/FileDocumentUseCase.swift:198`: Reload used the conflict-time context without an atomic expected-revision/binding check, so an edit after the displayed comparison or during reload I/O was overwritten and marked clean; carry the conflict token into the Domain workspace transaction and reject edit/close/rebind races before installation.

## Remediation Re-review

- **P16-01 CLOSED** — after disk read, comparison now requires unchanged exact
  `FileWorkspaceContext` plus the same editor revision. Typed
  `comparisonInvalidated` preserves local bytes, dirty state, external bytes,
  and the pending conflict on edit/close races.
- **P16-02 CLOSED** — Reload passes conflict-time revision and `FileBinding`
  through Application into `ScratchSession`; both are checked inside the serialized
  workspace transaction. Revision changes map to `editorRevisionMismatch`, while
  closed/rebound targets map to `comparisonInvalidated`; pending conflict clears
  only after successful replacement.
- External probe before remediation reproduced stale `.ready(localRevision: 1)`
  while live revision was 2, then reproduced Reload replacing a post-panel edit,
  returning saved and clean.
- The same current-byte probe now returns `comparisonInvalidated` for the read
  race and rejects post-panel Reload with expected revision 1 versus live revision
  3, preserving `mine-after-panel-opened` and dirty state.
- Independent focused adversarial suite: 9/9 PASS, covering ordinary Compare,
  oversize, edit/close during comparison read, edit after panel, edit during Reload
  read, close after panel, same-revision rebind, and Compare→Reload routing.
- Builder-reported exact supporting evidence: Debug 232/232 and Release 232/232
  PASS. Earlier parity 31/31 and governance 8/8 were supporting, not substitutes
  for current-byte race tests.
- `git diff --check`: PASS.

## Other Acceptance Checks

- Compare/oversize/failure paths do not mutate editor text, revision, selection,
  dirty state, recovery authority, or disk.
- Local UTF-8 and external encoded bytes are bounded before panel construction;
  the bound and decode/store failures are typed and preserve conflict retry.
- Repeated Compare uses an iterative loop; no async recursion growth exists.
- Presentation depends only on Application models/ports. Raw filesystem and
  workspace mutation remain below the AppKit boundary.
- Native response mapping keeps Cancel first, Compare second, Reload third, and
  Overwrite fourth. Panes are read-only/selectable and have explicit accessibility
  label/help; newline scanning recognizes CRLF, LF, CR, and other Swift newline
  graphemes without changing either snapshot.

Final verdict: **APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor**.
Exact staged-candidate review and signed receipt remain pending.

## Agent Work Log

- Inspected all final nine scoped paths and the relevant transaction/editor binding
  code; independently reproduced both initial live-race failures from `/tmp`.
- Rebuilt the external probe against remediation bytes and ran the focused 9-test
  adversarial set.
- Modified only this review evidence and the Phase 16 review row/work log in the
  wiki index.
