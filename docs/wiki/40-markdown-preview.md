# Markdown editing

## Live editing

Markdown tabs use a bundled **CodeMirror 6** editor in both **Source** and
**Live Preview** modes. Choose either mode in the editor header or use
**View → Markdown Live Editing**. Other file types continue to use Scintilla.

Live mode gives headings distinct sizes and variable line heights, renders bold,
italic, strikeout and inline code, indents nested lists, and displays task checkboxes
and blockquotes. Syntax delimiters reappear when the caret enters their range. During mouse
selection, the existing presentation and layout remain fixed; releasing the mouse
reveals the selected Markdown source after the final selection settles (50 ms).
Fenced code has language highlighting, a language label and a Copy button. Tables
render inline with directly editable cells; local images reveal their Markdown
source when clicked. Table cells keep the table layout while editing. Tab and
Shift-Tab move between cells, Enter moves to the next row, and moving past the
last row creates one. Plain arrow keys also enter and leave tables, move between
cells at text boundaries, and retain normal caret motion inside wrapped cell
text. Arrow navigation never inserts rows. Focused cells show a plain caret
without a cell selection background. Cell editors overlay the existing layout,
so focusing a cell never changes column widths or reflows neighboring rows. A compact **⋯** menu appears on hover or focus; it inserts
or deletes rows and columns. Right-clicking a cell preserves its text selection and opens a menu at the
click position with clipboard and table actions. Outside clicks or Escape close
it; the popup stays inside the window. The
header row and final column cannot be deleted through the menu. Cells show
formatted content when inactive and Markdown syntax while editing. Literal pipes
are escaped on write; unrelated cell spacing and original line endings remain
intact. Copy, Cut, Paste, Select All and Delete operate on the focused cell;
Undo/Redo uses the shared document history. Cell values occupy one Markdown line;
pasted line breaks become spaces. Save and mode changes commit pending cell
composition before proceeding.

Source and Live share one CodeMirror document and selection; switching does not
change bytes, dirty state or Undo/Redo. The existing hidden Scintilla document
remains the synchronous file/recovery/command bridge and canonical Undo journal.
Incoming UTF-16 edits map to validated UTF-8 byte deltas, preserving untouched
mixed line endings. Multi-cursor changes form a single undoable native group.
Save, Close and recovery flush pending web input before capturing document data.
IME composition accumulates locally and commits one replacement when it ends.

Links use the system link color; visible `[]()` markers and destinations use the
muted text color. **Command-click** follows a link in Source, Live, or a table
cell. HTTP(S) links open in the default browser; file links open as Duckpad tabs.
Relative paths resolve against the Markdown document's location. Ordinary clicks
keep editing. Reference links and autolinks follow the same routing. Unsaved
Markdown documents need an absolute target for file navigation.

Source and Live use the same workspace palette as native editor panes and tabs.
The native header, WebKit page and scroller share the editor background; code,
table headers and Mermaid nodes use the panel color. Links and accent controls
resolve through macOS colors. Syntax roles follow the native editor palette.
Light, dark and increased-contrast changes update existing panes and Mermaid
cache identities without changing document bytes, selection or Undo history.

The mode lasts for the editor pane's lifetime. A split pane can use a different
mode for the same document. The editor ships offline, uses a nonpersistent WebKit
store, and allows no document scripts or network requests. **Allow Local Images…**
grants access to local image folders. Inline image reads are limited to 32 MiB.

This provides the editing foundation rather than Obsidian's complete feature set.
For raw table syntax use Source mode. Math renders directly in Live. Obsidian plugins and vault features are not included. Real
hardware IME behavior still needs manual verification beyond composition tests.

## Inline Mermaid diagrams

Fenced `mermaid` blocks render directly in Live mode using the bundled engine.
Click a diagram or its **Edit Source** button to reveal its code. The diagram
stays below the code and refreshes 300 ms after the latest change, without saving.
Leaving the code hides its source again. Source mode keeps ordinary fenced text.
While syntax is incomplete, a small status message appears and the last valid
diagram remains visible; an initially invalid block displays its source.

Rendering is serialized with one latest pending request per visible widget;
source edits discard stale results. A cache holds at most 16 diagrams and 4 MiB,
and SVG IDs remain independent for identical diagrams visible together. SVG is
sanitized, Mermaid runs in strict mode, and all runtime assets ship offline.
Closing or switching modes discards queued work and late results.

## Workspace dragging

Explorer files can be dragged directly onto any editor edge to create a split,
or into the middle of an existing pane to open there. Workspace root identity
and the normal scoped read/open path are retained. Dragging the last tab to an
edge automatically shows the same document in both panes, without requiring
Option or a previous split. Markdown WebKit panes forward internal workspace
and tab drags, including exit and completion events, to the workspace.

## Live math and shared rendering

Inline `$x_1+x_2$`, display `$$` blocks, and fenced `math` blocks render with
the bundled KaTeX engine. Clicking a formula reveals editable source; display
math keeps a live rendered result beneath its source. Moving the caret outside
hides the delimiters again. Source mode always shows the Markdown. Invalid TeX
remains visible; trusted TeX commands and document scripts are disabled. Fonts
ship offline and use the same authorized resource loader as the editor.
Table previews also render inline math without changing cell geometry on focus.

**View → Markdown Live Editing** (⇧⌘V) switches Source/Live for the active
Markdown pane. The separate preview window, its View/Close menu items, and tab
eye/context actions have been removed. Cmd-W closes the active document normally.
HTML inside Markdown remains editable source rather than a separate rendered
HTML view. The shared Markdown parser and clipboard renderer remain for formatted
copy and table content; removal of the preview UI does not remove those features.

Build assets with `npm ci --ignore-scripts --prefix scripts/markdown-preview`,
`npm test --prefix scripts/markdown-preview`, then `npm run build --prefix scripts/markdown-preview`.
Node is required only when rebuilding. The editor and clipboard resources include
third-party notices from pinned dependencies. No new math dependency is added.

The packaged regression runs in an in-memory document before opening settings
or recovery stores:

```
DUCKPAD_MARKDOWN_SMOKE=1 /path/to/Duckpad.app/Contents/MacOS/Duckpad
```

It checks Source/Live, inline Mermaid, KaTeX font loading, theme colors, links,
table geometry and navigation, and unchanged document bytes/revision. Native
integration tests cover IME, Save/Undo/recovery barriers and language changes.
Image-resource safety tests reject non-regular files and release every image grant.

## Image drops

Dropping image files (including PNG and SVG) on a Markdown editor
asks whether to **Insert into Markdown** or **Open in New Tab**. Check **Don’t ask
again; use this action** to remember the chosen action. Cancel never remembers a
choice. **Settings → Editing → Markdown image drop** restores “Ask every time” or
selects either action directly. Drops on tab bars, other languages, or mixed file
lists keep the normal file-opening behavior.

Insertion replaces the current selection, uses document-relative links for saved
Markdown and absolute file URLs for unsaved documents, and groups multiple images
into one undoable edit. Filenames and link destinations are escaped. Original
images are referenced without copying or modifying them. Their sandbox bookmarks
are retained for preview access. A document or editor-group change while the
prompt is open cancels insertion to prevent edits to a different target.

## Input performance verification (2026-10-27)

Typing no longer rescans/re-encodes the entire raw document for UTF-16/UTF-8
coordinate conversion. A checkpoint index bounds local lookup scans; edits
rebuild neighboring intervals and shift suffix checkpoint metadata. Decoration
updates reuse unchanged Markdown blocks and link-reference definitions. Native
status echoes skip equivalent editor configuration; mapped widgets resolve their
current positions before editing. Drag start/selection changes preserve existing
presentation, including the starting block; release updates once after 50 ms.
Long single Markdown blocks can still cost proportional work inside that block;
this is not a claim of full viewport-only rendering.

The opt-in `CodeMirrorEditorTests/markdownTypingAndDragPerformance` fixture uses
real WKWebView/Scintilla, 24 one-character edits near EOF and 24 drag-selection
updates. It verifies final native bytes. In the same debug fixture run:

| UTF-8 size / lines | Transaction mean before → after | Through native barrier + next task mean before → after |
| --- | --- | --- |
| 69,014 / 4,502 | 6.96 → 2.04 ms | 17.67 → 3.92 ms |
| 276,014 / 18,002 | 12.79 → 3.46 ms | 29.38 → 6.29 ms |

At 276 KB the transaction p95 is 15 → 4 ms, and the native-barrier p95 is
40 → 11 ms. Drag-selection native-barrier mean is 6.33 → 1.83 ms. This synthetic
transaction/bridge benchmark excludes physical keyboard input, compositor paint,
and the full window controller's side effects. It is not keyboard-to-paint
latency or a runtime comparison with Obsidian. Timings are machine/run dependent.
Run with `DUCKPAD_MARKDOWN_PERF=1 swift test --filter 'CodeMirrorEditorTests/markdownTypingAndDragPerformance'`.

Installed Obsidian 1.8.9 was statically inspected: its markup plugin visits visible
ranges, maps decorations during pointer/IME interaction, and schedules selection
presentation 50 ms after release. Its parser reuses fragments and cooperatively
schedules background work. Evidence identifiers, artifact hashes, byte offsets and
limitations are retained in the local build investigation report; neither its
runtime input latency nor a current/latest version was measured.
