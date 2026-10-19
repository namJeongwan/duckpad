#!/bin/bash
# Build the full Ghostty macOS engine from pinned source. No installed Ghostty required.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCHITECTURE=native
if [[ $# == 2 && "$1" == --architecture ]]; then ARCHITECTURE="$2"; elif [[ $# != 0 ]]; then exit 64; fi
[[ "$ARCHITECTURE" == native || "$ARCHITECTURE" == universal ]] || exit 64
SOURCE="$ROOT/.build/ghostty-source"
DESTINATION="$ROOT/Vendor/Ghostty/GhosttyKit.xcframework"
COMMIT=332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28
STAMP="$ROOT/.build/ghostty-build-$ARCHITECTURE.stamp"
BUILD_KEY="$COMMIT-$(cat "$ROOT/scripts/build_ghostty.sh" "$ROOT/scripts/patch_ghostty_host_pty.py" "$ROOT/scripts/patch_ghostty_inspector.py" "$ROOT/Vendor/Ghostty/inspector-localization-keys.json" "$ROOT/scripts/ghostty_archive.py" | shasum -a 256 | cut -d ' ' -f 1)"
# A universal framework also satisfies a native package build.
if [[ -d "$DESTINATION" && -d "$SOURCE/zig-out/share/ghostty" ]] &&
   { [[ -f "$STAMP" && "$(cat "$STAMP")" == "$BUILD_KEY" ]] || [[ -f "$ROOT/.build/ghostty-build-universal.stamp" && "$(cat "$ROOT/.build/ghostty-build-universal.stamp")" == "$BUILD_KEY" ]]; }; then exit 0; fi
mkdir -p "$ROOT/.build/ghostty-toolchain" "$ROOT/Vendor/Ghostty"
if [[ ! -d "$SOURCE/.git" ]]; then git clone --depth 1 --branch v1.3.1 https://github.com/ghostty-org/ghostty.git "$SOURCE"; fi
[[ "$(git -C "$SOURCE" rev-parse HEAD)" == "$COMMIT" ]] || { echo 'Unexpected Ghostty source revision' >&2; exit 1; }
case "$(uname -m)" in
 arm64) ZIG_ARCH=aarch64; SHA=3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b ;;
 x86_64) ZIG_ARCH=x86_64; SHA=375b6909fc1495d16fc2c7db9538f707456bfc3373b14ee83fdd3e22b3d43f7f ;;
 *) exit 1 ;;
esac
TOOLCHAIN="$ROOT/.build/ghostty-toolchain"
ZIG="$TOOLCHAIN/zig-$ZIG_ARCH-macos-0.15.2/zig"
if [[ ! -x "$ZIG" ]]; then
 curl --fail --location "https://ziglang.org/download/0.15.2/zig-$ZIG_ARCH-macos-0.15.2.tar.xz" -o "$TOOLCHAIN/zig.tar.xz"
 [[ "$(shasum -a 256 "$TOOLCHAIN/zig.tar.xz" | cut -d ' ' -f 1)" == "$SHA" ]]
 tar -xf "$TOOLCHAIN/zig.tar.xz" -C "$TOOLCHAIN"
fi
xcrun -sdk macosx metal --version >/dev/null || {
 echo 'Install the Apple Metal compiler with: xcodebuild -downloadComponent MetalToolchain' >&2; exit 1;
}
# Zig 0.15.2 cannot resolve arm64 symbols in the latest arm64e-only SDK stubs.
# Clone the SDK locally and use Zig's shipped compatible libSystem stub. The
# installed SDK and compiler remain unchanged.
# xcrun may return a versioned alias pointing to MacOSX.sdk. Resolve only
# the root before copying, retaining relative links inside the private SDK.
SDK="$(cd "$(xcrun --sdk macosx --show-sdk-path)" && pwd -P)"
# Older builds copied that alias into a self-referential destination link.
if [[ -L "$TOOLCHAIN/MacOSX.sdk" ]]; then rm "$TOOLCHAIN/MacOSX.sdk"; fi
if [[ ! -d "$TOOLCHAIN/MacOSX.sdk" ]]; then cp -cR "$SDK" "$TOOLCHAIN/MacOSX.sdk"; fi
chmod u+w "$TOOLCHAIN/MacOSX.sdk/usr/lib/libSystem.tbd"
cp "$TOOLCHAIN/zig-$ZIG_ARCH-macos-0.15.2/lib/libc/darwin/libSystem.tbd" "$TOOLCHAIN/MacOSX.sdk/usr/lib/libSystem.tbd"
mkdir -p "$TOOLCHAIN/bin"
cp "$ROOT/scripts/ghostty_archive.py" "$TOOLCHAIN/bin/duckpad-libtool-v3"
export DUCKPAD_GHOSTTY_ZIG="$ZIG"
python3 - "$TOOLCHAIN" "$SOURCE" <<'PY'
from pathlib import Path
import shlex,sys
root,source=map(Path,sys.argv[1:])
wrapper=root/'bin/xcrun'
wrapper.write_text('#!/bin/sh\nif [ "$*" = "--sdk macosx --show-sdk-path" ]; then\nprintf "%s\\n" '+shlex.quote(str(root/'MacOSX.sdk'))+'\nelse\nexec /usr/bin/xcrun "$@"\nfi\n')
wrapper.chmod(0o755)
# Build only the full macOS core. The unrelated VT shared library/iOS variants
# are neither linked nor shipped by Duckpad.
p=source/'src/build/LibtoolStep.zig';s=p.read_text().replace('\"libtool\", \"-static\"', '\"duckpad-libtool-v3\", \"-static\"').replace('\"duckpad-libtool\", \"-static\"', '\"duckpad-libtool-v3\", \"-static\"');p.write_text(s)
p=source/'build.zig';s=p.read_text();s=s.replace('    libghostty_vt_shared.install(b.getInstallStep());','    // Duckpad: the VT-only shared library is not shipped.');p.write_text(s)
p=source/'src/build/GhosttyXCFramework.zig';s=p.read_text()
for name in ['ios','ios_sim']:
 block='''                .{
                    .library = %s.output,
                    .headers = b.path("include"),
                    .dsym = %s.dsym,
                },
'''%(name,name)
 s=s.replace(block,'')
 # Zig rejects unused local constants after removing their entries.
 s=s.replace('    // The xcframework wraps',f'    _ = {name};\n\n    // The xcframework wraps',1) if f'    _ = {name};' not in s else s
p.write_text(s)
PY
python3 "$ROOT/scripts/patch_ghostty_host_pty.py" "$SOURCE"
python3 "$ROOT/scripts/patch_ghostty_inspector.py" "$SOURCE"
export PATH="$TOOLCHAIN/bin:$PATH"
cd "$SOURCE"
"$ZIG" build -Doptimize=ReleaseFast -Dsentry=false -Demit-xcframework=true -Dxcframework-target="$ARCHITECTURE" -Demit-macos-app=false
# Only replace generated output after a complete successful build.
rm -rf "$DESTINATION"
ditto "$SOURCE/macos/GhosttyKit.xcframework" "$DESTINATION"
printf '%s\n' "$BUILD_KEY" > "$STAMP"
