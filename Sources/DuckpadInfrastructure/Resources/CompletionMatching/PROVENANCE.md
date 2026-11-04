# CodeMirror completion matching

- Upstream: https://code.haverbeke.berlin/codemirror/autocomplete
- Package: `@codemirror/autocomplete` 6.20.4, pinned in the Markdown package lock.
- License: MIT, retained verbatim in `LICENSE`.

`matcher.js` bundles the unchanged FuzzyMatcher class from the pinned package,
plus its CodeMirror state Unicode helpers and a small top-result adapter. It runs
in JavaScriptCore on an isolated Swift actor; it does not create a web editor or
send document text to a network service. Regenerate with `npm ci --prefix
scripts/markdown-preview --ignore-scripts` and `node
scripts/markdown-preview/build-completion-matcher.mjs`. Do not edit the generated
JavaScript directly.

The generator removes trailing whitespace from the bundle for Git checks.
