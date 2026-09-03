# Phase 21 Native Multiple Windows — Independent Code Review

- **Reviewer:** `/root/phase1_code_review` (independent; did not implement Phase 21)
- **Date:** 2026-09-03
- **Verdict:** **APPROVED — CONTENT REVIEW**
- **Final findings:** 0 Blocker, 0 Major, 0 Minor
- **Findings raised during review:** 0 Blocker, 3 Major, 1 Minor; all closed below

## Scope

Reviewed the initial staged Phase 21 candidate
`fc1516fef89aa386e0f7b2266cadffb211a61c1d233473534b5cf425bab5e4da`
and the final remediation candidate
`0249a77ee9743816c752758290c3d2cf574f64717f8f0352a9c15c9048907953`
against parent `f8925e383bb3c5153024a86ec148ae141bdd533b`: application composition,
multi-window termination coordinator, descriptor-bound recovery store, native
menu/controller lifecycle, four acceptance-test files, the Phase 21 work
document, and its wiki index entry.

Explicitly excluded and preserved `docs/wiki/04-implementation-foundation.md`
and `scripts/vendor_scintilla_5_6_6.sh`. README and ignored Notepad++ material
were not inspected or changed. The reviewer changed only this evidence file and
the Phase 21 index review row/work log; product, tests, work documentation,
index, stage, commit, push, and receipt were otherwise untouched.

## Findings

- **P21-01 Major** — `Sources/DuckpadPresentation/ApplicationTerminationCoordinator.swift:33`: `attach` only registers a weak controller while an application review is in flight, so the asynchronous restore at `Sources/DuckpadApp/DuckpadMain.swift:388` can publish an unlocked, unreviewed window after Cmd-Q's controller snapshot and before the final reply; track app-wide admission, synchronously admit/queue every late attachment (or join restoration before admission), and test blocked quit + late restored window mutation/final flush.
- **P21-02 Major** — `Sources/DuckpadApp/DuckpadMain.swift:348`: native close removes the controller from termination ownership, then launches an untracked autosave/reset Task whose failure is ignored, so an immediate Cmd-Q may exit before reset and resurrect an explicitly closed recovery archive; retain and join close-cleanup tasks in application termination, define reset-failure handling, and test blocked reset + immediate quit + relaunch absence.
- **P21-03 Major** — `Sources/DuckpadApp/DuckpadMain.swift:426`: discovery validates a UUID entry with descriptor-relative `fstatat(...AT_SYMLINK_NOFOLLOW)` but returns a pathname that path-based `LocalRecoveryStore` later follows, leaving a validation/use swap that can redirect load, cleanup, chmod, or writes outside the selected recovery directory; retain descriptor/inode authority through recovery access or rework the store to perform no-follow descriptor-relative operations, with deterministic directory-to-symlink/file swap probes.
- **P21-04 Minor** — `tests/DuckpadPresentationTests/FileCommandRoutingTests.swift:965`: all coordinator tests attach both windows before quit and the clean-close test has no recovery store, so neither late attachment nor close-reset ordering is exercised; add the two adversarial lifecycle tests required by P21-01/P21-02.

## Remediation Re-review

- **P21-01 CLOSED** — application review state is explicit; `attach` immediately
  admission-locks and queues a late controller. The review loops to a fixed
  point, re-draining the queue after every suspended cleanup, while a
  post-approval attachment is synchronously locked. Tests cover attachment
  during a blocked dirty decision and during a blocked close cleanup.
- **P21-02 CLOSED** — teardown registers recovery reset before detaching the
  controller. The shared coordinator retains and joins cleanup records before
  its AppKit reply; a failed cleanup denies termination and remains retryable.
  Reset invalidates the debounce token and enters the serialized recovery
  operation directly rather than awaiting a dormant autosave timer.
- **P21-03 CLOSED** — restored roots retain duplicated parent/root descriptors
  and use `openat`, `fstatat`, `O_NOFOLLOW`, descriptor-bounded reads,
  descriptor-relative publish/cleanup/reset, and inode comparisons. Root reset
  now repeats dev/inode validation after recursive removal and immediately
  before `unlinkat`; deterministic symlink, regular-file, and during-reset
  directory swaps cannot redirect load, mutation, or deletion.
- **P21-04 CLOSED** — focused tests now exercise late attachment at both review
  suspension points, blocked reset plus quit, cleanup failure/retry, verified
  root swaps, reset/recreate, and corrupt-generation fallback.

## Reproduction and Evidence

- Candidate identity recomputation matched exactly: parent
  `f8925e383bb3c5153024a86ec148ae141bdd533b`, tree
  `5e96a66ed071edc8a26e66966943d1addf17d327`, diff SHA-256
  `7e9589c580ae33a27e378f79b77722f31b4eb8222eb8c0a8819a8deb3daa211b`,
  message SHA-256
  `377ce9885b4f2d05f6852873038395a0d5f26d54c11d8718b1add4216f9d6a31`.
- The staged set was exactly the requested nine files and
  `git diff --cached --check` passed. The excluded doc04/vendor-script changes
  remained unstaged/untracked.
- Independent focused tests passed 5/5: two-window cancel/re-enable, all-window
  final flush, red-close isolation, same-file stale-save conflict, and exact
  New Window/menu shortcut publication.
- Builder-provided supporting evidence was reviewed but not independently
  rerun in full: Debug 293/293, Release 293/293, parity 31/31, governance 8/8,
  and the two-launch two-window recovery smoke all PASS.
- Structural adversarial trace for P21-01: `applicationShouldTerminate` takes
  `liveControllers()` and admits its result; `attach` during the subsequent
  await only updates `controllers`/`attachmentOrder`, never `admittedIDs` or
  `reviewQueue`, while the new controller remains mutation-enabled.
- Structural adversarial trace for P21-02: `onClosed` removes the only strong
  controller/termination registration before creating the reset Task; neither
  the app delegate nor coordinator stores that Task, so no termination path can
  await it or observe reset failure.
- Structural adversarial trace for P21-03: the verified descriptor is closed
  when discovery returns; the later `LocalRecoveryStore(root:)` performs
  `FileManager`/pathname loads and directory mutation, so the checked inode is
  not the used inode.
- Final candidate identity recomputation matched exactly: tree
  `b0e2fc8d29d3d81d65c62f3b18c30f40bf44e581`, diff SHA-256
  `c63439914a362a3e87a06abe2530f94c67b39c75aed68b3e1423d8e5cd8bb66d`,
  and the unchanged message SHA-256
  `377ce9885b4f2d05f6852873038395a0d5f26d54c11d8718b1add4216f9d6a31`.
- Independent final focused runs passed: late attachment during dirty review
  1/1, late attachment during cleanup plus cleanup join 1/1, cleanup
  failure/retry 1/1, post-recursion root swap 1/1, and all verified-root
  lifecycle/security tests 5/5. The invoked runs total 8/8 with the
  post-recursion case intentionally repeated inside the verified-root group.
- Builder-provided final supporting evidence: Debug 301/301, Release 301/301,
  three-launch create-two → restore/close → restore-one production smoke,
  parity 31/31, governance 8/8, and diff-check all PASS.

## Architecture and Invariants

The per-window Domain/Application/Presentation composition and same-file
`FileIdentity` conflict boundary are otherwise sound. Controllers are weakly
registered by the coordinator and app-owned closures use weak captures, so no
new steady-state controller retain cycle was found. The defects above are
authority/lifecycle ordering failures: the set of windows and recovery roots
covered by an accepted termination must remain closed under concurrent attach,
and recovery identity/durability cannot be dropped between validation, close,
and application reply.

## Manifest Evidence

Exact staged ten-path product/test/work-document manifest (wiki index and this
review evidence excluded):

- `Sources/DuckpadApp/DuckpadMain.swift`
- `Sources/DuckpadInfrastructure/LocalRecoveryStore.swift`
- `Sources/DuckpadPresentation/ApplicationTerminationCoordinator.swift`
- `Sources/DuckpadPresentation/DuckpadMainMenuFactory.swift`
- `Sources/DuckpadPresentation/DuckpadWindowController.swift`
- `docs/wiki/24-native-multiple-windows.md`
- `tests/DuckpadApplicationTests/FileDocumentUseCaseTests.swift`
- `tests/DuckpadInfrastructureTests/LocalRecoveryStoreTests.swift`
- `tests/DuckpadPresentationTests/FileCommandRoutingTests.swift`
- `tests/DuckpadPresentationTests/TabFlowLayoutTests.swift`

- Sorted NUL-delimited path digest:
  `6cc1b10d74379b0bcad04d8e64737788ee2867bb3dd7b2fef19ab0837ddbd4e0`
- Sorted `path NUL bytes NUL` digest:
  `5541ec23e9b8e7b0c77fe6618422c3d6121123a8cd71ba816e27893d49137d90`

Any product/test/work-document byte change invalidates this digest and requires
focused re-review.

## Verdict

**APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** Phase 21 content may
be restaged with this final review evidence for a new exact-candidate review.
The superseded/changed candidate `0249a77e…` must not be signed; this verdict is
not a receipt.

## Agent Work Log

- Read every staged source/test/work-document hunk and the relevant surrounding
  controller startup, termination, recovery-reset, menu, same-file conflict,
  and local recovery-store code.
- Recomputed exact candidate identity, staged set, message, and manifest
  digests; ran five focused acceptance tests and checked index hygiene.
- The `caveman-review` skill shaped findings as concise
  location/problem/fix lines. Only this review record and the wiki Phase 21
  review row/work log were edited.
- Re-reviewed both residual interleaves after candidate `842df3ec…` was
  abandoned, independently reran the final focused tests against
  `0249a77e…`, and updated only this record and the index to final approval.
