# Phase 5 Multiline Tabs Code Review

> Status: **CHANGES_REQUIRED**
>
> Date: 2026-09-02 (Asia/Seoul)
>
> Reviewer: `/root/phase1_code_review`
>
> Commit authorization: **not granted**

## Scope

Independent review of the current unstaged Phase 5 multiline-tab slice only: multirow layout/cache/resize and 500-tab updates; active visibility/order/pin/MRU/recovery migration; serialized single, bulk and termination close; real AppKit mouse, drag, keyboard, context-menu and accessibility wiring; path actions; and Clean Architecture boundaries. Close Unchanged/All/Left/Unpinned remain documented follow-up and were not treated as blockers. Pre-existing unrelated document 04 and vendor script changes were preserved and excluded. README and the ignored Notepad++ reference were neither accessed nor modified. Reviewed source/tests were not modified, staged, or committed.

## Evidence

- Phase 5 implementation/test/document-08 bytes: 15-file path-and-content manifest SHA-256 `dec960f3caca98e00853f130142ae649b26df5fb6411cf6df3f3a236632b31df`.
- Focused tab/layout/close/MRU suite: PASS, 32/32.
- `swift build && swift test`: PASS, debug 112/112.
- `swift build -c release && swift test -c release`: PASS, release 112/112.
- Production AppKit smoke with an isolated recovery root: PASS, 50 tabs, 17 wrapped rows, active tab visible, exit 0.
- Failed-activation AppKit probe built outside the worktree at `/tmp/duckpad-phase5-review-probe`: after a collection selection requested tab 1 and the serialized activation commit failed, output was `domain_active_original=true` and `selection_target=true`, proving the collection selection diverged from the authoritative workspace active tab.
- Static event tracing confirmed selection, close button, `otherMouseDown`, drag pasteboard/drop, context actions, menu selectors and accessibility callbacks reach controller/application ports. The tests route middle-click/drop through helpers rather than synthesized hardware events; that gap is non-blocking because the production overrides/delegate wiring is present.
- Staging remained empty.

## Findings

### Blocker

None.

### Major

`Sources/DuckpadPresentation/MultilineTabStripView.swift:L276-L300; Sources/DuckpadPresentation/DuckpadWindowController.swift:L420-L430`: 🔴 **P5-01 active-selection divergence:** `.persistence` returns without reconciling `selectionIndexPaths`; when an AppKit click selects B but its serialized activation save fails, Domain/editor stay on A while the collection remains selected on B. Synchronize selection and active visibility from every authoritative snapshot without a full reload, and add the reproduced failed-activation delegate test.

`Sources/DuckpadPresentation/TabFlowLayout.swift:L135-L169`: 🔴 **P5-02 cache contract violation:** `layoutAttributesForElements(in:)` scans all cached attributes and `rowCount` rescans every row index, so scrolling/resizing remains O(tab count) per query despite document 08 claiming O(1) visible/row metadata. Cache `rowCount` plus row/index ranges or binary-searchable frame bounds, and instrument 50/500-tab visible-rect queries rather than only per-item lookup/generation count.

`Sources/DuckpadPresentation/DuckpadWindowController.swift:L445-L455; Sources/DuckpadPresentation/DuckpadWindowController.swift:L492-L494; Sources/DuckpadPresentation/DuckpadWindowController.swift:L521-L548`: 🔴 **P5-03 duplicate save-failure ownership:** close-save failure is first presented by `resolve(fileOutcome:)`, then becomes a generic coordinator `.failed` and is presented again as a banner whose Retry closure is empty. Return a typed save result that preserves already-presented/actionable ownership, or centralize presentation once with a real retry; test single and termination close failures with production-equivalent distinct presenters.

### Minor

None recorded. Deferred close scopes and physical hardware/assistive-technology checks remain follow-up notes and do not affect this verdict.

## Exact Phase 5 Changed-file List

The reviewed implementation/acceptance slice is exactly these 15 files:

1. `Sources/DuckpadApp/DuckpadMain.swift`
2. `Sources/DuckpadApplication/ScratchWorkspaceUseCase.swift`
3. `Sources/DuckpadApplication/SessionRecoveryUseCase.swift`
4. `Sources/DuckpadApplication/TabCloseCoordinator.swift`
5. `Sources/DuckpadDomain/ScratchSession.swift`
6. `Sources/DuckpadInfrastructure/LocalRecoveryStore.swift`
7. `Sources/DuckpadPresentation/DuckpadMainMenuFactory.swift`
8. `Sources/DuckpadPresentation/DuckpadWindowController.swift`
9. `Sources/DuckpadPresentation/MultilineTabStripView.swift`
10. `Sources/DuckpadPresentation/TabFlowLayout.swift`
11. `docs/wiki/08-multiline-tabs.md`
12. `tests/DuckpadApplicationTests/ScratchWorkspaceUseCaseTests.swift`
13. `tests/DuckpadApplicationTests/TabCloseCoordinatorTests.swift`
14. `tests/DuckpadDomainTests/ScratchSessionTests.swift`
15. `tests/DuckpadPresentationTests/TabFlowLayoutTests.swift`

Review evidence consists of this document and Phase 5 status/work-log entries in `docs/wiki/00-wiki-index.md`. `docs/wiki/04-implementation-foundation.md` and `scripts/vendor_scintilla_5_6_6.sh` are explicitly excluded as unrelated pre-existing changes.

## Verdict

**CHANGES_REQUIRED.** Findings: **0 Blockers, 3 Majors, 0 Minors**. Core wrap, resize, ordering, pin/MRU, recovery migration, close serialization, revision guards, drag/context/accessibility wiring and ordinary regression suites pass. Failed activation must restore authoritative selection, the promised cached query complexity must be implemented, and close-save failures need single actionable presentation ownership before CONTENT APPROVED.

## Agent Work Log

| Field | Record |
| --- | --- |
| Agent | `/root/phase1_code_review` — independent Phase 5 code reviewer |
| Skill | `caveman-review`; findings use location/problem/concrete-fix form. |
| Static work | Read all 15 Phase 5 implementation/acceptance files and relevant test bodies; traced Domain order/pin/MRU, recovery v1 migration, coordinator serialization/revision races, layout caching, AppKit delegates/selectors/context/accessibility and path actions. |
| Dynamic work | Focused 32/32; debug 112/112; release 112/112; production 50-tab/17-row smoke; external failed-activation selection probe. |
| Files changed | This review document and Phase 5 status/work-log entries in `docs/wiki/00-wiki-index.md` only. |
| Preserved/excluded | Unrelated document 04 and vendor script; README and Notepad++ reference untouched; reviewed source/tests unchanged. |
| Stage/commit | None. |
| Verdict | CHANGES_REQUIRED — 0 Blocker, 3 Major, 0 Minor. |
