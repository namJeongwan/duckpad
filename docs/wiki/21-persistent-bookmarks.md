# Phase 18 — Persistent Document Bookmarks

Status: **Implemented; review pending**

## Outcome

Duckpad now supports per-document line bookmarks that survive tab switching and crash/session recovery. The Search menu exposes **Toggle Bookmark** (`Command-F2`), **Next Bookmark** (`F2`), **Previous Bookmark** (`Shift-F2`), and **Clear All Bookmarks** (`Command-Shift-F2`). Navigation wraps at the first and last bookmark.

Bookmarks are editor metadata: toggling, navigating, clearing, and restoring them do not change document bytes, revision, dirty state, or undo history. Macro recording and playback remain intentionally excluded.

## Editor ownership

- The Scintilla path owns bookmarks as native marker number 20. Marker numbers 21–24 remain reserved for history and 25–31 for folding. A dedicated narrow marker margin renders the bookmark glyph using the active system palette.
- Scintilla moves markers with line edits and its native undo/redo behavior. Reload and recovery restore only in-range marker lines.
- The AppKit fallback stores the same per-buffer state and updates line positions after accepted edits. Its visual emphasis uses temporary layout attributes so bookmark rendering never overwrites document attributes or enters the edit transaction.
- Switching buffers stores the outgoing view state and restores the incoming buffer's independent bookmark set.

## Recovery and bounds

`EditorViewState` persists sorted, unique zero-based line numbers. Legacy recovery without the field decodes to an empty bookmark set. Decoding rejects negative or over-limit input, and the local recovery store rejects bookmarks beyond the recovered text's CR, LF, or CRLF line count before accepting a generation.

The hard upper bound is 10,000 bookmarks per document. This prevents an untrusted or corrupt recovery manifest from causing unbounded main-thread marker restoration while remaining well above practical scratchpad use.

## Lifecycle and validation

Commands are enabled only while the editor is actionable; bookmark navigation and clearing additionally require at least one bookmark. View-state persistence is scheduled after each accepted bookmark operation and remains subject to the existing startup and termination admission gates.

Focused coverage verifies per-buffer ownership, navigation wrapping including a bookmarked first line, edit and Scintilla undo/redo line tracking, CRLF-boundary edits, decoration ownership, bounded maximum-count capture, recovery round trips, legacy decoding, malformed/out-of-range recovery fallback, menu selectors and shortcut uniqueness, controller persistence, and no revision/dirty/undo mutation. Full Debug and Release suites each pass 261/261 tests.

## Next slice

Split editing, additional window/workspace commands, and a file-browser surface follow.
