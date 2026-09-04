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
are not compiled. Duckpad carries two narrow Cocoa integration patches:

1. The two Xcode-generated TIFF cursor lookups in `cocoa/ScintillaView.mm` use
   Duckpad's configured SwiftPM resource directory and the official PNG names.
2. `ScintillaView.h` and `ScintillaView.mm` notify the existing delegate whether
   an insertion came from direct input, tentative composition, or an IME commit.
   This preserves Scintilla's insertion and composition behavior while allowing
   the Duckpad-owned bridge to keep smart editing out of IME transactions.

The four packaged cursor PNGs are byte-identical copies from `cocoa/res`.
