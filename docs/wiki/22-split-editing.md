# Phase 19 — Shared-Document Split Editing

Status: **Implemented; review pending**

## Outcome

Duckpad can split the active document side by side or top and bottom. Both panes are backed by the same Scintilla document and therefore expose identical text, markers, language styling, and one native undo history. Each pane retains an independent cursor, selection, scroll offset, word-wrap state, and wrap-symbol state.

The View menu provides:

- **Split Editor Right** — `Command-Backslash`
- **Split Editor Down** — `Command-Option-Backslash`
- **Focus Other Editor Pane** — `Command-Control-Backslash`
- **Close Editor Split** — `Command-Shift-Backslash`

## Native document ownership

The narrow Objective-C++ bridge shares Scintilla's reference-counted document pointer. Only the primary view subscribes to modification notifications, because a shared Scintilla document publishes the same mutation to every watcher. Edits made from either pane therefore cross the Application revision boundary exactly once. The secondary view synchronizes the accepted revision immediately and becomes read-only together with the primary view at revision exhaustion.

Programmatic replace and grouped replacement continue through the primary notification owner. Interactive typing, editing commands, and undo/redo can originate in either pane and mutate the shared document. Closing a split removes only the second view; it never copies or replaces document bytes.

## Recovery and lifecycle

Recovery adds an optional split orientation plus a bounded secondary-pane view state. Legacy archives omit both fields and remain unsplit. Malformed one-sided split metadata, negative positions, positions outside the document, and UTF-8 continuation offsets are rejected before a generation is accepted.

Split state is per buffer. Switching to an unsplit document collapses the divider; returning to a split document restores its orientation and secondary cursor/view options. A rejected native edit is quarantined by its exact buffer ID and synchronously recovered before any snapshot, buffer switch, or lifecycle input lock can observe its bytes. Revision exhaustion disables only that buffer's two panes. Closing a split invalidates its native callbacks/document watcher and evicts the secondary view; retiring the buffer removes both views. All split commands use the same startup/termination admission gate as editor commands.

The AppKit fallback deliberately drops split-only recovery metadata because it cannot provide the shared-document contract; plain text remains available.

## Validation

Focused tests cover one notification/revision per secondary-pane edit, rejected-edit recovery before an immediate buffer switch, per-buffer revision-exhaustion isolation, identical language configuration from either focused pane, split-view invalidation/cache eviction, shared native undo, independent selections, focused-pane wrap options, side-by-side/stacked layout, per-buffer switching, recovery round trip, malformed secondary recovery fallback, controller validation, shortcut uniqueness, and fallback degradation. Exact-current full Debug and Release suites each pass 270/270 tests.

## Next slice

Workspace roots/file browser and multiple-window lifecycle follow.
