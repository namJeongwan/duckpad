# Phase 6 — Search and Replace

## Status and scope

Phase 6 implements the first macOS-native, non-modal search/replace vertical slice. It advances the baseline search workflow for the current document and all open documents without importing or reading from the ignored Notepad++ reference tree. It is an implementation candidate, not an approved parity claim.

Delivered operations are Find Next/Previous, Replace current then find, Replace All in the current document, and Find All in the current or all open documents. Results retain stable `TabID`, `BufferID`, revision, UTF-8 byte range, one-based line, one-based UTF-8 byte column, and a bounded snippet. Activating a stale/closed/edited result fails before tab activation; a valid result activates the tab, selects/reveals the range, and focuses the editor.

## Architecture

- `DuckpadDomain/SearchModels.swift` contains AppKit-free mode, option, scope, range, result, limit, and typed failure values.
- `DuckpadApplication/SearchUseCase.swift` owns orchestration, immutable recovery-capture materialization, generation cancellation, UTF-8 range validation, result grouping, replacement expansion, and revision reservation. Multi-document captures are materialized sequentially off `MainActor`, so at most one document snapshot is in flight and merge order remains tab order.
- `DuckpadInfrastructure/ICURegexEngine.swift` implements `RegexEnginePort`. Its narrow C bridge sets ICU time and stack limits for every operation and maps invalid pattern, timeout, and complexity separately. ICU handles regular-expression semantics; C/ICU handles never leave Infrastructure.
- `DuckpadEditorAdapter/ScintillaEditorAdapter.swift` implements the active-editor port. Literal/extended Find uses the narrow Scintilla target/search façade. Replacement ranges are prevalidated as descending/non-overlapping UTF-8 boundaries and applied as one Scintilla undo group.
- `ScratchWorkspaceUseCase` reserves the exact active buffer/revision and holds the serialized workspace transaction across native apply and metadata commit. A cancelled queued reservation is released before native mutation. This prevents close/save/edit reentrancy from observing a partial Replace All.
- `SearchPanelView` is an AppKit-only non-modal bar/results view. It collapses to zero height when closed, is keyboard accessible, supports Return/double-click result activation, exposes progress/Cancel, and routes every status/result through the controller's operation token.

The existing editor recovery capture is an immutable checkpoint plus bounded deltas. Search copies this value on `MainActor` without reading Scintilla's full native document, then materializes bytes in a utility task. Search therefore does not reintroduce a per-keystroke snapshot path.

## Semantics and safety limits

Modes:

- Normal: literal text.
- Extended: `\n`, `\r`, `\t`, `\0`, `\\`, fixed-width binary `\b11111111`, octal `\o377`, decimal `\d255`, hexadecimal `\xFF`, and UTF-16 `\uFFFF`. Adjacent valid surrogate escapes form one Unicode scalar. Malformed or short numeric escapes stay literal, matching Notepad++ rather than silently deleting bytes; an unpaired surrogate fails explicitly.
- Regular Expression: ICU semantics with capture replacement `$0` and `$1`…`$99`, `$$` for a literal dollar, and backslash escaping. Named replacement groups are rejected as unsupported. Dot-newline is explicit.

Search ranges and selections are UTF-8 byte offsets. Invalid, overflowing, or code-point-splitting ranges fail before mutation. CRLF counts as one line break; result column is deliberately a UTF-8 byte column so its unit matches the activation range.

Defaults cap a document at 64 MiB, regex input at 8 MiB, a pattern at 64 KiB, results at 100,000 matches/32 MiB, aggregate replacement bytes at 16 MiB, and final document size at 128 MiB. ICU receives a 100 ms time limit and 8 MiB stack limit per operation. Search cancellation cancels the actual detached task; loops check cancellation and never publish a superseded generation. Multi-document scan uses one in-flight materialization (within the configured concurrency ceiling) rather than eagerly materializing all buffers.

Replace All is intentionally current-document only. All-open Replace All, folder/workspace replacement, mark/style operations, named replacement groups, and persistent search history are deferred. Incremental count/results are delivered after a 150 ms debounce; persistent all-match editor indicators are not yet claimed.

## macOS command surface

The Search menu routes `⌘F` Find, `⌘G` Find Next, `⇧⌘G` Find Previous, `⌘H` Replace, and Escape Close Find Panel. Closing by Escape or the close button cancels the owned operation, collapses the bar, and returns focus to the editor. Replace mode disables “All open documents” because Replace All is deliberately limited to the current buffer.

## Verification

Focused coverage includes Unicode/Korean/emoji byte ranges, Unicode whole-word behavior, strict selection bounds, CRLF line/column, Extended NUL/newline/tab/backslash, ICU captures/lookahead/zero-length/dot-newline/invalid expressions, safe quantified groups, hard pathological-regex budget mapping, a 50 MiB literal scan, native Scintilla literal search, reserved grouped Replace All, dirty/revision propagation, and menu/panel collapse routing.

Final verification commands for this implementation run are recorded in the Agent Work Log below. Review findings, approval, staging, and commit remain separate later activities.

## Agent Work Log

### 2026-09-03 — Phase 6 search/replace vertical slice

- **Agent/role:** `/root/philosophy_parity`, product builder; no reviewer or commit authority.
- **Skill:** `source-command-sc-implement` guided the implementation flow from contracts through adapters, UI, tests, and documentation.
- **Decisions:** AppKit-free search contracts; `RegexEnginePort` with a production ICU adapter; Scintilla target/search only behind the narrow active-editor façade; recovery checkpoint+deltas as the immutable search capture; sequential bounded multi-document materialization; exact buffer/revision reservation for replacement; token-gated non-modal UI.
- **Safety remediation during build:** replaced per-match full-document line rescans with a monotonic cursor; removed eager all-document materialization; removed Foundation regex timeout claims and added ICU time/stack limits; added actual task cancellation and stale tab/buffer/revision checks; changed Replace Current and Replace All to the same reserved grouped batch; added checked size/range arithmetic and explicit current-document-only Replace All. Directional ICU search now returns one edge match independently of the global result cap, including zero-length matches. Final transaction adversaries prove that a cancelled reservation waiter and an activation committed ahead of reservation cannot mutate editor bytes, revision, undo state, or recovery capture. One native undo after grouped Replace All restores the exact original UTF-8 and is propagated as revisioned recovery edits.
- **Files:** `Package.swift`; `Sources/DuckpadDomain/SearchModels.swift`; `Sources/DuckpadApplication/SearchUseCase.swift`; `Sources/DuckpadApplication/ScratchWorkspaceUseCase.swift`; `Sources/DuckpadICUBridge/**`; `Sources/DuckpadInfrastructure/ICURegexEngine.swift`; Scintilla bridge header/implementation and adapter; Presentation search view/controller/menu; Phase 6 tests; this document and wiki index.
- **Preserved:** `docs/wiki/04-implementation-foundation.md` and `scripts/vendor_scintilla_5_6_6.sh` pre-existing unstaged changes; ignored `notepad-plus-plus/`; no README, staging, or commit.
- **Validation:** final reservation adversaries 2/2 PASS; debug full 127/127 PASS in 13.961 s; release full 127/127 PASS in 5.916 s; fresh scratch `/tmp/duckpad-phase6-final.51OcHI` compiled all dependencies and passed 127/127 in 13.932 s. The production AppKit/Scintilla search smoke opened the real editor, found `한글(?=🙂)` through ICU, performed two grouped literal replacements, verified final text, printed `Duckpad search smoke ready: ICU regex + 2 grouped replacements`, and exited 0. The 50-tab UI smoke passed with 8 wrapped rows and the active tab visible.

### 2026-09-03 — P6-01 through P6-03 remediation

- **Agent/role:** `/root/philosophy_parity`, remediation builder; the independent review verdict was not edited.
- **P6-01:** Directional regex Whole Word now wraps the original pattern in fixed-width ICU Unicode-category assertions equivalent to the canonical `L/M/N/Pc` word predicate. ICU skips embedded candidates while streaming under one operation's time/stack budget; it does not first allocate or cap a rejected-candidate list. Forward, backward, and wrapped `duckling duck` searches select byte 9.
- **P6-02:** Last-find identity now retains pattern/options including direction, plus exact tab, buffer, and revision while ignoring replacement text. A terminal zero-length result marks the first directional region exhausted; non-wrap returns no result and wrap searches the opposite/full region only once. ICU subranges use transparent bounds and document anchoring so `^`, `$`, and lookarounds retain full-document semantics. Tests cover repeated `$`, backward `^`, emoji-scalar lookahead progression, and an empty document.
- **P6-03:** Selection scope identity ignores replacement text and direction but validates search pattern/options, tab, buffer, and revision. Find, Find All, Replace All, and Replace Current reuse the retained original range instead of a selected result range. A successful Replace Current rebases the scope length and revision; an edit, tab/query/scope change invalidates it and the next eligible nonempty selection reseeds it. The `0..<11` fixture replaces exactly two matches and leaves the third outside match unchanged; Replace Current then Find remains inside the rebased scope.
- **Validation:** focused remediation 3/3 PASS; debug full 130/130 PASS in 14.091 s; release full 130/130 PASS in 5.934 s; fresh scratch `/tmp/duckpad-phase6-remediation.rPo31Y` rebuilt all dependencies and passed 130/130 in 13.979 s. Production search smoke and 50-tab/8-row/active-visible smoke both exited 0. `git diff --check`, staged-tree emptiness, README/NPP/gitlink/cache hygiene were checked after documentation updates.

### 2026-09-03 — P6-03 selection fail-closed follow-up

- **Agent/role:** `/root/philosophy_parity`, remediation builder; scope was limited to the residual selection finding.
- **Contract:** Every `.selection` operation now passes the same throwing scope preflight before scan or reservation. No initial or collapsed selection throws typed `SearchFailure.noSelection`. A retained scope invalidated by tab, buffer, revision, or search-query identity followed by a collapsed current selection throws `SearchFailure.invalidSelection`. Neither condition can be represented as `nil`, so it cannot fall through to a whole-document scan. A valid new nonempty selection remains the explicit reseed boundary.
- **Presentation:** Find/Find All report “Select a non-empty range to search” or “Selection changed; select a range again”; Replace/Replace All use the corresponding replace message. These cases are no longer presented as “No matches” or a successful zero replacement.
- **Regression evidence:** Initial empty-selection tests invoke Find, Find All, Replace Current, and Replace All and assert typed failure plus exact text/revision/undo/recovery invariance. A revision-invalidated retained selection followed by a collapsed caret proves Replace All cannot modify the whole document; the pre-existing native undo still removes only the accepted edit.
- **Validation:** focused follow-up 2/2 PASS; debug full 132/132 PASS in 13.959 s; release full 132/132 PASS in 5.945 s; fresh scratch `/tmp/duckpad-p6-scope-final.BL0Ptb` rebuilt dependencies and passed 132/132 in 14.003 s. Production search smoke and 50-tab/8-row/active-visible smoke passed. Final hygiene remained README/NPP/gitlink/cache/staging clean.
