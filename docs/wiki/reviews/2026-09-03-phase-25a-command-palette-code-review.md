# Phase 25A Command Palette — Independent Code Review

- **Reviewer:** `/root/phase1_code_review` (independent; did not implement Phase 25A)
- **Date:** 2026-09-03
- **Candidate:** `51183bad8327e5ad28f9cf6ab540f44d33d608ec2728bb93e0f48da308db3f0e`
- **Remediation candidate:** `7f652642c679eae6c8bc1f784765019a5f663e1b0f0cb7c5e614a78e75373d8b`
- **Verdict:** **APPROVED — CONTENT REVIEW**
- **Current findings:** 0 Blocker, 0 Major, 0 Minor

## Scope

Reviewed the exact eight staged paths: command-palette registry/search/AppKit
popover, main-menu and window-controller integration, Presentation tests,
Phase 24 status correction, Phase 25A work document, and wiki index. Checked
menu-item target/selector/represented-object authority, validation and dispatch,
extension refresh, window/termination lifecycle, retain cycles, keyboard and
shortcut behavior, accessibility/Reduce Motion, search ranking/scaling, and the
documented macro boundary.

User-owned `docs/wiki/04-implementation-foundation.md` and untracked
`scripts/vendor_scintilla_5_6_6.sh` remained outside the candidate. README,
ignored Notepad++, gitlinks, product/source/test/work-document bytes, stage,
receipt, commit, and push were not modified by this review.

## Findings

- **P25A-01 Major** — `Sources/DuckpadPresentation/CommandPalettePanel.swift:54-59,276-283`: availability is validated only while the registry snapshot is built; activation trusts cached `command.isEnabled`, so a command enabled at presentation but disabled before Return/double-click still reaches `onExecute`, bypassing its current `NSMenuItemValidation`. Resolve the original target and re-run its current validator immediately before dismissal/dispatch, fail closed when unavailable, and add an enabled→disabled-after-open regression that proves zero action invocations.
- **P25A-02 Minor** — `Sources/DuckpadPresentation/CommandPalettePanel.swift:201-206`, `Sources/DuckpadPresentation/DuckpadWindowController.swift:2532-2548`: an open palette retains old menu items when extension refresh rebuilds `NSApplication.mainMenu`, so newly granted/revoked commands remain stale until reopen. Dismiss or re-apply the current menu after rebuild while preserving query/selection, and test refresh while presented.
- **P25A-03 Minor** — `tests/DuckpadPresentationTests/CommandPalettePresentationTests.swift:68-131`: tests exercise registry/search/direct activation without presenting the popover, leaving host-window close, termination dismissal, controller/panel release, nil-target responder routing, and Reduce Motion animation unexecuted. Add hosted AppKit probes for these lifecycle/accessibility branches.

## Evidence

- Candidate preparation recomputed exactly to
  `51183bad8327e5ad28f9cf6ab540f44d33d608ec2728bb93e0f48da308db3f0e`.
  Parent is `3721fcf247ed6c2e6c6c0cca4e9a5fc15d75e2a0`, tree is
  `93d965eef0e1ae1d1c5ad9d74c11bfa629cadbae`, diff SHA-256 is
  `9b81e5903aad87d2909c0375903c831ec53125e5f7ad699d8c0aae85625c9045`,
  and message SHA-256 is
  `6665c8c3786720f7a89c268fc1ae7dd77aab1ea060f712bac3eba3fec70c2d8a`.
- Exact eight-path candidate path digest is
  `283bd0e80401c83f9a2e22f810d059e3d5aa1d39a9d0a6ea7494cb833a8759f2`;
  sorted `path NUL bytes NUL` digest is
  `98876d59e9ace8baed904123a3d1c3fc2dc765c7ac1de278b38444d42789e346`.
  The seven product/test/work-document paths excluding the index have byte
  digest `d4aac6619c6d22e036cd8b38f6a56adeac70b96b647640da88ddfcca861ee774`.
- `git diff --cached --check` passed; excluded/forbidden paths and gitlinks are
  absent. The English Conventional Commit message explicitly says macro support
  is not added; parity baseline `C9.F02` remains honestly `Missing`.
- Independent focused registry/search/disabled-command/menu tests passed 4/4.
  They cover only commands disabled before registry capture and therefore do
  not close P25A-01.
- An independent exact-algorithm 5,000-command benchmark completed 100 searches
  in 1.519 seconds (about 15 ms per query), with deterministic tier then visual
  index ordering. No scaling/ranking finding was reproduced.
- Static lifecycle inspection confirmed weak controller callbacks, host-close
  observer removal, teardown and termination dismissal, and Reduce Motion
  animation selection. A standalone nil-target probe could not acquire a key
  window in the noninteractive runner (`keyWindow=nil`, `sendAction=false`), so
  it did not validate responder-chain execution; the implementation preserves
  the original nil target for dynamic AppKit routing, and the missing hosted
  regression is recorded as P25A-03 rather than asserted as a product defect.
- Builder Debug/Release 336/336, parity 31/31, governance 8/8, and expected
  structural-checker release=false are supporting evidence only.

## Initial Verdict

**CHANGES REQUIRED — 0 Blocker, 1 Major, 2 Minor.** P25A-01 blocks content
approval and refreeze. No receipt is authorized. This review/index evidence
also invalidates candidate `51183bad…`; remediation requires a new exact
candidate after execution-time validation is made authoritative.

## Focused Remediation Re-review

- **P25A-01 CLOSED** — `CommandPaletteRegistry.commands` resolves both explicit
  and nil-target actions before the popover changes the responder chain and
  stores only a weak exact-target reference. `isCurrentlyEnabled` re-runs that
  target's validator for displayed rows and again immediately before dispatch;
  a deallocated target or newly disabled command fails closed without invoking
  `onExecute`. The controller then sends the original menu item, selector, and
  represented object to that exact target after its own termination/startup
  admission check.
- **P25A-02 CLOSED** — every app `installMainMenu` publication notifies the
  owning controller. `refreshIfPresented` replaces only a visible palette's
  registry from the new current menu; `apply` leaves the search-field string
  intact and refilters it, so extension add/remove refresh neither loses the
  query nor retains stale command items.
- **P25A-03 CLOSED** — direct regressions now cover enabled→disabled activation,
  injected nil-target resolution and exact-target dispatch, visible menu
  refresh, host-window close, termination dismissal, and both Reduce Motion
  animation decisions. Static weak-reference inspection proves target release
  fails closed; the existing controller/window hosted-view deallocation test
  also remains green.
- Remediation candidate preparation recomputed exactly to
  `7f652642c679eae6c8bc1f784765019a5f663e1b0f0cb7c5e614a78e75373d8b`.
  Parent remains `3721fcf247ed6c2e6c6c0cca4e9a5fc15d75e2a0`, tree is
  `cdd19784b5f67342334db4b2450fb3b73c2c212b`, diff SHA-256 is
  `8eb0f43db475162d43dd7681766c12883459536e02e5dc3974a1519ff8e2f93e`,
  and message SHA-256 remains
  `6665c8c3786720f7a89c268fc1ae7dd77aab1ea060f712bac3eba3fec70c2d8a`.
  Exact 10-path stage, cached diff check, exclusions, and no-gitlink boundary
  passed.
- Exact eight-path product/test/work-document manifest (wiki index and this
  review excluded) has sorted NUL-delimited path digest
  `766df675bf84978f67ca250e62c1c854a34e59582eb4bd66d3a6935f8de874fa`
  and sorted `path NUL bytes NUL` digest
  `257ab07e9b60272e7b937c56ac3296c798f159daa2ac09dd46ff6ba113b9292b`.
- Independent remediation validation passed palette/lifecycle 7/7, native
  shortcut 1/1, extension rebuild 1/1, and existing hosted deallocation 1/1.
  Builder Debug/Release 340/340, parity 31/31, governance 8/8, expected
  structural-checker release=false, and diff check are supporting evidence.

## Final Verdict

**APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** P25A-01 through
P25A-03 are closed and Phase 25A content is authorized for exact-candidate
refreeze and receipt review. These review/index edits invalidate candidate
`7f652642…`; a new exact candidate is required before signing.

## Agent Work Log

- Recomputed candidate/tree/diff/message and exact manifests; checked cached
  whitespace, exclusions, forbidden paths, and gitlinks.
- Read all eight staged diffs and surrounding menu validation, extension-menu
  rebuild, termination admission, teardown, and command action guards.
- Ran independent focused 4/4, a 5,000-command scaling probe, and a constrained
  nil-target AppKit probe. The `caveman-review` skill kept each finding in
  concise location/problem/fix form.
- Modified only this independent review record and the Phase 25A wiki-index
  review row/work log; no candidate bytes were staged or signed.
- Recomputed remediation candidate `7f652642…`, inspected weak exact-target
  lifetime, current validation/dispatch, live-menu query-preserving refresh,
  and hosted teardown; ran independent focused 9/9 plus deallocation 1/1 and
  recorded final approval without touching product/test/stage bytes.
