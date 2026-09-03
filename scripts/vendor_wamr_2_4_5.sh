#!/bin/sh
set -eu

VERSION="WAMR-2.4.5"
ARCHIVE_SHA256="1ab09d51099f276ca4a1d6629f6b589aab2bd0caa01445e05031a4bed22c199b"
SOURCE_URL="https://github.com/bytecodealliance/wasm-micro-runtime/archive/refs/tags/${VERSION}.tar.gz"

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
target="$repo_root/Vendor/WAMR/2.4.5"
vendor_parent="$repo_root/Vendor/WAMR"

case "$target" in
    "$repo_root"/Vendor/WAMR/2.4.5) ;;
    *) echo "unsafe WAMR target: $target" >&2; exit 2 ;;
esac
if [ "$target" = "/" ] || [ "$target" = "$repo_root" ] || [ -e "$target" ] || [ -L "$target" ]; then
    echo "WAMR target must be an absent, non-symlink version directory: $target" >&2
    exit 3
fi
mkdir -p "$vendor_parent"
if [ "$(CDPATH= cd -- "$vendor_parent" && pwd -P)" != "$vendor_parent" ]; then
    echo "unsafe WAMR vendor parent" >&2
    exit 4
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/duckpad-wamr.XXXXXX")
stage="$vendor_parent/.2.4.5.stage.$$"
cleanup() {
    rm -rf -- "$work"
    if [ -e "$stage" ] && [ ! -L "$stage" ]; then rm -rf -- "$stage"; fi
}
trap cleanup EXIT HUP INT TERM

curl --fail --location --proto '=https' --tlsv1.2 --silent --show-error \
    "$SOURCE_URL" -o "$work/source.tar.gz"
actual=$(shasum -a 256 "$work/source.tar.gz" | awk '{print $1}')
if [ "$actual" != "$ARCHIVE_SHA256" ]; then
    echo "WAMR archive checksum mismatch: $actual" >&2
    exit 1
fi

if tar -tzf "$work/source.tar.gz" | awk '
    /^\// { bad=1 }
    { count=split($0, part, "/"); for (i=1; i<=count; i++) if (part[i] == "..") bad=1 }
    END { exit bad ? 0 : 1 }
'; then
    echo "archive contains an unsafe path" >&2
    exit 5
fi
if tar -tvzf "$work/source.tar.gz" | awk '
    (substr($1,1,1) == "l" || substr($1,1,1) == "h") &&
    ($6 ~ /\/core\// || $6 ~ /\/LICENSE$/) { found=1 }
    END { exit found ? 0 : 1 }
'; then
    echo "archive contains links in the vendored subset; refusing extraction" >&2
    exit 6
fi
tar -xzf "$work/source.tar.gz" -C "$work"
source_root="$work/wasm-micro-runtime-${VERSION}"
subset="$work/subset"
mkdir -p "$subset/core"

cp "$source_root/LICENSE" "$subset/LICENSE"
cp "$source_root/core/config.h" "$subset/core/config.h"
cp "$source_root/core/version.h" "$subset/core/version.h"
cat > "$subset/PROVENANCE.md" <<EOF
# WAMR provenance

- Upstream: Bytecode Alliance WebAssembly Micro Runtime (WAMR) \`${VERSION}\`
- Official source: \`${SOURCE_URL}\`
- Archive SHA-256: \`${ARCHIVE_SHA256}\`
- License: \`LICENSE\` (Apache License 2.0 with LLVM Exceptions)
- Included subset: Core interpreter loader/runtime, common runtime, allocator,
  utilities, and Darwin/POSIX memory/thread primitives plus public headers.
  AOT declaration headers required by common headers are present, but no AOT
  implementation source is compiled.
- Excluded at source selection and build time: AOT, LLVM/Fast JIT, WASI,
  built-in libc, sockets, filesystem/clock WASI shims, pthread/multi-module,
  debugger, samples, tools, tests, and release binaries.
- Duckpad build: interpreter-only; no native module imports are registered.
  Bulk-memory/reference-types decoding required by the pinned sample adds no
  host capability. Modules must still declare zero imports and bounded memory.
- Text normalization: trailing horizontal whitespace and extra blank lines at
  EOF are removed so regenerated sources pass the repository review gate.

Regenerate only into an absent target directory with
\`scripts/vendor_wamr_2_4_5.sh\`. The script validates HTTPS/TLS, checksum,
archive paths and links, and publishes with Darwin \`RENAME_EXCL\`.
EOF
mkdir -p "$subset/include"
cat > "$subset/include/WAMRRuntime.h" <<'EOF'
#ifndef DUCKPAD_VENDOR_WAMR_RUNTIME_H
#define DUCKPAD_VENDOR_WAMR_RUNTIME_H

#include <stdbool.h>
#include "../core/iwasm/include/wasm_export.h"

#endif
EOF

for relative in \
    core/iwasm/include \
    core/iwasm/aot \
    core/iwasm/compilation \
    core/iwasm/common \
    core/iwasm/interpreter \
    core/shared/utils \
    core/shared/mem-alloc \
    core/shared/platform/include \
    core/shared/platform/darwin \
    core/shared/platform/common/posix \
    core/shared/platform/common/memory
do
    mkdir -p "$subset/$(dirname "$relative")"
    cp -R "$source_root/$relative" "$subset/$relative"
done

# AOT headers are referenced by shared runtime declarations, but no AOT source
# is compiled into Duckpad. Remove executable AOT implementation files.
find "$subset/core/iwasm/aot" -type f ! -name '*.h' -delete
find "$subset/core/iwasm/compilation" -type f ! -name '*.h' -delete
# Debug/ELF AOT headers are not referenced by the interpreter-only build.
find "$subset/core/iwasm/aot/debug" -type f -delete

# Files removed by upstream's own no-WASI/no-debug source selection. Keeping
# them out makes the reviewed subset match Duckpad's denied ambient surface.
rm -f \
    "$subset/core/shared/platform/common/posix/posix_file.c" \
    "$subset/core/shared/platform/common/posix/posix_clock.c" \
    "$subset/core/shared/platform/common/posix/posix_socket.c"

find "$subset" -type f -exec perl -0pi -e \
    's/[ \t]+(?=\r?\n)//g; s/(?:\r?\n){2,}\z/\n/' {} +

find "$subset" -name '.DS_Store' -delete
find "$subset" -depth -type d -empty -delete
if [ -e "$stage" ] || [ -L "$stage" ]; then
    echo "unsafe pre-existing WAMR staging path" >&2
    exit 7
fi
mkdir "$stage"
cp -R "$subset/." "$stage/"
chmod -R u=rwX,go=rX "$stage"
if [ -e "$target" ] || [ -L "$target" ]; then
    echo "WAMR target appeared during preparation" >&2
    exit 8
fi
stage_inode=$(stat -f '%i' "$stage")
python3 -c '
import ctypes, errno, os, sys
libc = ctypes.CDLL(None, use_errno=True)
renameatx_np = libc.renameatx_np
renameatx_np.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
renameatx_np.restype = ctypes.c_int
AT_FDCWD = -2
RENAME_EXCL = 0x00000004
if renameatx_np(AT_FDCWD, os.fsencode(sys.argv[1]), AT_FDCWD, os.fsencode(sys.argv[2]), RENAME_EXCL) != 0:
    value = ctypes.get_errno()
    raise OSError(value, os.strerror(value), sys.argv[2])
' "$stage" "$target"
target_inode=$(stat -f '%i' "$target")
if [ "$stage_inode" != "$target_inode" ] || [ -L "$target" ] || \
   [ "$(CDPATH= cd -- "$target" && pwd -P)" != "$target" ]; then
    echo "published WAMR target identity mismatch" >&2
    exit 9
fi

echo "Vendored WAMR ${VERSION} interpreter subset from ${SOURCE_URL}"
echo "Archive SHA-256: ${ARCHIVE_SHA256}"
find "$target" -type f | LC_ALL=C sort | sed "s#^$repo_root/##"
