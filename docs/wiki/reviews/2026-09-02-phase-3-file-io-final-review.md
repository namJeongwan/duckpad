# Phase 3 File I/O Final Focused Re-review

> Status: **REJECTED — one remediation remains**
>
> Date: 2026-09-02 (Asia/Seoul)
>
> Reviewer: `/root/phase1_code_review`
>
> Content verdict: **REJECTED**
>
> Commit authorization: **not granted**

## Scope

Final focused re-review of P3-01 through P3-05 only. I inspected the current Darwin atomic-replacement/durability paths, red-close and Cmd-Q coordination, explicit BOM-less UTF-16 decoding, durable encoding/EOL binding behavior, and their adversarial tests. I reran debug, release, clean-scratch 67-test suites and the production Scintilla file-hash smoke. No unrelated feature scope was added. No reviewed source was modified, staged, or committed; this review document is the reviewer's only repository edit.

## Evidence

- Reviewed package/source/test SHA-256 manifest digest before and after validation: `5d82e7f95e1a3c8f9e37cf5ae3f977f352e23698b236bd62a69519c1d8e07b4f`.
- P3-01 remediation: existing targets use atomic `RENAME_SWAP`, inspect the displaced inode/stat/content token, and swap back on mismatch; absent targets use `RENAME_EXCL`. Real Darwin race tests inject replacement/creation after temp full-sync and preserve external bytes while returning conflict.
- P3-04 remediation: temp `fsync` plus `F_FULLFSYNC` and directory open/fsync/close are checked. Fault tests pass for pre-commit full-sync failure, all three directory failures with original restoration, and rollback uncertainty with a retained recovery path. Application tests keep binding absent, buffer dirty, and live editor text intact for typed durability failure.
- P3-03 remediation: BOM auto-detection remains strict; `decode(_:assuming:)` round-trips BOM-less UTF-16 LE/BE with Korean, emoji, combining scalar and CRLF, while unhinted decoding rejects those bytes.
- P3-05 remediation: every save normalizes to the binding-selected EOL and reuses encoding/BOM. Conversion to UTF-16LE/no-BOM/CRLF followed by another edit and ordinary save remains in the selected format.
- P3-02 individual paths: red-close cancel/discard, Cmd-Q `.terminateLater`, save/cancel/save-failure, and two-tab sequential review tests pass. Static cross-trigger tracing shows red-close is guarded only by `DuckpadWindowController.closeReviewTask`, while Cmd-Q is guarded only by `ApplicationTerminationCoordinator.reviewTask`; both independently call the unguarded async `reviewDirtyDocumentsForTermination()`.
- `swift build`: PASS. `swift test`: PASS, 67/67.
- `swift build -c release`: PASS. `swift test -c release`: PASS, 67/67.
- Fresh scratch `/tmp/duckpad-phase3-final-review.wrnogb`: full dependency/build/test PASS, 67/67.
- Production smoke `/tmp/duckpad-phase3-final-smoke.tu4LzD`: opened and saved through production Scintilla, exited 0, and retained SHA-256 `b51d6f984e3e95f4d46017b8a70062179c235945c07fd15bfb5e07a4828f6735` before/after.
- `git diff --cached --name-only`: empty.

## Findings

### Blocker

None.

### Major

`Sources/DuckpadPresentation/DuckpadWindowController.swift:L239-L276; Sources/DuckpadPresentation/ApplicationTerminationCoordinator.swift:L14-L26`: 🔴 **P3-02 residual bug:** red-close and Cmd-Q own separate in-flight guards, so Cmd-Q during an awaited red-close decision starts a second concurrent dirty-document review for the same tab; duplicate panels and conflicting save/discard outcomes violate the required shared serialization. Move the single in-flight review task/result fan-out into one shared coordinator used by both entry points, and add an overlap test that blocks the first decision, triggers the other entry point, and proves one presenter call plus consistent replies.

### Minor

None.

## Notes

- P3-01, P3-03, P3-04, and P3-05 are remediated in current bytes.
- Previously recorded Scintilla upstream deprecations and manual distributable-app checks remain non-blocking.

## Verdict

**REJECTED.** Findings: **0 Blockers, 1 Major, 0 Minors**. Atomic conflict replacement, durability failure semantics, explicit BOM-less UTF-16, and persistent encoding/EOL behavior pass focused review and adversarial coverage. Red-close and Cmd-Q still do not share one serialized in-flight review, so CONTENT APPROVED is not granted.

## Agent Work Log

| Field | Record |
| --- | --- |
| Agent | `/root/phase1_code_review` — independent Phase 3 final focused reviewer |
| Skill | `caveman-review`; used for severity/location/concrete-fix reporting. |
| Scope | P3-01 through P3-05 remediation only; no unrelated expansion. |
| Static work | Read current atomic swap/exclusive/rollback/sync logic, typed store contract, termination controller/coordinator, codec hint path, format persistence, and focused tests. |
| Dynamic work | Debug/release/fresh 67-test runs; Darwin race/durability test cases; lifecycle/codec/format tests; production Scintilla CRLF hash smoke; before/after source manifest and stage checks. |
| Files changed | `docs/wiki/reviews/2026-09-02-phase-3-file-io-final-review.md` only. |
| Reviewed source/stage/commit | None. |
| Verdict | REJECTED — 0 Blocker, 1 Major, 0 Minor. |
