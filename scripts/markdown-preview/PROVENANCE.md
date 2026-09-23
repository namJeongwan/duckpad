# Bundled Markdown preview engines

The app bundles the generated assets under
`Sources/DuckpadPresentation/Resources/MarkdownPreview/`. They are generated from
`parser.mjs` and `preview.mjs` by `build.mjs`; do not hand-edit generated JavaScript.
The app requires neither Node nor a CDN at runtime.

`clipboard.mjs` also builds `clipboard.js` from the same pinned markdown-it
dependency for synchronous JavaScriptCore clipboard export. It renders headings,
lists, tables and inline formatting with inline styles. Unlike preview, clipboard
export disables raw HTML, allows only HTTP(S)/mailto links, and emits image alt
text instead of resource URLs. No new dependency is introduced.

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

The build copies KaTeX fonts/CSS and highlight.js CSS and collects dependency
license/notice files into the packaged `THIRD_PARTY_NOTICES.txt`. Source HTML is
sanitized with DOMPurify; Mermaid uses strict security and KaTeX uses `trust:false`.
Swift additionally restricts WebKit resource loading with CSP and a custom scheme.

The generated bundle targets Safari 16 for macOS 13.0. `compatibility.mjs` supplies
`URL.canParse` on older WebKit; JavaScript class static blocks are lowered by esbuild.
