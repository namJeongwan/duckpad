> Native plugins use [SDK v1](native-sdk.md) with host API 1.3.0. The WASM interfaces below remain supported.

# Plugin API reference

Status: development host API **1.3.0**. This reference describes executable code in this branch; it is not a public stability guarantee for unreleased APIs.

## Authoritative definitions

- [Manifest/domain models](../../Sources/DuckpadDomain/ExtensionModels.swift)
- [Host API version, registration and limits](../../Sources/DuckpadApplication/ExtensionPlatform.swift)
- [List protocol codec](../../Sources/DuckpadApplication/ExtensionServiceModels.swift)
- [Package validation and publisher trust](../../Sources/DuckpadInfrastructure/LocalExtensionPlatform.swift)
- [WASM validation](../../Sources/DuckpadPluginSupport/WasmModulePolicy.swift)
- [Reference transform module](../../Samples/DuckpadTextTools/module.rs)

## Version numbers

These are separate: plugin release version, manifest `schemaVersion` (1), host API semantic version (1.3.0 here), WASM ABI (`duckpad-wasm-1`), and list value protocol (2). `api.minimum` is inclusive; `api.maximumExclusive` is exclusive. The plugin ID stays fixed across updates. Command IDs must belong to the plugin's ID namespace. `operation` is the plugin's UInt32 dispatch identifier.

Only set an API range you have tested. When a public API becomes stable, incompatible changes must receive a compatible negotiation/migration path or a major API change. The development Clipboard service protocol has evolved; use matching host and plugin development revisions rather than assuming compatibility from the app version alone.

## Manifest and contributions

`plugin.json` declares `schemaVersion`, `id`, `name`, `version`, `api`, `publisher`, `runtime`, `capabilities`, and `contributes`. Versions are objects with `major`, `minor`, and `patch` numeric fields. The parser rejects unknown keys and duplicate keys, including nested objects.

For WASM plugins, `runtime` must declare `kind: wasm-core`, `module: module.wasm`, `abi: duckpad-wasm-1`. `contributes` has arrays for `commands`, `keybindings`, `snippets`, `themes`, and `languages`. Commands run; keybindings are routed with permissions and conflict handling. The other contribution metadata is parsed but is not a complete runtime extension mechanism.

## Command scopes and capabilities

| `inputScope` | Input and result | Required grants |
| --- | --- | --- |
| `selection` | Selected UTF-8 bytes; return replacement UTF-8 | `documents.read` and `documents.write`, both scope `selection` |
| `document` | Active document UTF-8; return replacement UTF-8 | `documents.read` and `documents.write`, both scope `active` |
| `service` | Opaque binary request/response; no document edit result | `storage.plugin`, `ui.list`, plus declared service capabilities, scope `application` |

Clipboard monitoring additionally requires `clipboard.read`; insertion requires `clipboard.write`. A service does not gain access to document text. `ui.notifications` is a recognized identifier, but it is not an arbitrary callable notification API exposed to the WASM guest. Do not infer an import or function from a capability name.

User packages require enablement and grants tied to their publisher, exact version and package digest. Updating a package invalidates prior grants. Revocation cancels pending effects. Document results are rechecked against editor identity, revision and selection and applied through the editor's normal Undo path.

## WASM ABI

Export these functions and the linear `memory`:

```c
uint32_t duckpad_invoke(uint32_t operation, const uint8_t *input, uint32_t length);
uint32_t duckpad_output_pointer(void);
uint32_t duckpad_output_length(void);
```

The first function returns zero on success and nonzero on failure. Input is a borrowed byte slice; do not read beyond `length` or free it. Store output in the module's memory and keep it alive through the two output accessor calls. The host validates pointer ranges and copies the result. Do not depend on mutable globals surviving between invocations; a service must return serialized state.

The module uses **zero imports**, with explicit bounded memory/table maxima. WASI, native libraries, network, filesystem, environment, process, and clock imports are not available. For list protocol v2, the host supplies Unix seconds in the request. The production host runs the interpreter in the app's XPC service; SwiftPM development/tests use a helper transport.

Default limits: module 2 MiB, input 1 MiB, output 2 MiB, linear memory 128 pages/8 MiB, table 1,024 elements, invocation timeout 1,000 ms. Clipboard state is additionally capped at 512 KiB, individual text 256 KiB, query 16 KiB, and history 200 entries. A limit failure must preserve the previous persisted state and editor content.

## Localization

The current native host UI uses English/Korean `Localizable.strings`. It translates known command titles and the two current plugin display names, and refreshes open panels on language change. IDs, paths, publisher IDs and copied user content are never translated.

There is **no plugin-owned localization manifest/resource API yet**. An external plugin's unknown name/title falls back to its supplied text. Do not add invented `localizations` or `locales` manifest keys: the current parser rejects them. The host's Clipboard translations are not a reusable internationalization SDK. A future plugin localization contract must define locale selection, fallback and resource validation before it is advertised as supported.

## Current Clipboard service

See [list services](list-services.md) and the Clipboard repository's `docs/service-protocol.md`. Events are `capture`, `query`, `preview`, `select`, `pin`, `delete`, `clear`, and `retention`. `preview` returns text only for display. Only an explicit `select` can lead to insertion after native target validation. The host's Paste Next control selects successive visible rows; it is not a separate guest command.
