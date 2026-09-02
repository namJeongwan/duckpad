# Phase 5 Multiline Tabs Final Remediation Re-review

> Status: **APPROVED — CONTENT REVIEW**
>
> Date: 2026-09-02 (Asia/Seoul)
>
> Reviewer: `/root/phase1_code_review`
>
> Commit authorization: **not granted; exact-candidate receipt remains required**

## Scope

Final focused independent re-review of P5-03 termination Retry remediation, with regression confirmation that P5-01 and P5-02 remain closed. The review added no out-of-scope criteria. Pre-existing unrelated `docs/wiki/04-implementation-foundation.md` and `scripts/vendor_scintilla_5_6_6.sh` changes were preserved and excluded. Reviewed product source/tests were not modified, staged, or committed; README and the ignored reference tree were not accessed.

## Closure

| Finding | Status | Evidence |
| --- | --- | --- |
| P5-01 | **CLOSED** | Persistence failure restores authoritative Domain/editor/collection selection, visible accessibility state and active visibility without delegate recursion. Targeted test and external AppKit probe PASS. |
| P5-02 | **CLOSED** | Cached O(1) row count and binary-searched O(log rows + visible rows/items) query remain intact; 500/5,000-tab instrumentation PASS. |
| P5-03 | **CLOSED** | Retry preserves stable single/bulk target IDs. Termination Retry records only the failed tab ID, calls the app-installed native termination handler, receives a new `.terminateLater`/reply cycle, saves the newly accepted revision, reviews the remaining original dirty tab, performs durable recovery work/final flush, and replies once per cycle. Weak controller/coordinator captures avoid stale window ownership. |

## Static Evidence

- `ApplicationTerminationCoordinator` owns only one in-flight review, clears old reply slots before delivery, and defers an early Retry until that review has replied. The production app delegate installs `NSApplication.shared.terminate(nil)` as the new native request handler.
- `DuckpadWindowController` distinguishes `.tabs([TabID])` from `.termination`. Ordinary and bulk retries reuse the original stable ID set and skip targets already gone; termination stores only the failed `TabID` and starts the coordinator's new native cycle.
- The retried termination decision auto-selects Save only for the failed stable ID. `TabCloseCoordinator` then obtains the current snapshot/revision and passes that revision to `saveBeforeClosing`; other dirty tabs continue through ordinary serialized review.
- Retry closures capture the controller weakly; the production native handler captures no window/controller. Old application replies are cleared before the retry handler can create the new cycle, preventing stale callback reuse or double reply.
- The termination regression drains the explicit pending-persistence seam before injecting the newest edit, verifies the active tab/editor, and asserts immediate `revision == failedRevision + 1`. This replaces the ineffective post-edit polling that could only observe—never recover—a transaction-time rejected test edit.

## Dynamic Evidence

- Focused set (`terminationFileRetry...`, single Retry/latest revision, bulk failure targets, failed activation, 500/5,000 visible query): PASS, 5/5.
- Same full focused set repeated five times: PASS, 25/25 aggregate.
- `swift build && swift test`: PASS, debug 116/116 after synchronization correction.
- `swift build -c release && swift test -c release`: PASS, release 116/116 after synchronization correction.
- Before that correction, two debug and one release full-suite runs consistently exposed the test setup race: the one-shot edit occurred while `ScratchWorkspaceUseCase` was transaction-busy, was correctly rejected, and later polling could not accept it. This evidence drove the deterministic pre-edit drain/assertion; it is not hidden as a passing run.
- External failed-activation AppKit probe: `domain_active_original=true`, `selection_target=false`, `target_was_requested=true`.
- Isolated production AppKit smoke: PASS, 50 tabs, 17 wrapped rows, exit 0.
- `git diff --check`: PASS. Staging remained empty.

## Findings

### Blocker

None.

### Major

None.

### Minor

None recorded. Previously documented deferred Phase 5 parity and physical hardware/assistive-technology checks remain follow-up notes and do not affect this focused verdict.

## Exact Phase 5 Product/Acceptance File Set

Current implementation/acceptance scope is exactly these 18 files:

1. `Sources/DuckpadApp/DuckpadMain.swift`
2. `Sources/DuckpadApplication/ScratchWorkspaceUseCase.swift`
3. `Sources/DuckpadApplication/SessionRecoveryUseCase.swift`
4. `Sources/DuckpadApplication/TabCloseCoordinator.swift`
5. `Sources/DuckpadDomain/ScratchSession.swift`
6. `Sources/DuckpadInfrastructure/LocalRecoveryStore.swift`
7. `Sources/DuckpadPresentation/ApplicationTerminationCoordinator.swift`
8. `Sources/DuckpadPresentation/DuckpadMainMenuFactory.swift`
9. `Sources/DuckpadPresentation/DuckpadWindowController.swift`
10. `Sources/DuckpadPresentation/FilePanels.swift`
11. `Sources/DuckpadPresentation/MultilineTabStripView.swift`
12. `Sources/DuckpadPresentation/TabFlowLayout.swift`
13. `docs/wiki/08-multiline-tabs.md`
14. `tests/DuckpadApplicationTests/ScratchWorkspaceUseCaseTests.swift`
15. `tests/DuckpadApplicationTests/TabCloseCoordinatorTests.swift`
16. `tests/DuckpadDomainTests/ScratchSessionTests.swift`
17. `tests/DuckpadPresentationTests/FileCommandRoutingTests.swift`
18. `tests/DuckpadPresentationTests/TabFlowLayoutTests.swift`

The ordered path-and-content manifest SHA-256 is `b2758b324d67e8a58e1bd7e0f315e8b3fe63960c79fc3091c50bb35e672110b1`. Review evidence consists of the initial review, first remediation re-review, this final re-review and corresponding Phase 5 entries in `docs/wiki/00-wiki-index.md`. Document 04 and the vendor script are explicitly excluded.

## Verdict

**APPROVED — CONTENT REVIEW. Findings: 0 Blockers, 0 Majors, 0 Minors.** This approves the reviewed Phase 5 content only. Commit authorization still requires an exact staged candidate and canonical signed receipt.

## Agent Work Log

| Field | Record |
| --- | --- |
| Agent | `/root/phase1_code_review` — independent final focused re-reviewer |
| Skill | `caveman-review`; no actionable finding remains. |
| Static work | Traced native termination retry installation, new cycle/reply ownership, stable target IDs, current-revision save, remaining dirty review, final flush, weak captures and early-retry deferral; rechecked P5-01/P5-02 closure. |
| Dynamic work | Focused 5/5, five repetitions 25/25, debug 116/116, release 116/116, external AppKit selection probe and production 50-tab/17-row smoke. |
| Synchronization audit | Reproduced the original post-edit polling race in full debug/release, identified transaction-busy edit rejection, then verified the pre-edit pending-persistence drain plus immediate revision assertion in focused repetitions and both full configurations. |
| Files changed | This final re-review document and Phase 5 status/work-log entries in `docs/wiki/00-wiki-index.md` only. |
| Preserved/excluded | Unrelated document 04/vendor script preserved; reviewed source/tests, README and ignored reference untouched. |
| Stage/commit | None. |
| Verdict | APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor. |
