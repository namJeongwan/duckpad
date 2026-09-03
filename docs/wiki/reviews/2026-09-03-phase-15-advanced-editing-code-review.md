# Phase 15 Advanced Editing — Independent Code Review

- **Reviewer:** `/root/phase1_code_review` (independent; did not implement Phase 15)
- **Date:** 2026-09-03
- **Verdict:** **APPROVED — CONTENT REVIEW**
- **Final findings:** 0 Blocker, 0 Major, 0 Minor
- **Initial findings:** 0 Blocker, 3 Major, 0 Minor; all closed below

## Scope

Reviewed only the intended 11-path Phase 15 candidate: Application editor-command
ports, both editor adapters, menu/controller routing, the narrow Scintilla bridge,
the two touched test files, this phase's work document, and the Phase 15 index
entry/log. The reviewed path+byte manifest digest was
`fe8c0a711d41780fe4db782ffe1e37824ad3630c15829c0c07c1fa3c9d2eaf5f`.

Explicitly excluded and preserved: `docs/wiki/04-implementation-foundation.md`,
`scripts/vendor_scintilla_5_6_6.sh`, README, and ignored Notepad++ material.
No product, test, staging, commit, or push mutation was made by the reviewer.

## Findings

- **P15-01 Major** — `Vendor/Scintilla/5.6.6/bridge/DuckpadScintillaBridge.mm:511`: Join Lines computes the target endpoint from the raw selection without the endpoint-at-next-line-start correction used by validation, so selecting the first two complete lines of `a\nb\nc` joins all three (`a b c`) instead of preserving `c`; apply the same nonempty-boundary decrement before extending a single-line selection and add LF/CRLF/Unicode boundary tests.
- **P15-02 Major** — `Vendor/Scintilla/5.6.6/bridge/DuckpadScintillaBridge.mm:496`: one boolean revision preflight starts commands that can emit multiple synchronous `SCN_MODIFIED` records, so at `UInt64.max - 1` Trim Trailing Whitespace applies one reverse-ordered deletion, becomes read-only, leaves the command half-applied, and cannot undo; reserve enough revision capacity for the entire native command (or publish one atomic edit) before mutation and adversarially cover every multi-edit command near exhaustion.
- **P15-03 Major** — `Sources/DuckpadPresentation/TextViewEditorAdapter.swift:285`: fallback line moves derive the new selection from old range lengths and omit the virtual terminal line while redistributing endings, so moving `longer` below final `x` returns selection `{1,7}` and a following Delete Line erases the whole document; moving the final empty line in `a\n` also creates `\na\n` while Scintilla creates `\na`; model terminal empty lines explicitly and compute selection from rendered reordered chunks/EOLs, then cover unequal-length, empty-final, LF/CRLF, Unicode, and follow-up-command cases.

## Evidence

- `git diff --check`: PASS.
- Independent focused Debug: 4/4 PASS (`advancedLineCommandsUseNativeUTF8EditsAndGroupedUndo`, fallback advanced commands, fallback exhaustion, full-menu shortcuts).
- Independent focused Release: 4/4 PASS; these existing tests do not exercise the three adversarial boundaries above.
- External `/tmp` probe against the current local package: Join boundary produced `JOIN="a b c" REV=4`; near-exhaustion trim produced `TRIM="a  \\nb\\n" REV=18446744073709551615 CAN_UNDO=false`; fallback move produced `MOVE="x\\nlonger" SEL={1, 7}` then `AFTER_DELETE=""`; terminal-empty move produced fallback `"\\na\\n"` versus native `"\\na"`.
- Builder-reported supporting evidence (not independently rerun in full): Debug/Release 223/223 and governance 39/39 PASS.
- Clean Architecture ownership, raw `SCI_*` confinement, ready/active/no-termination menu admission, marked-text gating, and current shortcut uniqueness showed no separate blocking issue.

## Focused Remediation Re-review

- **P15-01 CLOSED** — Join Lines now applies the same exact-next-line-start
  endpoint correction during execution as during validation. Independent LF and
  Unicode CRLF tests pass; the external `a\nb\nc` probe now produces `a b\nc`
  at revision 2.
- **P15-02 CLOSED** — every native advanced command now refuses to start unless
  `2 * (documentByteLength + 1)` revision slots remain. The overflow checks are
  ordered before multiplication and the bound safely exceeds the maximum
  insertion/deletion notification count for the supported whole-document,
  selected-line, and selected-text operations. At `UInt64.max - 1`, the external
  trim probe now reports `canPerform == false`, preserves `a  \nb  \n` and its
  revision, and leaves undo empty.
- **P15-03 CLOSED** — fallback line parsing now works in UTF-16 code units at the
  AppKit boundary, explicitly models the virtual terminal empty line, redistributes
  LF/CRLF endings without changing their cardinality, and derives the moved
  selection from rendered reordered chunks. The external probes now produce
  `x\nlonger` with selection `{2,6}`, preserve `x\n` after the following Delete
  Line, and produce terminal move `\na`, matching Scintilla.
- Independent focused Debug: 5/5 PASS.
- Independent focused Release: 5/5 PASS.
- Remediated 10-path product/test/work-doc path+byte manifest digest (excluding
  reviewer-owned mutable index/evidence):
  `5a91897051561c7110dc66dcdc984f1bbfc5d31574ebe19f628cfeb9332ea072`.
- `git diff --check`: PASS after re-review evidence changes.

Final verdict is **APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor**.
Exact staged-candidate review and receipt remain separate and pending.

## Final Documentation Consistency Check

- No product or test byte changed after remediation approval; the exact nine-path
  product/test manifest remains
  `dba7c5d586cb793edc2e8ffb43f70492b69132ad8eba8e053645c7053856f596`.
- The doc-only update accurately records content approval, independent focused
  Debug/Release 5/5, final builder Debug/Release 224/224, and pending exact receipt.
  Its initially stale Commit evidence line was corrected to the final 0/0/0
  independent verdict.
- Exact current 10-path product/test/work-doc path+byte manifest digest:
  `89590bbc2c5daf36f95507cf95fe33b5b192bec16175a08dcbfe22b1e8068b9d`.
- Content approval continues to apply unchanged; `git diff --check` remains PASS.

## Agent Work Log

- Inspected all 11 scoped diffs and relevant surrounding mutation/recovery code.
- Ran focused Debug and Release tests and a standalone package probe outside the
  worktree to exercise untested selection and revision boundaries.
- Modified only this review evidence and the Phase 15 review row/work log in the
  wiki index; did not modify reviewed bytes or repository state.
- Re-inspected the exact P15-01 through P15-03 remediation, reran the standalone
  adversarial probe plus focused Debug/Release tests, and closed all three Majors.
- Reviewed the final doc-only consistency delta, verified unchanged product/test
  bytes, and recorded the final 10-path digest and 224/224 supporting evidence.
