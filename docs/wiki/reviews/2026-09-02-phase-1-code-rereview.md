# Phase 1 Independent Code Re-review

> Status: **REJECTED — new changes required**
>
> Date: 2026-09-02 (Asia/Seoul)
>
> Reviewer: `/root/phase1_code_review`
>
> Content verdict: **REJECTED**
>
> Commit authorization: **not granted**

## Scope and independence

This re-review independently inspected the current bytes of `Package.swift`, `Package.resolved`, every Swift file under `Sources/`, and every test body under `Tests/Duckpad*Tests/`. `docs/wiki/04-implementation-foundation.md` is the acceptance statement. The original `docs/wiki/reviews/2026-09-02-phase-1-code-review.md` supplied B-01, M-01 through M-05, and m-01 through m-03 for mandatory disposition.

The reviewer did not build or edit the remediation. Documentation/governance/parity files are outside candidate scope. No reviewed source was modified, staged, or committed. This re-review file is the only repository edit made by this reviewer.

## Current-byte evidence

- Toolchain: Apple Swift 6.3.1, target `arm64-apple-macosx26.0`; package deployment target macOS 13.
- Reviewed-file SHA-256 manifest digest: `a6060f277fafdc51f66c72f57728b4c7effafe2d94ff28d9ca00131fec453f87`. This hashes the ordered SHA-256 manifest for both package files, `Sources/**/*.swift`, and `Tests/Duckpad*Tests/*.swift`.
- Every one of the 20 test bodies was read before execution: Domain 6, Application 7, Presentation 7.
- `swift package describe --type json`: PASS; dependency direction remains Presentation/Infrastructure → Application → Domain, with no Domain dependency.
- `swift build`: PASS without warning.
- `swift build -c release`: PASS without warning.
- `swift test`: PASS, 20/20.
- Targeted last-tab, dirty-close, persistence-failure, incremental-edit, revision-overflow, 50/500-tab cap, selected-visibility, and accessibility filter: PASS, 11/11.
- `DUCKPAD_SMOKE_EXIT=1 swift run DuckpadApp`: PASS; `Duckpad smoke window ready`, exit 0.
- Fresh `swift build --scratch-path /tmp/duckpad-phase1-rereview.3ZPpIf`: PASS from dependency resolution, no warning.
- Fresh `swift test --scratch-path /tmp/duckpad-phase1-rereview.3ZPpIf`: PASS 20/20, Swift Testing 6.2.4, no `_TestingInterop` warning.
- `vtool -show-build` reports macOS `minos 13.0` for both the fresh app and test bundle. `otool -L` reports no host-path `_TestingInterop` dependency. Package/source scans found no `unsafeFlags`, linker/rpath workaround, or absolute CLT path.
- Persistence-failure live-text probe: typed `.failed(save, unavailable)` returned while `dirty=true` and editor text remained `keep-on-failure`; this path passes.
- Adversarial restore/edit probe: an edit was accepted at revision 1 while delayed restore was pending; restore then changed the active buffer and revision back to 0.
- Adversarial reordered-save probe: `flushPersistence()` returned `.saved` with workspace revision 2, then a canceled older async save completed and left the store at revision 1.
- Closed-buffer lifetime probe: after explicit discard and successful replacement, `snapshot(for: oldBufferID)` still returned `discarded-secret`.
- Domain invariant probe: adding two public untitled documents with the same `BufferMetadata.id`, then closing the first, left the second throwing `brokenBufferReference`.
- `git diff --cached --name-only`: empty. No stage or commit was performed.

## Prior finding disposition

| Prior finding | Disposition | Current-byte proof |
| --- | --- | --- |
| B-01 final-tab optional success | **Closed** | `close` builds a replacement candidate, persists once, applies once, and publishes once; the dedicated test verifies new active ID, stored tabs, save delta, and publish count. |
| M-01 implicit dirty deletion | **Closed as originally stated** | Domain rejects dirty close by default; Application exposes decision-required/cancel/save-unavailable/discard; AppKit prompts before discard. New F-03 covers editor-buffer retirement after a valid discard. |
| M-02 Domain full-text ownership | **Closed** | `BufferMetadata` contains identity/revision/dirty only; `EditorPort` uses revision-checked incremental edits and adapter snapshots. Real NSTextStorage acceptance/rejection tests pass. |
| M-03 synchronous MainActor persistence | **Contract remediated; new correctness findings F-01/F-02/F-04** | Port is typed async/throwing and the in-memory adapter is an actor. Failure/coalescing tests pass for non-suspending stores, but adversarial conforming stores expose ordering and startup races; presentation does not surface most failures. |
| M-04 unbounded tab height | **Closed** | Scroll-hosted collection plus four-row/workspace-fraction cap passes pure 50/500 tests and actual 500-tab AppKit resize/selected-visibility test. |
| M-05 host-specific test linkage | **Closed** | Exact source-built 6.2.4 dependency, fresh build/test, Mach-O minOS 13, and dependency scan all pass without the former warning/path. |
| m-01 false-positive boundary coverage | **Closed for requested paths** | Final close, binding, actual NSCollectionView resize/cap/visibility/actions, 50/500 tabs, and NSTextStorage edit/reject paths now execute. New m-03 identifies uncovered adversarial/lifecycle paths. |
| m-02 revision wrap | **Closed** | `UInt64.max` throws `revisionExhausted` and remains unchanged; boundary test passes. |
| m-03 accessibility semantics | **Closed** | Stable tab/close/add IDs, labels, state/index/row values, press, selection, and close action are present and AppKit-tested. |

## New findings

### Blocker

None.

### Major

`Sources/DuckpadApplication/ScratchWorkspaceUseCase.swift:L114-L130` / `Sources/DuckpadPresentation/DuckpadWindowController.swift:L35-L36`: 🔴 **F-01 bug:** the editor is rendered and enabled before async restore completes, so a conforming delayed store can accept revision-1 user input and then replace it with the restored revision-0 session. Gate editing behind a single startup state or queue/reconcile pre-restore edits by stable buffer identity; add a delayed-load test proving typed text survives restore.

`Sources/DuckpadApplication/ScratchWorkspaceUseCase.swift:L298-L327`: 🔴 **F-02 bug:** canceling `scheduledPersistence` neither awaits the in-flight store call nor prevents its side effect, so an older revision can commit after `flushPersistence()` reports a newer revision saved. Serialize all writes through one ordered writer and enforce a monotonic generation/revision at the store's atomic commit boundary; add a cancellation-ignoring, reentrant-store test that must retain revision 2.

`Sources/DuckpadPresentation/TextViewEditorAdapter.swift:L11-L12,L48-L60,L95-L99` / `Sources/DuckpadApplication/ScratchWorkspaceUseCase.swift:L192-L201`: 🔴 **F-03 bug:** successful close/discard never retires the adapter snapshot, so every visited closed buffer retains its complete text indefinitely and explicit-discarded text remains queryable. Add an editor-buffer lifecycle operation, invoke it only after successful close persistence, and test that inactive open buffers remain while closed buffers release text and undo state.

`Sources/DuckpadPresentation/DuckpadWindowController.swift:L25-L36,L66-L69,L80-L86`: 🔴 **F-04 bug:** add/activate/start/background-edit persistence failures are discarded or only rendered as ordinary workspace state, and the second discard-close result is ignored; only a failure returned by the first close call reaches an alert. Observe persistence failure transitions in presentation and handle every async action outcome once with a nonblocking visible error/retry path; test load, edit, add, activate, and post-discard save failures through the real controller boundary.

### Minor

`Sources/DuckpadDomain/ScratchSession.swift:L89-L100,L123-L126`: 🟡 **m-01 risk:** public `addUntitled(buffer:)` accepts a duplicate `BufferID`; closing either document deletes the shared dictionary entry and corrupts the remaining tab. Reject duplicate ownership, make seeded metadata construction non-public, or implement reference-counted shared-buffer semantics; add an aggregate-invariant test.

`Sources/DuckpadApplication/ScratchWorkspaceUseCase.swift:L214-L227` / `Sources/DuckpadPresentation/DuckpadWindowController.swift:L66-L69` / `Sources/DuckpadPresentation/MultilineTabStripView.swift:L168-L183`: 🟡 **m-02 risk:** every accepted character schedules a full workspace snapshot and `reloadData()` for all tabs, so the incremental text contract still performs O(tab-count) UI work per keystroke. Publish/diff buffer dirty-revision changes separately and reload only changed tab items; measure typing latency with 500 tabs.

`Tests/DuckpadApplicationTests/ScratchWorkspaceUseCaseTests.swift:L5-L28,L155-L173` / `Tests/DuckpadPresentationTests/TabFlowLayoutTests.swift:L16-L18,L33-L60`: 🟡 **m-03 risk:** persistence tests use non-suspending actors and AppKit tests intentionally retain every window for process lifetime, leaving startup interleaving, reordered store effects, adapter snapshot retirement, and window teardown untested. Add adversarial suspension/order tests and a close/deallocation lifecycle test without a global window leak.

## Verdict

**REJECTED.** Findings: **0 Blockers, 4 Majors, 3 Minors**. The nine original findings are materially remediated as listed, but CONTENT APPROVED requires Blocker/Major zero. F-01 through F-04 are reproducible correctness/data-lifecycle failures in the new async/editor boundaries, so this candidate is not commit-authorized.

Passing builds, 20/20 tests, targeted UI probes, the tab cap, accessibility actions, and macOS-13 binary metadata are accepted evidence. They do not cover or negate the independent delayed-load, reordered-write, retained-discarded-text, and unsurfaced-error failures.

## Agent Work Log

| Field | Record |
| --- | --- |
| Agent | `/root/phase1_code_review` — independent Phase 1 re-reviewer |
| Date | 2026-09-02 (Asia/Seoul) |
| Assigned scope | Revalidate prior B-01/M-01..M-05/m-01..m-03 against current package/source/tests and doc04; independently build, test, smoke, and probe; do not remediate/stage/commit. |
| Skill used | `caveman-review`; new findings use location/problem/fix form, retaining rationale where boundary design requires it. |
| Files fully read | `Package.swift`, `Package.resolved`, all 11 `Sources/**/*.swift` files, all 3 Swift test files including all 20 bodies, doc04, and the prior Phase 1 review. |
| Commands/evidence | Package description/import scan; debug/release/fresh build; normal/fresh/targeted tests; smoke; Mach-O minOS/dependency inspection; live-text failure, delayed restore, reordered write, closed-snapshot, and duplicate-buffer executable probes; SHA-256 manifest. |
| Key decision | Close the original nine findings where current evidence supports closure; reject new async ordering, startup overwrite, editor-retirement, and user-visible failure gaps. |
| Files changed | `docs/wiki/reviews/2026-09-02-phase-1-code-rereview.md` only. |
| Reviewed files changed | None. |
| Staged/commit | None. |
| Verdict | Rejected; no content or commit approval. |
