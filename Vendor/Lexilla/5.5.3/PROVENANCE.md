# Lexilla provenance

- Upstream: official standalone Lexilla 5.5.3
- Source: https://www.scintilla.org/lexilla553.tgz
- Archive SHA-256: `4d9e64263c337034a06f9c67f330c605764cac02aee83c06f6c21f9527a71628`
- Upstream version marker: `553`
- License: `License.txt` (Neil Hodgson permissive license)
- Compatibility: the official SciTE 5.6.6 release pairs Lexilla 5.5.3 with
  Scintilla 5.6.6. Lexilla's upstream build contract requires Scintilla 5+
  interface headers and C++17.
- Included subset: `include/`, `lexlib/`, `lexers/`,
  `src/Lexilla.cxx`, license, version marker, and the four lexer-interface
  headers copied from Duckpad's independently pinned official Scintilla 5.6.6.
- Excluded: examples, binaries, documentation images, tests, generated IDE
  projects, and platform packaging.
- Byte preservation: the official archive contains historical trailing/indent
  whitespace. The repository's path-scoped .gitattributes suppresses only
  blank-at-eol, blank-at-eof, and space-before-tab diagnostics for this
  exact versioned subtree. It defines no clean/smudge or EOL conversion, and
  this script does not read or depend on Git attributes.

Regenerate from the repository root with:

    scripts/vendor_lexilla_5_5_3.sh

## Duckpad long-line JSON patch

`lexers/LexJSON.cxx` and the Duckpad-owned `lexers/JSONLongLineCache.h` reuse
verified unchanged lexical regions when styling a complete single-line JSON
between 64 KiB and 32 MiB. The cache compares actual bytes in 4 KiB blocks;
there are no probabilistic hash matches. Restart points precede the lexer's
property-name lookahead and use existing structural-operator styles. Reuse
requires convergence at a matching operator or the single-line error state.
Error styling can cover the remaining physical line as one run; folding excludes
that proven non-operator tail from its scan. Changed brace
contributions update a cached folding index without rescanning the entire file.

One known error-free text/style/fold result is retained so temporary invalid
input and its deletion/Undo do not require a full re-lex. Property/keyword changes,
partial styling, and multi-line documents invalidate the cache. The 32 MiB input
limit restricts cache eligibility; retained text, styles, and brace indexes use
additional memory proportional to document size. This never disables styling,
wrapping, or editing. Noneligible
requests use the upstream lexer path. These changes preserve the existing JSON
and JSON-LD styles and fold semantics, including existing error recovery.

These files are maintained by hand. `scripts/vendor_lexilla_5_5_3.sh` imports the
original upstream files and overwrites this provenance file; it does not reapply
local patches. Preserve/reapply this patch after running that acquisition script.
`LongLineEditingTests.swift` compares incremental results with a fresh lexer
across Unicode, escapes, malformed input, structural edits, line splitting, and
Undo. The opt-in `DuckpadPerformanceBenchmark --long-line <fixture.json>` reports
p50, p95, maximum latency, and exact Undo/Redo under a 50 ms maximum budget,
including the first input and deferred Cocoa layer drawing.
