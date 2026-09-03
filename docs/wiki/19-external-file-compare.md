# Phase 16 — External File Compare

Status: **Implemented; independent review pending**

## Outcome

When a save detects that the bound file changed on disk, Duckpad now offers **Compare** alongside Reload, Overwrite, and Cancel. Compare opens a read-only side-by-side view of the current editor snapshot and the latest disk contents, marks lines that differ at the same position, and then returns to the unresolved conflict decision.

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

Independent review, exact staged-candidate receipt, and commit evidence are pending.

## Next slice

Folder search/results and bookmark navigation follow this phase. A richer aligned diff algorithm can replace positional line marking later without changing the conflict or persistence boundary.
