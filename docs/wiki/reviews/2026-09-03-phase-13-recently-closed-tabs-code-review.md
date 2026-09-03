# Phase 13 Recently Closed Tabs Independent Code Review

- **Date:** 2026-09-03
- **Reviewer:** `/root/phase1_code_review`
- **Final verdict:** **APPROVED — CONTENT REVIEW**
- **Final counts:** 0 Blocker, 0 Major, 0 Minor
- **Receipt:** Pending exact staged-candidate review

## Scope

The reviewed product/acceptance manifest contains these eleven paths:

1. `Sources/DuckpadDomain/ScratchSession.swift`
2. `Sources/DuckpadApplication/ScratchWorkspaceUseCase.swift`
3. `Sources/DuckpadPresentation/DuckpadMainMenuFactory.swift`
4. `Sources/DuckpadPresentation/DuckpadWindowController.swift`
5. `tests/DuckpadDomainTests/ScratchSessionTests.swift`
6. `tests/DuckpadApplicationTests/ScratchWorkspaceUseCaseTests.swift`
7. `tests/DuckpadApplicationTests/SessionRecoveryUseCaseTests.swift`
8. `tests/DuckpadPresentationTests/TabFlowLayoutTests.swift`
9. `docs/wiki/00-wiki-index.md`
10. `docs/wiki/15-searchable-document-switcher.md`
11. `docs/wiki/16-recently-closed-tabs.md`

Pre-existing user changes in `docs/wiki/04-implementation-foundation.md` and
`scripts/vendor_scintilla_5_6_6.sh`, every README, and the ignored Notepad++
checkout were excluded and preserved. Existing recovery-port and editor-adapter
interfaces were inspected only as unchanged dependencies. The reviewer did not
edit product, test, or work-document bytes and did not stage, sign, commit, or
push.

## Coverage

- Verified stable tab/document/buffer identity; pinned-prefix insertion; title,
  file binding, language override, dirty flag, and revision restoration.
- Verified immutable UTF-8 recovery capture, utility-task materialization,
  editor install/retire ownership, Unicode content and view-state transfer, and
  no close-path full snapshot materialization in the production Scintilla path.
- Verified close admission to the recent stack only after both session and
  recovery commits, restore publication only after both reconstructed-session
  and restored-byte recovery commits, and failure rollback/retry behavior.
- Verified 20-entry cap, LIFO order, oldest eviction, automatic final-scratch
  replacement, customized replacement preservation, and stable retry identity.
- Verified exact `Command-Shift-T` selector/modifiers, whole-menu collision
  coverage, startup/termination validation, synchronous pending-task
  registration, and termination join before dirty review/final recovery flush.
- Domain stays free of editor/AppKit types; Application owns transaction and
  immutable capture policy through `EditorPort`; Presentation owns AppKit menu
  and lifecycle routing. Weak editor bridges do not introduce a retain cycle.

## Initial Findings

`P13-01 Major — Sources/DuckpadApplication/ScratchWorkspaceUseCase.swift:L547-L555 (initial bytes): automatic replacement eligibility checked only revision/dirty/file binding, so pin, manual language, or view-only customization could be deleted by Undo Close Tab. Compare the complete replacement metadata and default editor capture, and add pin/language/view adversarial tests.`

`P13-02 Major — Sources/DuckpadApplication/ScratchWorkspaceUseCase.swift:L74,L319-L320,L534-L586 (initial bytes): restore Retry had no closed-entry identity, so a failed newest restore followed by a successful direct restore let the stale banner restore the next older entry. Bind Retry to a stable recent-entry token and reject consumed/stale tokens before editor install or stack mutation.`

Initial verdict was **CHANGES REQUIRED — 0 Blocker, 2 Major, 0 Minor**.
The builder also found that eagerly materializing `EditorRecoverySnapshot` on
close could scale with document size on `MainActor`; the candidate was not
frozen until that path was replaced.

## Focused Re-review

- **P13-01 closed:** the automatic replacement records its complete
  `ClosedTabState`; removal requires exact current metadata plus an empty,
  revision-zero, delta-free capture with default `EditorViewState`. Edited,
  pinned, manual-language, and view-only customized replacements remain live.
- **P13-02 closed:** each recent entry owns a UUID carried by
  `PersistenceRetry.restoreClosedTab`. Expected identity is checked before
  materialization/install; a consumed retry cannot restore or pop the next LIFO
  entry.
- The stack now retains immutable `EditorRecoveryCapture`. Close remains a
  bounded capture/journal operation, while explicit restore materializes UTF-8
  in a detached utility task under the serialized workspace transaction.
- Pinned file metadata/manual language restoration and the 20-entry LIFO/evict
  policy have direct acceptance coverage. Recovery integration proves restored
  bytes are durable before UI publication, and AppKit coverage blocks
  termination approval until an accepted restore completes.
- If the same canonical file is reopened before Undo Close Tab, the closed
  content is restored under its stable IDs as a dirty, unbound
  `title (restored)` scratch. The newly opened file remains the sole owner of
  the binding, so neither version is overwritten or silently discarded.

Independent latest-byte focused validation passed 9/9. An independent full
Debug run passed 214/214 immediately before the final duplicate-path case was
added; it is not presented as an exact-final suite. `git diff --check` passed.
Builder-provided exact-final supporting evidence, kept separate from the
independent runs, is Debug 215/215 and Release 215/215 PASS.

## Manifest Evidence

- Sorted NUL-delimited path digest:
  `d67461a7c0ccde0bbff3883fe27008548cca740cc697407e520074f4b435168d`
- Sorted `path NUL bytes NUL` digest:
  `d441c2f7371e8465f14aa565cce25517d4fb784cdf736c8cd60805d238420412`
- Index was empty throughout content review; exact staged candidate and receipt
  remain pending.

## Notes

- The recent-close stack is intentionally process-local and capped by entry
  count. Cross-relaunch history and missing-file/permission presentation remain
  documented follow-ups, not claims of this slice.

## Final Verdict

**APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** Phase 13 product
content may be frozen for exact staged-candidate review. This verdict is not a
receipt and does not approve any later byte change.

## Agent Work Log

- `/root/phase1_code_review` independently inspected the exact Phase 13 source,
  tests, docs, lifecycle paths, and unchanged recovery/editor dependencies.
- The reviewer reported P13-01 and P13-02 before freeze, held the verdict while
  remediation and the capture hot-path correction were moving, then inspected
  the final duplicate-path safety bytes and ran latest focused 9/9. The earlier
  independent full Debug run passed 214/214 before that final added case;
  builder exact-final Debug/Release each passed 215/215.
- The `caveman-review` skill shaped findings as concise
  location/problem/fix lines. Only this review record and the Phase 13 review
  row/work log in the wiki index were authored by the reviewer.
