# Phase 1 Independent Code Review

> Status: **REJECTED — changes required**
>
> Date: 2026-09-02 (Asia/Seoul)
>
> Reviewer: `/root/phase1_code_review`
>
> Commit authorization: **not granted**

## Scope

This review covers the current bytes of `Package.swift`, `Package.resolved`, every Swift file under `Sources/`, and the three Swift test targets under `Tests/Duckpad*Tests/`. Correctness, macOS lifecycle/UI behavior, Clean Architecture dependency direction, retention, tab reflow/resize behavior, editor/domain synchronization, the last-tab invariant, test strength, Swift concurrency/API availability, and build reproducibility were checked against the user requirements and `docs/wiki/02-clean-architecture-and-plugins.md` plus `docs/wiki/04-implementation-foundation.md`.

Documentation, parity/governance implementation, Python/shell tests, staging, and commit creation are outside this review. The architecture and foundation documents were read as acceptance criteria but were not reviewed as candidate content. No reviewed implementation file was modified. This review file is the reviewer's only repository edit.

## Evidence

- Toolchain: Apple Swift 6.3.1, target `arm64-apple-macosx26.0`; package deployment target macOS 13.
- Reviewed-file SHA-256 manifest digest: `07f6a800e19fa2febea126adb8954f6423c559be1706e9eda0adc73d71f60d24`. This is the SHA-256 of the ordered `shasum -a 256` output for `Package.swift`, `Package.resolved`, `Sources/**/*.swift`, and `Tests/Duckpad*Tests/*.swift`.
- `swift package describe --type json`: PASS; `Presentation` and `Infrastructure` depend inward on `Application`/`Domain`, `Application` depends on `Domain`, and `Domain` has no target dependency.
- `swift build`: PASS.
- `swift test`: PASS, 8/8 discovered tests.
- `DUCKPAD_SMOKE_EXIT=1 swift run DuckpadApp`: PASS, printed `Duckpad smoke window ready`, exit 0.
- Fresh scratch-path `swift build --scratch-path /tmp/duckpad-phase1-review.IDOVIV`: PASS after resolving the exact pins.
- Fresh scratch-path `swift test --scratch-path /tmp/duckpad-phase1-review.IDOVIV`: PASS 8/8, but the linker warned that the macOS-13 test executable links `lib_TestingInterop.dylib` built for macOS 14.
- Last-tab executable probe against the reviewed module objects: after closing the sole tab, `snapshotTabs=0`, persisted `savedTabs=1`, `saveCount=1`, and `publishCount=0`. This proves the in-memory state mutates to empty while persistence and presentation retain the stale old tab.
- Tab geometry probe against `TabFlowLayoutEngine` at 380pt: 50 tabs produce 17 rows/650pt; 500 tabs produce 167 rows/6,350pt.
- Import and ownership inspection found no AppKit import in Domain/Application and no retain cycle in the assembled `DuckpadWindowController` → workspace/editor binding callback graph. Smoke launch alone does not verify typing, first-responder behavior, accessibility, or resize interaction.
- `git diff --cached --name-only`: empty before writing this review; no staging or commit was performed.

## Findings

### Blocker

`Sources/DuckpadApplication/ScratchWorkspaceUseCase.swift:L60-L64`: 🔴 **B-01 bug:** `close(tabID:)` treats the valid `nil` returned after successfully closing the final tab as failure, so it returns after mutating `session` but before adding the replacement scratch, saving, or publishing. Replace the optional-success guard with `do/try/catch`, always enforce the nonempty-session invariant after a successful close, commit once, and add a regression asserting new active tab, persisted state, and one published snapshot.

### Major

`Sources/DuckpadDomain/ScratchSession.swift:L100-L107` / `Sources/DuckpadPresentation/MultilineTabStripView.swift:L133-L136`: 🔴 **M-01 bug:** the exposed close button immediately deletes a dirty scratch buffer with no explicit discard decision or recovery record. Route close through an application close policy that returns a save/discard/cancel outcome; never remove the final dirty reference until the user explicitly discards it or recoverable content is durably retained.

`Sources/DuckpadDomain/ScratchSession.swift:L3-L20` / `Sources/DuckpadApplication/Ports.swift:L9-L13` / `Sources/DuckpadApplication/ScratchWorkspaceUseCase.swift:L66-L69`: 🔴 **M-02 architecture:** Domain owns the complete text and `EditorPort` sends a complete `String` on every keystroke, making the future Scintilla engine a mirrored UI rather than the text-buffer authority. This contradicts the selected architecture, creates O(document-size) edit traffic, and requires Domain/Application contracts to be rewritten during the promised adapter swap. Keep buffer ID/revision/dirty metadata inward, define revision-checked incremental edit and snapshot operations at the port, and let the editor adapter own live text.

`Sources/DuckpadApplication/Ports.swift:L3-L7` / `Sources/DuckpadApplication/ScratchWorkspaceUseCase.swift:L88-L90`: 🔴 **M-03 architecture:** `SessionStore` is synchronous and globally `@MainActor`, so replacing the in-memory adapter with the required disk session/recovery implementation either blocks typing or hides completion and write failures. This violates the off-main persistence rule and the requirement that failures be explicit. Make persistence operations async/throwing and implemented off the main actor; publish UI state on `MainActor` while recovery/session writes are scheduled, coalesced, and reported through typed outcomes.

`Sources/DuckpadPresentation/TabFlowLayout.swift:L74-L87` / `Sources/DuckpadPresentation/MultilineTabStripView.swift:L88-L102` / `Sources/DuckpadPresentation/DuckpadWindowController.swift:L46-L54`: 🔴 **M-04 bug:** every wrapped row increases a required height constraint without a workspace cap or scroll container, so 50 tabs at 380pt demand 650pt and 500 demand 6,350pt, eliminating the editor or causing unsatisfiable constraints. Cap the strip by a window-relative/configured maximum, put overflow rows in an internal scrolling clip view, keep the selected tab visible, and add 50/500-tab narrow-window tests.

`Package.swift:L8-L15,L63-L70`: 🔴 **M-05 build:** tests depend on an absolute standalone-CLT path and link a `lib_TestingInterop.dylib` whose minimum OS is macOS 14 into a package declared for macOS 13. A supported macOS-13 release gate is therefore not reproducible, and machines without that exact CLT layout fail differently. Remove the host-specific unsafe linker path and use a supported full toolchain or build/package a deployment-compatible test shim; prove clean build/test on every supported macOS baseline.

### Minor

`Tests/DuckpadApplicationTests/ScratchWorkspaceUseCaseTests.swift:L14-L38` / `Tests/DuckpadPresentationTests/TabFlowLayoutTests.swift:L5-L32`: 🟡 **m-01 risk:** tests never close the only tab, exercise `EditorBindingUseCase`, instantiate `NSCollectionView`, trigger real bounds invalidation/height propagation, or test 50/500 tabs; the claimed last-close and AppKit resize evidence is therefore false-positive coverage. Add boundary tests for each path plus an AppKit-hosted resize/selection test.

`Sources/DuckpadDomain/ScratchSession.swift:L16-L21`: 🟡 **m-02 risk:** `revision &+= 1` wraps `UInt64.max` to zero and violates the documented monotonic revision invariant. Reject an exhausted revision or use a nonwrapping revision policy and test the boundary through the public initializer.

`Sources/DuckpadPresentation/MultilineTabStripView.swift:L22-L25,L43-L53`: 🟡 **m-03 risk:** the `×` control has no semantic accessibility label/action context and tabs expose neither stable identifiers nor index/row/pinned state. Add tab-specific Close labels, stable accessibility identifiers, selection/close actions, and index/row/pinned/modified descriptions; verify them with accessibility tests.

### Notes

`Package.swift:L31-L50` / `Sources/**`: **N-01:** the implemented target dependency direction is inward-only, and Domain/Application do not import AppKit. Preserve this boundary while fixing M-02/M-03.

`Sources/DuckpadApplication/ScratchWorkspaceUseCase.swift:L98-L109` / `Sources/DuckpadPresentation/DuckpadWindowController.swift:L23-L28`: **N-02:** the assembled closures use weak captures and do not create an evident retain cycle. The editor callback should still be cleared on binding teardown once editor ownership becomes longer-lived or replaceable.

## Verdict

**REJECTED.** Findings: **1 Blocker, 5 Majors, 3 Minors, 2 Notes**. Approval requires zero Blockers and zero Majors. B-01 must be fixed before any Phase 1 commit because it directly breaks the claimed last-tab invariant. M-01 through M-05 also require remediation and independent re-review of the resulting exact source bytes.

The successful compile, 8/8 tests, and AppKit smoke establish that the executable starts; they do not outweigh the reproduced state corruption, silent dirty-buffer deletion, inverted editor/persistence boundaries, unbounded tab-strip height, or unsupported test-runtime linkage. No commit is authorized by this review.

## Agent Work Log

| Field | Record |
| --- | --- |
| Agent | `/root/phase1_code_review` — independent Phase 1 code reviewer |
| Date | 2026-09-02 (Asia/Seoul) |
| Assigned scope | Review only `Package.swift`, `Package.resolved`, `Sources/**`, and `Tests/Duckpad*Tests/**`; execute independent build/test/smoke; write this review; do not modify, stage, or commit reviewed files. |
| Skill used | `caveman-review`; findings use terse location/problem/fix form, with rationale retained for architecture findings. |
| Sources inspected | Every reviewed Swift/package file; architecture acceptance criteria in wiki documents 02 and 04; SwiftPM dependency description; current Git index/status. |
| Independent probes | Standard and fresh-scratch builds/tests; AppKit smoke launch; compiled last-tab state probe; compiled 50/500-tab geometry probe; exact reviewed-file hashes. |
| Key findings | Final-tab success is mistaken for failure after mutation; dirty close is destructive; live text and synchronous persistence boundaries contradict the chosen architecture; tab height is unbounded; the test-runtime workaround does not support the declared macOS baseline. |
| Files changed | `docs/wiki/reviews/2026-09-02-phase-1-code-review.md` only. |
| Reviewed files changed | None. |
| Staged/commit | None. |
| Decision | Rejected; no commit authorization. |
