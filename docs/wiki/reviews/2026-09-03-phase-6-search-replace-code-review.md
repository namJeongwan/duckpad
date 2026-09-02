# Phase 6 Search/Replace — Independent Code Review

## Scope

- **Reviewer:** `/root/phase1_code_review` (`caveman-review` concise format).
- **Baseline:** `22662e0 feat(tabs): complete multiline workspace flows`.
- **Reviewed product/acceptance files (18):** `Package.swift`; `Sources/DuckpadApp/DuckpadMain.swift`; `Sources/DuckpadApplication/{ScratchWorkspaceUseCase,SearchUseCase}.swift`; `Sources/DuckpadDomain/SearchModels.swift`; `Sources/DuckpadEditorAdapter/ScintillaEditorAdapter.swift`; `Sources/DuckpadICUBridge/{DuckpadICUBridge.c,include/DuckpadICUBridge.h}`; `Sources/DuckpadInfrastructure/ICURegexEngine.swift`; `Sources/DuckpadPresentation/{DuckpadMainMenuFactory,DuckpadWindowController,SearchPanelView}.swift`; `Vendor/Scintilla/5.6.6/bridge/{DuckpadScintillaBridge.mm,include/DuckpadScintillaBridge.h}`; `docs/wiki/09-search-replace.md`; `tests/DuckpadApplicationTests/SearchUseCaseTests.swift`; `tests/DuckpadEditorAdapterTests/ScintillaEditorAdapterTests.swift`; `tests/DuckpadPresentationTests/FileCommandRoutingTests.swift`.
- **Evidence-only Phase 6 file:** `docs/wiki/00-wiki-index.md`.
- **Explicitly excluded/preserved:** pre-existing `docs/wiki/04-implementation-foundation.md` and `scripts/vendor_scintilla_5_6_6.sh`; README and ignored Notepad++ reference; unrelated governance. No source/test edit, staging, or commit.
- **Reviewed-byte manifest digest:** SHA-256 `d0e2197112e0bf333d5601171386feec4ab50efd1ea8630a5c62fa378fbbbff3` over ordered per-file SHA-256 records for the 18 reviewed product/acceptance files.

## Evidence

- Static review: Domain/Application/Infrastructure/Presentation dependency direction; ICU C bridge budgets/statuses; UTF-8/CRLF/range/capture/replacement/result caps; current/all-open capture ordering; generation/task cancellation; stale tab/buffer/revision activation; workspace reservation and grouped native mutation; recovery delta propagation; panel/menu/focus/accessibility wiring.
- Phase 6 test bodies read: 7 search-engine/ICU tests, 3 Scintilla/reservation tests, 1 panel/menu test. The existing tests do not exercise the three failures below.
- `git diff --check -- <Phase 6 manifest>`: PASS.
- `swift test`: PASS, 127/127 in 14.016 s.
- `swift test -c release`: PASS, 127/127 in 5.841 s.
- `DUCKPAD_SEARCH_SMOKE=1 .build/debug/DuckpadApp`: PASS; ICU regex find plus two grouped replacements, exit 0.
- Independent ignored-package probe, debug and release: both reproduced `regexWholeWordLocation=0`, `zeroEdgeFirst=1,second=1`, and `fixedSelectionReplaced=1,text=goose x duck y duck`.

## Findings

- **[Major][P6-01] `Sources/DuckpadApplication/SearchUseCase.swift:519` — directional regex Find calls a port with no `wholeWord` input/filter, so Whole Word selects byte 0 inside `duckling` instead of byte 9 in `duckling duck` — iterate bounded directional ICU candidates with the same Unicode whole-word predicate used by `SearchEngine`, preserving timeout/cancellation, then add current-document forward/backward/wrap tests.**
- **[Major][P6-02] `Sources/DuckpadApplication/SearchUseCase.swift:507` — zero-length progress clamps “after EOF/before BOF” back onto the same boundary; non-wrapping `$` on `a` returns byte 1 on both successive Find calls — represent exhausted first regions explicitly, return nil without wrap or search only the opposite wrap region, and test forward EOF/backward BOF with wrap on/off and Unicode-adjacent boundaries.**
- **[Major][P6-03] `Sources/DuckpadApplication/SearchUseCase.swift:770` — selection Replace All reads the editor's current match selection instead of the retained original scope; after Find in `0..<11` of `duck x duck y duck`, it replaces one match rather than both — give selection scope an explicit tab/buffer/revision-bound lifetime, reuse it for Find/Find All/Replace All regardless of result selection (and replacement-field changes), reset it on panel/scope lifecycle boundaries, and add fixed-scope orchestration tests.**

## Verdict

**CHANGES_REQUIRED — 0 Blocker, 3 Major.**

Builds, existing tests, smoke, clean dependency direction, ICU hard budgets, ordered off-main materialization, stale-result checks, and reserved atomic grouped replacement pass. Approval remains blocked only by P6-01 through P6-03. Documented deferrals for Extended hex/octal/decimal escapes and all-open Replace All are accepted and nonblocking.

## Agent Work Log

### 2026-09-03 — Independent Phase 6 content review

- Read every changed Phase 6 implementation/test body in scope and checked the acceptance paths above.
- Built an ignored `.build/phase6-review-probe` consumer without changing reviewed bytes; reproduced all three Major failures in debug and release.
- Ran full debug/release suites, production search smoke, scoped whitespace validation, and byte-manifest hashing.
- Added only this review evidence and the wiki index entry/log; did not edit source/tests, stage, commit, or access forbidden trees.
