# Phase 23 Encoding and Line Endings — Independent Code Review

- **Reviewer:** `/root/phase1_code_review` (independent; did not implement Phase 23)
- **Date:** 2026-09-03
- **Candidate reviewed:** `bf601e1f180f457032df755c8a09ff8567cf6110c9228b613a3f0616cf683228`
- **Remediation candidate:** `176c5431547e826a912a75fe7e712f2d90b15156db9d0363c08b45d8445277d9`
- **Verdict:** **APPROVED — CONTENT REVIEW**
- **Current findings:** 0 Blocker, 0 Major, 0 Minor

## Scope

Reviewed the exact nine staged paths for explicit BOM-less UTF-16 open,
durable encoding/EOL conversion, scratch Save As, atomic conflict resolution,
tab/context/revision/binding authority, native menu validation/check state,
status accessibility/layout, shortcut uniqueness, and lifecycle ordering.

The unstaged user-owned `docs/wiki/04-implementation-foundation.md` and
untracked `scripts/vendor_scintilla_5_6_6.sh` were excluded and preserved.
README and ignored Notepad++ material were not inspected or changed. Product,
tests, work documentation, stage, commit, receipt, and push were not modified.

## Findings

- **P23-01 Major** — `Sources/DuckpadApplication/FileDocumentUseCase.swift:275,385-433`: overwrite retry and post-write publication reuse a stale `FileWorkspaceContext`, then `bindSavedFile` unconditionally replaces the live binding; an exact probe rebound the same-revision tab from `/tmp/A.txt` to `/tmp/B.txt` after conflict, but `.overwrite` returned `.saved` and changed it back to A, so a prompt/write suspension can overwrite the obsolete path and clobber newer tab authority. Revalidate exact tab/buffer/revision/binding before writing and atomically compare that authority when publishing the receipt; if a durable write races a rebind, preserve the newer binding and return a typed external-write/invalidated result, with conflict-prompt and blocked-write same-revision rebind tests.
- **P23-02 Major** — `Sources/DuckpadPresentation/DuckpadWindowController.swift:1219-1235,1417-1420,1450-1465,1527-1535`: a validated format action launches an untracked `Task`, while termination admission immediately locks interactions and joins only other task registries; immediate action→Cmd-Q can make the accepted task silently fail its later guard, and a task already suspended in file I/O can outlive final recovery/termination. Synchronously register accepted save/conversion work, include it in termination join before dirty review/final flush, and add clean-file immediate-action and cancellation-ignoring blocked-write termination tests proving no lost or late conversion.

## Evidence

- Candidate preparation recomputed exactly to
  `bf601e1f180f457032df755c8a09ff8567cf6110c9228b613a3f0616cf683228`.
  Parent was `83dcb74fac113e72fe1bc2123750c4409d43d3c0`, tree
  `c0de58e8fc14de24292870537504d4f9e415a8fa`, diff SHA-256
  `42684615b2bbc92574a7ebadfd9578b9d8c82e460d126197975a49ed07b12943`,
  and message SHA-256
  `b3c6955833e60c5f7f118f6632498a090985cc11882873bb4e4cab5f3cbecb39`.
- The exact English message was `feat(files): add encoding and EOL controls`
  with the two-line atomic-authority rationale. The staged set contained only
  the requested nine paths; `git diff --cached --check` passed.
- Independent focused tests passed 7/7: explicit UTF-16 open/durable
  conversion, scratch Save As, Save-panel tab switch, queued-operation tab
  switch, Korean/emoji format round trip, following ordinary-save persistence,
  and exact menu shortcut publication.
- An independent compiled Application probe reproduced P23-01 exactly:
  `before=/tmp/B.txt`, overwrite outcome `.saved`, `after=/tmp/A.txt`, with
  sentinel exit 23. This proves the newer same-revision binding is overwritten,
  not merely a theoretical UI race.
- P23-02 follows deterministically from MainActor ordering: the command body
  enqueues at line 1233 and returns; termination admission can run in the same
  turn before that task enters line 1372, where the new lock rejects it. If it
  has entered and suspended instead, `waitForAcceptedWorkspaceTasks` still has
  no reference to join it.
- The explicit codec path correctly decodes BOM-less UTF-16 LE/BE with strict
  surrogate validation; conversion preserves the independently selected
  encoding/BOM/EOL; scratch conversion routes through Save As. Menu items have
  no key equivalents, validation/check states derive from the active binding,
  and the format status control has an accessibility identifier and separate
  status-bar layout. No additional current-scope finding was found there.
- Builder Debug/Release 317/317, production format smoke, parity 31/31,
  governance 8/8, checker, and diff-check are supporting evidence only; the two
  adversarial authority paths above are not covered by those passing tests.

## Exact Staged Manifest Evidence

The sorted nine-path staged manifest has path digest
`58a1c42bdf88a9fbbd225ce4f8c0f72329568fa024b1292af004b4f3021ae3bc`
and sorted `path NUL bytes NUL` digest
`70671496aab4a8d4a002ba71ec9918d977beda6b4f472b5f4d5db36e0884daeb`.
Any product/test/work-document change requires focused re-review.

## Verdict

The initial candidate verdict was **CHANGES REQUIRED — 0 Blocker, 2 Major,
0 Minor**. The focused remediation below supersedes that verdict for the exact
current product/test/work-document bytes.

## Focused Remediation Re-review

- **P23-01 CLOSED** — `save` now rejects an already stale exact context before
  write. After a durable write, `bindSavedFileIfCurrent` publishes inside the
  workspace transaction only when TabID, BufferID, and prior `FileBinding`
  remain authoritative; concurrent text revision is deliberately allowed so
  the older durable snapshot updates observed identity while the newer edit
  remains dirty. Rebind-before-overwrite preserves both A/B bytes and B
  authority; rebind-during-write returns typed `.comparisonInvalidated`, keeps
  B authority, and cannot relabel the durable A write as current tab state.
- **P23-02 CLOSED** — native Open/Save/Save As/format actions synchronously put
  their task in `pendingFileCommandTasks` before returning. Accepted saves use
  an explicit pre-termination admission flag, while `requiresTerminationReview`
  and `waitForAcceptedWorkspaceTasks` include the registry. The exact immediate
  format-action → application-termination test proves the later lock does not
  drop the conversion, blocked cancellation-ignoring I/O delays the reply and
  recovery commit, and final flush occurs only after bytes and binding publish.
- The original external stale-binding probe now reports
  `before=/tmp/B.txt`, outcome `.failed(.comparisonInvalidated)`,
  `after=/tmp/B.txt`, exit 0. The three new adversarial tests passed 3/3
  independently; the combined original/remediation focused selection passed
  10/10.
- Surrounding explicit BOM-less UTF-16 decoding, encoding/EOL byte conversion,
  scratch Save As, active-context rejection, no-op/check-state menus,
  accessibility/status layout, and shortcut-free surface remain correct.
- Remediation candidate preparation recomputed exactly to
  `176c5431547e826a912a75fe7e712f2d90b15156db9d0363c08b45d8445277d9`.
  Parent was unchanged, tree was
  `995aacba48ccffe90ea5204d736f192139747cd8`, diff SHA-256 was
  `137a1e7058bf5cdc84e47e5d012be1cc62eff30c8f2acdf5cf9eadc48d4c87a7`,
  and message SHA-256 remained
  `b3c6955833e60c5f7f118f6632498a090985cc11882873bb4e4cab5f3cbecb39`.
  The exact 11-path stage and `git diff --cached --check` passed; doc04 and the
  vendor script remained excluded. Builder Debug/Release 320/320 is supporting
  evidence, not an independent full-suite rerun.

## Final Manifest Evidence

Exact nine-path product/test/work-document manifest (wiki index and this review
evidence excluded):

- `Sources/DuckpadApp/DuckpadMain.swift`
- `Sources/DuckpadApplication/FileDocumentUseCase.swift`
- `Sources/DuckpadApplication/ScratchWorkspaceUseCase.swift`
- `Sources/DuckpadPresentation/DuckpadMainMenuFactory.swift`
- `Sources/DuckpadPresentation/DuckpadWindowController.swift`
- `docs/wiki/26-encoding-and-line-endings.md`
- `tests/DuckpadApplicationTests/FileDocumentUseCaseTests.swift`
- `tests/DuckpadPresentationTests/FileCommandRoutingTests.swift`
- `tests/DuckpadPresentationTests/TabFlowLayoutTests.swift`

- Sorted NUL-delimited path digest:
  `1d54d83f6a146ba3a0131e2eb406bf53f0f31cb681ebb2fcc8a286a43e5fc434`
- Sorted `path NUL bytes NUL` digest:
  `2a38aa0a8e8c9aee5e7cd4c1d9296d27e3d3841d0e5e8fd3b0c16d7c5cc06edc`

Any product/test/work-document byte change invalidates this approval digest
and requires focused re-review.

## Final Verdict

**APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** P23-01 and P23-02
are closed on the exact nine-path digest above. Updating this review/index
evidence changes the staged candidate identity, so a new exact freeze is still
required before receipt creation; this verdict alone is not a signing receipt.

## Agent Work Log

- Recomputed the exact candidate/tree/diff/message and staged manifest, checked
  cached-diff hygiene and exclusions, and read every staged hunk plus the
  surrounding file transaction, workspace binding, lifecycle, menu, and status
  paths.
- Ran seven focused current-byte tests and compiled an external stale-binding
  adversarial probe without changing repository bytes.
- The `caveman-review` skill shaped findings into concise
  location/problem/fix statements. Only this review record and the matching
  wiki index review row/work log were edited.
- Recomputed the remediation identity, inspected the safe publication
  transaction and synchronous lifecycle registry, reran the three adversarial
  tests plus all ten focused format paths, and reran the original external
  stale-binding probe before granting final content approval.
