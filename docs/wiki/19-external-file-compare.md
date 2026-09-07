# Phase 16 — External File Compare

Status: **Phase 16 delivered; renderer superseded by locally audited Phase 33 implementation**

## Current Compare surface

[Phase 33](38-editor-groups-compare-and-native-tabs.md) adds **View → Compare
with Open Document…** and the equivalent tab-context command for any two open
documents. It captures immutable exact-revision snapshots without activation,
then uses the same bounded, read-only aligned renderer now shared by external
file conflicts.

The common renderer uses 32 MiB and 50,000 logical lines per side, at most
2,000,000 Myers steps and 100,000 aligned rows. It marks insert/delete/replace
rows with semantic color plus textual `+`/`-`/`~`, disables wrapping, mirrors
normalized vertical scroll with exact end clamping, and leaves horizontal
scroll independent. Pending work is cancellable, and changed/closed revisions,
newer requests, dismissal, or teardown suppress stale presentation.

## Outcome

When a save detects that the bound file changed on disk, Duckpad offers
**Compare** alongside Reload, Overwrite, and Cancel. Compare opens a read-only
side-by-side view of the current editor snapshot and the latest disk contents,
aligns changed rows with the shared Phase 33 renderer, and then returns to the
unresolved conflict decision. The original Phase 16 renderer used positional
line marking; that rendering detail is historical and no longer current.

The operation does not save, reload, clear dirty state, alter selection, or consume the pending conflict. Reload and Overwrite still pass through the existing file use-case and workspace revision authority.

## Safety and ownership

- `FileDocumentUseCase` owns conflict serialization and produces an immutable `ExternalFileComparison`.
- Both local UTF-8 size and external byte size are capped at 32 MiB before presenting the native comparison panel.
- Disk bytes use the document's bound encoding when available; decode/store/revision failures remain typed failures.
- After asynchronous disk I/O, the use case revalidates the exact tab, buffer, revision, and binding before exposing a comparison; an edit, close, or rebind invalidates the result.
- Reload carries the conflict revision into the workspace transaction and replaces contents only if that exact revision still owns the tab; edits accepted while a comparison is displayed or while disk I/O is pending fail closed.
- Presentation owns only the read-only AppKit panel and the user's next decision.
- Repeated Compare choices run in an iterative resolver loop rather than growing async recursion.
- Macro recording and playback remain intentionally excluded from Duckpad's roadmap.

## Validation

Application tests cover exact local/external comparison contents, non-mutating Compare, follow-up Cancel, comparison-size rejection, and edit/close/rebind races while the pending conflict remains resolvable. Presentation routing covers Compare followed by Reload, including captured panel contents, final clean state, and unchanged external disk bytes. Final remediated Debug and Release suites each pass 232/232 tests; `git diff --check` passes.

The Phase 16 independent review, exact staged-candidate receipt, commit, and
delivery were completed; the richer renderer is now superseded by Phase 33 as
described above.

## Superseded next-slice note

The richer aligned diff anticipated by Phase 16 is now implemented by Phase
33 without changing the conflict or persistence boundary. Folder search and
bookmark navigation were delivered in their subsequent phases.
