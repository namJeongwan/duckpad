# Phase 4 Session/Crash Recovery Code Review

> Status: **CHANGES_REQUIRED**
>
> Date: 2026-09-02 (Asia/Seoul)
>
> Reviewer: `/root/phase1_code_review`
>
> Content verdict: **CHANGES_REQUIRED**
>
> Commit authorization: **not granted**

## Scope

Independent review of the current unstaged Phase 4 session/crash-recovery vertical slice only: Domain recovery invariants; Application capture, autosave, generation and close ordering; Infrastructure archive atomicity, fallback, validation and permissions; Scintilla recovery mirror/view state; production startup, close and termination wiring; and new tests/document 07. Pre-existing unrelated unstaged document 04 and vendor script changes were preserved and excluded. README and the Notepad++ reference were neither accessed nor modified. Reviewed source was not modified, staged, or committed; this review document and the Phase 4 review link/work log in wiki index 00 are the reviewer's only worktree edits.

## Evidence

- Phase 4 source/test/document-07 diff SHA-256 before review edits: `36b25ad1149bff81257e413c639ee7254784aa1799a9081d1f45ecb1a58e5b4c`.
- Focused recovery run: PASS, 17 test functions / 19 parameterized cases. Existing tests cover ordinary round-trip, two corrupt-newest fallbacks, injected incomplete generations, post-publish recovery, permissions, retention, collision, reset, large archive, startup restore, autosave/coalescing/edit-follow-up/discard ordering, Scintilla no-snapshot-read instrumentation and clean termination flush.
- `swift build && swift test`: PASS, 86/86 debug.
- `swift build -c release && swift test -c release`: PASS, 86/86 release.
- Two-launch production Scintilla recovery smoke at `/tmp/duckpad-phase4-review.jS6Rjp/recovery`: write process exited 86 after autosave; verify process restored `crash 한글🙂` and one tab, then exited 0.
- Negative-view-state adversarial smoke: changing only `buffers[0].viewState.caretUTF8` to `-1` passed store validation, then production restore exited 133 with `Fatal error: Negative value is not representable`.
- Duplicate tab/document adversarial smoke at `/tmp/duckpad-phase4-duplicate-tab.v0yWZh/recovery`: adding a second unique tab ID that references the first tab's document passed store/domain recovery validation and production reported two restored tabs; static close tracing then removes their shared document/buffer while the second tab remains.
- Hot-path probe matching the recovery mirror's contiguous-`Data.replaceSubrange` algorithm took 0.2795 s for fifty 1-byte middle edits in a 50 MiB buffer on the review host; cost scales with the suffix/file size although the bridge snapshot-read counter stays zero.
- Staging remained empty throughout review.

## Findings

### Blocker

None.

### Major

`Sources/DuckpadApplication/SessionRecoveryUseCase.swift:L84-L120; Sources/DuckpadPresentation/DuckpadWindowController.swift:L248-L283`: 🔴 **P4-01 data-loss race:** a final close/Quit flush returns `.saved` for its old capture after `changeSerial` advances and only schedules a later autosave, so the coordinator can approve process exit before input accepted during the awaited commit becomes durable. Add a serialized final-flush mode that gates input or loops capture/commit until the serial is unchanged, and adversarially block the first commit, edit, request close/Quit, then prove the newest revision is durable before approval.

`Sources/DuckpadInfrastructure/LocalRecoveryStore.swift:L188-L221`: 🔴 **P4-02 crash-durability bug:** blob files are individually synced but their `blobs` parent directory is never fsynced before manifest/publish; a reported-success generation can lose blob directory entries after power loss and force fallback to stale text. Sync and close-check the blobs directory after all blob creation and before writing/publishing the manifest, with an injectable directory-sync failure test that forbids success/publication.

`Sources/DuckpadDomain/ScratchSession.swift:L110-L120; Sources/DuckpadDomain/ScratchSession.swift:L196-L215`: 🔴 **P4-03 invalid ownership:** recovery validation checks unique tab IDs but not unique `documentID` ownership, so two tabs may share one document; closing either deletes the document/buffer and leaves the other tab dangling. Require `Set(tabs.map(\.documentID)).count == tabs.count` and add decode/load plus close invariant tests.

`Sources/DuckpadInfrastructure/LocalRecoveryStore.swift:L139-L161; Sources/DuckpadEditorAdapter/ScintillaEditorAdapter.swift:L234-L241`: 🔴 **P4-04 corrupt-manifest crash:** signed/hash-valid recovery accepts negative view-state integers and restore traps when converting them to `UInt`; the production adversarial launch exits 133 instead of rejecting/falling back. Validate all view coordinates as nonnegative and anchor/caret as UTF-8 boundaries within the blob before returning an archive, then cover negative/oversized/split-code-point values and fallback.

`Sources/DuckpadEditorAdapter/ScintillaEditorAdapter.swift:L164-L174`: 🔴 **P4-05 hot-path regression:** every accepted middle edit mutates a contiguous full-buffer `Data` mirror on `@MainActor`, making recovery bookkeeping O(file size) even though `contentUTF8` is not called; large files can stall typing and violate the bounded-delta contract. Keep a chunked/delta-backed recovery journal and materialize immutable bytes off the edit path, with 1/10/50 MiB instrumentation that bounds bytes/work rather than snapshot-call count alone.

`Sources/DuckpadApplication/SessionRecoveryUseCase.swift:L38-L69; Sources/DuckpadApp/DuckpadMain.swift:L23-L30; Sources/DuckpadPresentation/DuckpadWindowController.swift:L185-L193`: 🔴 **P4-06 startup dead-end:** recovery load failure only invokes unwired `onFailure`, while the controller discards `start()`'s failure; a no-valid-generation root leaves the editor disabled indefinitely with no surfaced error or retry/reset path. Route typed recovery failure into the existing presentation failure/retry boundary and prove corrupt-only startup remains disabled but visible and recoverable without external file surgery.

### Minor

None recorded; non-blocking hardening is deferred to Notes.

## Notes

- `LocalRecoveryStore(root:)` follows/chmods an existing root and `reset()` recursively removes it. A follow-up should bind the store to a verified dedicated non-symlink root (or marker/inode) before chmod, retention, cleanup or reset; all current tests use fresh UUID roots and do not cover this boundary.
- Concurrent background resign flushes can race at one generation and produce a collision when their captures differ. Serializing all recovery operations with the final-flush fix would make lifecycle results deterministic.
- The ordinary smoke and all supplied tests pass, but they do not exercise the six blocking paths above.

## Verdict

**CHANGES_REQUIRED.** Findings: **0 Blockers, 6 Majors, 0 Minors**. The normal recovery path works, but final-exit freshness, directory-entry durability, recovered aggregate integrity, corrupt view-state handling, large-buffer edit cost, and startup failure recovery must be fixed before CONTENT APPROVED.

## Agent Work Log

| Field | Record |
| --- | --- |
| Agent | `/root/phase1_code_review` — independent Phase 4 code reviewer |
| Skill | `caveman-review`; findings use location/problem/concrete-fix form. |
| Static work | Read every Phase 4 production diff/new source and recovery test; traced domain ownership, generation publish/fallback, editor revision/capture, close/Quit/resign and startup failure paths. |
| Dynamic work | Focused 17-function/19-case recovery suite; debug/release 86-test suites; two-launch forced-exit smoke; negative view-state crash and duplicate tab/document acceptance probes; 50 MiB recovery-mirror hot-path probe. |
| Files changed | This review document and Phase 4 review status/work-log entries in `docs/wiki/00-wiki-index.md` only. |
| Preserved/excluded | Existing unrelated unstaged document 04 and vendor script; README and Notepad++ reference untouched; reviewed source/tests unchanged. |
| Stage/commit | None. |
| Verdict | CHANGES_REQUIRED — 0 Blocker, 6 Major, 0 Minor. |
