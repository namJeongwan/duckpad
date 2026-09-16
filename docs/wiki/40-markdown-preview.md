# Built-in Markdown preview

For `.md` and `.markdown` tabs, choose **View → Markdown Preview** to open a
preview beside the editor with **⇧⌘V**. This menu item is hidden for other active tabs.
Hover a Markdown tab to reveal an eye in place of its file icon; click the eye
or choose **Markdown Preview** from that tab's context menu to activate it and
open its preview. Repeating either action keeps the preview open. The View
menu item, **Ctrl+W**, **⌘W**, or the panel's close button dismisses it. Switching to a
non-Markdown tab also closes the preview. Preview follows the
active document, including unsaved edits, without changing its contents,
selection, revision, or undo history. No plugin or runtime installation is required.

The bundled Markdown engine renders headings, emphasis, lists, quotes, fenced
code with language syntax coloring, tables, links, and images. KaTeX renders
`$inline math$` and `$$display math$$`; fenced `mermaid` blocks render diagrams.
These engines and their fonts ship with the app and work offline. HTML is
sanitized before display; document scripts and event handlers do not execute.
Malformed diagram source remains readable as code.

Markdown documents are excluded from built-in manual and save-time formatting.
Saving preserves whitespace, including indentation. Code fences use three
backticks (```), not three apostrophes ('''). The native Markdown lexer colors
headings, emphasis, links, and code regions; language-specific highlighting
inside code fences is provided by the preview.

Relative image paths resolve against the saved Markdown file. Absolute file
image paths also work. In a sandboxed build, if the image directory has not
already been authorized, use **Allow Local Images…** in the preview header to
choose it. Folder grants are remembered with security-scoped bookmarks. The
resource loader only serves image files and bundled preview assets. Local
resources must be regular files. Large images and image symlinks remain supported
when their targets are accessible regular files. Reads use 64 KiB chunks and
stop on cancellation. HTTP/HTTPS
images may load from the network; other preview engines never need a CDN.

There is no arbitrary document-size cutoff. Preview waits 350 ms after a content
change, skips caret-only changes, and materializes a recovery capture off the
main thread. At most one render and one latest pending capture are retained.
Native editor snapshot reads are avoided. Large documents still require memory
and rendering time proportional to their content. Closing stops resource loads
and invalidates pending updates. Binary documents are not Markdown content.

`MarkdownPreviewCoordinator` owns preview scheduling and teardown. Filesystem
reading and persistent image-folder grants are supplied by the application
composition root through required ports; the panel does not persist bookmarks
itself. Window and panel construction must supply the resource reader and image
access provider, including smoke-test composition.

Build bundled assets with `npm ci --ignore-scripts --prefix scripts/markdown-preview`
and `npm run build --prefix scripts/markdown-preview`. The lockfile pins dependencies;
packaged assets include third-party notices. Node is only needed to rebuild assets.

Tests cover real WebKit rendering, sanitization, math, diagrams, code styles,
local images, documents above the former 2 MiB limit, source-preserving saves,
menu localization, native lexer colors, capture counts, live edits, and teardown.

Packaged-app regression check (run after building, under the app sandbox):

```
DUCKPAD_MARKDOWN_SMOKE=1 /path/to/Duckpad.app/Contents/MacOS/Duckpad
```

This uses an in-memory test document before user settings or recovery stores
are opened. It opens/closes the preview three times and checks Rust highlighting,
KaTeX font loading, Mermaid labels, and unchanged source/revision. A SwiftPM test
alone cannot verify the packaged `Contents/Resources` layout. Presentation assets
resolve from that location first; an app with missing resources returns an error
instead of evaluating SwiftPM's development-path `fatalError` fallback.

## Image drops

Dropping image files (including PNG and SVG) on a Markdown editor or its preview
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
