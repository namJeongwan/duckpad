# Phase 14 Tab Lifecycle Independent Code Review

- **Date:** 2026-09-03
- **Reviewer:** `/root/phase1_code_review`
- **Final verdict:** **APPROVED — CONTENT REVIEW**
- **Final counts:** 0 Blocker, 0 Major, 0 Minor
- **Receipt:** Pending exact staged-candidate review

## Scope

The reviewed product/acceptance manifest contains these ten paths:

1. `Sources/DuckpadApplication/ScratchWorkspaceUseCase.swift`
2. `Sources/DuckpadPresentation/DuckpadMainMenuFactory.swift`
3. `Sources/DuckpadPresentation/DuckpadWindowController.swift`
4. `Sources/DuckpadPresentation/MultilineTabStripView.swift`
5. `tests/DuckpadApplicationTests/ScratchWorkspaceUseCaseTests.swift`
6. `tests/DuckpadPresentationTests/TabFlowLayoutTests.swift`
7. `tests/DuckpadEditorAdapterTests/ScintillaEditorAdapterTests.swift`
8. `docs/wiki/00-wiki-index.md`
9. `docs/wiki/16-recently-closed-tabs.md`
10. `docs/wiki/17-tab-lifecycle-commands.md`

Pre-existing user changes in `docs/wiki/04-implementation-foundation.md` and
`scripts/vendor_scintilla_5_6_6.sh`, every README, and the ignored Notepad++
checkout were excluded and preserved. The reviewer did not edit product, test,
or work-document bytes and did not stage, sign, commit, or push.

## Coverage

- Verified the process-local recent stack has an exact 100-entry cap, evicts
  only the oldest entry on overflow, and restores every retained entry in
  reverse close order through the existing durable restore transaction.
- Verified All/Others/Left/Right/Unchanged/Unpinned capture stable `TabID`
  targets in visual order. Every implicit bulk scope excludes pinned tabs;
  Unchanged additionally requires clean Domain buffer metadata. Explicit
  current-tab close remains available for pinned tabs.
- Verified targets that become dirty after admission cannot be silently closed:
  the shared `TabCloseCoordinator` re-reads the stable target and applies the
  existing exact-revision Save/Discard/Cancel review. Cancel or failure stops
  the remaining batch without reopening already durable closures.
- Verified native Tabs-menu and per-tab context-menu selectors, menu validation,
  empty-scope disabling, stable clicked-tab routing, deliberate absence of new
  key equivalents, and the existing complete-menu collision assertion.
- Verified close admission is taken synchronously on `MainActor`, accepted tasks
  are retained and joined before termination dirty review/final recovery flush,
  and post-admission commands remain blocked. Both termination approval and
  cancellation/reopened-interaction paths are covered.
- Application owns scope/history policy and Presentation only maps AppKit
  actions to Application types. No Domain or inward dependency violation was
  introduced.

## Initial Findings

`P14-01 Major — Sources/DuckpadPresentation/DuckpadWindowController.swift:L487-L503 (initial bytes): an accepted close was registered, then rechecked the later termination gate inside its queued Task, so Close All followed immediately by termination dropped the close instead of joining it. Acquire admission synchronously before registration and let that admitted task run; test queued-before-entry approval and cancel/reopen orderings.`

`P14-02 Minor — tests/DuckpadApplicationTests/ScratchWorkspaceUseCaseTests.swift:L437-L455 (initial bytes): the 100-entry test restored the whole set and checked only final membership, so FIFO would pass despite the claimed LIFO proof. Assert each restored active TabID against `closedIDs.dropFirst().reversed()` and the remaining count after every pop.`

Initial verdict was **CHANGES REQUIRED — 0 Blocker, 1 Major, 1 Minor**.
An external public-API probe reproduced P14-01 deterministically: 100/100
same-actor Close-All → termination runs aborted the accepted close.

## Focused Re-review

- **P14-01 closed:** `performClose(_:)` now checks interaction admission before
  registering the task. The registered task no longer rechecks a later
  termination lock, while calls arriving after the lock return a no-op task.
  Termination joins the exact admitted task. The external probe now completes
  100/100 runs with zero aborts; AppKit tests cover immediate approval and dirty
  termination cancellation with interaction restoration.
- **P14-02 closed:** the cap test checks all 100 expected active IDs in strict
  reverse close order and the exact 99...0 stack count after each restore.
- No remaining regression was found in pinned protection, dirty-review
  serialization, stable target routing, retry ownership, menu validation, or
  shortcut uniqueness.

The Scintilla test narrowing does not hide a Phase 14 product regression. Only
`firstVisibleLine` equality was removed from a headless rejected-replacement
assertion because AppKit may settle that viewport coordinate asynchronously.
The same test still requires exact text, revision, selection anchor/caret,
horizontal offset, wrap settings, recovery UTF-8 and undo behavior; separate
adapter recovery tests continue to cover first-visible-line capture/restore.
No Scintilla production byte changed in this slice.

Independent initial focused validation passed 6/6. Independent exact-final
focused validation passed 8/8, and the external lifecycle probe passed 100/100.
`git diff --check` passed. Builder-provided exact-final supporting evidence,
kept separate from the independent runs, is Debug 221/221 and Release 221/221
PASS; Release emitted only the existing SwiftPM convenience-symlink warning.

## Manifest Evidence

- Sorted NUL-delimited path digest:
  `6dd7a6eb829ea02d4db1a9433775ca8419c0917938d93c4d84450a10d9e79456`
- Sorted `path NUL bytes NUL` digest:
  `546f32c9ca443c033df81bdae0e912429f08a744d12349ceed19d9944da7d5be`
- Git index remained empty during content review. Exact staged candidate and
  canonical receipt remain pending.

## Final Verdict

**APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** Phase 14 product
content may be frozen for exact staged-candidate review. This verdict is not a
receipt and does not approve any later byte change.

## Agent Work Log

- `/root/phase1_code_review` independently inspected the ten-path Phase 14
  source/test/docs slice and the shared close/recovery dependencies.
- The reviewer reproduced P14-01 with an external public-API probe, reported the
  LIFO assertion gap as P14-02, then re-reviewed both remediations and reran the
  final focused suite and 100-iteration probe.
- The `caveman-review` skill shaped findings as concise
  location/problem/fix lines. Only this review record and the Phase 14 review
  row/work log in the wiki index were authored by the reviewer.
