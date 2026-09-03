#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$repo_root"
source_file="Samples/DuckpadTextTools/module.rs"
output_file="$repo_root/Sources/DuckpadInfrastructure/Resources/BundledExtensions/com.duckpad.text-tools.duckpad-plugin/module.wasm"
expected_rustc="rustc 1.91.1 (ed61e7d7e 2025-11-07)"
expected_sha256="f73060b3d52a468ce1d804b741ce65a45465bc3d6f280f4e69a2aef677994278"
package_dir="$repo_root/Sources/DuckpadInfrastructure/Resources/BundledExtensions/com.duckpad.text-tools.duckpad-plugin"
inventory_file="$package_dir/SHA256SUMS"
signature_file="$package_dir/SIGNATURE.ed25519"
expected_public_key="4pf5NP1voP8k8NDDZEQ58lGM5D1xJlHh15QUO0jFSos="

if [ "$(rustc --version)" != "$expected_rustc" ]; then
    echo "verification requires $expected_rustc" >&2
    exit 2
fi
rustc --print target-libdir --target wasm32-unknown-unknown >/dev/null

temporary=$(mktemp -d "${TMPDIR:-/tmp}/duckpad-text-tools.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
candidate="$temporary/module.wasm"
rustc --edition 2021 --crate-type cdylib --target wasm32-unknown-unknown -C opt-level=z -C panic=abort \
    -C target-feature=-bulk-memory \
    -C link-arg=--no-entry -C link-arg=--export=duckpad_invoke \
    -C link-arg=--export=duckpad_output_pointer -C link-arg=--export=duckpad_output_length \
    -C link-arg=--export=memory -C link-arg=--initial-memory=5242880 \
    -C link-arg=--max-memory=8388608 -C link-arg=--strip-all \
    "$source_file" -o "$candidate"
actual=$(shasum -a 256 "$candidate" | awk '{print $1}')
if [ "$actual" != "$expected_sha256" ]; then
    echo "sample module digest mismatch: $actual" >&2
    exit 3
fi
if [ -e "$output_file" ]; then
    cmp "$candidate" "$output_file"
    echo "verified existing sample module $expected_sha256"
else
    mkdir -p "$(dirname "$output_file")"
    mv "$candidate" "$output_file"
    echo "published sample module $expected_sha256"
fi

# Signing identity is deliberately not generated here. Normal builds verify the
# checked-in signature. Release operators may additionally point at the existing
# 0600 raw Ed25519 private seed; this proves continuity but still does not rewrite
# tracked trust material or signatures.
set -- "$inventory_file" "$signature_file" "$expected_public_key"
if [ -n "${DUCKPAD_EXTENSION_SIGNING_KEY:-}" ]; then
    signing_key=$(realpath "$DUCKPAD_EXTENSION_SIGNING_KEY")
    case "$signing_key" in "$repo_root"/*)
        case "$signing_key" in "$repo_root/.git/"*) ;; *) echo "signing key must stay outside the tracked worktree" >&2; exit 5 ;; esac
    esac
    [ ! -L "$DUCKPAD_EXTENSION_SIGNING_KEY" ] || { echo "signing key symlink is forbidden" >&2; exit 5; }
    [ "$(stat -f '%Lp' "$signing_key")" = "600" ] || { echo "signing key must be mode 0600" >&2; exit 5; }
    set -- "$@" "$signing_key"
fi
swift "$repo_root/scripts/verify_duckpad_extension_signature.swift" "$@"
echo "verified publisher fingerprint 18d068f648c2dac6ff0bed7f1bf92acef3c7c89fa54ca5ab028531cbb161773e"
