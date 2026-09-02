# Phase 7 Independent Language/Lexilla Code Review

> Status: **REJECTED — changes required**
>
> Date: 2026-09-03 (Asia/Seoul)
>
> Reviewer: `/root/phase1_code_review`
>
> Content verdict: **REJECTED**
>
> Commit authorization: **not granted**

## Scope

Focused review of the current unstaged Phase 7 language/Lexilla slice: package wiring; the official Lexilla 5.5.3 subset, provenance, license, and regeneration script; typed Domain language state and session migration; Application registry/detection/override service and editor port; Infrastructure manifest; Scintilla bridge/editor adapter; production composition, menu, status, and workspace event wiring; Phase 7 tests; and `docs/wiki/10-language-support.md`. Pre-existing `docs/wiki/04-implementation-foundation.md` and `scripts/vendor_scintilla_5_6_6.sh` were excluded and preserved. The root README and ignored reference repository were not accessed. No reviewed source/test was modified, staged, or committed.

The exact product/acceptance manifest is 188 files: the 23 non-Lexilla paths below plus every one of the 165 files under `Vendor/Lexilla/5.5.3/`. Its sorted LF-delimited path-list SHA-256 is `d906d2f42c893dc301b04b7618ed1a71df5166a3b720adc0b946883c420c0c89`; SHA-256 over each path, NUL, and file SHA-256 is `3c92c932e7175a94890c2875c0f8ebc62e44105af8597ddc3140b58ada535022`.

- `Package.swift`
- `Sources/DuckpadApp/DuckpadMain.swift`
- `Sources/DuckpadApplication/LanguageService.swift`
- `Sources/DuckpadApplication/Ports.swift`
- `Sources/DuckpadApplication/ScratchWorkspaceUseCase.swift`
- `Sources/DuckpadApplication/SessionRecoveryUseCase.swift`
- `Sources/DuckpadDomain/LanguageModels.swift`
- `Sources/DuckpadDomain/ScratchSession.swift`
- `Sources/DuckpadEditorAdapter/ScintillaEditorAdapter.swift`
- `Sources/DuckpadInfrastructure/LanguageManifestLoader.swift`
- `Sources/DuckpadInfrastructure/Resources/Languages.json`
- `Sources/DuckpadPresentation/DuckpadMainMenuFactory.swift`
- `Sources/DuckpadPresentation/DuckpadWindowController.swift`
- `Sources/DuckpadPresentation/MultilineTabStripView.swift`
- `Vendor/Scintilla/5.6.6/bridge/DuckpadScintillaBridge.mm`
- `Vendor/Scintilla/5.6.6/bridge/include/DuckpadScintillaBridge.h`
- `docs/wiki/10-language-support.md`
- `scripts/vendor_lexilla_5_5_3.sh`
- `tests/DuckpadApplicationTests/LanguageWorkspaceUseCaseTests.swift`
- `tests/DuckpadDomainTests/ScratchSessionTests.swift`
- `tests/DuckpadEditorAdapterTests/LanguageEditorAdapterTests.swift`
- `tests/DuckpadInfrastructureTests/LanguageManifestTests.swift`
- `tests/DuckpadPresentationTests/TabFlowLayoutTests.swift`

## Evidence

- Independently downloaded official `https://www.scintilla.org/lexilla553.tgz`; SHA-256 is exactly `4d9e64263c337034a06f9c67f330c605764cac02aee83c06f6c21f9527a71628`.
- Vendor comparison PASS: `include/`, `lexlib/`, all 125 `lexers/*.cxx`, `src/Lexilla.cxx`, `License.txt`, and `version.txt` are byte-identical to that archive. The four self-contained lexer interface headers are byte-identical to the pinned Scintilla 5.6.6 copies. Regeneration script pins HTTPS, hash, version, subset, and a guarded target. Package compilation is C++17; license/provenance are present; no gitlink exists.
- Manifest probe PASS: schema version 1; exactly 78 unique definitions = 20 `keywordComplete`, 57 structural, and 1 plain; 64 distinct lexer names. The curated 20-language set is exact. Runtime test resolves every distinct bundled lexer through the compiled Lexilla catalogue.
- Static review PASS for Clean Architecture direction, stable `DocumentID` override persistence, legacy missing-field migration to Auto, Save As survival, deterministic precedence/tie ordering, case policy, BOM/suffix-safe 64 KiB probe, shebang/XML/longest-extension handling, `.m/.fs/.r` collisions, typed packaging/lexer degradation, native menu/status wiring, buffer-local configuration, and cache retirement.
- Static/dynamic bridge review PASS for semantic style-role mapping and palette application, configured indent policy, fold glyph/margin/toggle, UTF-8 matched/bad brace positions, theme/language text-revision-undo invariants, grouped CRLF/Korean multiline line comment with bounded inspection, 256 KiB synchronous style cap, 16 MiB threshold transitions, and 50 MiB null-lexer/fold/brace-off/zero-synchronous-style fallback without a full native snapshot.
- Focused `swift test --filter 'Language|language|commentToggle|foldBrace'`: PASS 18/18.
- Debug `swift test`: PASS 150/150.
- Release `swift test -c release`: PASS 150/150.
- Fresh release scratch build/test: PASS 150/150 (`/tmp/duckpad-phase7-fresh.dFrxxE`).
- Production language smoke: PASS, `Duckpad language smoke ready: Lexilla 5.5.3 Swift/Python + dark palette`.
- arm64 release executable: Mach-O arm64, minOS 13.0. Cross-built release executable: Mach-O x86_64, minOS 13.0.
- `git diff --check`: PASS; index is empty.

## Findings

### Blocker

None.

### Major

`Sources/DuckpadApplication/LanguageService.swift:L82-L85,L281-L303; Sources/DuckpadPresentation/DuckpadWindowController.swift:L916-L923`: 🔴 **P7-01 recovery/UI bug:** an unknown persisted manual `LanguageID` is detected as Plain Text with an unavailable reason, but refresh publishes ordinary `.ready` and the status renderer discards that reason, so recovery silently looks like a valid Plain Text selection instead of the required visible unavailable override; apply the null lexer while preserving a typed unavailable/fallback state, render the missing ID warning without rewriting it to Auto, and add service plus hosted-status recovery tests that fail the current path.

### Minor

None.

## Notes

- `localizedCaseInsensitiveContains` for collision signatures depends on localized comparison behavior. Use a fixed POSIX/root-locale or explicit Unicode folding in a follow-up to make cross-locale reproducibility self-evident; current collision fixtures pass and this is not treated as a current data-loss or Major defect.
- Structural-tier keyword breadth, live appearance-change observation, and closed-buffer language-cache eviction remain explicitly deferred and do not block this review.
- Upstream Scintilla Cocoa API deprecation warnings and manual Intel runtime/VoiceOver hardware coverage remain non-blocking follow-up gates.

## Verdict

**REJECTED.** Findings: **0 Blockers, 1 Major, 0 Minors**. Provenance, packaging, registry breadth/runtime resolution, styling behavior, large-file bounds, migration storage, builds, tests, and smoke pass. The recovered unknown-manual path nevertheless violates the current explicit visible-unavailable contract, and its detector-only test masks the presentation/application loss of state. CONTENT APPROVED requires Blocker/Major zero; no commit is authorized.

## Agent Work Log

| Field | Record |
| --- | --- |
| Agent | `/root/phase1_code_review` — independent Phase 7 language/Lexilla reviewer |
| Skill | `caveman-review`; concise location/problem/fix finding format used. |
| Scope | Current Phase 7 188-file product/acceptance manifest plus index; old document 04/vendor-Scintilla script excluded. |
| Static work | Read all Phase 7 production/test/document changes; audited layer dependencies, manifest truth, detection, recovery/Save As, runtime wiring, style/fold/brace/comment behavior, event/persistence bounds, and macOS 13 APIs. |
| Dynamic work | Official tar/hash/subset/header comparison; 78/20/57/1/64/125 inventory probes; focused 18, debug/release/fresh 150-test runs; language smoke; arm64/minOS and x86_64 cross-build inspection. |
| Files changed | This review document and the document-00 Agent Work Log/index entry only. |
| Reviewed source/stage/commit | None. |
| Verdict | REJECTED — 0 Blocker, 1 Major, 0 Minor. |
