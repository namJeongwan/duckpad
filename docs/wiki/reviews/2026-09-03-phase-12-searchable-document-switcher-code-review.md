# Phase 12 Searchable Document Switcher Independent Code Review

- **Date:** 2026-09-03
- **Reviewer:** `/root/phase1_code_review`
- **Final verdict:** **APPROVED — CONTENT REVIEW**
- **Final counts:** 0 Blocker, 0 Major, 0 Minor
- **Receipt:** Pending exact staged-candidate review

## Scope

The intended product/acceptance set contains these ten paths:

1. `Sources/DuckpadPresentation/DocumentSwitcherPanel.swift`
2. `Sources/DuckpadPresentation/WorkspaceChromeViews.swift`
3. `Sources/DuckpadPresentation/DuckpadWindowController.swift`
4. `Sources/DuckpadPresentation/DuckpadMainMenuFactory.swift`
5. `tests/DuckpadPresentationTests/TabFlowLayoutTests.swift`
6. `tests/DuckpadPresentationTests/FileCommandRoutingTests.swift`
7. `docs/wiki/00-wiki-index.md`
8. `docs/wiki/03-development-workflow-and-roadmap.md`
9. `docs/wiki/14-workspace-chrome-and-document-dropdown.md`
10. `docs/wiki/15-searchable-document-switcher.md`

The P12-02 remediation additionally changes `Sources/DuckpadPresentation/MultilineTabStripView.swift` so hosted-view teardown owns popover dismissal; that exact closure dependency was independently reviewed. Pre-existing user changes in `docs/wiki/04-implementation-foundation.md` and `scripts/vendor_scintilla_5_6_6.sh`, every README, and the ignored Notepad++ checkout were excluded and preserved. The reviewer did not edit product, test, or work-document bytes and did not stage, sign, commit, or push.

## Review Coverage

- Inspected AppKit popover ownership, host-window observation, keyboard routing, focus, empty results, accessibility labels, teardown, and deallocation.
- Verified title/path term matching, case/diacritic folding, exact/prefix/containment tiers, deterministic visual-order ties, stable `TabID` activation, live structural updates, and the 5,000-tab interaction budget.
- Verified startup/termination admission for menu, button, direct callback, and queued controller activation paths; the switcher is dismissed when interaction locks.
- Verified `Command-Shift-O` selector wiring and whole-menu collision detection. The removed flat-menu implementation has no remaining action path.
- Presentation remains the only AppKit owner. Search emits only `TabID` and does not bypass Application workspace authority or mutate text, revision, dirty state, undo, file binding, language, or recovery.
- Verified the canonical remote wording against local `origin` fetch/push URL `https://github.com/namJeongwan/duckpad.git`, branch `main`, and the reviewed-commit-before-push policy.

## Initial Findings

`P12-01 Major — Sources/DuckpadPresentation/DocumentSwitcherPanel.swift:L20-L30: per-term scalar scoring allowed an earlier path-only match to tie and precede a later exact multi-word title. Rank the normalized whole title phrase before term fallback and add competing exact-title/path tests.`

`P12-02 Major — Sources/DuckpadPresentation/DuckpadWindowController.swift:L289-L303: closing the host window left the attached NSPopover presented; the independent AppKit probe remained true after 0.5 seconds. Observe the exact host window and dismiss during both host close and hosted-view teardown, then assert closure/deallocation.`

`P12-03 Minor — docs/wiki/14-workspace-chrome-and-document-dropdown.md:L26-L29: the Phase 11 document still described the removed flat menu/checkmark UI. Mark it historical and link the Phase 12 searchable popover.`

Initial verdict was **CHANGES REQUIRED — 0 Blocker, 2 Major, 1 Minor**. Independent focused validation passed 9/9 and the current Debug suite passed 204/204, demonstrating that the two adversarial failures were missing coverage rather than existing-suite failures.

## First Focused Re-review

- **P12-02 closed:** `DocumentSwitcherPanel` observes only its weak exact host window, removes the observer on every dismissal path, and closes on `NSWindow.willClose`; `MultilineTabStripView.tearDownHostedViews()` also dismisses. Host-close and deallocation tests pass.
- **P12-03 closed:** Phase 11 documentation now explicitly marks its flat menu as historical and links the current Phase 12 popover.
- **P12-01 remained Major:** whole-phrase tiers were added, but `tier * 1_000 + summedOffsets` could let a long tier-2 phrase-containment result sort behind tier-3 all-title terms. An independently compiled current-byte probe reproduced `[1, 0]` where tier dominance required `[0, 1]`.

Independent focused document/menu/admission/lifecycle/deallocation validation passed 11/11. Verdict remained **CHANGES REQUIRED — 0 Blocker, 1 Major, 0 Minor**.

## Final Focused Re-review

- **P12-01 closed:** candidates now carry only `(index, tier)` and sort lexicographically by `tier`, then visual `index`. No offset arithmetic can cross a tier. The exact reviewer adversarial case—long phrase containment versus compact all-title terms—is checked in the acceptance suite and passes.
- **P12-02 and P12-03 remain closed.** No regression was found in stable-ID activation, termination/startup admission, popover teardown, accessibility, shortcut collision, Clean Architecture, or retained ownership.

Independent final focused document/lifecycle/deallocation validation passed 8/8. `git diff --check` passed and the index remained empty throughout content review. Builder-provided supporting evidence, clearly separate from the independent focused runs, is final Debug 205/205 and Release 205/205 PASS.

## Final Verdict

**APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** Phase 12 content may be frozen and prepared for an exact staged-candidate review. This approval is not a receipt and does not authorize an unreviewed byte change.

## Agent Work Log

- `/root/phase1_code_review` performed the initial independent review, compiled two external adversarial probes, ran the current focused and Debug validations, and issued the first changes-required verdict.
- The same independent reviewer inspected both remediation rounds and ran focused 11/11 followed by final focused 8/8. The builder's Debug/Release 205/205 results are recorded only as supporting evidence.
- The `caveman-review` skill shaped each finding as a concise location/problem/fix line. Only this review record and the Phase 12 review row/work log in the wiki index were authored by the reviewer.
