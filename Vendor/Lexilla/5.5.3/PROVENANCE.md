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
