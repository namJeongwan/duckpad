# Phase 24 Settings, Themes, and Accessibility — Independent Code Review

- **Reviewer:** `/root/phase1_code_review` (independent; did not implement Phase 24)
- **Date:** 2026-09-03
- **Candidate reviewed:** `e50c26612b2d9146e8c2ab649c8706e89db6a724867dd22e28c294a684d5213d`
- **Remediation candidate:** `57fb25d0d779dd5ed6020a69e1c721fc5d296c3d4a412f9754e5af83d817dd59`
- **Final remediation candidate:** `56e800dc8b1e7cd006d41874a8792e6027468b12584517f55e7d0e375719c5e5`
- **Verdict:** **APPROVED — CONTENT REVIEW**
- **Current findings:** 0 Blocker, 0 Major, 0 Minor

## Scope

Reviewed the exact 18 staged paths for Domain/Application/Infrastructure
dependency direction, settings schema and persistence, native Settings UI and
`Command-,`, multi-window propagation, effective light/dark/high-contrast
refresh, new-buffer defaults, existing/recovered buffer preservation,
lifecycle/menu validation, accessibility, retain cycles, tests, and bounded
work.

The unstaged user-owned `docs/wiki/04-implementation-foundation.md` and
untracked `scripts/vendor_scintilla_5_6_6.sh` were excluded and preserved.
README and ignored Notepad++ material were not inspected or changed. Product,
tests, work documentation, stage, commit, receipt, sign, and push were not
modified.

## Findings

- **P24-01 Major** — `Sources/DuckpadInfrastructure/UserDefaultsAppSettingsStore.swift:20-34`: `data(forKey:)` conflates an absent key with a present non-Data corrupt value, while `save` catches only fixed-model JSON encoding and treats nonthrowing, asynchronously persisted `UserDefaults.set` as an acknowledged durable write; an exact probe stored a String, then observed `load=nil` and `.ready(.defaults)`, so corruption is hidden, and a dropped persistent write would still publish “Saved” instead of exercising rollback. Distinguish `object(forKey:)==nil` from a non-Data `.corrupt`; if persist-before-publication/write-failure rollback remains the contract, use an acknowledged off-main atomic store (and async port), or explicitly narrow the contract/UI/error model to UserDefaults' asynchronous best-effort semantics and test the production adapter rather than only a throwing fake.
- **P24-02 Major** — `Sources/DuckpadPresentation/DuckpadWindowController.swift:73-75,1668-1670,1783-1785,2467-2476`: palette selection reads `accessibilityDisplayShouldIncreaseContrast` but refreshes only on `viewDidChangeEffectiveAppearance`; AppKit's SDK directs clients to `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` for live contrast changes, so toggling Increase Contrast without a light/dark appearance change leaves existing editors on the stale palette, and the new test changes only Aqua/Dark Aqua. Observe the workspace accessibility notification with teardown-safe ownership, call `refreshAppearance` for every live window, and add a notification-driven high-contrast palette regression.
- **P24-03 Major** — `Sources/DuckpadApp/DuckpadMain.swift:430-456,512-524`: Settings is targeted through a document `DuckpadWindowController`, but the app intentionally remains running after its last window closes and `onClosed` removes the last strong controller reference; `NSMenuItem.target` is weak, so the retained main menu's Settings target becomes nil and `Command-,` stops working until Dock reopen creates another document window. Route app-level Settings through an app-lifetime target/coordinator independent of key-window document routing, then test last-document close → Settings and verify a subsequently reopened/new window receives the authoritative saved defaults.

## Evidence

- Candidate preparation recomputed exactly to
  `e50c26612b2d9146e8c2ab649c8706e89db6a724867dd22e28c294a684d5213d`.
  Parent was `703b89cdce2ec7a5f8bd7d9fe24d90ff7df14efe`, tree
  `5b13a625fca3f7cf171b58e33bbf928d8a39d5ce`, diff SHA-256
  `25588011d640fa9a6ac972be33a94c7adf382f891975192957ac7f8989e906ca`,
  and message SHA-256
  `1345b1b8c2cd923ff74d403ad07d0282c1fa97c4a5934eb0f92f4dd12f4a2540`.
- The staged set was exactly the requested 18 paths and
  `git diff --cached --check` passed. Its sorted NUL-delimited path digest is
  `612f3f24b0512c34c47e56b92f94bd6bd31bf8cd24c04267f511f3a4316fa9c3`;
  sorted `path NUL bytes NUL` digest is
  `433dc0e6b09b9b5062d82c3998b0f149b80b9d08ee07d610d87ff9602ae869a9`.
- Independent settings-focused tests passed 8/8: load/update/schema fallback,
  isolated UserDefaults Data round trip/malformed JSON, Settings controls and
  rollback fake, new-buffer defaults, effective Aqua/Dark Aqua propagation,
  and menu routing.
- An independent wrong-type production-store probe printed
  `object=__StringStorage`, `load=nil`, `.ready(defaults)` and exited with the
  failure sentinel 24, reproducing P24-01. Foundation's installed SDK states
  `setObject` persists asynchronously, matching the unacknowledged-write trace.
- The installed AppKit SDK declares `NSMenuItem.target` weak; an independent
  AppKit probe released the sole target and printed
  `weakTargetReleased=true menuTargetNil=true`, completing the P24-03 ownership
  trace with the app's explicit last-window retention removal.
- The SDK comment for `accessibilityDisplayShouldIncreaseContrast` explicitly
  names `NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification`; no
  source/test observer exists. This confirms P24-02 independently of the
  passing appearance-only test.
- A clean scratch-path Swift 6 Debug build passed in 41.82 seconds. The only
  warnings were pre-existing vendored Scintilla deprecations; the standalone
  probe's initial actor-default warning did not reproduce in the exact package
  build and is not a finding.
- Builder Debug/Release 328/328, parity 31/31, governance 8/8, checker, and
  diff-check are supporting evidence only; their settings tests do not exercise
  the three failing paths above.

## Architecture and Preserved Invariants

The value model remains in Domain, the store contract and state machine remain
in Application, the local-file adapter remains outward in Infrastructure,
and AppKit/composition remain in Presentation/App. Successful settings changes
propagate to every retained editor, and a newly created/reopened window reads
the authoritative `settingsUseCase.state`. Adapter default state is copied
only when a buffer is first seen; recovery installation overwrites it with the
captured per-buffer state, so existing/recovered text, revision, undo, and view
options remain unchanged. Weak closures avoid a new steady-state retain cycle,
and the 32-window cap bounds propagation. These correct boundaries do not cure
the persistence acknowledgment, accessibility notification, or zero-window
command-ownership defects above.

## Verdict

The initial candidate verdict was **CHANGES REQUIRED — 0 Blocker, 3 Major,
0 Minor**. The focused remediation below closes P24-02/P24-03 but leaves a
P24-01 residual and one newly introduced lifecycle Major.

## Focused Remediation Re-review

- **P24-01 OPEN / Major** — `Sources/DuckpadInfrastructure/LocalAppSettingsStore.swift:30-79`: replacing UserDefaults with an async actor and
  regular-file/size checks fixes wrong-type corruption and moves ordinary I/O
  off MainActor, but `lstat(path)` followed by `Data(contentsOf:path)` is still
  a TOCTOU path read: a regular archive can become a symlink or grow after the
  check, so the actual read is neither no-follow nor bounded. Save uses
  `Data.write(.atomic)` without file/directory durability sync and applies mode
  `0600` only after rename. An injected `FileManager` probe made that chmod
  fail: `save` returned `.writeFailed`, yet the complete new dark-settings JSON
  remained visible and would be loaded on restart (sentinel exit 24). Use
  descriptor-relative/no-follow bounded reads with same-fd identity checks;
  create the replacement privately before publication, sync file and directory,
  and distinguish pre-publication failure from replacement-visible durability
  uncertainty so a failed UI update cannot silently become authoritative next
  launch.
- **P24-02 CLOSED** — every document controller owns a weak-capture observer on
  `NSWorkspace.shared.notificationCenter`, explicitly invalidates it during
  teardown, and refreshes the effective palette. The independent notification
  regression increments theme publication while Aqua/Dark Aqua behavior remains
  intact.
- **P24-03 CLOSED** — the app delegate, retained for the application run loop,
  is the Settings item target and validator. Closing the last document no longer
  removes command ownership; the focused action test and production smoke cover
  zero-window Settings, then create a new editor from the authoritative saved
  defaults.
- **P24-04 Major** — `DuckpadSettingsWindowController.swift:145-170` launches
  accepted async persistence in a private `updateTask`, but
  `ApplicationTerminationCoordinator.swift:139-157` has no settings task
  registration/join. Immediate Cmd-Q can approve termination while the actor is
  blocked writing, so the process may exit before the accepted preference is
  durable or the live state is published. Register settings work synchronously
  with an app-lifetime task barrier, join it before the true termination reply,
  and add cancellation-ignoring blocked-save success/failure tests that prove
  publication and failure UI precede termination disposition.
- Remediation candidate preparation recomputed exactly to
  `57fb25d0d779dd5ed6020a69e1c721fc5d296c3d4a412f9754e5af83d817dd59`.
  Parent remained `703b89cdce2ec7a5f8bd7d9fe24d90ff7df14efe`; tree was
  `4d597e20a5b130185adc200b91a5fe684b459355`, diff SHA-256 was
  `2fcb21ad9b2e5f7b0aa0266a28d370be37784cd4df51797580b869123a5d181b`,
  and message SHA-256 remained
  `1345b1b8c2cd923ff74d403ad07d0282c1fa97c4a5934eb0f92f4dd12f4a2540`.
  Exact 20-path stage/exclusions and cached check passed.
- Independent remediation-focused tests passed 10/10. Builder Debug/Release
  329/329, production settings smoke, parity 31/31, governance 8/8, checker and
  diff-check remain supporting evidence; no test covers the post-rename failure
  or accepted-update termination interleave.

## Remediation Manifest Evidence

Exact 18-path product/test/work-document manifest (wiki index and this review
evidence excluded) has sorted NUL-delimited path digest
`d07b499054472caebaa2986ba83042312df0823911961f3ba7e5d5d81a5322c8`
and sorted `path NUL bytes NUL` digest
`341653569744167d5b44d9dfe312b1f7a674f7d43f79b606f96536f124041630`.

## First Remediation Verdict

**CHANGES REQUIRED — CONTENT REVIEW; 0 Blocker, 2 Major, 0 Minor.** P24-01
remains open and P24-04 is a new accepted-settings termination race. No receipt
is authorized. Updating this review/index evidence invalidates candidate
`57fb25d…`; the next remediation requires a new exact freeze.

## Final Focused Remediation Re-review

- **P24-01 CLOSED** — `Sources/DuckpadInfrastructure/LocalAppSettingsStore.swift:40-204` opens the archive relative to an `O_NOFOLLOW` directory descriptor, rejects non-regular and over-1 MiB files, reads at most 1 MiB+1, and validates dev/inode/size/mtime/ctime plus the consumed length on the same descriptor. Save creates a same-directory `O_EXCL` mode-0600 temporary, writes fully, applies `fchmod`, `fsync`, `F_FULLFSYNC`, and successful close before `renameat`, then syncs the directory. Every pre-rename failure removes only the temporary and preserves the old archive; every post-rename sync/injected failure is typed `writeUncertain`.
- **P24-01 authority outcome CLOSED** — `Sources/DuckpadApplication/AppSettingsUseCase.swift:61-82` keeps an ordinary write failure on the prior live state, while post-publish uncertainty adopts the normalized visible replacement as degraded state and returns `savedWithWarning`. `DuckpadSettingsWindowController.swift:176-188` renders that authoritative new value with a visible durability warning instead of rolling back to bytes the next launch can load.
- **P24-02 remains CLOSED** — the teardown-owned `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` observation and effective-appearance callback both invalidate the palette cache and reapply the correct light/dark/high-contrast palette to existing windows.
- **P24-03 remains CLOSED** — the app delegate remains the native Settings command target/validator with zero document windows, and every subsequently created window reads the authoritative settings state for new-buffer defaults without changing existing/recovered per-buffer state.
- **P24-04 CLOSED** — `DuckpadSettingsWindowController.swift:160-174` checks admission, creates the accepted task, and invokes the coordinator registration synchronously in the same MainActor turn. `ApplicationTerminationCoordinator.swift:89-103,162-181,201-227` blocks new app commands after review begins, includes tracked tasks in the fast-path decision, and joins them before cleanup and the true termination reply. The cancellation-ignoring success/failure regressions prove UI publication or rollback precedes that reply; five independent repetitions passed 10/10 without a missed registration.
- Candidate preparation recomputed exactly to
  `56e800dc8b1e7cd006d41874a8792e6027468b12584517f55e7d0e375719c5e5`.
  Parent is `703b89cdce2ec7a5f8bd7d9fe24d90ff7df14efe`, tree is
  `65db8d55685688980da3fe85a237e81674200319`, diff SHA-256 is
  `fb883dec5242215ca97e019a23cf724bc05e92b5461d235f305ceec2025b5c8b`,
  and message SHA-256 is
  `1345b1b8c2cd923ff74d403ad07d0282c1fa97c4a5934eb0f92f4dd12f4a2540`.
  Exact 20-path stage and cached diff check passed; doc04/vendor script remain
  unstaged and README/Notepad++/gitlink paths are absent.
- Independent final-remediation focused validation passed 14/14 in Debug and
  14/14 in Release. The two termination interleaves additionally passed five
  repetitions, 10/10 total. Builder exact-current Debug/Release 333/333,
  production settings smoke, parity 31/31, governance 8/8, checker, and diff
  check are recorded as supporting evidence.

## Final Manifest Evidence

The exact 18-path product/test/work-document manifest (wiki index and this
review evidence excluded) has sorted NUL-delimited path digest
`d07b499054472caebaa2986ba83042312df0823911961f3ba7e5d5d81a5322c8`
and sorted `path NUL bytes NUL` digest
`50a5ced36952165005b32942f4a5ecb1cabff813a8c7f2c8194265127bb629a4`.

## Final Content Verdict

**APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** P24-01 and
P24-04 are closed; P24-02 and P24-03 remain closed. Phase 24 content is
authorized for exact-candidate refreeze and receipt review. These reviewer
evidence edits invalidate candidate `56e800dc…`; a new exact candidate must be
prepared before signing, and no receipt is issued by this content-review turn.

## Agent Work Log

- Recomputed candidate/tree/diff/message and the exact staged manifest, checked
  exclusions/cached-diff hygiene, read every staged hunk plus surrounding app
  ownership/recovery/theme code, and ran a clean Swift 6 build.
- Ran eight focused tests and two external read-only probes, and inspected the
  installed Foundation/AppKit SDK contracts for persistence, accessibility
  notification, and menu-target ownership.
- The `caveman-review` skill shaped findings into concise
  location/problem/fix statements. Only this review record and the Phase 24
  index review row/work log were edited.
- Recomputed the 20-path remediation candidate, inspected async persistence,
  notification teardown, app-lifetime routing, and termination coordination;
  ran focused 10/10 and the deterministic post-write failure probe before
  recording two remaining Majors.
- Recomputed final candidate `56e800dc…`, audited descriptor-bound read and
  durable publication failure boundaries plus synchronous application-task
  ownership, ran Debug/Release focused 14/14 and five termination repetitions
  (10/10), and recorded final approval with the exact 18-path manifest digest.
