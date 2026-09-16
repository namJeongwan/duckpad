# Native plugin SDK v1

Host API 1.3.0 adds native plugins to the existing package installer and command registry. The native ABI is version 1. Native modules execute in the Duckpad process and can create their own AppKit views. Clipboard History 0.2.0 is the reference implementation: Rust owns history semantics; Swift owns clipboard observation, persistence, UI, and all eight UI translations.

## SDK and entry points

The public contract is [DuckpadNative.h](../../SDK/DuckpadNative/include/DuckpadNative.h). [DuckpadHost.swift](../../SDK/DuckpadNative/Swift/DuckpadHost.swift) is a source wrapper compiled into a Swift plugin; plugins do not link Duckpad's internal Swift modules.

Export these C symbols:

- `duckpad_native_abi_version`: return 1.
- `duckpad_native_create`: copy the host callback table and JSON configuration; return an owned instance pointer, or null on failure. Configuration contains `resourceDirectory`, `storageDirectory`, `language`, and `commandID`.
- `duckpad_native_view`: return a borrowed `NSView *` owned by the plugin. Duckpad retains it while docked. Views can contain arbitrary AppKit controls, SwiftUI hosted in AppKit, or a plugin-managed web view.
- `duckpad_native_set_language`: update the existing view using the plugin's own translations.
- `duckpad_native_deactivate`: cancel work, stop timers/observers, remove callbacks. Must be idempotent.
- `duckpad_native_destroy`: release the instance. Duckpad detaches the view before calling deactivate/destroy.

All entry points and callbacks run on the AppKit main thread. Dispatch expensive work off the main thread. Never throw Swift/C++ exceptions across C entry points. Strings are UTF-8 and borrowed only during the call. All memory must be released by the module that allocated it. Swift plugins should use a version-specific module name so classes from different loaded versions do not collide.

The host table contains:

- `prepare_insert`: capture the active editor/document/revision/selection and return an opaque token. Zero means insertion is unavailable. Preparing another token invalidates the preceding one for that instance.
- `insert_text`: insert UTF-8 using that token through Duckpad's normal paste/Undo path. Returns 1 on success. A changed editor/selection, closed panel, disabled plugin, or consumed token returns 0.
- `close_panel`: close the plugin's dock while keeping the enabled plugin active.

These are the initial native SDK operations, not a complete editor API. Selection reads, general document commands, notifications, and dynamic command registration have not been added to the C table yet. New operations must preserve the ABI's version/struct-size contract. Menus and shortcuts are currently declared in `plugin.json`; the host owns routing and shortcut collision resolution.

## Package

Use the existing `.duckpad-plugin` directory format with these manifest values:

```json
{
  "runtime": { "kind": "native", "module": "module.dylib", "abi": "duckpad-native-1" },
  "api": { "minimum": { "major": 1, "minor": 3, "patch": 0 }, "maximumExclusive": { "major": 2, "minor": 0, "patch": 0 } }
}
```

This is a manifest fragment, not a complete manifest. See the reference plugin's `plugin.json` for publisher, version, commands, keybindings, and capabilities. Native commands currently use `inputScope: service` and require `runtime.native`, `ui.list`, and `storage.plugin` at application scope. Additional declared capabilities describe the plugin's intended behavior.

The signed flat package contains `module.dylib`, `plugin.json`, plugin resource files, `SHA256SUMS`, and `SIGNATURE.ed25519`. The reference plugin stores translations as `locale-<language>.strings` files. Resources are owned and read by the plugin. The existing package inventory covers every resource, not just executable bytes. The installer verifies the package before publishing a version. The embedded native installer XPC service independently verifies the signature and writes an immutable execution copy to Duckpad’s managed folder; every file is checked against the verified snapshot before loading. There is no destination picker or executable-file bookmark. macOS validates the Mach-O load and architecture. Build for the architecture of the host process; the current Clipboard build script builds for the current machine.

There is no JavaScript/TypeScript interpreter in this SDK. A native plugin can embed its own runtime. C/C++ and Rust can implement the C boundary; Swift has the provided wrapper. The reference validates a Swift dynamic library linked with a Rust static library.

## Lifecycle and updates

Installing a plugin enables it with its declared capabilities. Enable and Update likewise authorize the verified package without a separate Grant button or Duckpad trust dialog. Existing enabled installations from the former Grant workflow are migrated at launch. Disable and publisher revocation still stop access. macOS handles its own protected-resource prompts; these do not grant unrestricted access or replace App Sandbox entitlements. Capability declarations are **not** a native-code isolation mechanism.

One instance is owned per authorized service command across Duckpad windows. Opening the panel in another window moves the same view. Closing the panel keeps clipboard collection active. Disabling/revoking the plugin or closing its last owning window stops and destroys its instances. Removing or changing the selected package so it no longer verifies also stops activation. Pending insert tokens are invalidated when the panel closes or moves.

Dynamic libraries remain loaded until process exit. Do not use `dlclose` for plugins that register Swift/Objective-C classes or callbacks. All windows share a `NativeExtensionActivationSession`: the first verified native version selected in an app process stays selected until the app exits. Installing a newer compatible version keeps the current version and its panel running, and Extensions Manager shows the installed version that will apply on the next launch. Disabling and re-enabling, opening another window, or refreshing the registry does not replace native code. A first installation can activate in the current process. The next process selects the newest verified compatible version; the Update button renews identity-bound grants for that verified release. Clicking Update authorizes the new version and its declared capabilities; no extra Duckpad permission dialog is shown. No forced restart or document close is triggered.

The selected package must remain installed and pass verification; an update must retain that version alongside the new version. If it disappears or changes, the host stops serving it and requires a restart instead of substituting another native image. Plugin data uses a separate publisher/command storage identity and is not moved or deleted by version selection. Extensions Manager reads the official `duckpad-plugins/index.json` at launch and every six hours, then checks the per-plugin catalogs for indexed installed plugins. It also provides Check for Plugin Updates. An invalid or missing index is reported as a failed check. Update downloads and verifies the archive, renews approved grants, installs it alongside the existing version, and shows the next-launch status. Failed download, verification, or installer work leaves the existing version in place. There is no unattended update installation, rollback picker, or automatic old-version cleanup. A catalog release must actually be published before it appears as an available update.

The host's Hardened Runtime signing enables `com.apple.security.cs.disable-library-validation` to load code signed by third-party developers. The Duckpad package signature and Apple's Mach-O code signature are separate. Production native plugin distribution needs appropriate macOS signing/notarization; local test packages use ad-hoc code signing. See [Apple's entitlement documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation).

App Sandbox remains enabled for Duckpad and its existing WASM runtime service. Only `DuckpadNativeInstaller.xpc` runs outside Sandbox, as the logged-in user without administrator privileges. It accepts only a bounded signed-file payload, not destination paths or commands. It verifies the configured publisher signature, package inventory, native runtime, and host API range before writing under `~/Library/Containers/com.namjeongwan.duckpad/Data/Library/Application Support/Duckpad/NativePluginModules/<verified-digest>.duckpad-plugin`. The original signed registry package remains under Duckpad’s `Extensions` folder. Clipboard data remains separately under `PluginData`.

The app and installer use `NSXPCConnection.setCodeSigningRequirement` with the shipped peer’s designated requirement; the installer additionally checks the connecting user. Ad-hoc builds bind to the code hash. Developer ID builds retain their signing requirement. See [Apple’s XPC requirement documentation](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:)). No quarantine attributes or system security settings are removed. The old `files.user-selected.executable` entitlement and installation Save panel are no longer used.

The automated native installer smoke launches a real sandboxed/hardened app, installs and loads the signed module through the embedded helper, then launches a second process that loads it without an installation request or picker. It does not access clipboard contents or create plugin UI instances. Local tests use ad-hoc signatures; production Developer ID signing/notarization remains untested without a signing identity. This architecture does not imply Mac App Store approval.

## Reference development

In the Clipboard repository, point the build to this SDK directory:

```sh
cargo test
bash scripts/build.sh /path/to/duckpad/SDK/DuckpadNative
bash scripts/test-native.sh /path/to/duckpad/SDK/DuckpadNative
bash /path/to/duckpad/scripts/test_native_installer.sh dist/native/com.duckpad.clipboard-history.duckpad-plugin
swift scripts/sign.swift dist/native/com.duckpad.clipboard-history.duckpad-plugin
```

The Rust tests cover history behavior. The native smoke executable loads the actual dynamic module and checks legacy-state migration, clipboard capture, search, sequential paste, selection after deletion, preview, language changes, the close callback, and stopping collection. It uses its own pasteboard and temporary storage.

Install the signed package using Plugins Admin. Clipboard 0.2.1 continues to use the 0.1.x state format and publisher/command storage identity, preserving unexpired history and pins. The retained WASM 0.1.2 package continues to work in the legacy host; unpublished service-protocol-v1 development guests are unsupported; `scripts/build-wasm.sh` builds the preserved 0.1.2 manifest.

## Uninstall lifecycle

Uninstall withdraws the package from all window registries before deleting its installed versions. Service hosts deactivate and destroy instances and detach panels; plugin code must stop timers, observers, and callbacks in `deactivate`. In-progress installation results are fenced so they cannot republish a removed package. History and settings in `PluginData` are retained.

The host also removes known managed execution copies. An installer XPC request already accepted before cancellation may finish afterward and leave an inactive cached copy; that copy cannot restore registry registration or reactivate the plugin. Mapped native code is retained until process exit, never unloaded with `dlclose`. The existing process-wide native identity pin remains in effect across uninstall/reinstall.
