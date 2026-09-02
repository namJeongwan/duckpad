# Phase 3 Independent File I/O Code Review

> Status: **REJECTED — changes required**
>
> Date: 2026-09-02 (Asia/Seoul)
>
> Reviewer: `/root/phase1_code_review`
>
> Content verdict: **REJECTED**
>
> Commit authorization: **not granted**

## Scope

Focused review of the current Phase 3 file-I/O diff since `80bb610a18fdc54ce308041b8e1c4b9453e0d737`: `Package.swift`, Phase 3 Domain/Application/Infrastructure/Presentation/App composition and editor-port changes, Phase 3 Swift tests, `docs/wiki/06-file-io.md`, and its document-00 index entry. Pre-existing unstaged document-04, vendor helper script, and governance were excluded. No reviewed source was modified, staged, or committed; this review document is the reviewer's only repository edit.

## Evidence

- Reviewed package/source/test SHA-256 manifest digest before and after validation: `578b4edd17cf76a2d3fdbac9ec837eff362d6d89eeb5fceb15aad36cbbf3077e`.
- Clean Architecture direction passes: Domain has value/policy types, Application owns codec/ports/use cases, Infrastructure owns Darwin/CryptoKit syscalls, Presentation owns AppKit panels/commands/drop UI, and App is the composition root.
- Debug build PASS; debug tests PASS 56/56.
- Release build PASS; release tests PASS 56/56.
- Fresh scratch `/tmp/duckpad-phase3-review.0cLbcZ`: dependency resolution, full build, and tests PASS 56/56.
- Production Scintilla file smoke PASS. `/tmp/duckpad-phase3-review-smoke.ljU7oF` remained UTF-8 with CRLF and SHA-256 `b51d6f984e3e95f4d46017b8a70062179c235945c07fd15bfb5e07a4828f6735` before and after open/save.
- Existing tests pass for UTF-8/UTF-16-with-BOM and LF/CRLF/CR round trips, malformed Unicode rejection, injected pre-rename failure preservation, ordinary stale identity, duplicate canonical open, save-as binding, save-race dirty state, and controller command routing.
- Adversarial real-store TOCTOU probe waited until the sibling temp existed, then replaced the destination before Duckpad's rename. Result: `save_succeeded`, `external_preserved=false`, `candidate_overwrote=true`.
- Codec probe encoded Korean/emoji as UTF-16 LE and BE with the public `.absent` BOM option; both produced bytes that `decode` rejected as `invalidUTF8`.
- Static AppKit lifecycle audit found no window-close or application-termination dirty-document review path.
- `git diff --cached --name-only`: empty.

## Findings

### Blocker

None.

### Major

`Sources/DuckpadInfrastructure/LocalTextFileStore.swift:L75-L81,L103-L110`: 🔴 **P3-01 bug:** conflict identity/existence is checked before the potentially long temp write, then `rename` unconditionally overwrites whatever path exists; the adversarial probe reproduced loss of an external edit made after the check. Implement an atomic compare-and-swap replacement (for example Darwin `renameatx_np` swap, validate the displaced target, then keep or restore it; use exclusive rename for a new target) and test both existing-file change and new-file creation after temp sync.

`Sources/DuckpadApp/DuckpadMain.swift:L51,L58-L61`: 🔴 **P3-02 bug:** red-window close and Cmd-Q bypass `requestClose`, so dirty tabs can terminate without Save/Discard/Cancel. Route `NSWindowDelegate.windowShouldClose` and `NSApplicationDelegate.applicationShouldTerminate` through one all-dirty-documents coordinator, return cancel/terminate-later while async saves run, and add real lifecycle tests for Save, Discard, Cancel, save failure, and multiple dirty tabs.

`Sources/DuckpadApplication/FilePorts.swift:L95-L115`: 🔴 **P3-03 bug:** the public codec accepts UTF-16 with `ByteOrderMark.absent`, but BOM-less input is always decoded as UTF-8; a file Duckpad can save cannot be reopened (both LE/BE probes failed). Make UTF-16-without-BOM an invalid typed conversion/encode request, or require an explicit encoding hint at open, then cover every publicly representable encoding/BOM pair.

`Sources/DuckpadInfrastructure/LocalTextFileStore.swift:L111-L116`: 🔴 **P3-04 bug:** directory open, `fsync`, and close failures are ignored, yet the operation reports durable success; a crash can lose the rename after Duckpad marks the document clean. Fail closed on every durability syscall and retain enough replacement state to report/restore safely; add injected directory-open/sync/close failure tests.

`Sources/DuckpadApplication/FileDocumentUseCase.swift:L195-L218`: 🔴 **P3-05 bug:** explicit EOL conversion changes only the bytes for that save, records the converted EOL in the binding, but leaves the live snapshot unchanged; the next normal save writes the old separators and silently reverses the selected conversion. Keep live/editor/domain text synchronized with the converted content or normalize to the bound EOL on every later save, and test conversion followed by edit plus normal save.

### Minor

None.

## Notes

- Existing Scintilla upstream Cocoa deprecation warnings remain outside this Phase 3 gate.
- Legacy code pages, heuristic BOM-less encoding detection, xattrs/permission preservation, file coordination/iCloud, watchers, recent files, and recovery across process restarts remain the explicitly deferred document-06 scope.

## Verdict

**REJECTED.** Findings: **0 Blockers, 5 Majors, 0 Minors**. The standard 56-test matrix and production hash smoke pass, but the real atomic writer loses an external edit in the checked TOCTOU window, application/window termination bypasses dirty-file decisions, public UTF-16/BOM states are not round-trippable, directory durability failures are reported as success, and explicit EOL conversion is not stable across the next save. CONTENT APPROVED requires Blocker/Major zero; no commit is authorized.

## Agent Work Log

| Field | Record |
| --- | --- |
| Agent | `/root/phase1_code_review` — independent Phase 3 file-I/O reviewer |
| Skill | `caveman-review`; concise severity/location/fix findings, with data-integrity rationale retained. |
| Scope | Phase 3 package/source/tests/document-06/index only; pre-existing document-04, vendor helper, and governance excluded. |
| Static work | Read all Phase 3 production paths and test bodies; traced dependency direction, codec/BOM/EOL state, canonical paths, identity/conflict/save races, atomic syscalls, editor/domain synchronization, panels/menu/drop/title/dirty/close, and production composition. |
| Dynamic work | Debug/release/fresh 56-test runs; production Scintilla CRLF hash smoke; adversarial real-store after-check replacement; public BOM-less UTF-16 codec probe; before/after source manifest and staging checks. |
| Files changed | `docs/wiki/reviews/2026-09-02-phase-3-file-io-code-review.md` only. Temporary probes were outside the repository. |
| Reviewed source/stage/commit | None. |
| Verdict | REJECTED — 0 Blocker, 5 Major, 0 Minor. |
