# Scintilla 5.6.6 provenance

- Upstream: https://www.scintilla.org/scintilla566.tgz
- Version: `5.6.6` (`version.txt`: `566`)
- Archive SHA-256: `b6b08598c68fac90990d010c1142494d707530602b5320753274d045c2b02189`
- Acquired: 2026-09-02
- License: upstream `License.txt`, preserved byte-for-byte

The separately established Notepad++ reference pin reports Scintilla version
`566`, matching this official standalone archive; no file was copied from that
reference tree.

This directory was produced only from the official standalone archive. The
Notepad++ reference checkout is not a source or build input. The vendored
subset contains the public Scintilla headers, private editor-core headers, the
core translation units selected by the upstream Cocoa Xcode target, the Cocoa
backend, and its six PNG resources. `bridge/` is Duckpad-owned code and is not
part of the upstream archive.

Reproduce the acquisition outside the repository:

```sh
tmp_dir="$(mktemp -d /tmp/duckpad-scintilla.XXXXXX)"
curl --fail --location --silent --show-error \
  https://www.scintilla.org/scintilla566.tgz \
  -o "$tmp_dir/scintilla566.tgz"
printf '%s  %s\n' \
  b6b08598c68fac90990d010c1142494d707530602b5320753274d045c2b02189 \
  "$tmp_dir/scintilla566.tgz" | shasum -a 256 -c -
tar -xzf "$tmp_dir/scintilla566.tgz" -C "$tmp_dir"
```

The allowlist is normative in `Package.swift`; files not named by that target
are not compiled. Duckpad carries six narrow integration and behavior patches:

1. The two Xcode-generated TIFF cursor lookups in `cocoa/ScintillaView.mm` use
   Duckpad's configured SwiftPM resource directory and the official PNG names.
2. `ScintillaView.h` and `ScintillaView.mm` notify the existing delegate whether
   an insertion came from direct input, tentative composition, or an IME commit.
   The same synchronous preflight/finish callbacks narrowly bracket an
   unmodified or Shift-modified Return handled directly by Scintilla before
   AppKit text interpretation. Command paths such as paste remain outside the
   direct-input signal. This preserves Scintilla's insertion and composition
   behavior while allowing the Duckpad-owned bridge to keep smart editing out
   of paste and IME transactions. An optional synchronous direct-selection
   delegate can consume one opener before native typing deletes a selection;
   composition commits and explicit replacement ranges bypass it. The bridge
   surrounds stream selections by inserting only their two boundary bytes,
   groups the insertions into one native undo action, and preserves selection
   direction and multiple ranges. Empty-caret-only input remains unchanged.
3. `cocoa/ScintillaCocoa.mm` resolves dynamic system colors within the content
   view's effective appearance using `performAsCurrentDrawingAppearance:`. This
   replaces the macOS 12-deprecated global current-appearance mutation while
   preserving the appearance used for color resolution.
4. `cocoa/PlatCocoa.mm` gives the completion table `NSTableViewStylePlain`
   directly. Duckpad's macOS 13 minimum deployment target makes this the
   supported replacement for the macOS 12-deprecated source-list selection
   highlight style.

5. `cocoa/ScintillaView.mm` ignores explicit replacement input whose text is
   identical to the existing range, while moving the caret to the range end.
   This prevents reconfirmed text from adding delete/insert pairs to native
   undo history. Active IME composition follows the original commit path.

6. `src/UndoHistory.h` and `src/UndoHistory.cxx` split otherwise coalescible
   typing and deletion after at least 1 second without an edit, using a monotonic
   clock per document. The former 300 ms boundary split ordinary paced typing
   into individual characters. Explicit undo groups and tentative IME composition are
   not split by elapsed time. Container actions do not restart the clock.

The four packaged cursor PNGs are byte-identical copies from `cocoa/res`.

Fold-state capture, restore, commands, and recovery-progress callbacks are
implemented only in Duckpad-owned `bridge/` code. Apart from the six patches
listed above, no byte from the official Scintilla 5.6.6 archive was modified
for that façade.

Phase 32 block-comment selection validation, aggregate edit publication,
shared-document publisher routing, and direct-closing-delimiter indentation
likewise modify only Duckpad-owned files under `bridge/`; no additional
upstream Scintilla or Lexilla source file changed.

Editor-group rejection recovery uses a Duckpad-owned, publisher-only
pre-mutation callback in `bridge/`. The callback is driven by Scintilla's public
`SC_MOD_BEFOREINSERT` and `SC_MOD_BEFOREDELETE` notifications. Its publisher
event mask is installed during bridge-view construction and reused for later
mask reconfiguration. This adds no upstream Scintilla or Lexilla changes beyond
the patches listed above.

External file reloads use an undo-preserving load option in Duckpad-owned
`bridge/DuckpadScintillaBridge.mm` and its public header. Changed contents form
one native undo group; identical contents retain the existing undo/redo stack.
Initial loads and recovery still clear history. No upstream files or generated
files are changed by this option.
Full binary display adds the Duckpad-owned `bridge/DPScintillaBinaryDocument`
wrapper and attachment methods in `bridge/`. The wrapper constructs a standalone
Scintilla `Document` with the same loading sequence as `SCI_CREATELOADER`, on a
background queue, using `StylesNone | TextLarge`, disabled undo collection, and
single-byte code page. No UTF-8 conversion or full-file validation is performed.
Prepared documents are attached on the main thread, which also owns subsequent
reference-count changes. Text reload creates a regular document
to restore style storage. No additional upstream source changes are made.
The bridge also measures the line-number margin using the actual line-count
digit width (at least five digits), refreshing it on document attachment,
text reload, font or zoom changes, and display configuration so multi-million
line binary files retain fully visible line numbers.

Incremental binary opening additionally prepares capacity and the first 64 KiB
off the main thread, then appends bounded raw-byte chunks to the attached
document on the main thread. The wrapper retains immutable source data only
until loading completes or is cancelled. Appends restore read-only state before returning and
do not publish editor edits or advance revisions in any shared pane. Each pane
updates its line-number margin and selection cache from the native insertion
notification; status publication occurs after read-only state is restored.
Native selection serialization preserves multi-selections (including the loaded
end of file), virtual space, and viewport positions through each chunk append.
Binary views use Scintilla's viewport-sized line-layout cache so incremental
repaints reuse measured glyph positions. Selection and viewport restoration
only sends setters when values changed, avoiding unconditional redraws per
chunk. Regular text reload restores the default uncached layout policy.

Search highlighting uses reserved indicator 8 in the Duckpad-owned bridge/header.
It validates revision and UTF-8 ranges, applies palette-aware green decorations
without changing selections or text, and clears decorations on native edits.
The vendor import script leaves `bridge/` untouched; these are not generated
files. No upstream Scintilla/Lexilla source is changed.

Programmatic batch replacements in the Duckpad-owned bridge defer explicit lexer
and fold styling until all descending edits have been applied, then refresh the
affected suffix once. This prevents format-document and replace-all commands
from repeatedly lexing long JSON lines for every small edit. Native edits,
revision increments, selection adjustment, and the single Undo group remain
unchanged. Existing synchronous styling instrumentation also counts replacement
styling for a deterministic work-bound regression. The bridge is not generated;
no upstream Scintilla/Lexilla source changes are involved.

Native Undo/Redo edit payloads now expose whether more text edits follow in the
same synchronous action, derived from Scintilla's MULTISTEPUNDOREDO and
LASTSTEPINUNDOREDO notification flags. Duckpad advances every revision and
records every recovery delta, while the workspace publishes UI updates and
schedules persistence only for the final edit. This prevents thousands of
transient AppKit updates and cancelled tasks from accumulating in one Undo
event. This is a Duckpad-owned bridge/header change, not an upstream patch.

- Markdown presentation: explicitly map legacy Lexilla Markdown style IDs to the
  existing theme palette because its lexer exposes no named-style metadata.
  Apply heading/strong/emphasis/link/code appearance and clear it with the normal
  style reset when switching languages or themes.
Clipboard dock: the Duckpad-owned bridge exposes a read-only serialized selection identity for deferred paste validation. It includes all carets, virtual spaces, and selection shape without reading document text. Upstream Scintilla sources and generated files are unchanged.

Search overview markers add a Duckpad-owned overlay in `bridge/`.
Validated search results are mapped to native display lines, shared across cloned
panes, and cleared with the existing search indicators. The overlay coalesces
marks by screen row; tick clicks reveal the matching line, while empty track
passes through to the native scrollbar. The bridge and
new helper are not generated; upstream Scintilla/Lexilla sources are unchanged.

Change history enables Scintilla's native marker tracking in a dedicated 3-point
margin with palette-aware modified/saved/reverted colours. Initial loads reset
the baseline; successful matching-revision saves set the native save point
without clearing undo. Binary viewers keep this feature disabled. No upstream
sources or generated files are modified.

Search overview ticks use source-over alpha blending with merged pixel coverage,
so densely overlapping hits remain translucent above the native scrollbar thumb.

Search overview mapping retains exact match byte offsets, including separate
wrapped sublines within one document line. Native scroll-document height supplies
the scale; clicking unfolds and centers the actual match. During idle wrapping,
positions remain inside each line's current display span. Wrapped text panes with
no persistent layout cache temporarily reuse a single-line cache for the mapping
pass and restore the previous setting afterward.

### Configurable editor spacing

- The Duckpad-owned bridge exposes left/right text padding and total extra line
  spacing, using Scintilla's margin and extra ascent/descent APIs. Values are in
  Cocoa points, bounded to 0–32 for padding and 0–20 for extra line spacing.
- The default left padding changes from 8 to 0, placing the first text column
  next to the change-history margin. This matches the local Notepad++ reference
  (`PowerEditor/src/Parameters.h`, `ScintillaViewParams::_paddingLeft = 0`).
  Right padding stays 8 and extra line spacing stays 4 (2 above + 2 below).
- Palette/lexer changes no longer reset these view settings. Document bytes,
  font character spacing, and Undo/Redo are unaffected. The bridge is not
  generated; upstream Scintilla/Lexilla sources are unchanged.

### Plain-text indentation and IME Return

- The Duckpad bridge preserves leading spaces/tabs on direct newline input when
  the requested lexer is `null`. Code-specific pairing/dedenting stays disabled;
  pasted/bulk input, selections, binary documents and unsupported code lexers
  do not acquire plain-text indentation rules. This includes the change from
  Duckpad commit `861e102` (PR #42) in the combined local test build.
- `cocoa/ScintillaView.mm` implements Cocoa's `insertNewline:` command. After an
  IME composition commit, `interpretKeyEvents:` can dispatch this command on
  the same Return that skipped Scintilla's normal keyboard path. Previously it
  was not handled, requiring another Return. The command now uses SCI_NEWLINE
  with an explicit direct-newline source in `ScintillaView.h`, so EOL mode and
  indentation do not depend on NSApp.currentEvent. The newline and its indent
  form one Undo action, separate from the committed composition.
  No extra newline is injected for input methods that only confirm a candidate.
- ScintillaView.mm and ScintillaView.h are locally patched upstream sources; retain these patches when
  re-vendoring Scintilla (the import script copies upstream Cocoa sources).

### Change-history colour and growing line numbers

- Modified/reverted-to-modified margin markers now use blue (`#247ED5` in light
  mode, `#64B5F4` in dark mode), encoded in Scintilla's BGR colour format. Saved
  and reverted-to-origin marker colours retain their existing meanings.
- The bridge updates line-number widths for all panes sharing a text document
  after insertions/deletions that change the line count, including Undo/Redo
  and recovery. Each pane retains its line-number visibility, font and zoom.
  Unchanged widths do not trigger an unnecessary margin layout update.

Large-file initial text loading temporarily disables undo collection while
replacing the document, then restores its previous setting. Initial loads
already discard undo history; this avoids retaining a document-sized insertion
record only to discard it immediately. Reloads that preserve undo keep their
existing grouped replacement. This changes only Duckpad-owned
`bridge/DuckpadScintillaBridge.mm`, which is not generated by the vendor script;
upstream Scintilla sources and generated files are unchanged.

The same initial-load path reserves 64 KiB of editing headroom before its bulk
insertion. Scintilla otherwise starts with an eight-byte gap; typing a few more
bytes would reallocate and copy the entire text and style buffers. Reservation
uses the existing SCI_ALLOCATE API with an overflow guard and does not alter
text, encoding, selection, or undo behavior.
