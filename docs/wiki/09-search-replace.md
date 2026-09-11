# Phase 6 — Search and Replace

## Status and scope

Phase 6 implements the first macOS-native, non-modal search/replace vertical slice. It advances the baseline search workflow for the current document and all open documents without importing or reading from the ignored Notepad++ reference tree. It is an implementation candidate, not an approved parity claim.

Delivered operations are Find Next/Previous, Replace current then find, Replace All in the current document, and Find All in the current or all open documents. Results retain stable `TabID`, `BufferID`, revision, UTF-8 byte range, one-based line, one-based UTF-8 byte column, and a bounded snippet. Activating a stale/closed/edited result fails before tab activation; a valid result activates the tab, selects/reveals the range, and focuses the editor.

## Search dialog layout (2026-09-11)

Matching text receives a palette-aware green Scintilla indicator, independent of the active selection. Incremental search, explicit count/results, and directional find update it. Navigation retains all matches; query/scope changes, edits, and close invalidate decorations. Edits/Undo and active-buffer changes schedule a refresh. Native range application checks UTF-8 boundaries and revision and does not read full document contents or change selections, text, or Undo.

The search controls now live in a separate, non-modal macOS window. Four tabs — Find, Replace, Find in Files, and Bookmarks — share the search text and common options. The compact form fits a 640-point-wide window: inputs sit at the top left, selection scope immediately below them, unboxed match options in the middle left, and three search mode rows at the bottom left. Context-specific actions occupy the right, with optional transparency controls below them. Only explicit Find All and folder search expand the result list. Typing, Count matches, and Bookmarks update the status without expanding it. Opening or closing search no longer resizes the editor.

Find provides separate count and result-list actions for the current document (or selection), plus an all-open-documents action. The backward-search checkbox controls the primary Find action; explicit previous/next menu commands keep their specified direction. Replace keeps current-document/selection scope. Find in Files displays a reusable folder selection and invokes the existing recursive, read-only folder search; file filters, folder replacement, and project search are outside this change. Regex-only dot/newline matching is disabled in other modes. Changes to query options invalidate stale results and refresh the current-document search after the existing debounce.

Bookmarks adds markers to distinct matching lines without moving the selection or changing text, revision, dirty state, or Undo. Existing markers are retained unless “Clear previous bookmarks” is selected. Results are checked against the current buffer, revision, and editor context before markers are applied. The existing bookmark limit remains in force, and the status reports accepted versus matched lines. Clear All Bookmarks uses the existing metadata/recovery path.

Verification covers English/Korean light/dark window captures, tab state retention, bounded control layouts, window close/reopen, search option refresh, explicit search scopes, native bookmark integration, bookmark capacity, and selection/revision/Undo preservation. The pre-change controls overflow and missing option-refresh callbacks were reproduced before implementation. A second regression reproduced the oversized form, misplaced selection scope, and automatic result expansion. Compact sizing, count-only incremental search, backward direction, opacity modes, and idle cancellation visibility are now covered. Transparency can apply while inactive or always; it defaults off, stays at least 50% opaque, and returns to full opacity while its slider is dragged. The slider uses opaque track/thumb drawing. Search-field editing completion never navigates: Return is handled explicitly so clicking selection scope retains the editor selection.

## Architecture

- `DuckpadDomain/SearchModels.swift` contains AppKit-free mode, option, scope, range, result, limit, and typed failure values.
- `DuckpadApplication/SearchUseCase.swift` owns orchestration, immutable recovery-capture materialization, generation cancellation, UTF-8 range validation, result grouping, replacement expansion, and revision reservation. Multi-document captures are materialized sequentially off `MainActor`, so at most one document snapshot is in flight and merge order remains tab order.
- `DuckpadInfrastructure/ICURegexEngine.swift` implements `RegexEnginePort`. Its narrow C bridge sets ICU time and stack limits for every operation and maps invalid pattern, timeout, and complexity separately. ICU handles regular-expression semantics; C/ICU handles never leave Infrastructure.
- `DuckpadEditorAdapter/ScintillaEditorAdapter.swift` implements the active-editor port. Literal/extended Find uses the narrow Scintilla target/search façade. Replacement ranges are prevalidated as descending/non-overlapping UTF-8 boundaries and applied as one Scintilla undo group.
- `ScratchWorkspaceUseCase` reserves the exact active buffer/revision and holds the serialized workspace transaction across native apply and metadata commit. A cancelled queued reservation is released before native mutation. This prevents close/save/edit reentrancy from observing a partial Replace All.
- `SearchPanelView` supplies the form and results inside `SearchWindowController`. It is keyboard accessible, supports Return/double-click result activation, exposes progress/Cancel, and routes every status/result through the controller's operation token.

The existing editor recovery capture is an immutable checkpoint plus bounded deltas. Search copies this value on `MainActor` without reading Scintilla's full native document, then materializes bytes in a utility task. Search therefore does not reintroduce a per-keystroke snapshot path.

## Semantics and safety limits

Modes:

- Normal: literal text.
- Extended: `\n`, `\r`, `\t`, `\0`, `\\`, fixed-width binary `\b11111111`, octal `\o377`, decimal `\d255`, hexadecimal `\xFF`, and UTF-16 `\uFFFF`. Adjacent valid surrogate escapes form one Unicode scalar. Malformed or short numeric escapes stay literal, matching Notepad++ rather than silently deleting bytes; an unpaired surrogate fails explicitly.
- Regular Expression: ICU semantics with capture replacement `$0` and `$1`…`$99`, `$$` for a literal dollar, and backslash escaping. Named replacement groups are rejected as unsupported. Dot-newline is explicit.

Search ranges and selections are UTF-8 byte offsets. Invalid, overflowing, or code-point-splitting ranges fail before mutation. CRLF counts as one line break; result column is deliberately a UTF-8 byte column so its unit matches the activation range.

Defaults cap a document at 64 MiB, regex input at 8 MiB, a pattern at 64 KiB, results at 100,000 matches/32 MiB, aggregate replacement bytes at 16 MiB, and final document size at 128 MiB. ICU receives a 100 ms time limit and 8 MiB stack limit per operation. Search cancellation cancels the actual detached task; loops check cancellation and never publish a superseded generation. Multi-document scan uses one in-flight materialization (within the configured concurrency ceiling) rather than eagerly materializing all buffers.

Replace All is intentionally current-document only. All-open Replace All, folder/workspace replacement, text mark/style operations, named replacement groups, and persistent search history are deferred. Incremental count/results are delivered after a 150 ms debounce; all non-empty matches are decorated with the native search indicator, within the existing scan limits.

## macOS command surface

The Search menu routes `⌘F` Find, `⌘G` Find Next, `⇧⌘G` Find Previous, `⌘H` Replace, and Escape Close Find Panel. Closing by Escape or the close button cancels the owned operation, hides the search window, and returns focus to the editor. All-open-document search is an explicit action on the Find tab; Replace All is limited to the current buffer.

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
