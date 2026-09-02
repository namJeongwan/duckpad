# Phase 5 Multiline Tabs Remediation Re-review

> Status: **CHANGES_REQUIRED**
>
> Date: 2026-09-02 (Asia/Seoul)
>
> Reviewer: `/root/phase1_code_review`
>
> Commit authorization: **not granted**

## Scope

Focused independent re-review of only P5-01, P5-02 and P5-03 from the prior Phase 5 review. No new acceptance criteria were introduced. Pre-existing unrelated `docs/wiki/04-implementation-foundation.md` and `scripts/vendor_scintilla_5_6_6.sh` changes were preserved and excluded. Reviewed product source/tests were not modified, staged, or committed; README and the ignored reference tree were not accessed.

## Closure Matrix

| Finding | Status | Evidence |
| --- | --- | --- |
| P5-01 | **CLOSED** | Persistence-only changes now restore the authoritative collection selection, refresh visible accessibility state, scroll the active tab visible, and suppress delegate recursion. Targeted test PASS; external AppKit probe reports `domain_active_original=true`, `selection_target=false`, `target_was_requested=true`. |
| P5-02 | **CLOSED** | Layout generation caches row count and ordered row item ranges/bounds. Visible lookup binary-searches the first row and inspects only intersecting rows/items. Instrumented 500/5,000-tab test PASS and engine/width invalidation remains covered. |
| P5-03 | **OPEN — Major** | Duplicate presentation is removed and single-close Retry saves the newest revision exactly once, but termination Retry is not a termination operation: the shared closure always launches ordinary `requestClose`. The termination test records one closure but never invokes it. |

## Evidence

- Current 17-file Phase 5 implementation/acceptance path-and-content manifest SHA-256: `a4b5c225e9c0417df74df629b0bc6dda582fa418727e7ee1ec0b2ec4ac452ab3`.
- Focused remediation filter: PASS, 4/4.
- `swift build && swift test`: PASS, debug 115/115.
- `swift build -c release && swift test -c release`: PASS, release 115/115.
- Isolated production AppKit smoke: PASS, 50 tabs, 17 wrapped rows, exit 0.
- External failed-activation AppKit probe at `/tmp/duckpad-phase5-review-probe`: PASS with authoritative selection restored and no second activation request.
- `git diff --check`: PASS. Staging remained empty.

## Findings

### Blocker

None.

### Major

`Sources/DuckpadPresentation/DuckpadWindowController.swift:L350-L366,L602-L606; tests/DuckpadPresentationTests/FileCommandRoutingTests.swift:L342-L352`: 🔴 **P5-03 termination Retry changes operation:** after termination save failure has replied `false`, the stored Retry always calls ordinary `requestClose(tabID:decision:)`; it closes/replaces one tab and never resumes remaining dirty review, final recovery flush, or application termination, while the termination regression only counts the uninvoked closure. Carry the initiating close context into the retry: single close may restart single close, but termination must start a fresh shared termination request/review, then prove by invoking its sole Retry after a newer edit that the newest revision is saved, remaining dirty tabs are reviewed once, final flush completes, and termination receives the new result.

### Minor

None recorded. Previously documented out-of-scope features remain follow-up and do not affect this verdict.

## Exact Phase 5 Product/Acceptance File Set

1. `Sources/DuckpadApp/DuckpadMain.swift`
2. `Sources/DuckpadApplication/ScratchWorkspaceUseCase.swift`
3. `Sources/DuckpadApplication/SessionRecoveryUseCase.swift`
4. `Sources/DuckpadApplication/TabCloseCoordinator.swift`
5. `Sources/DuckpadDomain/ScratchSession.swift`
6. `Sources/DuckpadInfrastructure/LocalRecoveryStore.swift`
7. `Sources/DuckpadPresentation/DuckpadMainMenuFactory.swift`
8. `Sources/DuckpadPresentation/DuckpadWindowController.swift`
9. `Sources/DuckpadPresentation/FilePanels.swift`
10. `Sources/DuckpadPresentation/MultilineTabStripView.swift`
11. `Sources/DuckpadPresentation/TabFlowLayout.swift`
12. `docs/wiki/08-multiline-tabs.md`
13. `tests/DuckpadApplicationTests/ScratchWorkspaceUseCaseTests.swift`
14. `tests/DuckpadApplicationTests/TabCloseCoordinatorTests.swift`
15. `tests/DuckpadDomainTests/ScratchSessionTests.swift`
16. `tests/DuckpadPresentationTests/FileCommandRoutingTests.swift`
17. `tests/DuckpadPresentationTests/TabFlowLayoutTests.swift`

Review evidence is this re-review, the superseded initial review, and the corresponding Phase 5 status/work-log entries in `docs/wiki/00-wiki-index.md`. Document 04 and the vendor script are explicitly excluded.

## Verdict

**CHANGES_REQUIRED — 0 Blockers, 1 Major, 0 Minors.** P5-01 and P5-02 are closed. P5-03 is closed for single-close presentation/latest-revision behavior but remains open for a functional termination Retry.

## Agent Work Log

| Field | Record |
| --- | --- |
| Agent | `/root/phase1_code_review` — independent focused re-reviewer |
| Skill | `caveman-review`; the remaining finding uses location/problem/concrete-fix form. |
| Static work | Re-read only P5-01..P5-03 remediation code and relevant tests; traced authoritative selection, row spatial index/invalidation, typed error ownership, latest-revision Retry and termination coordinator behavior. |
| Dynamic work | Focused 4/4; debug 115/115; release 115/115; isolated 50-tab/17-row smoke; external AppKit failed-activation probe. |
| Files changed | This re-review document and Phase 5 status/work-log entries in `docs/wiki/00-wiki-index.md` only. |
| Preserved/excluded | Unrelated document 04/vendor script preserved; reviewed source/tests, README and ignored reference untouched. |
| Stage/commit | None. |
| Verdict | CHANGES_REQUIRED — 0 Blocker, 1 Major, 0 Minor. |
