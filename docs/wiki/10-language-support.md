# Phase 7 — Language Detection and Syntax Services

## Status and scope

Phase 7 adds a language-service foundation and production Lexilla syntax styling without reading or copying the ignored Notepad++ reference repository. It is an implementation candidate, not an approved parity claim. The delivered slice includes deterministic detection, per-document manual override, a broad bundled registry, real Lexilla lexers, light/dark/high-contrast-aware palettes, line numbers, fold margin, brace feedback, indentation settings/guides, and a loss-safe line-comment command.

Block-comment commands, newline auto-indent, explicit indent/outdent commands, code completion, symbol navigation, LSP, user-defined languages, and Notepad++ language-menu exact ordering remain deferred.

## Official source and reproducibility

- Upstream: official standalone Lexilla 5.5.3, `https://www.scintilla.org/lexilla553.tgz`.
- Archive SHA-256: `4d9e64263c337034a06f9c67f330c605764cac02aee83c06f6c21f9527a71628`.
- License: bundled `Vendor/Lexilla/5.5.3/License.txt`, the permissive Neil Hodgson Lexilla/Scintilla license.
- Compatibility: the official SciTE 5.6.6 release dated 2026-08-12 explicitly pairs Lexilla 5.5.3 and Scintilla 5.6.6. Lexilla's official build contract requires Scintilla 5+ interface headers and C++17.
- Reproduction: `scripts/vendor_lexilla_5_5_3.sh` downloads over HTTPS, checks the exact archive checksum/version marker, and extracts only the lexer runtime subset. `PROVENANCE.md` records included/excluded files. Four interface headers are copied from Duckpad's independently pinned official standalone Scintilla 5.6.6 tree so the Lexilla target is self-contained.

The vendored subset contains `include/`, `lexlib/`, 125 upstream lexer translation units, `src/Lexilla.cxx`, license/version/provenance, and no examples, binaries, IDE projects, or documentation images. No file under `notepad-plus-plus/` is accessed or included.

The official archive contains historical trailing and indentation whitespace. Root `.gitattributes` assigns only `-blank-at-eol,-blank-at-eof,-space-before-tab` to `Vendor/Lexilla/5.5.3/**`; every Duckpad-owned path keeps Git's strict defaults. This is diagnostic metadata only—there is no `text`, `eol`, clean/smudge, or normalization rule—so the official source bytes and regeneration output remain unchanged.

## Architecture

- `DuckpadDomain/LanguageModels.swift` defines typed language IDs, confidence, overrides, filename policy, comments, indentation, fold/brace capabilities, definitions, and detection results. `ScratchSession` persists overrides by stable `DocumentID`; Save As changes only `FileBinding`, so the override survives. Legacy archives missing the field decode as Auto. Unknown persisted IDs remain visibly unavailable and safely style as Plain Text; they are not silently rewritten to Auto.
- `DuckpadApplication/LanguageService.swift` validates the registry, implements precedence and ambiguity handling, owns per-buffer effective-configuration caching, applies overrides, and exposes comment/theme operations without AppKit. A style-budget eligibility bit is part of the cache so crossing the threshold reconfigures while ordinary edits do not.
- `DuckpadInfrastructure/Resources/Languages.json` is the versioned bundled registry; `LanguageManifestLoader` strictly validates it and requires at least 60 entries plus a Plain Text/null-lexer fallback. Missing/corrupt packaging returns a typed error. Production keeps an editable Plain Text fallback but surfaces a degraded status rather than claiming the broad registry loaded.
- `DuckpadLexilla` compiles the official C++17 lexer runtime. The internal Objective-C++ Scintilla bridge creates lexers and maps `ILexer5` style names/tags/descriptions into semantic palette roles. No raw Scintilla message, pointer, `ILexer`, or C++ type crosses the Swift editor port.
- `LanguageEditorPort` exposes only bounded detection-prefix reads, lexer resolution/configuration, theme, style-budget state, and line-comment intent. `ScintillaEditorAdapter` retains the effective language per live buffer, preserving independent text/undo/view state.
- Presentation provides a grouped Language menu with Auto, Plain Text, every bundled language, `⌘/` line comment, and a `⇧⌘P` command-palette hook. A nonblocking accessible status label shows the effective language, large-file styling pause, or degraded registry error.

## Detection contract

The stable precedence is manual override, exact special filename, exact shebang interpreter, XML root, longest dotted extension, then Plain Text. Filename case behavior is explicit per definition. Extensions are case-insensitive and require an actual `.` separator; an extensionless file named `c` is not treated as C. Hidden files are detected only through explicit special-filename entries such as `.bashrc`.

Shebang parsing compares interpreter basenames, never substrings. It supports direct paths and bounded `/usr/bin/env` forms including assignments, `-S`, `-u NAME`, `--unset NAME`, and `--`. Aliases such as `python2`, `python3`, `nodejs`, and common shells are explicit registry data; `notpython` cannot match Python.

Ambiguous conventional extensions remain honest many-to-many selectors. `.m` records Objective-C/MATLAB/Octave candidates, `.fs` records F#/Forth, and `.r` records R/Rebol. Bounded content signatures select a matching candidate; otherwise stable explicit priority and LanguageID order produce a deterministic result while the full candidate list remains in `LanguageDetection`.

The content probe is capped at 64 KiB. A probe cut through the final UTF-8 scalar trims only the incomplete suffix rather than discarding the valid prefix. UTF-8 BOM is removed before shebang/XML inspection.

## Styling and editor behavior

Registry entries use only lexer names resolved by the compiled Lexilla catalogue. Support is stated in three tiers: Plain Text, structural Lexilla support, and `keywordComplete` for the curated Phase 7 vocabulary contract. Exactly 20 common definitions are in the latter tier: Swift, C, C++, Objective-C, C#, Java, Kotlin, JavaScript, TypeScript, Python, Rust, Go, Ruby, PHP, SQL, HTML, CSS, JSON, YAML, and Shell. The remaining bundled languages claim structural coloring only, not complete keyword parity. Registry comment/fold/brace/indent capabilities are explicit, not inferred. Fold/brace are opt-in and disabled for Plain Text and languages where the bundled definition does not verify them.

On a lexer switch the bridge sets the lexer and keyword lists, rebuilds semantic style roles from Lexilla metadata, applies the current palette, enables after-visible idle styling, and synchronously colours at most 256 KiB. Files above the default 16 MiB style budget use the null lexer and skip synchronous colourisation entirely. Shrinking below the threshold restores the selected lexer. Normal edits do not read the full native document and do not reapply an unchanged lexer; prefix-relevant auto detection is debounced and persistence-only events are ignored.

Theme changes update styles, brace feedback, fold markers, and redraw existing views without reading or changing text, revision, undo, recovery, or file-conflict metadata. Font family/size remains editor-owned and independent of semantic colors. Fold markers use distinct plus/minus/connector glyphs. Brace matching is disabled and cleared for definitions without that capability.

Toggle Line Comment operates on all nonblank lines intersecting the primary selection. If all are commented it removes the marker; otherwise it inserts the marker after existing indentation. It preserves blank lines, CRLF, and UTF-8 byte boundaries, scans only selected-line indentation/prefix bytes, and wraps the edits in one native undo group. Each native edit still advances workspace revision and recovery journal state.

## Verification

Phase 7 focused tests cover the 78-entry packaged registry, the exact 20-language `keywordComplete` set, and runtime resolution of every distinct lexer; filename/shebang/XML/BOM/case/extensionless precedence; `.m/.fs/.r` collisions; unavailable manual IDs; legacy recovery decoding; manual override/Auto/Save As; malformed packaging degradation; exact C++/Python/Rust keyword/number/string/comment style IDs at UTF-8 offsets; fold/brace/indent configuration including UTF-8 matched and bad-brace positions; theme invariants; 50 MiB null-lexer/fold/brace-off zero-synchronous-style fallback; and multiline CRLF/Korean comment toggle with a single undo and recovery propagation.

Final validation on 2026-09-03:

- `swift test --filter 'Language|language|commentToggle|foldBrace'` — **PASS**, 18 focused tests.
- `swift test` — **PASS**, 150 tests in 4 suites.
- `swift test -c release` — **PASS**, 150 tests in 4 suites.
- `swift test --scratch-path <new /tmp/duckpad-phase7-fresh.*>` — **PASS**, clean dependency resolution/build and 150 tests in 4 suites.
- `swift build -c release --triple x86_64-apple-macosx13.0 --scratch-path <new /tmp/duckpad-phase7-x86.*>` — **PASS**, including Lexilla, Scintilla Cocoa, bridge, and app link. Native arm64 debug/release builds also passed as part of the test and smoke commands.
- `DUCKPAD_RECOVERY_ROOT=<new temp root> DUCKPAD_LANGUAGE_SMOKE=1 .build/release/DuckpadApp` — **PASS**, printed `Duckpad language smoke ready: Lexilla 5.5.3 Swift/Python + dark palette` and exited 0.
- `git diff --check` — **PASS**; staged paths and gitlinks are empty; root README is absent; `notepad-plus-plus/` remains root-ignored and uninspected.

The only compiler diagnostics in fresh/x86 builds are four deprecation warnings inside the separately pinned upstream Scintilla 5.6.6 Cocoa implementation. They do not come from the new Lexilla or Duckpad bridge code.

## Agent Work Log

### 2026-09-03 — Phase 7 language and Lexilla vertical slice

- **Agent/role:** `/root/philosophy_parity`, authenticated product builder; no independent review, staging, or commit authority.
- **Skill:** `source-command-sc-implement` guided contract-first implementation, adapter isolation, validation, and integration.
- **Provenance work:** verified official Lexilla download/history/license and official SciTE pairing; independently downloaded the tarball and measured SHA-256 before creating the reproducible subset script.
- **Implementation:** added typed Domain language state and backward-compatible recovery persistence, Application registry/detection/cache/override/theme/comment orchestration, strict bundled Infrastructure manifest, official Lexilla C++ target, semantic narrow Scintilla façade, production adapter wiring, native grouped menu/status, and multi-language application smoke.
- **Architecture-guard input:** Russell (`/root/clean_architecture`) continuously reviewed WIP boundaries. Resulting remediations include suffix-safe UTF-8 probes, exact `env` shebang parsing, honest ambiguous extensions, runtime resolution of every manifest lexer, explicit capability/support tiers, semantic `ILexer5` role mapping instead of style-number guessing, bounded/idle styling, null-lexer large-file fallback, brace suppression, fold glyphs, full effective-config threshold caching, persistence/theme event no-ops, and bounded grouped multiline comment edits.
- **Preserved:** the pre-existing unstaged `docs/wiki/04-implementation-foundation.md` and `scripts/vendor_scintilla_5_6_6.sh`, ignored reference tree, and existing user work. No README, staging, or commit.
- **Validation:** focused Phase 7 18/18 PASS; full debug, release, and fresh suites 150/150 PASS; x86_64 macOS 13 release build/link PASS; native release language smoke PASS. Hygiene found no staged paths, gitlinks, README, or non-ignored reference path.

### 2026-09-03 — P7-01 unavailable persisted manual language remediation

- **Finding source:** independent review `P7-01` found that the detector preserved an unknown manual ID internally but `LanguageWorkspaceUseCase` published ordinary ready/Plain Text state, hiding the recovery warning in Presentation.
- **Implementation:** added typed `LanguageServiceState.unavailableManual(requestedID:fallback:)`. Refresh still applies the safe bundled Plain Text/null-lexer configuration, but preserves the requested ID in `ScratchSession` and publishes the unavailable state. The status overlay renders the missing ID and active fallback in warning color; the Language menu continues to offer Auto and every currently available manual choice without inventing or rewriting the missing ID.
- **Acceptance:** Application and hosted AppKit controller tests restore a removed registry ID, verify the null lexer and visible accessible warning, compare text/revision/editor mutation/recovery state, inspect the menu, and prove that only an explicit Auto choice clears the persisted override and redetects Python.
- **Validation:** focused Phase 7 20/20 PASS; full debug, release, and clean fresh-scratch suites each 152/152 PASS; native release `DUCKPAD_LANGUAGE_SMOKE=1` PASS. `git diff --check` and forbidden-path/index hygiene were rerun after the final documentation update.

### 2026-09-03 — Exact upstream whitespace policy correction

- **Correction:** candidate `00788bcd…` was rejected and the real index was reset to `HEAD` without changing the worktree. Its temporary environment-only Git whitespace override was not persisted; no `core.whitespace` or `apply.whitespace` repository/global setting was added.
- **Policy:** added a tracked `.gitattributes` rule scoped to the exact official `Vendor/Lexilla/5.5.3/**` subtree. It disables only the three diagnostics already present upstream. Non-vendor files remain on Git's default strict whitespace policy.
- **Reproducibility:** a clean temporary root reran the vendor script from HTTPS archive verification through extraction, then `diff -qr` matched all 165 generated files. The 164 official source/license/version/header files excluding generated provenance have identical current/reproduced path+byte digest `6c44a2b96fc27c52ebcedec5a2dfe5b8f5f62e7eb6c30b7d50773446c2b6162d`. The script and generated provenance explicitly state that attributes are not read and no byte-transforming rule exists.
- **Whitespace evidence:** `git check-attr` returns the three disabled diagnostics only for the versioned Lexilla path and `unspecified` for Duckpad Application source. The same upstream whitespace fixture reports no diagnostic in the vendor path while an out-of-tree strict probe is rejected. A normal-config isolated index containing the eventual 192-path scope passes `git diff --cached --check`; the real index remains empty and its normal cached check also passes.
- **Authority:** this `.gitattributes` and documentation change requires fresh independent content approval. No staging, candidate preparation, or commit follows this correction in the builder turn.
