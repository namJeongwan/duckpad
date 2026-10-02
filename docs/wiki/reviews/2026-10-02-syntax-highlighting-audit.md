# Syntax highlighting audit — 2026-10-02

All **78 registered languages / 64 Lexilla lexers** were exercised through the
native `DPScintillaEditorView` with the bundled language configuration, UTF-8
fixtures, and light, dark, high-contrast light and high-contrast dark palettes.
Plain Text and CSV intentionally use the null lexer and retain a single text
colour. The other 76 language fixtures have visible syntax colours in all four
palettes. This verifies lexical presentation; it is not a claim of complete
language grammar or semantic analysis.

## Findings and changes

- 43 non-null lexers publish no `ILexer5` named-style metadata. Markdown already
  had an explicit fallback. The other **42 lexers / 43 language entries** had no
  semantic colour map, even though native token styles were generated. A shared
  fallback now maps their pinned `SCE_*` constants to the existing palette.
- JSON keys, strings, numbers and literals now have distinct colours. JSON and
  YAML require configured literal word lists; missing lists were corrected.
- PHP's word list belongs at index 4, not index 0. Objective-C directives include
  their `@` prefix in native tokenization. Both configurations were corrected.
- CSS requires property and pseudo-selector word lists. These were populated
  using the local Notepad++ reference vocabulary (`PowerEditor/src/langs.model.xml`,
  CSS `instre1`, `instre2`, `type3`) at LexCSS's native indices 0, 1 and 4.
- Named styles for properties, attributes and tags now have their own colour.
  Error metadata takes precedence over ordinary string/comment/keyword metadata.
  HTML's built-in tag recognition was already working with an empty word list.

## Verification

- Before the fix, the native regression run failed with 183 issues: 43 fixtures
  lacked colours across four palettes, five keyword samples were misclassified,
  and JSON's literal classification and distinct-colour checks failed.
- After the fix, the new regression tests pass: all 78 fixtures across
  four palettes, reserved-token classification and visible colour for each of
  the 20 declared `keywordComplete` languages, and JSON's distinct token colours
  plus reset to plain text. Content bytes and Undo state remain unchanged.
  Independent review additionally identified Smalltalk binary selectors and
  Oracle SQL q-strings: these now use operator and string colours respectively,
  with a native regression check that failed in all four palettes before correction.
- Related native editor and manifest checks: **95 tests passed**, including
  palette/lexer changes, styling-budget fallbacks, shared documents, smart
  editing, selection and Undo/Redo checks. Command:

  ```sh
  DUCKPAD_HIGHLIGHTING_SNAPSHOTS=/tmp/duckpad-highlighting-snapshots \
  swift test --no-parallel --filter 'LanguageHighlightingTests|LanguageEditorAdapterTests|LanguageManifest|bundledLanguageRegistry|detector|unknownPersistedManualLanguage|registryRejectsDuplicate'
  ```

- The optional capture flag writes 312 native editor PNGs and runtime audit rows
  to the test log. Light/dark contact sheets for all 78 fixtures and individual
  JSON/Raku captures were visually inspected. The table below records the number
  of distinct emitted token foregrounds different from default text, in palette order light / dark /
  high-contrast light / high-contrast dark. Zero is expected only for the null
  lexer. Native captures are diagnostic output, not repository assets.
- No upstream lexer engine, generated API, dependency, UI string or translation
  resource changed. Vendor changes are recorded in `Vendor/Scintilla/5.6.6/PROVENANCE.md`.

## Limits

The existing support tiers remain unchanged: 20 `keywordComplete`, 57
`structural`, and one `plain` entry. Structural entries have native lexical
colouring without a promise of comprehensive keyword vocabulary. CSV is a
structural registry entry rendered with the null lexer. Several languages reuse
the C++ lexer (including Swift, Go, JavaScript and TypeScript); grammar-specific
features such as all interpolation forms are outside this colour-mapping fix.
Each audit fixture is representative, not an exhaustive grammar corpus. The
full application suite is validated separately during release preparation.
Physical Intel hardware and macOS 13 execution were not checked.

## Changed files

- [Languages.json](../../../Sources/DuckpadInfrastructure/Resources/Languages.json):
  JSON/YAML/CSS vocabulary, PHP keyword index, Objective-C directives.
- [DuckpadScintillaBridge.mm](../../../Vendor/Scintilla/5.6.6/bridge/DuckpadScintillaBridge.mm):
  shared fallback application, property palette role, error priority.
- [DPScintillaLegacyStyleRoles.h](../../../Vendor/Scintilla/5.6.6/bridge/DPScintillaLegacyStyleRoles.h):
  pinned legacy style-to-palette mappings.
- [LanguageHighlightingTests.swift](../../../tests/DuckpadEditorAdapterTests/LanguageHighlightingTests.swift):
  all-language fixtures, palette/keyword/reset checks, optional native captures.
- [PROVENANCE.md](../../../Vendor/Scintilla/5.6.6/PROVENANCE.md):
  downstream bridge patch scope and upgrade requirements.
- This audit records the results and limits for every registered language.

## Every registered language

“Fallback added” means this fix repaired a previously empty colour map.
“Named metadata” uses the existing ILexer5 metadata path; “Markdown fallback”
was already present. Numbers represent native results, not inferred support.

| Language | ID | Lexer | Declared tier | Colour mapping | Non-default colours (L / D / HCL / HCD) |
|---|---|---|---|---|---|
| Plain Text | `text` | `null` | plain | Plain | 0 / 0 / 0 / 0 |
| C | `c` | `cpp` | keywordComplete | Named metadata | 5 / 5 / 5 / 5 |
| C++ | `cpp` | `cpp` | keywordComplete | Named metadata | 5 / 5 / 5 / 5 |
| Objective-C | `objc` | `cpp` | keywordComplete | Named metadata | 5 / 5 / 5 / 5 |
| C# | `csharp` | `cpp` | keywordComplete | Named metadata | 5 / 5 / 5 / 5 |
| Java | `java` | `cpp` | keywordComplete | Named metadata | 5 / 5 / 5 / 5 |
| Kotlin | `kotlin` | `cpp` | keywordComplete | Named metadata | 5 / 5 / 5 / 5 |
| JavaScript | `javascript` | `cpp` | keywordComplete | Named metadata | 5 / 5 / 5 / 5 |
| TypeScript | `typescript` | `cpp` | keywordComplete | Named metadata | 5 / 5 / 5 / 5 |
| CSS | `css` | `css` | keywordComplete | Fallback added | 4 / 4 / 4 / 4 |
| SCSS | `scss` | `css` | structural | Fallback added | 4 / 4 / 4 / 4 |
| HTML | `html` | `hypertext` | keywordComplete | Named metadata | 4 / 4 / 4 / 4 |
| PHP | `php` | `phpscript` | keywordComplete | Named metadata | 5 / 5 / 5 / 5 |
| XML | `xml` | `xml` | structural | Named metadata | 4 / 4 / 4 / 4 |
| Markdown | `markdown` | `markdown` | structural | Markdown fallback | 2 / 2 / 2 / 2 |
| AsciiDoc | `asciidoc` | `asciidoc` | structural | Fallback added | 2 / 2 / 2 / 2 |
| LaTeX | `latex` | `latex` | structural | Fallback added | 2 / 2 / 2 / 2 |
| YAML | `yaml` | `yaml` | keywordComplete | Fallback added | 5 / 5 / 5 / 5 |
| JSON | `json` | `json` | keywordComplete | Fallback added | 5 / 5 / 5 / 5 |
| TOML | `toml` | `toml` | structural | Fallback added | 5 / 5 / 5 / 5 |
| INI / Properties | `ini` | `props` | structural | Fallback added | 3 / 3 / 3 / 3 |
| CSV | `csv` | `null` | structural | Plain | 0 / 0 / 0 / 0 |
| SQL | `sql` | `sql` | keywordComplete | Fallback added | 5 / 5 / 5 / 5 |
| MySQL | `mysql` | `mysql` | structural | Fallback added | 4 / 4 / 4 / 4 |
| Python | `python` | `python` | keywordComplete | Named metadata | 5 / 5 / 5 / 5 |
| Ruby | `ruby` | `ruby` | keywordComplete | Named metadata | 5 / 5 / 5 / 5 |
| Perl | `perl` | `perl` | structural | Named metadata | 4 / 4 / 4 / 4 |
| Lua | `lua` | `lua` | structural | Named metadata | 4 / 4 / 4 / 4 |
| Shell Script | `bash` | `bash` | keywordComplete | Named metadata | 5 / 5 / 5 / 5 |
| PowerShell | `powershell` | `powershell` | structural | Fallback added | 4 / 4 / 4 / 4 |
| Tcl | `tcl` | `tcl` | structural | Fallback added | 3 / 3 / 3 / 3 |
| R | `r` | `r` | structural | Fallback added | 4 / 4 / 4 / 4 |
| Julia | `julia` | `julia` | structural | Named metadata | 4 / 4 / 4 / 4 |
| MATLAB | `matlab` | `matlab` | structural | Fallback added | 4 / 4 / 4 / 4 |
| Octave | `octave` | `octave` | structural | Fallback added | 4 / 4 / 4 / 4 |
| Fortran | `fortran` | `fortran` | structural | Fallback added | 4 / 4 / 4 / 4 |
| Fortran 77 | `fortran77` | `f77` | structural | Fallback added | 4 / 4 / 4 / 4 |
| Rust | `rust` | `rust` | keywordComplete | Named metadata | 5 / 5 / 5 / 5 |
| Swift | `swift` | `cpp` | keywordComplete | Named metadata | 5 / 5 / 5 / 5 |
| Go | `go` | `cpp` | keywordComplete | Named metadata | 5 / 5 / 5 / 5 |
| Zig | `zig` | `zig` | structural | Named metadata | 4 / 4 / 4 / 4 |
| D | `d` | `d` | structural | Fallback added | 4 / 4 / 4 / 4 |
| Assembly | `asm` | `asm` | structural | Named metadata | 4 / 4 / 4 / 4 |
| CMake | `cmake` | `cmake` | structural | Fallback added | 3 / 3 / 3 / 3 |
| Makefile | `make` | `makefile` | structural | Named metadata | 2 / 2 / 2 / 2 |
| Dockerfile | `dockerfile` | `bash` | structural | Named metadata | 2 / 2 / 2 / 2 |
| Diff / Patch | `diff` | `diff` | structural | Fallback added | 4 / 4 / 4 / 4 |
| Git Commit Message | `gitcommit` | `conf` | structural | Fallback added | 1 / 1 / 1 / 1 |
| CoffeeScript | `coffee` | `coffeescript` | structural | Fallback added | 4 / 4 / 4 / 4 |
| Dart | `dart` | `dart` | structural | Named metadata | 4 / 4 / 4 / 4 |
| F# | `fsharp` | `fsharp` | structural | Fallback added | 4 / 4 / 4 / 4 |
| OCaml | `ocaml` | `caml` | structural | Fallback added | 4 / 4 / 4 / 4 |
| Haskell | `haskell` | `haskell` | structural | Fallback added | 4 / 4 / 4 / 4 |
| Lisp | `lisp` | `lisp` | structural | Fallback added | 4 / 4 / 4 / 4 |
| Erlang | `erlang` | `erlang` | structural | Fallback added | 5 / 5 / 5 / 5 |
| Ada | `ada` | `ada` | structural | Fallback added | 4 / 4 / 4 / 4 |
| Pascal | `pascal` | `pascal` | structural | Named metadata | 4 / 4 / 4 / 4 |
| Visual Basic | `vb` | `vb` | structural | Named metadata | 4 / 4 / 4 / 4 |
| COBOL | `cobol` | `COBOL` | structural | Fallback added | 4 / 4 / 4 / 4 |
| Nim | `nim` | `nim` | structural | Named metadata | 4 / 4 / 4 / 4 |
| Nix | `nix` | `nix` | structural | Named metadata | 4 / 4 / 4 / 4 |
| Windows Batch | `batch` | `batch` | structural | Named metadata | 1 / 1 / 1 / 1 |
| AutoIt | `autoit` | `au3` | structural | Fallback added | 4 / 4 / 4 / 4 |
| Inno Setup | `inno` | `inno` | structural | Fallback added | 1 / 1 / 1 / 1 |
| NSIS | `nsis` | `nsis` | structural | Fallback added | 2 / 2 / 2 / 2 |
| Verilog | `verilog` | `verilog` | structural | Fallback added | 4 / 4 / 4 / 4 |
| VHDL | `vhdl` | `vhdl` | structural | Fallback added | 4 / 4 / 4 / 4 |
| GraphQL | `graphql` | `cpp` | structural | Named metadata | 3 / 3 / 3 / 3 |
| Protocol Buffers | `protobuf` | `cpp` | structural | Named metadata | 4 / 4 / 4 / 4 |
| Gettext PO | `po` | `po` | structural | Fallback added | 3 / 3 / 3 / 3 |
| Windows Registry | `registry` | `registry` | structural | Fallback added | 4 / 4 / 4 / 4 |
| Rebol | `rebol` | `rebol` | structural | Fallback added | 3 / 3 / 3 / 3 |
| Smalltalk | `smalltalk` | `smalltalk` | structural | Fallback added | 4 / 4 / 4 / 4 |
| Stata | `stata` | `stata` | structural | Fallback added | 4 / 4 / 4 / 4 |
| SAS | `sas` | `sas` | structural | Fallback added | 4 / 4 / 4 / 4 |
| Raku | `raku` | `raku` | structural | Fallback added | 4 / 4 / 4 / 4 |
| Forth | `forth` | `forth` | structural | Fallback added | 3 / 3 / 3 / 3 |
| TADS 3 | `tads3` | `tads3` | structural | Fallback added | 4 / 4 / 4 / 4 |
