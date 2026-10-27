# Bundled Markdown preview and editing engines

The app bundles CodeMirror editor assets under
`Sources/DuckpadEditorAdapter/Resources/MarkdownEditor/`, and synchronous formatted
clipboard assets under `Sources/DuckpadPresentation/Resources/MarkdownPreview/`.
`build.mjs` produces both from pinned dependencies; do not hand-edit generated
JavaScript. The app requires neither Node nor a CDN at runtime.

`clipboard.mjs` builds `clipboard.js` from the shared Markdown parser for
JavaScriptCore export. It renders headings, lists, tables and inline formatting
with inline styles, disables raw HTML, allows HTTP(S)/mailto links, and emits image
alt text rather than resource URLs. The former separate preview has been removed.

Direct runtime dependencies (exact dependency tree: `package-lock.json`):

- markdown-it 15.0.2 — https://github.com/markdown-it/markdown-it — MIT
- @vscode/markdown-it-katex 1.1.2 — https://github.com/microsoft/vscode-markdown-it-katex — MIT
- KaTeX 0.18.7 — https://github.com/KaTeX/KaTeX — MIT
- highlight.js 11.12.0 — https://github.com/highlightjs/highlight.js — BSD-3-Clause
- Mermaid 12.0.0 — https://github.com/mermaid-js/mermaid — MIT
- DOMPurify 3.4.15 — https://github.com/cure53/DOMPurify — Apache-2.0 OR MPL-2.0

Build tool: esbuild 0.28.2 (MIT). KaTeX is pinned across the math plugin and root
to avoid shipping duplicate engines/fonts. lodash-es is pinned to 4.18.1 because
the original Mermaid transitive dependency range also accepts an audited vulnerable
version. `npm audit` reported zero vulnerabilities for this lockfile on 2026-09-14.

Rebuild:

```
npm ci --ignore-scripts --prefix scripts/markdown-preview
npm test --prefix scripts/markdown-preview
npm run build --prefix scripts/markdown-preview
```

The build copies KaTeX fonts/CSS into editor resources and collects dependency
license/notice files into the packaged `THIRD_PARTY_NOTICES.txt`. Source HTML is
sanitized with DOMPurify; Mermaid uses strict security and KaTeX uses `trust:false`.
Swift additionally restricts WebKit resource loading with CSP and a custom scheme.

The generated bundle targets Safari 16 for macOS 13.0. `compatibility.mjs` supplies
`URL.canParse` on older WebKit; JavaScript class static blocks are lowered by esbuild.

## CodeMirror Markdown editor (2026-10-27)

`editor.mjs`, `editor-live.mjs`, `editor-link.mjs`, `editor-diagram.mjs`, `editor-table.mjs`, `editor-table-model.mjs`, `editor-table-caret.mjs`,
`editor-raw-document.mjs`, `editor-decoration-updates.mjs`, `editor-math.mjs` and `editor.css` build the
assets in `Sources/DuckpadEditorAdapter/Resources/MarkdownEditor/`. Rebuild with
the same commands above. Runtime code and language parsers are bundled offline.
The editor resources include the same collected third-party notices.

New pinned runtime dependencies, all MIT licensed:

- @codemirror/state 6.7.6, @codemirror/view 6.43.15
- @codemirror/commands 6.11.1, @codemirror/language 6.13.1
- @codemirror/lang-markdown 6.5.2, @codemirror/language-data 6.5.2
- @lezer/highlight 1.2.5, @lezer/markdown 1.8.1

Sources: https://github.com/codemirror and https://github.com/lezer-parser.
Markdown table widgets reuse markdown-it and DOMPurify. Live decorations and
native integration are Duckpad implementations; no Obsidian source is copied.
Source and Live share one CodeMirror state. The native document retains the
canonical Undo journal and synchronous file/recovery API. A UTF-16/UTF-8 mapping
preserves original mixed line endings instead of serializing normalized content.

Inline Mermaid widgets reuse the same pinned runtime and generated `mermaid.js`
in the editor bundle. The runtime loads on demand, serializes visible diagram
updates, and sanitizes resulting SVG. The editor retains at most 16 diagrams and
4 MiB of cache, discards stale render results, and never shares active SVG IDs.
No new package dependency is introduced by inline rendering or table controls.

Workspace theme colors are supplied by `EditorThemePalette.colors` through the
native coordinator. CSS variables style the editor, syntax roles and tables;
Mermaid's base theme receives the same colors. Diagram cache keys include the
resolved palette, so appearance changes never reuse SVGs with old theme colors.

Typing and pointer performance work (2026-10-27) indexes exact-byte coordinates
at roughly 1,024 UTF-16 intervals and updates presentation/link decorations in
changed Markdown blocks. Selection changes affect only previous/current blocks;
dragging maps existing decorations until 50 ms after release. Native configuration
messages contain only changed values. Widgets resolve current mapped positions
when activated. This is Duckpad code informed by static architectural inspection
of installed Obsidian 1.8.9; no proprietary source is incorporated.

In 0.16.0 the separate native preview panel and its renderer/loader/WebView were
removed. Presentation keeps only `clipboard.js` and notices; the editor owns its
Mermaid bundle and KaTeX CSS/fonts. Math uses the existing pinned KaTeX package,
`trust:false`, `maxExpand:1000`, and `maxSize:20`. Live syntax nodes keep math
out of code/escaped-dollar syntax and reveal source through the usual selection
path. Literal U+FEFF and CR/LF split/join edits preserve the byte/document mirror;
randomized tests assert the actual CodeMirror transaction state on every edit.
