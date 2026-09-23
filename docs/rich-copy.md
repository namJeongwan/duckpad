# Clipboard formats

Ordinary Copy now preserves Scintilla's plain text and adds HTML and RTF for a
single continuous selection. Receiving applications choose a supported format.
Settings → Editing → **Include formatting when copying** is enabled by default;
disabling it restores plain-text-only copy. Existing settings files receive the
enabled default without a schema migration.

Edit → **Copy as Plain Text** overrides the setting for one copy. Edit → **Copy
as Image** renders the selected source text into PNG, on a white background with
12-point padding and a 2× raster scale. These commands are also searchable in
the command palette. Image copy deliberately publishes PNG alone so a receiver
does not choose text instead. Ordinary copy does not allocate an image.

For documents whose editor language is Markdown (including automatic `.md` and
`.markdown` detection), ordinary Copy renders the selected fragment as HTML:
headings, nested lists, tables, emphasis, links and code blocks. Plain text remains
the exact Markdown source. Copy as Plain Text bypasses rendering. Markdown HTML
uses a compact 11-point body with inline styles that survive rich-editor paste;
source-form RTF is omitted to avoid conflicting representations. Rendering is
bounded to 256 KiB and falls back to plain text on failure or larger selections.
Raw HTML is escaped, links allow only HTTP(S)/mailto, and image references become
alt text without loading files/network resources. Math and Mermaid fences are
exported as source rather than rendered diagrams. Partial selections are parsed
as standalone fragments, so select complete blocks to preserve their structure.

Other languages retain source formatting. HTML escapes markup characters,
preserves whitespace in a `pre` element, and includes tab width, font and existing
syntax styles. Code HTML uses CSS pixels for Cocoa screen-point sizes, includes
editor zoom and line height, and sets the base font on `pre` as well as token
spans. This avoids CSS point conversion enlarging text by 96/72 at browser zoom
100%. Receivers may still override fonts/styles or apply their own zoom.
Export uses Duckpad's light syntax colors regardless of editor
appearance. RTF preserves styled text for native document applications. The
original plain text, including its line endings, is unchanged.

## Bounds and compatibility

- Rich copy: at most 1 MiB of selected UTF-8 and 4,096 style runs; oversized or
  unsupported selections retain native plain-text copy.
- Image copy: at most 64 KiB of selected UTF-8, 4,096 pixels on either axis and
  8 million pixels total. Invalid/oversized input is rejected before changing
  the clipboard. Select a smaller continuous section when rejected.
- Rectangular, multiple and virtual-space selections retain native copy and
  its existing selection metadata. Image export requires a continuous selection.
- Read only the selection and existing Scintilla style bytes; do not snapshot,
  re-lex or render the whole document. Unstyled regions use ordinary text styling.
- Native keyboard/menu/context-menu copy use the same post-copy hook. Cut,
  drag-and-drop and paste retain their existing behavior.
- KCUBE ON's outer portal HTML does not expose the editor's paste handler.
  HTML availability may affect its paste dialog, but the dialog and any
  HTML-to-image conversion belong to the receiving editor. Live KCUBE ON
  behavior must be verified separately.

## Reference behavior

- [VS Code](https://code.visualstudio.com/updates/v1_10#_copy-with-syntax-highlighting)
  documents adding HTML alongside text, with a size limit for automatic rich copy.
- [JetBrains Rider](https://www.jetbrains.com/help/rider/Cutting_Copying_and_Pasting.html)
  documents default rich copy and a plain-text override;
  [its settings](https://www.jetbrains.com/help/rider/Settings_Editor_General.html)
  provide a separate copy color scheme.
- [iTerm2](https://iterm2.com/documentation-menu-items.html) provides Copy With
  Styles as a separate command including fonts and colors.
- The local Notepad++ reference routes ordinary Copy in
  `notepad-plus-plus/PowerEditor/src/NppCommands.cpp` (`IDM_EDIT_COPY`, line 517).
  Its installer describes the bundled **NppExport plugin** as the HTML/RTF
  exporter in `PowerEditor/installer/nppSetup.nsi`, line 420. This is a plugin,
  not ordinary core Copy.

These references motivate text/HTML/RTF copy. Duckpad's explicit PNG export is a
separate feature; no claim is made that these editors automatically generate an
image for ordinary Copy. OrbStack's exact clipboard representations were not
established from public documentation.

## Validation (2026-09-23)

- `swift test --filter 'RichClipboardTests|LocalizationTests|SettingsLanguageRefreshTests|CommandPalettePresentationTests|AppSettingsUseCaseTests|LocalAppSettingsStoreTests'`: 36 tests passed (only suites matching existing test names run).
- `swift build --product DuckpadApp`: passed, local native debug build.
- `scripts/verify_localizations.py`: all 8 language catalogs and argument checks passed.
- Native copy tests cover HTML/RTF availability, unchanged CRLF/plain text,
  Korean/emoji and markup escaping, Undo/revision preservation, settings,
  oversized/multiple-selection fallback and bounded reads in a large document.
- PNG output was visually inspected for orientation, Korean/emoji, whitespace
  and padding. Bounds rejection retains the previous clipboard data.
- A standalone local export sample measured approximately 4 ms for 40 bytes,
  3 ms for 64 KiB and 31 ms for 1 MiB of uniform text. This measures HTML/RTF
  serialization and pasteboard writes, not end-to-end browser paste or a
  worst-case syntax-token workload.
- Built a native arm64 release app bundle at `build/rich-copy/Duckpad.app`;
  `scripts/verify_macos_app.sh` passed. Version remains 0.7.2 (46), ad-hoc signed.
- Launched the packaged app with isolated settings/recovery and a CRLF fixture.
  The actual Copy menu publishes unchanged plain text plus HTML and RTF;
  Copy as Plain Text publishes no rich formats; Copy as Image publishes PNG.
- Pasted through native menus into a separate WKWebView receiver. Contenteditable
  received HTML with indentation, Korean/emoji and escaped markup; textarea
  preserved the text after browser newline normalization. Plain-only paste
  carried the exact text payload (WebKit may use NBSP/paragraphs in its DOM).
  PNG paste inserted an actual image, and its orientation/padding were inspected.
- Live KCUBE ON paste-dialog behavior and native RTF application paste remain
  unverified. All 8 catalogs were checked, but packaged UI was tested in Korean
  only. Synthetic Command-C did not update the clipboard in the packaged UI
  session, so physical keyboard copy still needs verification; menu copy passed.
  No release publication or Applications-folder installation was performed.

### Markdown follow-up

- `swift test --filter 'MarkdownClipboardTests|RichClipboardTests'`: 12 tests
  passed, covering structured rendering, unsafe HTML/links/images, CRLF,
  source preservation, plain-copy override and failure fallback.
- Rebuilt the native arm64 bundle at `build/markdown-copy/Duckpad.app` and passed
  `scripts/verify_macos_app.sh`; version remains 0.7.2 (46).
- Actual packaged `.md` Copy → WKWebView contenteditable retained `h2`/`h3`,
  nested lists, a table and inline emphasis. The original Markdown was preserved
  when pasted into textarea, and Copy as Plain Text omitted all rich formats.
- Live KCUBE ON behavior remains unverified. Copy as Image still renders the
  selected source text; Markdown rendering applies to ordinary rich Copy.

### Code typography follow-up

- Reproduced before fixing: 13-point native code exported as CSS `13pt` computed
  to `17.333334px` in WKWebView; selected presentation also ignored editor zoom.
- After the fix, all 14 rich/Markdown clipboard tests passed. The added WebKit
  test checks 13px, the Menlo family, exact line height and rendered text width
  within one pixel of AppKit. Zoomed/fractional sizes and the one-point minimum
  are covered separately.
- Built and verified `build/copy-typography/Duckpad.app` (native arm64, 0.7.2/46).
  Actual Python-file Copy → WKWebView contenteditable computed to Menlo 13px
  with explicit line height; clipboard plain text remained byte-for-byte intact.
  KCUBE ON's own font filtering and zoom still require site-specific verification.

### Pre-PR review correction

- Independent review found that `Editor::Cut` dispatches virtual `Copy`.
  Native-cut tests reproduced unintended rich clipboard output for plain and
  Markdown documents. `ScintillaCocoa::Cut` now suppresses the enrichment
  callback through all cut entry points, with scoped restoration afterward.
- Regression coverage checks exact plain text, absence of HTML/RTF and Markdown
  rendering, selected-text deletion and Undo restoration.
- Final focused clipboard, Markdown, localization and settings verification:
  43 tests in 4 suites passed, including both native-cut regression cases.
