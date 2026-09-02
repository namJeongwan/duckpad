# Phase 1 Independent Code Second Re-review

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

Current bytes of `Package.swift`, `Package.resolved`, `Sources/**`, and `Tests/Duckpad*Tests/**` were independently reviewed against `docs/wiki/04-implementation-foundation.md` and both prior Phase 1 reviews. All 30 test bodies were read. No reviewed source was modified, staged, or committed; this file is the reviewer's only repository edit.

## Evidence

- Reviewed-file SHA-256 manifest digest: `c37cde94bc02ea00d73df39ba58fc52caf2982ab2a7041b65d49468923960616`.
- `swift build`: PASS; `swift build -c release`: PASS; no warnings.
- `swift test`: PASS, 30/30.
- Fresh dependency-resolution build and 30/30 test at `/tmp/duckpad-phase1-second-rereview.xYdYET`: PASS, no warnings.
- `DUCKPAD_SMOKE_EXIT=1 swift run DuckpadApp`: PASS, exit 0.
- Fresh app and test Mach-O both report macOS minOS 13.0; no `_TestingInterop`, absolute CLT, unsafe linker, or rpath workaround remains.
- AppKit controller/window deallocation test repeated 10/10 in separate test processes: PASS, no signal 11.
- Existing probes pass for delayed initial restore gating, cancellation-ignoring ordered store, atomic generation, dirty/final close, editor text retirement, duplicate BufferID rejection, revision overflow, 50/500-tab cap/visibility/accessibility, all controller failure events/retry, and immediate one-item 500-tab update.
- Adversarial concurrent-action probe: two `addScratch()` calls both returned `.applied(.saved)`, but workspace and durable store ended with 2 tabs rather than the required 3.
- Adversarial failed-load retry probe: fallback edit was accepted at revision 1; retry restored a different revision-0 buffer, losing the accepted edit.
- Real AppKit undo probe: inactive first buffer retained text, but closing the active second buffer changed `canUndo` from true to false for the still-open first buffer.
- Settled 500-tab edit probe: immediate delta was full reload 0/item reload 1; after debounced persistence it was full reload 1/item reload 1.
- `git diff --cached --name-only`: empty.

## Prior findings

The original B-01, M-01 through M-05, and m-01 through m-03 are closed on current evidence. First re-review F-01 through F-04 and m-01/m-03 are remediated for their original probes: initial restore blocks input, store commits are generation-atomic and writer-ordered, successful close retires text, failures are presented once with retries, duplicate IDs fail closed, and AppKit teardown is stable. First re-review m-02 is only partially closed because persistence completion still performs a full reload; see f-04.

## Findings

### Blocker

None.

### Major

`Sources/DuckpadApplication/ScratchWorkspaceUseCase.swift:L230-L243,L323-L335,L364-L369`: 🔴 **F2-01 bug:** MainActor reentrancy lets concurrent mutations derive candidates from the same old session; two successful `addScratch()` operations persist generations in order but the second overwrites the first, yielding only one added tab. Serialize the complete read-candidate-save-apply transaction or rebase each queued intent after its predecessor; add concurrent add/close/edit interleaving tests.

`Sources/DuckpadApplication/ScratchWorkspaceUseCase.swift:L203-L225,L286-L297` / `Sources/DuckpadApplication/ScratchWorkspaceUseCase.swift:L426-L429`: 🔴 **F2-02 bug:** `.failed` startup enables editing, then Retry resets startup and replaces the accepted fallback revision/text with restored durable state. Keep fallback editing disabled until recovery is resolved, or merge/retain accepted fallback buffers before `.start` retry; test load failure → type → store recovery → retry with live text preservation.

`Sources/DuckpadPresentation/TextViewEditorAdapter.swift:L43-L68`: 🔴 **F2-03 bug:** all buffers share one NSTextView undo manager; retiring the active buffer calls `removeAllActions()` and erases undo history for inactive open buffers. Own undo state per buffer/editor document and retire only the closed buffer's history; test edit A → edit B → close B → switch A → undo A.

### Minor

`Sources/DuckpadPresentation/MultilineTabStripView.swift:L196-L214` / `Sources/DuckpadApplication/ScratchWorkspaceUseCase.swift:L351-L359`: 🟡 **f-04 risk:** a 500-tab character edit reloads one item immediately but the subsequent `.persistence` change falls through to full `reloadData()`, so the documented settled full-reload count is not zero. Treat persistence-only changes as tab-strip no-ops and assert metrics after `waitForPendingPersistence()`.

## Verdict

**REJECTED.** Findings: **0 Blockers, 3 Majors, 1 Minor**. CONTENT APPROVED requires Blocker/Major zero. Generation atomicity fixes durable write order, but it does not serialize application mutations; fallback retry can still lose accepted text; editor retirement still destroys another open tab's undo history. No commit is authorized.

## Agent Work Log

| Field | Record |
| --- | --- |
| Agent | `/root/phase1_code_review` — independent second re-reviewer |
| Scope | Phase 1 package/source/tests and doc04 acceptance only; both prior review finding sets. |
| Skill | `caveman-review`. |
| Work | Read all reviewed files and 30 tests; executed debug/release/fresh builds, normal/fresh tests, smoke, minOS/link scan, 10-process teardown stress, and adversarial concurrency/retry/undo/500-tab settled-update probes. |
| Key result | Prior remediation largely works; three in-scope correctness defects remain. |
| Files changed | `docs/wiki/reviews/2026-09-02-phase-1-code-second-rereview.md` only. |
| Reviewed source/stage/commit | None. |
| Verdict | Rejected; no content or commit approval. |
