# Notepad++ replacement workflows

Source: user requirements reviewed against main `67a0f1e` on 2026-10-19.
Keep existing editing, recovery, and performance guarantees while filling these gaps.

| Order | Workflow | Status | Acceptance |
| --- | --- | --- | --- |
| 1 | Legacy file encodings | Implemented on `feature/legacy-encoding` | Explicit open/reopen and undoable format selection before saving for CP949, EUC-KR, Shift-JIS/CP932, Windows-1252/1251, ISO-8859-1, GB18030, Big5; status display; retain encoding on save/reload/recovery; reject invalid input and unrepresentable output without changing files or dirty buffers. |
| 2 | Replace across files | Planned | Replace across open documents and unopened folder files, with preview, explicit scope, conflicts, encodings, and safe writes. Existing folder search is not folder replacement. |
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
