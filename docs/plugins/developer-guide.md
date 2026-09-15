# Build your first Duckpad plugin

Read the [API reference](api-reference.md) first. The examples below target a matching development checkout. They do not imply that the Clipboard APIs are available in a released Duckpad installer.

## 1. Pick the extension boundary

Start with a selection transform: it receives text and returns text. Use the existing [Rust sample](../../Samples/DuckpadTextTools/module.rs), whose operation 1 sorts lines and operation 2 trims trailing whitespace. For clipboard policy/storage, study the separate Clipboard repository. Arbitrary native UI, custom webviews, LSP processes and network access are not currently plugin APIs.

Keep the plugin in a separate repository. Do not fork the catalog to store its source. Choose your own stable plugin ID, command IDs, publisher ID and signing key ID; the `com.duckpad` identity belongs to Duckpad.

## 2. Package layout

```text
org.example.line-tools.duckpad-plugin/
  plugin.json
  module.wasm
  SHA256SUMS
  SIGNATURE.ed25519
```

A minimal selection-transform manifest:

```json
{
  "schemaVersion": 1,
  "id": "org.example.line-tools",
  "name": "Example Line Tools",
  "version": {"major": 0, "minor": 1, "patch": 0},
  "api": {
    "minimum": {"major": 1, "minor": 0, "patch": 0},
    "maximumExclusive": {"major": 2, "minor": 0, "patch": 0}
  },
  "publisher": {"id": "org.example", "keyID": "release-1"},
  "runtime": {"kind": "wasm-core", "module": "module.wasm", "abi": "duckpad-wasm-1"},
  "capabilities": [
    {"id": "documents.read", "scope": "selection"},
    {"id": "documents.write", "scope": "selection"}
  ],
  "contributes": {
    "commands": [{"id": "org.example.line-tools.sort", "title": "Sort Lines", "operation": 1, "inputScope": "selection"}],
    "keybindings": [], "snippets": [], "themes": [], "languages": []
  }
}
```

The range above targets the existing transform API. Clipboard list protocol v2 requires the matching development API 1.2.0. Verify the range with actual host versions before publishing.

## 3. Compile

The reference toolchain is Rust 1.91.1 with `wasm32-unknown-unknown`. From the Duckpad checkout, compile the existing sample into a new development package directory:

```sh
mkdir -p build/plugin-example/org.example.line-tools.duckpad-plugin
rustc +1.91.1 --edition 2021 --crate-type cdylib \
  --target wasm32-unknown-unknown -C opt-level=z -C panic=abort \
  -C target-feature=-bulk-memory -C link-arg=--no-entry \
  -C link-arg=--export=duckpad_invoke \
  -C link-arg=--export=duckpad_output_pointer \
  -C link-arg=--export=duckpad_output_length \
  -C link-arg=--export=memory -C link-arg=--initial-memory=5242880 \
  -C link-arg=--max-memory=8388608 -C link-arg=--strip-all \
  Samples/DuckpadTextTools/module.rs \
  -o build/plugin-example/org.example.line-tools.duckpad-plugin/module.wasm
```

Save the manifest above as `plugin.json` beside the resulting module. The supplied source implements more than one operation; only operation 1 is contributed by this manifest. In your own repository, use your own source path. The host repository's bundled-sample script verifies a fixed Duckpad release artifact; do not repurpose its signing identity for your plugin.

## 4. Inventory, signing and publisher onboarding

Create `SHA256SUMS` using SHA-256 for every package file except the inventory and signature themselves. With just these two input files:

```sh
cd build/plugin-example/org.example.line-tools.duckpad-plugin
shasum -a 256 module.wasm plugin.json > SHA256SUMS
```

Sign the exact byte concatenation of UTF-8 `duckpad-extension-signature-v1\n` and the inventory bytes using your Ed25519 private key. `SIGNATURE.ed25519` contains the base64 signature, optionally followed by a newline. Keep the private key outside the repository; publish only its public identity. The Clipboard repository's signing script is an identity-checked example, not a general tool that signs arbitrary publishers with Duckpad's key.

**Current onboarding gap:** the default loader trusts only configured publisher keys. There is no public key-import UI or automatic catalog trust yet. An external package cannot become installable merely by declaring a new publisher or copying a catalog entry. For local integration tests, construct `LocalExtensionPackageLoader` with your public `TrustedPublisherKey` and an isolated package root; the existing installer tests demonstrate this. Distribution in the stock app requires an agreed publisher onboarding mechanism with the maintainers. Do not disable signature checks to work around this missing product feature.

## 5. Test and install

Test empty input, Unicode, multiline text, bounds, malformed output and failure without changing the document. Exercise the real WAMR runtime and verify Undo/Redo for transforms. Service tests additionally cover persisted-state migration, expiry, revoked grants, rapid selection changes, closed panels and stale results. Use an isolated app profile, never your normal recovery session, for destructive test cases.

For a signed package whose public key the host recognizes: **Plugins → Manage Extensions… → Install Plugin…**, select the `.duckpad-plugin` directory. Installation enables the plugin immediately with its declared capabilities. Enable and Update do not require a separate Grant action or Duckpad permission dialog. macOS protected-resource access remains subject to system authorization. Native updates apply on the next launch; installation destinations are managed automatically. Existing installed versions are immutable; increment the plugin version instead of replacing their bytes.

For the Clipboard reference module, from its repository:

```sh
cargo test
bash scripts/build.sh
```

Then run the host's integration suite using the actual module:

```sh
DUCKPAD_CLIPBOARD_PLUGIN_MODULE=/absolute/path/to/module.wasm \
  swift test --no-parallel --filter ExtensionServiceIntegrationTests
```

To include production-trust installation, also set `DUCKPAD_SIGNED_CLIPBOARD_PACKAGE` to the signed Clipboard package directory. This test expects Duckpad's Clipboard publisher and is not a generic test for a different publisher.

## 6. Publish

1. Test the exact release module against its declared host API range.
2. Sign a new immutable version in the plugin repository.
3. Publish a release asset and record its SHA-256.
4. Submit a catalog entry/update in `duckpad-plugins` with the version, API range, immutable URL, checksum and public signing key ID.
5. Run the catalog's `python3 -m unittest discover -s tests` and `python3 scripts/validate.py`.

The current catalog is descriptive; a network installer is not implemented. A draft entry with an empty release list must never appear installable. The host, catalog and plugin releases are independent.

The catalog repository provides a root `index.json` with plugin ID/path references. When adding or removing a per-plugin catalog, regenerate it with `python3 scripts/generate_index.py` and run `--check` plus the catalog validator. Version and release metadata remain in `plugins/<plugin-id>.json`; draft entries have no installable releases.
