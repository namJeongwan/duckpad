# Duckpad plugin development

This is the developer entry point for the current source tree. Host API **1.3.0** and the native SDK are **unreleased development APIs**. An app's version (for example a local 0.5.0 test build) does not identify its host API version. Check `ExtensionWorkspaceUseCase.apiVersion` in the matching source revision.

- [Native plugin SDK](native-sdk.md): C ABI, Swift wrapper, plugin-owned UI/resources, lifecycle, and native Clipboard reference.
- [Developer guide](developer-guide.md): package layout, first build, signing, installation, testing, and catalog submission.
- [API reference](api-reference.md): manifest, command scopes, WASM ABI, capabilities, limits, and compatibility.
- [Clipboard list service](list-services.md): current native dock and storage behavior.
- [Platform architecture](../wiki/11-extension-platform.md): implementation history and trust model; some historical status statements predate this development branch.

## Repository responsibilities

| Repository | Owns |
| --- | --- |
| `namJeongwan/duckpad` | Host API, runtime, manifest validation, generic docking, SDK, developer documentation, reference transform sample |
| `namJeongwan/duckpad-plugins` | Catalog metadata, publisher public keys, release URLs and checksums; no plugin implementation |
| `namJeongwan/duckpad-plugin-clipboard-history` | Clipboard implementation, manifest, module build/test/signing scripts, plugin releases |

Each new plugin should normally have its own repository. The catalog registers independently versioned packages. Adding a catalog entry does not install a plugin or automatically trust its publisher.

## What is ready, and what is not

Selection/document transforms retain the WASM ABI. Native plugins can own their AppKit views and resources through SDK v1. Clipboard 0.2.1 demonstrates this path with Swift UI and a Rust history engine. The legacy WASM list service remains for 0.1.x compatibility.

The native SDK currently exposes docking, locale changes, insertion tokens, and manifest-declared commands/shortcuts. It does not yet provide the full Notepad++ editor API, a JavaScript runtime, automated publisher onboarding, unattended updates or uninstall UI. The API is not yet a published stable release.
