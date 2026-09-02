# Phase 6 Search/Replace — Remediation Re-review

## Scope

- **Reviewer:** `/root/phase1_code_review`, independent reviewer using `caveman-review` format.
- **Scope frozen to:** P6-01, P6-02, and P6-03 from the [initial review](2026-09-03-phase-6-search-replace-code-review.md); no new acceptance criteria.
- **Current reviewed-byte manifest:** the same 18 Phase 6 product/acceptance files listed by the initial review, SHA-256 `894718a9670b741d0c2f20a6ea983d3085316284ae9e9b054d827d6e1bb847e8` over ordered per-file SHA-256 records. Central remediation bytes: `SearchUseCase.swift` SHA-256 `2555247dac944cc4561df534c36a53e560ba3a1caca83cae3456bdf2d5f3c10a`; `ScintillaEditorAdapterTests.swift` SHA-256 `c885fc8511f3a875d81dc353c9fd7fc1b3b634568f4207153403a9e7dcc7bfad`.
- **Preserved/excluded:** pre-existing `docs/wiki/04-implementation-foundation.md`, `scripts/vendor_scintilla_5_6_6.sh`, README, ignored Notepad++ reference, and unrelated governance. Source/tests were not edited; no staging or commit.

## Closure Evidence

- **P6-01 CLOSED:** directional regex wraps the original expression in noncapturing Unicode `L/M/N/Pc` boundary assertions under the same ICU budget. Targeted test passes forward/backward/wrap. Independent probe on `한글자 글` returns standalone `글` at UTF-8 byte 10 in all three directions/routes, continuing past the embedded candidate.
- **P6-02 CLOSED:** a repeated terminal zero-length match now marks the first region exhausted instead of clamping past EOF/BOF onto the same boundary. Targeted tests pass `$`/`^` nonwrap, wrap, emoji lookahead boundaries, repeated nil, and empty document. Original probe changed from `1,1` to `1,nil`.
- **P6-03 OPEN:** retained original scope and successful Replace Current revision/length rebase pass, including a replacement-field change. The invalidation/empty-selection branch still broadens selection-only Replace All to the whole document; details below.

## Finding

- **[Major][P6-03] `Sources/DuckpadApplication/SearchUseCase.swift:798` — `replaceAll` passes `nil` from `selectionRestriction(for:)` directly to `SearchEngine.scan`, where `nil` means unrestricted document; empty selection replaces 3/3 matches, and revision-invalidated retained scope plus a collapsed caret replaces both remaining matches including the one outside the old scope — fail closed before materialization/scan when `scope == .selection` and no nonempty valid retained/current range exists, then test initial empty selection and post-edit revision invalidation for zero mutation/revision/undo/recovery changes.**

## Validation

- Focused remediation tests: 3/3 PASS in 0.097 s.
- Full debug: 130/130 PASS in 13.941 s.
- Full release: 130/130 PASS in 5.848 s.
- `DUCKPAD_SEARCH_SMOKE=1 .build/debug/DuckpadApp`: PASS, ICU find plus two grouped replacements, exit 0.
- Independent ignored `.build/phase6-review-probe`: P6-01/P6-02/fixed-range paths PASS; empty selection reproduced `emptySelectionReplaced=3,text=goose x goose y goose`; post-revision invalidation reproduced `invalidatedSelectionReplaced=2,text=Z x goose y goose`.

## Verdict

**CHANGES_REQUIRED — 0 Blocker, 1 Major.** P6-01 and P6-02 are closed; P6-03 remains open only for the nil/empty/invalidation fail-closed branch.

## Agent Work Log

### 2026-09-03 — P6-01~P6-03 remediation re-review

- Read the changed remediation implementation and all three new targeted test bodies.
- Re-ran the original failures, added ignored-only Unicode directional and selection invalidation probes, and independently reproduced the residual broadening.
- Ran focused, debug, release, and production search smoke validation.
- Added only this review evidence and the wiki index entry/log; source/tests/index staging/commit were not performed.
