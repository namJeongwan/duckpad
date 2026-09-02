#!/bin/sh
set -eu

VERSION="5.5.3"
ARCHIVE="lexilla553.tgz"
URL="https://www.scintilla.org/${ARCHIVE}"
SHA256="4d9e64263c337034a06f9c67f330c605764cac02aee83c06f6c21f9527a71628"

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
target="$repo_root/Vendor/Lexilla/$VERSION"

case "$target" in
  "$repo_root"/Vendor/Lexilla/*) ;;
  *) echo "unsafe target: $target" >&2; exit 2 ;;
esac

if [ -e "$target" ]; then
  echo "target already exists: $target" >&2
  exit 3
fi

temporary=$(mktemp -d "${TMPDIR:-/tmp}/duckpad-lexilla.XXXXXX")
cleanup() { rm -rf -- "$temporary"; }
trap cleanup EXIT HUP INT TERM

curl --fail --location --proto '=https' --tlsv1.2 "$URL" -o "$temporary/$ARCHIVE"
actual=$(shasum -a 256 "$temporary/$ARCHIVE" | awk '{print $1}')
if [ "$actual" != "$SHA256" ]; then
  echo "checksum mismatch: expected $SHA256, got $actual" >&2
  exit 4
fi

tar -xzf "$temporary/$ARCHIVE" -C "$temporary"
test "$(cat "$temporary/lexilla/version.txt")" = "553"

mkdir -p "$target"
cp "$temporary/lexilla/License.txt" "$target/License.txt"
cp "$temporary/lexilla/version.txt" "$target/version.txt"
cp -R "$temporary/lexilla/include" "$target/include"
cp -R "$temporary/lexilla/lexlib" "$target/lexlib"
cp -R "$temporary/lexilla/lexers" "$target/lexers"
mkdir -p "$target/src"
cp "$temporary/lexilla/src/Lexilla.cxx" "$target/src/Lexilla.cxx"

# Lexilla consumes Scintilla's stable lexer interface headers. Keep the build
# target self-contained by copying only the official headers from Duckpad's
# already-pinned standalone Scintilla 5.6.6 source tree.
mkdir -p "$target/scintilla/include"
for header in ILexer.h Sci_Position.h Scintilla.h ScintillaTypes.h; do
  cp "$repo_root/Vendor/Scintilla/5.6.6/include/$header" "$target/scintilla/include/$header"
done

cat > "$target/PROVENANCE.md" <<EOF
# Lexilla provenance

- Upstream: official standalone Lexilla ${VERSION}
- Source: ${URL}
- Archive SHA-256: \`${SHA256}\`
- Upstream version marker: \`553\`
- License: \`License.txt\` (Neil Hodgson permissive license)
- Compatibility: the official SciTE 5.6.6 release pairs Lexilla 5.5.3 with
  Scintilla 5.6.6. Lexilla's upstream build contract requires Scintilla 5+
  interface headers and C++17.
- Included subset: \`include/\`, \`lexlib/\`, \`lexers/\`,
  \`src/Lexilla.cxx\`, license, version marker, and the four lexer-interface
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
EOF

echo "vendored Lexilla $VERSION at $target"
