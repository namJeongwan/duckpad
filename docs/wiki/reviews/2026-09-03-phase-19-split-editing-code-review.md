# Phase 19 Shared-Document Split Editing — Independent Code Review

- **Reviewer:** `/root/phase1_code_review` (independent; did not implement Phase 19)
- **Date:** 2026-09-03
- **Verdict:** **APPROVED — CONTENT REVIEW**
- **Final findings:** 0 Blocker, 0 Major, 0 Minor
- **Initial findings:** 0 Blocker, 3 Major, 1 Minor; all closed below

## Scope

Reviewed the current Phase 19 changes against committed Phase 18 baseline
`bd9c43c`: two Application port files, the production Scintilla adapter, local
recovery validation, three Presentation files, the narrow Objective-C++ bridge,
five acceptance-test files, the Phase 19 work document, and the Phase 19 index
changes.

Explicitly excluded and preserved `docs/wiki/04-implementation-foundation.md`,
`scripts/vendor_scintilla_5_6_6.sh`, README, and ignored Notepad++ material. The
reviewer modified only this evidence file and the Phase 19 review row/work log;
no product/test edit, stage, commit, or push was performed.

## Findings

- **P19-01 Major** — `Sources/DuckpadEditorAdapter/ScintillaEditorAdapter.swift:74`: a rejected secondary-pane edit schedules unbound next-turn recovery, so an immediate `display` snapshots the rejected shared bytes and the delayed recovery targets the newly active buffer; bind recovery to the rejected BufferID/generation and complete or quarantine it before any display/snapshot/termination transition.
- **P19-02 Major** — `Sources/DuckpadEditorAdapter/ScintillaEditorAdapter.swift:707`: secondary revision overflow calls adapter-global `setInputEnabled(false)`, so switching from an exhausted document leaves an unrelated healthy buffer disabled; disable only both panes of the exhausted buffer and keep the lifecycle-wide input admission independent.
- **P19-03 Major** — `Sources/DuckpadEditorAdapter/ScintillaEditorAdapter.swift:378`: `applyLanguage` configures only the focused pane, leaving the peer's bridge lexer/folding/palette state stale despite the identical-language split contract; persist once and apply the complete configuration to both current pane views, with primary- and secondary-focused regressions.
- **P19-04 Minor** — `Sources/DuckpadEditorAdapter/ScintillaEditorAdapter.swift:687`: Close Split removes the secondary view from the hierarchy but retains it and its shared-document watcher in `secondaryBufferViews` until the tab retires, allowing split/close across many open tabs to retain an extra native editor per tab; release the secondary on close after storing its bounded view state and prove weak deallocation/bounded lifecycle behavior.

## Remediation Re-review

- **P19-01 CLOSED** — recovery is keyed by BufferID, disables both panes, and is
  completed synchronously before outgoing snapshot/display, capture, or
  lifecycle input lock. The original immediate-switch probe now returns
  `reject-switch=safe`; the rejected bytes never enter snapshot/recovery state.
- **P19-02 CLOSED** — revision exhaustion is tracked per BufferID and combined
  with, rather than written into, the adapter-wide lifecycle admission. Both
  panes of the exhausted document remain read-only while a subsequently shown
  healthy split reports input enabled in both panes. Accepted revision
  transitions also refresh the exhaustion set.
- **P19-03 CLOSED** — language application validates the lexer once and applies
  the full lexer/keywords/indent/fold/brace/palette configuration to primary and
  secondary views regardless of which pane has focus. Both focus directions are
  covered without changing document revision or undo ownership.
- **P19-04 CLOSED** — hiding or closing a split clears callbacks, evicts the
  secondary from its buffer cache, invalidates its native bridge, and releases
  it after stored view state is captured. Reopening creates a fresh secondary
  over the current shared document.

## Reproduction and Evidence

- The external probe first reproduced the original failures as
  `reject-switch=safe!`, `healthy-input=false`, primary/secondary language
  `cpp/null`, and a retained closed secondary. Against current bytes it returns
  `reject-switch=safe`, `healthy-input=true`, primary/secondary `cpp/cpp` with
  folding enabled, and `closed-secondary-retained=false`.
- Independent current-byte focused runs: rejected/recovery 2/2,
  exhaustion-isolation 1/1, dual-pane language 1/1, close/eviction 1/1, and
  controller routing 1/1 PASS (6/6 total).
- Builder-provided current-byte supporting evidence: editor-focused 39/39,
  Debug 270/270, and Release 270/270 PASS.
- `git diff --check`: PASS; Git index remained empty during content review.

## Architecture and Invariants

- The platform-neutral split/recovery values remain in Application, native
  document mechanics remain in the adapter/bridge, persistence validation stays
  in Infrastructure, and lifecycle/menu routing remains in Presentation. No
  inward dependency inversion or raw `SCI_*` escape was found.
- Scintilla `SCI_SETDOCPOINTER` uses the native document reference-count path,
  and primary-only modification notification avoids duplicate Application edit
  publication on the reviewed happy path. Buffer retirement clears callbacks
  and releases both cached views.
- Pending recovery is now an explicit per-buffer adapter state which is drained
  before any boundary that could publish rejected native bytes. The lifecycle
  gate remains global while revision exhaustion remains document-local.
- Shared document ownership, one primary modification publisher, pane-local
  selection/view options, and complete dual-pane language styling now agree
  with the declared Application contracts.

## Manifest Evidence

The current 15-path product/test/work-document manifest excludes the mutable
wiki index and this reviewer evidence.

- Sorted NUL-delimited path digest:
  `6e1751e77db347a7bb8329ecae5db46d44f379cf6a2a5bdccdf8c05ccf6bfcdc`
- Sorted `path NUL bytes NUL` digest:
  `365676f8a3cb9ded350755c76befb2dd591a4024306fc87d37ac4dfc7f62a5e6`

Any later product/test/work-document byte change invalidates this review digest
and requires focused re-review.

## Verdict

**APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** Phase 19 content may
be frozen for exact staged-candidate review. This verdict is not a receipt.

## Agent Work Log

- Read every scoped diff and the surrounding document sharing, notification,
  snapshot/recovery, view-state, language, menu admission, and retirement paths.
- Ran focused repository tests and the same external adversarial
  production-adapter probe before and after remediation, inspected the
  accepted-revision and lifecycle-drain follow-up, then recomputed the exact
  current product/test/work-doc manifest.
- The `caveman-review` skill shaped findings as concise
  location/problem/fix lines. Only this review record and the wiki index Phase
  19 review row/work log were changed.
