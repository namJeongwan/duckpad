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
   of paste, IME, selection, and multi-caret transactions.
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
   typing and deletion after at least 300 ms without an edit, using a monotonic
   clock per document. Explicit undo groups and tentative IME composition are
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
