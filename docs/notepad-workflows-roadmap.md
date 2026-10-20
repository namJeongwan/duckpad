# Notepad++ replacement workflows

Source: user requirements reviewed against main `67a0f1e` on 2026-10-19.
Keep existing editing, recovery, and performance guarantees while filling these gaps.

| Order | Workflow | Status | Acceptance |
| --- | --- | --- | --- |
| 1 | Legacy file encodings | Released in 0.12.2 | Explicit open/reopen and undoable format selection before saving for CP949, EUC-KR, Shift-JIS/CP932, Windows-1252/1251, ISO-8859-1, GB18030, Big5; status display; retain encoding on save/reload/recovery; reject invalid input and unrepresentable output without changing files or dirty buffers. |
| 2 | Replace across files | Open-document and folder-to-buffer phases implemented on `feature/search-experience`; full-file replacement diffs and folder legacy decoding remain planned | Replace across open documents and unopened folder files, with preview, explicit scope, conflicts, encodings, and safe writes. Existing folder search is not folder replacement. |
| 3 | Marked-line operations | Planned | Delete bookmarked lines / delete unbookmarked lines across the current document; preserve Undo and exact line endings. Existing bookmark marking remains available. |
| 4 | Visible whitespace preferences | Planned | Persistent defaults for new documents, clear space/tab/EOL indicators, configurable size/color where supported; restore per-document settings. |
| 5 | Mouse-wheel zoom | Planned | Modifier + wheel zoom, predictable direction and bounds, status/recovery consistency, ordinary scrolling preserved. Keyboard and pinch zoom already exist. |
| 6 | Record and replay macros | Planned | Record supported editing/search commands, stop/play/save/name/repeat; define handling of IME, selections, failures, and Undo. |

Already supported: common text/source files, single-document search/replace including escaped line breaks, search across open documents and folders, visual side-by-side comparison, session restoration including unnamed and unsaved documents.

## Encoding scope

Automatic opening remains BOM/UTF-8 based. Ambiguous legacy bytes require an explicit encoding selection; no locale guess silently makes a binary/legacy file editable. Encoding and LF/CRLF/CR selection change the requested output format and mark the document unsaved; only Save/Save As writes converted bytes. Format selections share the native text Undo/Redo history, preserve selection, and survive recovery for named and untitled documents. Undo after a save changes the document state, not disk bytes; another Save is required. Reopening interprets bytes from disk and retains the existing unsaved-change guard. Legacy encodings have no BOM. macOS built-in converters add no external runtime dependency.

Notepad++ local reference: `PowerEditor/src/EncodingMapper.cpp` separates Windows code page 949 from EUC-KR (51949), and uses code page 932 for its Shift-JIS menu. Duckpad likewise keeps Korean encodings distinct and labels the Japanese Windows-compatible variant explicitly.

Folder-search encoding selection/detection is not part of step 1; unopened legacy files are still subject to the existing UTF/BOM search decoder. Step 2 must address this explicitly.

## Step 1 validation

Related Swift suites pass: 256 test functions covering known encoding byte fixtures, strict rejection, reopen/save/reload, menu routing/status, UTF/BOM regressions, and native editor save/recovery behavior, including format Undo/Redo across reload and asynchronous save failures. CP949 dirty recovery is exercised through `LocalRecoveryStore` and a new workspace/editor before verifying exact saved CP949/CRLF bytes.

Save validation runs before automatic formatting or whitespace cleanup changes the buffer; formatter output is checked before it enters Undo history. Regression tests failed before the ordering fix and passed afterward. Unchanged legacy output reuses the validated bytes to avoid encoding twice.

All eight localization catalogs pass key and format validation (796 strings, four plural entries). Independent review found no remaining Blocker/Major issues. Full manual UI inspection in all eight languages and a packaged release build were not performed for this step.

## Deferred format changes

The status menu now says **Convert Encoding** / **Convert Line Endings**, with no implicit write. Restoring a saved format via Undo removes its pending override, allowing project conventions to apply again. File reload groups text and format changes into the same Undo action. A save completing after concurrent Undo retains the newer requested format, marks it dirty, and invalidates the older native save point. Pending output settings are persisted in session metadata; Undo history itself remains session-local, as with normal text edits.

Transaction ownership transfers the next autosave’s edit allowance before resuming it, avoiding a temporary native Undo rejection during handoff. Reload Undo tests issue commands immediately without waiting for persistence. A concurrent metadata-edit stress test and the related suites pass; the stress test alone also passes on the old implementation and is not a deterministic reproduction of the timing gap.


## Step 2: open documents

The Replace tab offers an explicit scope selector: current document, selection, or all open documents in the current window. Find All can review matches before applying Replace All. All-open scope disables the current-document Find Next/Replace actions; Return runs Find All. Replacement results show per-document counts or a reason for skipping, and can activate the corresponding tab.

All-open replacement plans matches from immutable captures off the main actor. Document and regex byte limits are checked before replaying recovery deltas; match, result, replacement, and final-document budgets bound the operation. Each accepted document is one native undo group. Background tabs retain their position and do not become active; typing, pending formats, selection state, split-document sharing, and recovery continue through the existing editor bridge. Files are marked unsaved and are written only on an explicit save.

Read-only, unavailable, changed, oversized, timed-out, and cancelled targets are reported. Invalid queries fail before applying edits. Equal-byte replacements leave dirty state and Undo untouched. This is a per-document operation: cancelling after some documents have completed retains those edits and reports them; there is no cross-document Undo transaction. Folder replacement now stages matching files as inactive, unsaved editor documents after identity checks; it never writes source files automatically. Full-file replacement diff previews and explicit legacy decoding for folder search remain planned.

Validation: 374 related test functions passed across application, native editor, presentation, infrastructure, and app suites, including independent document Undo/Redo, inactive and split buffers, encoding/disk preservation, recovery, stale captures, cancellation, query errors, and bounded replacement. All eight localization catalogs passed (847 string keys and four plural entries); panel layout assertions and snapshots cover all eight languages, with Korean and German screenshots visually inspected. Independent review found no remaining Blocker/Major issues. A packaged app build and full manual inspection in every language were not performed for this phase.

## Separate search experiences

Cmd-F / Cmd-H keep the existing Notepad++ style dialog. Cmd-Shift-F / Cmd-Shift-R use a separate project search and replacement window with dense one-line match results above a resizable code-context preview with line numbers. Double Shift opens filename/path search across open tabs and registered workspace folders, including unopened files; it does not search file contents or LSP symbols. Both new windows share panel chrome and selection styling. Content search, replacement, filename mask, filename search and the command palette also share `SearchInputField` for centered text/editor geometry and flat focus chrome. Both windows use all eight locale catalogs and inherit Duckpad's current appearance. Clicking the editor dismisses either popup and delivers the same click to the editor; attached sheets and menu tracking keep the popup open.

Project Replace All requires a completed, nontruncated preview and explicit confirmation; Replace applies only the selected match. Filename masks (*, ?, comma/semicolon lists and ! exclusions) constrain both searches and replacements, including after moving results to the classic Find window. Tab moves from Find directly to Replace with, and Shift-Tab returns. Open-document revisions and folder file identities are rechecked. Changed, closed, dirty folder targets and other skipped documents remain visible in the outcome. Folder replacement prepares up to 200 files per operation, leaves the active editor's selection/focus unchanged, and applies each document as an independent Undo group. Disk writes still require Save / Save All.

The current source change has 332 distinct related test functions passing across the final broad run and focused popup suite, with the real-sheet test isolated to avoid AppKit interference in the broad process. The compact search options fit the minimum window width in all locales and search modes. The 34 new-window screenshots cover eight languages and light/dark appearances, including empty-input checks. See [the review record](wiki/reviews/2026-10-20-search-experience.md) for exact commands, validation limits and remaining scope.

The filename-reference follow-up adds Files/Open Documents tabs, dense rows with material file icons and matched-name highlights, inline directory/workspace metadata, and a selected full-path footer. Open in Right Split preserves the invoking pane and copies the same buffer beside it. Normal and split requests share cancellation; queued tab activation validates the current request after acquiring the transaction. The search option component owns persistent blue On/clear Off state and matcher updates. Forty-seven focused functions pass, with all eight locales checked at minimum width and 56 presentation captures. Actual packaged mouse interaction was blocked by the Mac login screen; automated accessibility and rendered-state tests passed.


Packaged folder content search now uses bundled ripgrep 15.1.0 for streaming file
discovery with selected-root `.gitignore`/`.ignore` rules. Verified file bytes are
matched immediately by the optimized native engine to preserve Unicode/ICU and
replacement semantics; no system rg installation is needed. Partial results
appear during the scan, with replacement disabled until completion. The list
shows up to 5,000 rows while retaining the full bounded replacement preview.
The helper never edits source files. Local build/signature, cancellation/limits,
streaming-state and native Undo checks are recorded in the review document.


The search scope selector now distinguishes All (open buffers + all registered
roots), Open Documents (current-window tabs), Workspace (all registered roots),
and Folder (an explicit directory). Open unsaved contents override disk results,
overlapping roots are deduplicated, budgets are shared, and a transferred classic
Find window retains its original search/replacement scope. Classic Find keeps its
original labeled fields, native checkboxes/radio buttons and compact layout;
shared light/dark colors and compact action-button chrome connect it visually to
the project search windows. Search field editors refresh Korean marked-text
queries without requiring a space/backspace or committing the composition.


Double-Shift filename search now uses the same All / Open Documents / Workspace /
Folder scopes as project content search. All combines current-window tabs with
all workspace roots; Open Documents includes scratch and external tabs without
disk indexing; Workspace includes unopened files across registered roots; Folder
indexes an independently chosen directory without adding it to the workspace.
Open tabs win duplicate paths. Scope changes preserve the query and discard late
index/picker results. Folder enumeration uses bundled rg names only, and selected
results retain root authority for safe normal/split opening. Korean marked-text
refresh remains shared with the other search inputs.


The filename popup keeps its original wide tab appearance for the four scopes:
separate text tabs with hover feedback and a highlighted active tab. Project
content search retains its compact selector; both use the same scope semantics.


## Next tasks after 0.14.0

- Add bounded, structured error diagnostics for search and other user-visible failures. Reuse the usage-sharing preference; send only stable error/feature codes and app/build versions, never document contents, search queries, filesystem paths, credentials or raw error descriptions. Make delivery state visible and verify version-change event delivery separately.
- Add a persistent hidden-file visibility option shared by the workspace tree, folder content search and filename search. Define interaction with ignore files explicitly, refresh existing views/indexes on changes, and retain path, symlink, package and resource limits.
