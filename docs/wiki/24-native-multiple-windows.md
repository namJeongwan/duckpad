# Phase 21 — Native Multiple Windows

Status: **Implemented; review pending**

## Outcome

Duckpad now supports independent native document windows. **File → New Window** uses `Command-Shift-N`; `Command-N` remains the faster scratch-tab command inside the current window. Closing the last window keeps the application alive, and clicking the Dock icon reopens an existing hidden window or creates a fresh one. The active key window owns the current menu command target.

Each window has its own scratch session, tab strip, editor and split state, recovery stream, search panels, language state, extension command surface, and workspace-sidebar presentation. Shared infrastructure actors retain process-wide filesystem identity checks, saved workspace roots, extension packages, grants, and isolated extension transport. Opening the same path in two windows is allowed as two independent buffers; the second stale save is rejected by the existing `FileIdentity` conflict flow and requires Compare, Reload, Overwrite, or Cancel. It never silently overwrites the first window's newer bytes.

## Window and recovery lifecycle

The application delegate retains every live `DuckpadWindowController` by stable object identity. Controllers detach synchronously when their native windows close. A normal red-window close reviews only that window's dirty tabs. `Command-Q` synchronously admits every live window that requires review, locks their mutation surfaces, serially resolves dirty-document decisions, and performs each final recovery flush before answering AppKit. If any window cancels or a save/flush fails, every admitted window is reopened for editing and the application remains alive. Red-close and application-quit requests that overlap join the same review task.

The original recovery directory remains the primary-window archive for compatibility. Additional windows use UUID-named sibling recovery directories under `<primary>-Windows`. Discovery is off the main actor, descriptor-relative, no-follow, and bounded to 1,024 raw entries and 31 additional windows. Only real UUID directories are restored; symlinks, hidden names, malformed entries, and over-limit containers fail closed. Each accepted directory keeps its exact parent/root descriptors. Manifest and blob load, atomic generation publication, stale-generation cleanup, and reset all remain descriptor-relative, so replacing the visible UUID path with a directory, symbolic link, or regular file cannot redirect read, write, chmod, cleanup, or deletion.

Creating windows is capped at 32 live native windows so a restored or automated session cannot exhaust the UI process. Explicitly closing a window registers its recovery reset with the application termination coordinator before detaching. `Command-Q` joins that reset; reset failure denies termination and arms one retry for the next quit request instead of silently resurrecting the closed window. A successful descriptor-relative reset unlinks the UUID directory. If the still-live recovery use case later needs to write again, it recreates that same private entry exclusively without following a replacement. An approved application termination skips window-close cleanup and preserves all still-open window archives for the next launch.

## Native commands and accessibility

The Window menu provides macOS-standard Minimize (`Command-M`), Zoom, Enter Full Screen (`Command-Control-F`), and Bring All to Front commands. Existing editing, tab, search, language, view, and extension selectors are rebuilt against the key window so keyboard commands never mutate a background window accidentally. New Window is disabled during prepared termination review, just like other document mutations.

## Validation

Focused AppKit tests cover exact New Window selector/shortcut/menu publication, callback routing, two-window application termination cancellation, reopening every admitted window after cancellation, final recovery flushes for all approved windows, late-attached windows joining reviews blocked by either a dirty decision or close cleanup, red-close isolation, native close teardown, a blocked close reset delaying quit, and failed-reset denial/retry. Infrastructure tests retain a verified directory descriptor across visible-path symlink and regular-file swaps, reject reset against replacements made both before reset and immediately before root unlink, preserve the foreign target, safely unlink/recreate a legitimate root, and preserve corrupt-newest fallback. Application tests cover two independent sessions opening the same file and rejecting the stale window's save without losing either buffer. A production three-launch smoke creates and flushes two windows, restores and explicitly closes the additional window while joining cleanup, then verifies that only the primary window returns. Exact-current Debug and Release suites each pass 301/301 tests; parity governance passes 31/31 and commit governance passes 8/8.

README files and the ignored Notepad++ reference remain outside this work. The pre-existing user edits in `docs/wiki/04-implementation-foundation.md` and `scripts/vendor_scintilla_5_6_6.sh` remain preserved and excluded.

## Next slice

Symbols/completion, encoding and EOL controls, settings/theme/accessibility completion, then release packaging and the machine-readable 90% parity audit follow. Macro recording/playback remains deliberately excluded.
