# File location commands and printing

File > Rename, Move To, and Move to Trash operate on the active file. The same
commands appear in file tabs’ context menus and target the clicked tab, including
inactive tabs and tabs in another editor group. Rename
and Move To use a native destination panel initialized to the current file.
Existing destinations are never overwritten. Scratch documents first need Save As.

Moving does not save pending text edits or apply formatting. The buffer, revision,
selection, dirty state, and native Undo history remain intact. The new file binding
and title are published after the filesystem operation, including when recovery
persistence fails; retry saves the updated session rather than restoring an old path.
A workspace structural transaction prevents close/rebind/edit races during I/O.
Panel responses are rejected if the active document changed in the meantime.

Trash requires confirmation and closes the tab after the filesystem move succeeds.
The confirmation explicitly warns that unsaved changes will be discarded. Normal
close/recovery handling removes the tab from all editor groups; the last tab is
replaced by a blank document. If persistence fails, the buffer stays available: text
is detached from its old file, while binary content retains the resulting Trash URL.
Files are restored through Finder, not text Undo. Only explicit UI actions modify
files; formatting, printing, and opening never invoke these commands.

File > Print (Command-P) prints the current text, including unsaved edits, through
the native print panel with its PDF options. Printing uses a separate black-on-white
monospaced text view with line wrapping and pagination. Binary documents do not
expose text printing. The editor's text, selection, and Undo history are untouched.

New commands and prompts include English and Korean translations. Filesystem
operations run off the main actor and use file coordination, identity checks,
no-overwrite rename semantics, and native Trash handling. Moves across volumes
use Foundation's move operation. File access and recovery use the existing
security-scoped bookmark owner lifecycle.

## Validation

- Focused regression tests cover file operations, existing file saving/lifecycle,
  tab menus, editor groups, native editor integration, and recovery on close failure.
  Context menu commands target inactive tabs in both single and split layouts;
  Trash also closes cloned views and read-only binary tabs.
  A separate isolated native printing test validates PDF output.
- Real temporary-file rename/move retains disk bytes, dirty buffer contents,
  revision, CRLF metadata, native Undo/Redo, and the subsequent Save destination.
- Case-only renames retain the requested spelling; a regression reproduced three
  failures before the fix and passed afterward.
- Occupied paths and symlink destinations remain untouched. External modifications
  reject Trash. Cancelled and stale panel responses perform no filesystem change.
- Native Trash returns the exact recoverable test file; test-owned trash artifacts
  are removed after verification. Successful Trash removes the tab from the session
  and editor groups. A failed close commit preserves unsaved text as a scratch buffer.
- Session-write failure after a committed move retains the new in-memory binding
  and successfully persists it on retry. Structural mutations wait for file I/O.
- Native printing produced a multi-page PDF containing the final source line;
  print layout preserves the Unicode source string. Command-P wiring is verified.
- The app requests the standard sandbox printing entitlement. Physical printers,
  cross-volume hardware moves, and interactive sandbox grant dialogs have not
  been manually exercised. The test build is native to the development Mac.

The PDF test opts into a separate process because native printing runs a nested
AppKit event loop that can interfere with concurrent window/lifecycle tests:

```sh
DUCKPAD_PRINT_PDF_TEST=1 swift test --filter printOperationProducesMultiplePDFPagesWithoutChangingText
```

## File drops and sandbox access

Finder/pasteboard file URLs can already be readable by the sandboxed process while
`startAccessingSecurityScopedResource()` returns false on the received URL. The
file store first preserves the original URL, then promotes an implicit grant to
an app-scoped bookmark and acquires the resolved URL. Cached bookmarks remain a
fallback. Scopes are released using the exact acquired URL, not a normalized copy.
No Downloads-wide entitlement or file-panel fallback is added.

Regression coverage verifies opening and saving through the native editor drop
callback, implicit-grant acquisition/renewal, denied grants, balanced release, and
bookmark restoration. A sandboxed probe received a test-only Downloads file through
an interprocess AppKit pasteboard: direct start returned false while the file was
readable; bookmark conversion returned true and read the exact expected contents.
The packaged app also opened a test-only Downloads file via Launch Services,
retained its bookmark across process termination, and saved it after relaunch.
The native drag callback is exercised with NSDraggingInfo; physical pointer dragging
from Finder has not been automated.

The broader run exposed an existing folder-search UI test that looks for search
controls in the main window (`routedFolderSearchOpensIdentityCheckedResultAndSelectsUTF8Range`).
It fails before opening a search result and also fails in isolation; it is outside
the file-drop change. Other tests in that run completed successfully.
