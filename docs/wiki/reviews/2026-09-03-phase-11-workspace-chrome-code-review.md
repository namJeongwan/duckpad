# Phase 11 Workspace Chrome Independent Code Review

- **Date:** 2026-09-03
- **Reviewer:** `/root/phase1_code_review`
- **Verdict:** **APPROVED — focused re-review**
- **Counts:** 0 Blocker, 0 Major, 0 Minor

## Scope

Reviewed the current unstaged Phase 11 workspace chrome slice: five `DuckpadPresentation` files, the Scintilla bridge palette change, three acceptance-test files, `AppIcon-SOURCE.md`, ten standard iconset PNGs, `Duckpad.icns`, this phase's work document, and the Phase 11 portions of the wiki index. The pre-existing unstaged `docs/wiki/04-implementation-foundation.md` and `scripts/vendor_scintilla_5_6_6.sh`, README files, and the ignored Notepad++ checkout were excluded and preserved. No product, test, resource, stage, receipt, or commit bytes were changed by the reviewer.

## Evidence

- Read the complete changed code and relevant test bodies for banner collapse, compact multiline layout, document switching, status controls, language menu state, appearance updates, Scintilla predefined styles, and icon packaging.
- Independent focused UI/palette validation passed 5/5. Independent current Debug suite passed 197/197; the isolated Release suite passed 197/197. `git diff --check` passed.
- The provided source `/Users/namjeongwan/Downloads/Duckpad.png` is 1254×1254 RGB and SHA-256 `8aabc7d54946c849fc0659ca4d7e264edf6505aa2e3c55feba908df17fd75d7c`.
- All ten iconset PNGs have the required 16…1024 pixel dimensions and alpha. Every corner is alpha 0 except the Lanczos 16 px right corners at 1/255, every center is alpha 255, and the 1024 px alpha bounds are `(81,79)…(943,943)`, consistent with the documented centered 84% footprint.
- `Duckpad.icns` SHA-256 is `9057939b1eed79a6f4d887ad3dba694d25cb732b8d8de42ece23264d9c8d9528`; `iconutil` extraction produced exact canonical RGBA for the eight modern representations. The legacy 1x `ic04`/`ic05` representations preserve alpha bounds and remain below normalized RMSE `0.035`; the resource test and `NSImage` load passed.
- Presentation remains the only layer importing AppKit; no Domain/Application dependency inversion was introduced. Existing hosted-view deallocation and Scintilla text/revision/undo invariants passed.
- Builder evidence additionally records a macOS 13 x86_64 Release link and production Scintilla 50-tab smoke pass.
- Exact reviewed 23-path current manifest digest is recorded below after the reviewer-only index update.

## Findings

`P11-01 Major — Sources/DuckpadPresentation/WorkspaceChromeViews.swift:L82-L95,L160-L168: .bufferEdited/.tabUpdated configures one item, then synchronizeActiveState rewrites every menu item's state, so the claimed 500-tab incremental hot path is O(n) while itemUpdates reports 1. Remove the full synchronization from non-active changes, update only authoritative changed indices (two for activeTabChanged), and assert inspected/configured item count at 500/5000 tabs.`

`P11-02 Major — Sources/DuckpadPresentation/DuckpadWindowController.swift:L646-L649,L869-L871 and Sources/DuckpadPresentation/WorkspaceChromeViews.swift:L124-L127: termination locks editor input but leaves the new document/language chrome actionable, and every ready workspace event re-enables the tab strip; activation can race dirty-review/save ownership. Disable chrome synchronously for termination, compute enabled as startup-ready && !terminationReviewInProgress, restore only after denied termination, guard queued actions, and add delayed-start/termination race tests.`

`P11-03 Minor — tests/DuckpadPresentationTests/AppIconResourceTests.swift:L25-L45: the icon test checks only the top-left corner and merely opens ICNS, so the earlier opaque-right-corner defect passed. Assert all four PNG corners/expected centered alpha bounds and pixel equality for every iconutil-extracted ICNS representation.`

## Initial Verdict

**CHANGES REQUIRED.** Banner collapse, editor/status separation, stable `TabID` payloads, compact layout, palette range protection, the corrected 84% icon resources, packaging, and Clean Architecture checks pass. The per-edit O(n) menu mutation and termination lifecycle admission remain current-scope Major issues, so Phase 11 content is not approved and must not be frozen, staged, signed, or committed.

## Initial Reviewed Manifest

The exact current reviewed set contains 23 paths. SHA-256 of the LF-separated sorted paths is `5f035cf564ea88e5e00a15eedb2bcc8e8f0dae4212831f7c378a174ffadf804f`; SHA-256 of the sorted `sha256  path` records is `29a896d28f41ab58b0575b7f39eed44cf2c5f0f2c9b749a21e38696a97d5c3e0`. This set includes the final reviewer-updated Phase 11 portions of `docs/wiki/00-wiki-index.md` and excludes this review evidence file itself.

## Agent Work Log

- `/root/phase1_code_review` performed read-only code/resource inspection, independent focused and full-suite validation, source/icon SHA checks, four-corner alpha measurements, ICNS RGBA round-trip validation, dependency/lifecycle review, and diff hygiene checks.
- The `caveman-review` skill required concise `severity + file:line + concrete fix` findings; it shaped the three finding lines above without changing the review criteria.
- Only this review record and the Phase 11 review row/work log in `docs/wiki/00-wiki-index.md` were authored.

## Focused Re-review — 2026-09-03

### Scope and Evidence

- Re-read the current remediation bytes for `WorkspaceChromeViews`, `MultilineTabStripView`, `DuckpadWindowController`, `ApplicationTerminationCoordinator`, the icon resource tests, and the new termination/document-switching adversarial tests. The focused scope is the original 23 paths plus `Sources/DuckpadPresentation/ApplicationTerminationCoordinator.swift` and `tests/DuckpadPresentationTests/FileCommandRoutingTests.swift`.
- Independent focused remediation validation passed 9/9. Independent current Debug and isolated-scratch Release suites each passed 200/200. The prior macOS 13 x86_64 Release link and production Scintilla 50-tab smoke remain supporting evidence.
- `git diff --check` passed before this reviewer-only documentation update. The index remained empty, and the excluded doc04/vendor script/README/ignored reference boundaries were preserved.

### Closure

`P11-01 CLOSED — Sources/DuckpadPresentation/WorkspaceChromeViews.swift and MultilineTabStripView.swift: ordinary tab/buffer edits inspect and configure one stable-ID item; active dropdown changes touch at most previous/current items; 500/5,000-tab tests assert constant inspection; the tab strip uses cached activeIndex for edit and persistence-restore selection work.`

`P11-02 CLOSED — Sources/DuckpadPresentation/ApplicationTerminationCoordinator.swift and DuckpadWindowController.swift: beginReview acquires admission synchronously before creating asynchronous review work; editor/tab/document/language/extension interaction remains disabled across ready publications and direct or queued actions; only denied termination restores admission, while approval stays locked. Delayed-startup, blocked dirty-review, cancel, and stable-ID action tests pass.`

`P11-03 CLOSED — tests/DuckpadPresentationTests/AppIconResourceTests.swift: all four PNG corners, centered 84% alpha bounds, every iconutil representation, exact modern canonical RGBA, and fail-closed legacy alpha-bound/RMSE behavior are asserted. The current ICNS hash remains 9057939b1eed79a6f4d887ad3dba694d25cb732b8d8de42ece23264d9c8d9528.`

No regression was found in hidden-banner collapse, status/editor separation, stable-ID routing, semantic palettes, lifecycle admission, Clean Architecture, memory ownership, or text/revision/undo preservation. The startup-before-ready Find-panel regression described by the builder is closed: non-mutating panel presentation is allowed outside termination, while search/replace execution remains readiness-gated.

### Final Verdict

**APPROVED — 0 Blocker, 0 Major, 0 Minor.** The three initial findings above are retained as historical review evidence and superseded by this closure. Phase 11 content may be frozen and prepared for exact staged-candidate review/signing; no receipt is issued by this content review.

### Exact Current Manifest

The final reviewed product/acceptance set contains 25 paths and excludes this self-referential review evidence file. SHA-256 of the LF-separated sorted paths is `961d744f43b22da5aad0166a915959168c1ef0df8bae428248334f12c29eb26d`; SHA-256 of the sorted `sha256  path` records is `c97580b5f22ec5e3f563404add9b7af432ac187dba69d5bb1af6f5fad3dcb00f`.

### Focused Re-review Agent Work Log

- `/root/phase1_code_review` independently inspected P11-01…P11-03 remediation, read the targeted tests, ran focused 9/9 plus Debug/Release 200/200, and checked lifecycle/performance/icon invariants without implementing any fix.
- Only this review record and the Phase 11 review row/work log in `docs/wiki/00-wiki-index.md` were changed. Product, tests, resources, work docs, index staging, receipts, and commits were untouched.
