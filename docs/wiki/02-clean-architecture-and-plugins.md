# Duckpad Clean Architecture and Plugin Platform

> Status: **Revised after independent review; pending re-review**
>
> Scope: macOS native application architecture, Scintilla integration, document/session/tab model, language support, and plugin boundary
>
> Reference source: local `notepad-plus-plus` repository fixed at commit `dda973d2b`
>
> Compatibility target: reproduce at least 90% of the user-visible Notepad++ behavior while preferring the native macOS convention when literal Windows behavior conflicts with it

## 1. Decision summary

Duckpad is a **Swift + AppKit macOS application**. AppKit owns windows, menus, commands, focus, drag and drop, accessibility, and the multiline tab bar. Scintilla Cocoa remains the editing engine and is reachable only through a narrow Objective-C++ adapter. Domain and application code never import AppKit, Objective-C++, Scintilla, Lexilla, SQLite, or a plugin runtime.

The first milestone fixes these decisions:

1. Use AppKit as the primary UI framework. SwiftUI may be embedded for low-risk preference or onboarding screens, but it does not own the editor workspace.
2. Use the existing Scintilla Cocoa frontend behind an Objective-C++ bridge. No Scintilla pointer, numeric message, or notification structure crosses into the domain.
3. Represent an untitled scratch document as a first-class document, not as an exceptional file state. Content recovery is independent from explicit file saving.
4. Represent a tab as a placement of a document view. A tab is not the document and a Scintilla document handle is not a domain identifier.
5. Implement wrapping document tabs with `NSCollectionView` and a custom `NSCollectionViewLayout`; do not use `NSTabViewController` or SwiftUI `TabView` as the document tab model.
6. Use bundled Lexilla for fast syntax styling and LSP for semantic/editor intelligence. Tree-sitter is not a baseline dependency; it may later be exposed as an optional analysis service when a feature has a concrete parsing requirement.
7. Execute third-party plugins only as WebAssembly modules inside the minimal-entitlement `DuckpadPluginRuntime.xpc` service and expose a versioned, capability-checked SDK. Version 1 never loads a plugin-provided executable, dylib, script runtime, or JIT code. Plugins receive commands, events, snapshots, revision-checked edits, and host-rendered declarative panels—not AppKit views, Scintilla handles, unrestricted host objects, WASI, or ambient operating-system access.
8. Port **observable behavior**, not Win32 implementation. The compatibility matrix is the acceptance source of truth; macOS menus, shortcuts, text input, accessibility, security, and window behavior take priority over literal UI duplication.

## 2. Pinned local-source evidence

The checked-in Notepad++ tree is a behavioral reference, not an implementation layer for Duckpad. Every link and line range in this section is fixed to the clean local reference commit **`dda973d2b`**; moving that reference requires a documentation review that revalidates all ranges.

| Evidence | Local source and lines | Architectural consequence |
| --- | --- | --- |
| A `BufferID` is a unique buffer pointer and file manager operations create/load/save/backup buffers | [`Buffer.h:23-28`](../../notepad-plus-plus/PowerEditor/src/ScintillaComponent/Buffer.h#L23-L28), [`Buffer.h:72-107`](../../notepad-plus-plus/PowerEditor/src/ScintillaComponent/Buffer.h#L72-L107) | Preserve stable document identity and buffer lifecycle, but replace pointer identity with typed UUIDs and ports. |
| Unnamed, deleted, externally modified, reload-needed, and inaccessible documents are explicit states | [`Buffer.h:30-51`](../../notepad-plus-plus/PowerEditor/src/ScintillaComponent/Buffer.h#L30-L51) | Model file/recovery state explicitly; do not infer it from a tab title or URL. |
| Buffer metadata includes dirty/read-only, EOL, language, encoding, Scintilla document, per-view positions/folds, backup state, and external synchronization | [`Buffer.h:187-245`](../../notepad-plus-plus/PowerEditor/src/ScintillaComponent/Buffer.h#L187-L245), [`Buffer.h:417-469`](../../notepad-plus-plus/PowerEditor/src/ScintillaComponent/Buffer.h#L417-L469) | Split logical document state, shared text-buffer state, per-view state, and persistence state rather than creating one UI-owned mega-object. |
| A document may have multiple editor references with separate positions and folds | [`Buffer.h:432-439`](../../notepad-plus-plus/PowerEditor/src/ScintillaComponent/Buffer.h#L432-L439) | A split view shares one buffer but owns independent `EditorViewState`. |
| Sessions retain two views, active indices, language/encoding, marks/folds, pinned state, renamed untitled state, and backup path | [`Parameters.h:121-169`](../../notepad-plus-plus/PowerEditor/src/Parameters.h#L121-L169) | Session snapshots must restore document placement and editor state as well as filenames. |
| `DocTabView` maps tabs to buffers and handles add/close/activate/update independently of the editor view | [`DocTabView.h:32-61`](../../notepad-plus-plus/PowerEditor/src/ScintillaComponent/DocTabView.h#L32-L61), [`DocTabView.h:80-101`](../../notepad-plus-plus/PowerEditor/src/ScintillaComponent/DocTabView.h#L80-L101) | Keep tab placement separate from document content and route updates by stable IDs. |
| Multiline tabs are a runtime tab-bar style, currently implemented with Win32 `TCS_MULTILINE` | [`TabBar.cpp:40-52`](../../notepad-plus-plus/PowerEditor/src/WinControls/TabBar/TabBar.cpp#L40-L52), [`TabBar.cpp:616-623`](../../notepad-plus-plus/PowerEditor/src/WinControls/TabBar/TabBar.cpp#L616-L623) | Reproduce row wrapping as native AppKit layout behavior; do not port the Win32 control. |
| Scintilla already has a Cocoa `NSView`, `NSTextInputClient`, drag/drop, accessibility, delegate notifications, and direct-message API | [`ScintillaView.h:26-43`](../../notepad-plus-plus/scintilla/cocoa/ScintillaView.h#L26-L43), [`ScintillaView.h:59-83`](../../notepad-plus-plus/scintilla/cocoa/ScintillaView.h#L59-L83), [`ScintillaView.h:100-144`](../../notepad-plus-plus/scintilla/cocoa/ScintillaView.h#L100-L144) | Wrap the existing Cocoa frontend; keep IME/accessibility notification handling in the adapter and presentation layers. |
| The Cocoa backend is Objective-C++ and derives from `ScintillaBase` | [`ScintillaCocoa.h:84-100`](../../notepad-plus-plus/scintilla/cocoa/ScintillaCocoa.h#L84-L100), [`ScintillaCocoa.h:136-149`](../../notepad-plus-plus/scintilla/cocoa/ScintillaCocoa.h#L136-L149) | An Objective-C++ target is the natural compilation boundary between Swift and Scintilla C++. |
| Cocoa key bindings already map Command-based edit actions | [`ScintillaCocoa.mm:137-150`](../../notepad-plus-plus/scintilla/cocoa/ScintillaCocoa.mm#L137-L150) | Validate and extend native shortcuts instead of importing Windows key maps. |
| The Notepad++ plugin ABI hands plugins native window handles and callbacks, then loads DLL exports into the app process | [`PluginInterface.h:28-40`](../../notepad-plus-plus/PowerEditor/src/MISC/PluginsManager/PluginInterface.h#L28-L40), [`PluginInterface.h:53-72`](../../notepad-plus-plus/PowerEditor/src/MISC/PluginsManager/PluginInterface.h#L53-L72), [`PluginsManager.cpp:130-172`](../../notepad-plus-plus/PowerEditor/src/MISC/PluginsManager/PluginsManager.cpp#L130-L172) | Do not copy the ABI. It is Win32-specific and an in-process crash/security boundary. |
| Notepad++ broadcasts copied Scintilla notifications but still invokes plugin code in process | [`PluginsManager.cpp:696-735`](../../notepad-plus-plus/PowerEditor/src/MISC/PluginsManager/PluginsManager.cpp#L696-L735) | Duckpad events must be value messages over IPC and plugin failure must not crash the editor. |
| Lexilla defines macOS `.dylib` support and a stable lexer-factory surface | [`Lexilla.h:12-30`](../../notepad-plus-plus/lexilla/include/Lexilla.h#L12-L30), [`Lexilla.h:51-79`](../../notepad-plus-plus/lexilla/include/Lexilla.h#L51-L79), [`Lexilla.h:81-105`](../../notepad-plus-plus/lexilla/include/Lexilla.h#L81-L105) | Bundle a reviewed Lexilla build for baseline language coverage. Do not treat arbitrary lexer dylibs as trusted general plugins. |
| Notepad++ sets both built-in and external `ILexer5` instances through `SCI_SETILEXER` | [`ScintillaEditView.cpp:1209-1235`](../../notepad-plus-plus/PowerEditor/src/ScintillaComponent/ScintillaEditView.cpp#L1209-L1235), [`ScintillaEditView.cpp:2322-2329`](../../notepad-plus-plus/PowerEditor/src/ScintillaComponent/ScintillaEditView.cpp#L2322-L2329) | Put lexer selection in the editor-engine adapter behind a `LanguageStylingPort`. |
| Scintilla and Lexilla grant use/copy/modify/distribute permission with notice retention | [`scintilla/License.txt:1-20`](../../notepad-plus-plus/scintilla/License.txt#L1-L20), [`lexilla/License.txt:1-20`](../../notepad-plus-plus/lexilla/License.txt#L1-L20) | They may be integrated with required notices and attribution. |
| Notepad++ application code is distributed under GNU GPL v3 with the local license's “clarifications and exceptions described below” | [`LICENSE:1-14`](../../notepad-plus-plus/LICENSE#L1-L14) | Study behavior and write an independent Swift implementation. Directly copying NPP application code requires an explicit GPL distribution decision and legal review. |

## 3. Architecture

### 3.1 Modules and dependency direction

```text
DuckpadApp (composition root)
├── DuckpadPresentation (AppKit, optional embedded SwiftUI)
│   ├── Workspace window/controllers
│   └── Multiline tab collection view/layout
├── DuckpadApplication (use cases and ports)
│   └── depends on DuckpadDomain
├── DuckpadInfrastructure (files, recovery, session DB, file watcher)
│   └── implements DuckpadApplication ports
├── DuckpadEditorAdapter (Swift facade)
│   └── calls DuckpadScintillaBridge
├── DuckpadScintillaBridge (Objective-C++)
│   └── owns Scintilla Cocoa + bundled Lexilla
├── DuckpadPluginBroker (manifest, permissions, IPC, lifecycle)
│   └── implements plugin-related application ports
└── DuckpadDomain (Foundation-safe value types and policies)
```

The dependency rule is inward:

```text
Presentation ─┐
Infrastructure ├──> Application ──> Domain
EditorAdapter ─┤
PluginBroker ──┘
```

- `DuckpadDomain` imports no UI, persistence, editor-engine, or plugin framework.
- `DuckpadApplication` defines ports and use cases. It may depend on domain types only.
- Outer modules implement ports and are assembled by `DuckpadApp`.
- Presentation sends intents to use cases and renders immutable view state. It does not save files or call Scintilla messages directly.
- Cross-module IDs are typed (`DocumentID`, `BufferID`, `ViewID`, `TabID`, `SessionID`, `PluginID`), not raw strings or pointers.
- All state-changing use cases are `@MainActor` only when they coordinate visible workspace state. File I/O, recovery, LSP, and plugin calls execute off the main actor and return value results.

Suggested application ports:

```swift
protocol TextBufferPort {
    func createBuffer(for document: DocumentID) async throws -> BufferID
    func snapshot(_ buffer: BufferID) async throws -> BufferSnapshot
    func apply(_ edit: TextEdit, to buffer: BufferID, expectedRevision: UInt64) async throws
    func attachView(_ view: EditorViewID, to buffer: BufferID) async throws
}

protocol DocumentStorePort { /* metadata and explicit save/load */ }
protocol RecoveryStorePort { /* atomic content snapshots and journal */ }
protocol SessionStorePort { /* workspace graph and view-state snapshots */ }
protocol FileObservationPort { /* rename/delete/external modification events */ }
protocol LanguageServicePort { /* lexer selection, LSP lifecycle, diagnostics */ }
protocol PluginRuntimePort { /* discovery, activation, commands, events */ }
```

These are contract shapes, not an instruction to make each method a remote call. The editor adapter may execute synchronously on the main thread where Scintilla requires it, while the application API preserves engine independence.

### 3.2 Editor bridge

`DuckpadScintillaBridge` exposes an Objective-C-compatible facade such as `DPKEditorView` and translates typed methods/events:

```text
AppKit controller
  -> DuckpadEditorAdapter (Swift, typed API)
    -> DPKEditorView / DPKScintillaClient (Objective-C++)
      -> ScintillaView message API + Lexilla ILexer5

SCNotification
  -> Objective-C++ copies required fields immediately
    -> Swift EditorEvent value
      -> application use case
```

Rules:

- The bridge owns the lifetime of `ScintillaView`, `ScintillaCocoa`, document handles, lexer instances, and C strings.
- Swift never retains `SCNotification *` or a borrowed Scintilla buffer. Notification payloads are copied before returning from the callback.
- The public adapter uses operations (`setWrapMode`, `replaceRanges`, `setLanguage`, `captureViewState`) rather than public numeric `SCI_*` messages.
- A private escape hatch for uncovered compatibility work may exist only inside `DuckpadEditorAdapter`, with a test and a tracking entry; presentation/plugins cannot use it.
- IME, marked text, first-responder state, services, accessibility, pasteboard, and drag/drop are verified on supported macOS versions before declaring editor parity.
- Scintilla document sharing is hidden behind `attachView`; reference counting is owned by the bridge so split views cannot double-free the document.

## 4. Domain model

### 4.1 Identity and ownership

| Model | Responsibility | Important fields/invariants |
| --- | --- | --- |
| `Document` | User-recognizable editing unit | `id`, `source`, display name, language selection, encoding, EOL, read-only reason, file-sync state. Exists before a file URL does. |
| `TextBufferState` | Shared editable-content state | `id`, `documentID`, monotonically increasing `revision`, dirty/save-point state, recovery revision. One per open document; content remains in the editor engine rather than duplicated in domain memory. |
| `EditorViewState` | One rendering/interaction view of a buffer | `id`, `bufferID`, selections, caret, first visible line, horizontal offset, zoom, folds, wrap mode. Multiple views may share one buffer. |
| `TabItem` | Ordered placement and controls | `id`, `documentID`, `viewID`, `groupID`, order key, pinned/color state. Closing a tab detaches a placement; it closes the document only when policy says the final reference is gone. |
| `TabGroup` | One tab strip + editor area | ordered tab IDs, active tab ID, tab mode. Supports main/sub split without hard-coding two groups into the domain. |
| `WorkspaceSession` | Restorable window/workspace graph | windows, split topology, groups, selected tabs, document metadata, view states, plugin enablement references, schema version. |
| `RecoveryRecord` | Crash-safe content checkpoint | document ID, buffer revision, checksum, timestamp, payload/blob reference, original file fingerprint. Never pretends to be an explicit user save. |

`DocumentSource` is a closed state machine:

```text
untitled(recoveryID)
  -- Save As --> file(fileReference, lastKnownFingerprint)

file(...)
  -- external delete --> missing(lastKnownReference, recoverableContent)
  -- external modify --> conflict(diskFingerprint, bufferRevision)
  -- rename observed --> file(updatedReference, fingerprint)
```

Closing, saving, recovery, and external-change handling are application use cases. UI controllers cannot mutate these states opportunistically.

### 4.2 Session and recovery invariants

- Session metadata and recovery content are separate stores. A corrupt session layout must not destroy recoverable scratch text.
- Recovery writes use a temporary file, `fsync` where appropriate, atomic replace, checksum, and a retained previous generation.
- Untitled documents are recovered by stable ID even if the user renamed their tab.
- Explicit Save advances the file save point; automatic recovery advances only `recoveryRevision`.
- Session persistence records split topology and per-view state, but a single shared text payload for cloned/split views.
- Security-scoped bookmarks and raw file-system details live in infrastructure. Domain receives a `FileReferenceID` and display metadata.
- Restore is idempotent: replaying the same snapshot does not duplicate documents or tabs.
- External file changes never overwrite dirty content silently. Reload, compare, keep-buffer, and save-as are explicit outcomes.

## 5. Multiline document tabs

### 5.1 AppKit design

Use an `NSCollectionView` with a custom `MultilineTabLayout`, diffable data source, and host-rendered `DocumentTabItem` views.

The layout algorithm:

1. Measure each tab between configured minimum and maximum widths, reserving pin/dirty/close/icon hit regions.
2. Keep pinned tabs first and stable within their section.
3. Pack unpinned tabs row-major into the available width. Repacking never changes model order.
4. Compute intrinsic strip height as `rowCount * rowHeight + spacing` and publish it to the workspace controller.
5. In unlimited multiline mode, show every row. If the strip would consume more than the user-configured workspace limit, use an internally scrolling strip plus the searchable tab switcher; never silently discard a tab.
6. Keep the selected item visible without moving its model position. A width or window resize reflows only layout coordinates.

Required behavior:

- Modes: single-line with overflow, multiline wrap, and optional vertical document list; the setting applies per window and persists in the session.
- Mouse: select, middle-click close, close/pin buttons, context menu, local drag reorder, drag between groups/windows, and file drop to open.
- Keyboard: macOS focus-ring behavior, Control-Tab history switching, Command-Shift-brackets for adjacent tabs, and full keyboard navigation when the strip has focus.
- Accessibility: each item exposes title, selected/pinned/modified state, close action, index/row description, and stable accessibility identifiers.
- The dirty marker is state, not title punctuation. Truncation preserves extension when useful and the full path appears in help/tooltip and the tab switcher.
- Drag insertion uses the model order key and handles row transitions. Reflow during drag is animated but reduced-motion settings disable nonessential animation.
- Closing the active tab follows a tested selection policy (most-recently-used by default, adjacent optional), independent of visual row packing.

Layout tests cover narrow/wide/Retina widths, mixed Unicode titles, pinned tabs, 1/50/500 tabs, drag across rows, dynamic type/accessibility sizes, RTL content titles, selected-item visibility, and window resizing. The NPP `TCS_MULTILINE` behavior is a parity reference, not a reason to inherit Windows row-selection quirks.

## 6. Plugin platform

### 6.1 Enforceable v1 topology

Plugin v1 has one fixed execution topology; there is no fallback that runs arbitrary plugin executables:

```text
signed .duckpad-plugin package (manifest + module.wasm + passive assets)
  -> Duckpad main app verifies package signature/hash and reads module bytes
    -> private NSXPCConnection sends bytes, PluginID, limits, and events
      -> DuckpadPluginRuntime.xpc [App Sandbox; no file/network/process entitlement]
        -> non-JIT WebAssembly interpreter
          -> one validated module instance/store per plugin
            -> allowlisted duckpad.* host imports only
              -> XPC effect request
                -> PluginCapabilityBroker in the main app
                  -> grant + scope + revision check
                    -> document / filesystem / network / tool / UI adapter
```

The main app is distributed directly, signed with Developer ID, notarized, App Sandbox enabled, and Hardened Runtime enabled. Direct distribution is the v1 decision; Mac App Store compatibility is not assumed. `DuckpadPluginRuntime.xpc` is bundled and signed by the same Duckpad team, has `com.apple.security.app-sandbox = true`, and has **none** of the file-user-selection, network client/server, automation, device, app-group, or process-expanding entitlements. It does not use `com.apple.security.inherit`, because it is the narrower privilege-separated XPC service rather than a directly launched child. The main app sends module/resource bytes and value messages; it passes no file URL, bookmark, environment block, file handle, or file descriptor to the service, and the plugin ABI exposes none.

This follows Apple's platform model: [XPC supports privilege isolation and launchd-managed crash recovery](https://developer.apple.com/documentation/xpc), [XPC services have their own restricted sandbox](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html), and [a directly launched helper inherits the launching app's sandbox while different privilege sets require XPC/helper separation](https://developer.apple.com/documentation/security/discovering-and-diagnosing-app-sandbox-violations). Hardened Runtime remains strict: v1 does not request JIT, unsigned executable memory, disabled library validation, DYLD, or executable-memory exceptions; Apple documents those exceptions and recommends using only what is necessary in [Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime).

The embedded runtime uses an interpreter, not JIT or plugin-supplied native/AOT code. It instantiates WebAssembly Core modules with no WASI implementation. Module validation rejects imports in `wasi_snapshot_preview1`, `wasi:*`, or any namespace other than the versioned `duckpad:v1/*` allowlist. WebAssembly itself has no ambient access; environment interaction occurs only through embedder-provided imports, as stated in the [WebAssembly Core security considerations](https://webassembly.github.io/spec/core/intro/introduction.html#security-considerations). Consequently a plugin has no direct file, socket, process, pasteboard, AppKit, Objective-C runtime, Scintilla, bookmark, or syscall route.

Every plugin gets its own store, linear-memory maximum, table/stack limits, fuel budget, wall-clock deadline, bounded output queue, cancellation token, and opaque `PluginID`. A trap terminates that instance. An XPC runtime failure invalidates all connections, never the editor; launchd restart is followed by deterministic revalidation/reactivation from host-owned state. Persistent plugin state is a quota-bound broker key-value API, not XPC-service filesystem access.

Explicitly prohibited in v1:

- plugin-provided Mach-O executables, dylibs, XPC services, app extensions, shell scripts, JavaScript runtimes, JIT/AOT native pages, or dynamic libraries
- arbitrary `Process`, `posix_spawn`, shell, socket, file-descriptor, path, URL-session, pasteboard, Accessibility, Apple Event, or Objective-C bridging imports
- passing security-scoped bookmarks, raw paths, AppKit objects, Scintilla pointers/messages, or XPC endpoint objects to a module
- weakening the XPC entitlements to make an extension work; a feature that needs weakening remains unavailable until it has a narrower broker design

Bundled Scintilla/Lexilla and reviewed first-party application code are not third-party plugins and may run in the appropriate trusted process. They do not expand the WebAssembly plugin import surface.

### 6.2 Signing, installation, and distribution

A plugin package is a `.duckpad-plugin` directory containing `plugin.json`, one WebAssembly Core module, passive local assets, `SHA256SUMS`, publisher identity, and `SIGNATURE.ed25519`. `SHA256SUMS` is a UTF-8, path-sorted list covering the exact bytes of the manifest, module, and every asset; `SIGNATURE.ed25519` is a CryptoKit Curve25519 signing signature over a version-domain separator plus the exact `SHA256SUMS` bytes. The registry binds `(publisher ID, key ID)` to the public key. Installation is transactional into the app container after all of these checks pass:

1. canonical manifest parsing, schema/API compatibility, package-root containment, compressed/uncompressed size limits, and duplicate-ID rejection;
2. hash verification for every declared file and rejection of undeclared executable/native content;
3. publisher signature verification against the Duckpad registry or a user-imported trust root;
4. WebAssembly validation, import allowlist, memory/table limits, and forbidden WASI/native metadata checks before activation;
5. a user review of publisher, requested capabilities/scopes, panel/language contributions, and update changes.

Official Duckpad builds and all nested native code are Developer ID signed with Hardened Runtime and notarized. Apple requires Hardened Runtime for notarization and explains Developer ID distribution in [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution). Release CI verifies the sealed app with `codesign`, `spctl`, notarization staple/assessment, and an exact entitlement allowlist for every Mach-O. Plugin packages contain no Mach-O and cannot alter the app code signature.

Unsigned packages are available only in an explicit Developer Mode that shows a persistent warning, records a local audit entry, and still uses the identical XPC/WebAssembly sandbox and capability denial. Developer Mode never enables a native-code path. A plugin update is a new package: changed publisher identity, module hash, capabilities, broker scopes, panels, or language/tool declarations disables automatic activation and requires review; capability additions always require new consent.

### 6.3 Manifest and versioning

An illustrative v1 manifest is:

```json
{
  "schemaVersion": 1,
  "id": "com.example.symbol-tools",
  "name": "Symbol Tools",
  "version": "1.2.0",
  "publisher": "Example",
  "engines": { "duckpad": ">=1.0.0 <2.0.0", "pluginApi": "1.x" },
  "runtime": { "kind": "wasm-core", "module": "module.wasm", "abi": "duckpad-wasm-1" },
  "activationEvents": [
    "onCommand:com.example.symbol-tools.sortLines",
    "onPanel:com.example.symbol-tools.symbols"
  ],
  "capabilities": [
    { "id": "documents.read", "scope": "active" },
    { "id": "documents.write", "scope": "active" }
  ],
  "contributes": {
    "commands": [{
      "id": "com.example.symbol-tools.sortLines",
      "title": "Sort Selected Lines"
    }],
    "panels": [{
      "id": "com.example.symbol-tools.symbols",
      "title": "Symbols",
      "location": "sidebar.trailing",
      "viewSchema": "duckpad.panel.v1"
    }],
    "languages": []
  }
}
```

Manifest rules:

- The plugin ID is reverse-DNS and globally stable. Every command, panel, setting, and action ID starts with the exact manifest plugin ID plus `.`; the host rejects unowned IDs.
- Unknown required fields or an unsupported `schemaVersion`, runtime kind, ABI major, or API range reject installation; unknown optional contribution fields are ignored with diagnostics.
- Paths are canonical package-relative paths and cannot escape the package root or resolve through links.
- Contributions are inert until activation and do not imply a permission grant.
- The manifest, module/asset hashes, publisher identity, host/API versions, and granted scopes are recorded together.

The SDK/API uses semantic versioning. The v1 module ABI is defined by versioned WIT/interface definitions and canonical value envelopes; generated bindings are shipped first for Rust and C-compatible WebAssembly toolchains. The module exports allocation/deallocation, activation, event handling, panel rendering, and state serialization functions. It imports only capability-neutral logging/time/cancellation primitives plus effect requests in `duckpad:v1/*`; the broker still validates every effect. A major version may break; a minor version only adds negotiable imports, events, fields, or feature flags. Deprecations remain for at least one host major version and appear in plugin diagnostics.

Activation handshake supplies only value data: host/API versions, supported feature flags, locale, granted capability IDs/scopes, quotas, and a nonce-bound instance ID. No compatible major version means disabled with an actionable error. Commands are namespaced and cancellable; event subscriptions are explicit; high-frequency edit events are coalesced and carry revisions. Read APIs return immutable bounded snapshots/streams. Write APIs return `WorkspaceEdit` with `expectedRevision`, so stale edits fail. SDK v1 uses UTF-8 byte offsets for Scintilla-facing edits and provides explicit UTF-16 LSP conversion helpers.

### 6.4 Capability broker

Capability declaration is a request, not authority. All capabilities begin denied; the user grants a scope, the main-app broker stores it, and every request is rechecked against plugin instance, operation, current scope, document revision, deadline, rate, and payload limit. Revocation takes effect before the next operation and cancels in-flight work where safe.

| Capability | Brokered grant | Direct access that remains impossible |
| --- | --- | --- |
| `documents.read` | Bounded snapshots of active, selected, or explicitly scoped open documents | Scintilla pointers, recovery files, session DB, arbitrary documents |
| `documents.write` | Revision-checked `WorkspaceEdit` on scoped documents | Direct buffer mutation, silent save, undo-history replacement |
| `workspace.read` | Read/list by opaque workspace-resource ID under user-approved security-scoped roots | Raw bookmark transfer, home traversal, arbitrary path open |
| `workspace.write` | Atomic write/create by opaque resource ID under approved roots, with conflict policy | Writes outside scope, executable-bit change, recovery/session mutation |
| `network.fetch` | Main-app `URLSession` request restricted to approved HTTPS origins, methods, size, redirects, and timeout | Socket/DNS API, local network, credentials/cookies/keychain by implication |
| `process.runTool` | **Unavailable in v1.** Every declaration/request returns `unsupportedCapability`; its parity item remains **Missing**. | No plugin-triggered tool, `fork`, `exec`, `Process`, shell, arbitrary executable/path, or inherited secret |
| `clipboard.read` / `clipboard.write` | One foreground, user-associated pasteboard operation | Polling or background capture |
| `ui.notifications` | Rate-limited host-rendered notification | Arbitrary windows, AppKit, Accessibility automation, Apple Events |
| `ui.panel` | Host-rendered `duckpad.panel.v1` tree and typed actions | HTML/JavaScript, native view code, remote image load, hidden input capture |

The main app holds only the entitlements required by its product and brokers: user-selected file access/security-scoped bookmarks and network client access where shipped. `process.runTool` does not exist in the v1 runtime import allowlist, cannot be granted during installation or at runtime, and cannot be used by an LSP descriptor. Unsupported tool requests are audited and rejected before any path lookup or process API call.

#### 6.4.1 Future `process.runTool` enablement contract

`process.runTool` may move out of `Unavailable / Missing` only through a separate security ADR and independent review after all section 6.6 gates pass. It will remain a foreground, per-tool grant rather than general code hosting. The approved native tool is a distinct trust boundary: it inherits the main app's App Sandbox and is not confined by the WebAssembly import allowlist; [Apple documents that directly launched helpers inherit the parent's sandbox](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app).

Each supported tool has a host-owned, versioned `ToolDefinition`, never plugin-supplied metadata. Its contract contains:

- `toolID` and an executable identity tuple: immutable-vault snapshot ID, canonical relative executable, SHA-256, Team ID, signing identifier, designated requirement, CDHash, architecture set, notarization result, and package version;
- a finite ordered argument schema. Each field is a typed `boolean`, closed `enum`, range-bounded integer, length/character-bounded scalar string, opaque document/resource ID, or broker-produced literal. The schema defines the exact token expansion, whether a value may begin with `-`, normalization, maximum byte length/count, and mutual-exclusion/dependency rules;
- fixed broker arguments that disable the tool's implicit configuration, response-file, plugin/module, startup script, extension, current-directory, parent-directory, and environment-based discovery. A tool that cannot disable those discovery paths is ineligible;
- stdin policy (`none`, bounded UTF-8 snapshot, or bounded broker-produced bytes), separate bounded stdout/stderr policies, accepted encodings, maximum total bytes/lines, backpressure, truncation-as-error, and cancellation behavior;
- a host-selected working-directory policy (`emptyBrokerScratch` or an explicitly approved opaque workspace resource), with no plugin/package/config directory and no plugin-supplied raw path;
- an explicit empty-or-fixed environment allowlist. The plugin cannot set or discover `PATH`, `HOME`, `TMPDIR`, `PWD`, shell variables, loader variables, XDG/tool config variables, credentials, Duckpad paths, plugin paths, or inherited app environment. If a tool requires `HOME`/temporary storage, the broker supplies a fresh private scratch directory and destroys it after the run;
- wall-clock, CPU, memory, open-file, output, scratch-disk, and child-process limits; no TTY, inherited handles, interactive prompt, network grant by implication, or detached/background lifetime. Timeout, quota breach, unexpected child, or host termination kills the complete supervised process tree and returns a typed failure.

The plugin sends a typed field-value map, never raw argv, an executable URL, environment, workdir, stdin file, response file, or config/plugin/module path. The broker validates all fields, expands tokens itself without a shell, inserts the definition's fixed `--`/sentinel where applicable, and logs the redacted expansion. It rejects arguments that a tool can reinterpret as any of the following unless that exact semantic is a fixed host-owned token: `@response`, config/startup/rc path, plugin/extension/module/load path, include/search path, output/executable path, working directory, environment file, file descriptor, device path, URL, command/eval/script text, nested argument source, or equivalent abbreviated/Unicode form.

Executable identity is bound without a path-check/path-use race. Approval copies the complete signed code object into a host-only, non-plugin-writable tool vault using a temporary sibling and atomic rename; the broker rejects links and unexpected nested code, verifies ownership/mode and the full identity tuple after the copy, and records the vault generation. Immediately before every launch it opens the vault generation without following links, rechecks file identity/hash/code-signing/notarization and expected bundle contents, and launches only that generation. Replacement, mutation, identity drift, writable parent, or verification mismatch invalidates the grant before spawn. The child audit token and running-code identity are checked against the approved tuple; mismatch terminates the process and revokes the generation.

No compatibility or LSP requirement can weaken these rules. If the exact supported-macOS spike cannot prove typed expansion, identity binding, inherited containment, bounded execution, cancellation, and the escape fixtures below, `process.runTool` remains unavailable and Missing.

Permission UI explains publisher, effect, scope, duration, and data destination and offers deny/once/always only where meaningful. Grants are reviewable and revocable in Settings. A file, network origin, or tool granted to one plugin is not visible to another.

### 6.5 Host-rendered declarative panel v1

Panels are a required v1 contribution, not a future web-view option. AppKit owns all panel views. A plugin supplies a validated immutable `PanelDocument` value with this top-level contract:

```json
{
  "schema": "duckpad.panel.v1",
  "panelID": "com.example.symbol-tools.symbols",
  "instanceID": "host-issued-opaque-id",
  "revision": 7,
  "title": "Symbols",
  "root": {
    "type": "vstack",
    "id": "root",
    "children": [
      { "type": "textField", "id": "filter", "label": "Filter symbols", "value": "" },
      { "type": "list", "id": "results", "label": "Symbols", "selectionMode": "single",
        "items": [{ "id": "symbol-1", "primaryText": "render", "secondaryText": "Line 42" }] },
      { "type": "button", "id": "open", "title": "Open Symbol", "enabled": true,
        "actionID": "com.example.symbol-tools.openSymbol" }
    ]
  }
}
```

Allowed nodes are versioned and finite: `vstack`, `hstack`, `group`, `scroll`, `text`, sanitized host-rendered `markdown`, `image` from verified package assets, `separator`, `button`, `toggle`, `textField`, `searchField`, `select`, `list`, `tree`, `table`, `progress`, and `spacer`. Schema limits depth, nodes, text/asset bytes, list rows, update frequency, and retained state. Unknown required nodes/attributes reject the revision; optional unknown attributes are ignored with diagnostics. Layout uses host spacing and typography; plugins cannot set coordinates, fonts, native class names, selectors, URLs, scripts, stylesheets, accessibility hierarchy, or event handlers. Links, file reveals, clipboard, network content, and commands are explicit host actions and pass through their corresponding capabilities.

Lifecycle is deterministic:

1. **register** — validate manifest contribution without activating code; host reserves `panelID`, location (`sidebar.leading`, `sidebar.trailing`, or `bottom`), title, icon asset, and default visibility;
2. **activate** — first reveal or declared activation event creates an opaque `instanceID`; runtime receives `panel/open` with restored host state and must return revision 1 within deadline;
3. **render/update** — host validates and renders the full document or an ID-addressed patch whose `baseRevision` matches; stale, oversized, or invalid updates are rejected without replacing the last valid UI;
4. **action** — AppKit emits `{instanceID, panelID, actionID, sourceNodeID, uiRevision, value, selectionIDs, modifiers}` only after native validation; the plugin returns no effect, a revisioned UI patch, and/or separately authorized broker requests;
5. **hide/suspend** — host sends `panel/visibilityChanged`; hidden panels receive no high-frequency UI events and keep only quota-bound host state;
6. **restore** — window/session restore recreates placement, size, selection/focus hints, and plugin-serialized state only after schema/API compatibility checks;
7. **dispose/deactivate** — cancellation closes subscriptions and invalidates `instanceID`; late actions/patches are discarded.

Accessibility is a host contract. Every interactive node requires a nonempty localized label or an unambiguous host-derived title; optional help, value, validation error, and live-region priority are value fields. AppKit maps nodes to native accessibility roles/actions, owns focus order and keyboard traversal, respects Reduce Motion/Increase Contrast, preserves VoiceOver focus across revisioned patches by stable node ID, and coalesces live announcements. A panel cannot override roles or hide interactive content from accessibility. Missing labels, duplicate IDs, focus traps, keyboard-inaccessible actions, stale action dispatch, or VoiceOver focus loss fail the panel acceptance gate.

This surface preserves the VS Code-class extension direction—commands, events, document/editor operations, decorations, settings, languages, and interactive panels—without allowing extension-provided native/web code into the UI process. Future schema minors may add host-rendered nodes; arbitrary HTML/JavaScript/native panels require a separate security ADR and are outside v1.

### 6.6 MUST security and distribution gates

Plugin v1 is **not releasable** until every gate below passes on every supported macOS major version and architecture. These are MUST gates, not best-effort tests:

1. **Topology and entitlements** — CI enumerates every nested Mach-O and proves Developer ID team identity, Hardened Runtime, notarization assessment, and exact entitlements. `DuckpadPluginRuntime.xpc` has App Sandbox only and no file/network/process/JIT/unsigned-memory/library-validation exception. Any extra entitlement fails the build.
2. **Module import denial** — fixtures importing WASI, unknown namespaces, socket/file/process-shaped imports, excessive memory/tables, or native metadata fail before instantiation. A valid module receives only the documented `duckpad:v1/*` imports.
3. **Direct filesystem denial** — a native red-team probe compiled into a test-only build of the same XPC target fails to open/read/write outside its minimal container, including the user's home, workspace, recovery store, plugin package, and security-scoped roots. Tests assert `EPERM`/sandbox denial and capture App Sandbox diagnostic evidence. The WebAssembly fixture has no file import at all.
4. **Direct network denial** — the same XPC probe cannot resolve/connect to loopback, local-network, or public endpoints and cannot create listening sockets. A module with no `network.fetch` grant gets broker `permissionDenied`; an origin/redirect/method/size outside a grant also fails.
5. **Direct process-route denial and v1 unavailability** — malicious modules requesting WASI or unknown process/shell imports fail before instantiation, runtime interface inspection proves there is no process import, and source/dependency policy rejects `Process`, `posix_spawn`, `fork`, `exec`, `system`, shell, and executable-file-descriptor calls from the production XPC target. Every v1 `process.runTool` declaration/request returns `unsupportedCapability` before tool/path discovery and no child appears. A test-only native probe records platform inheritance behavior; if macOS permits a child launch from native test code, that child must inherit the same minimal XPC sandbox and fail the filesystem/network probes. Thus the MUST is absence of any untrusted-module route to process creation, not an unsupported claim that App Sandbox universally rejects `posix_spawn`.
6. **Broker scope denial** — negative fixtures cover no grant, another plugin's grant, expired/once-used grant, out-of-root file ID, symlink escape, stale bookmark, wrong document/revision, disallowed redirect, DNS rebinding/local address, tool signature change, environment injection, and payload/rate/deadline overflow.
7. **Direct-access regression** — tests inspect module imports and runtime exports, XPC request classes, open file descriptors, child processes, and sandbox logs while malicious fixtures run. A denial inferred only from a mocked broker does not pass.
8. **Isolation and recovery** — trap, infinite loop, fuel exhaustion, memory exhaustion, malformed value, runtime crash, connection interruption, and crash loop never block typing/save/recovery or corrupt another plugin's state; XPC restart restores only validated host-owned state.
9. **Panel safety and accessibility** — invalid/oversized trees, unverified assets, link/capability bypass, stale actions/patches, focus traps, keyboard traversal, VoiceOver labels/actions/focus restoration, Reduce Motion, and high-frequency updates pass automated and manual gates.
10. **Supply chain and updates** — tampered hash/signature, untrusted publisher, native executable smuggling, path/link escape, downgrade, changed capabilities/panels/languages, and revoked publisher all reject atomically. Stable and Developer Mode use the same runtime isolation.
11. **Future ToolBroker enablement** — this gate is required only to change `process.runTool` from Unavailable/Missing and must pass before that change. Contract tests cover every `ToolDefinition` field and prove plugins cannot provide raw argv, executable identity/path, environment, workdir, response/config/startup/plugin/extension/module/include/search/output path, stdin file, file descriptor, URL, command/eval/script text, or nested argument source. Argument escape fixtures include leading/embedded option prefixes, `--`, `@response`, long/short config and load aliases, repeated/conflicting keys, `../` and absolute paths, links, `/dev/fd`, `file:` URLs, NUL/newline/control bytes, invalid UTF-8, Unicode normalization/confusable dashes, quotes/backslashes/whitespace, shell metacharacters and substitutions, environment syntax, oversized/repeated values, and tool-specific implicit config discovery. Identity tests replace/symlink/mutate/resign the executable before approval, after vault copy, between preflight and spawn, and while running; every mismatch fails closed. Execution tests prove the exact stdin mode/limit, separate stdout/stderr limit and backpressure, no TTY/inherited handles, broker-owned workdir/scratch cleanup, empty/fixed environment, wall/CPU/memory/file/output/disk/child limits, full-tree cancellation, and no ambient network/resource access. A happy-path signature test without these adversarial fixtures cannot enable the capability.

Apple's [App Sandbox violation diagnostics](https://developer.apple.com/documentation/security/discovering-and-diagnosing-app-sandbox-violations) are captured with the negative test artifacts. A passing host-API mock, a successful happy path, process separation alone, or “out of process if possible” is insufficient evidence.

## 7. Language support decision

### ADR: Lexilla for styling, LSP for intelligence, Tree-sitter deferred

**Decision:** Bundle Lexilla with the Scintilla adapter for baseline syntax highlighting and folding across many languages. Add LSP clients behind `LanguageServicePort` for completion, hover, go-to-definition, references, symbols, formatting, and diagnostics. Do not put Tree-sitter on the critical path for the first 90% compatibility objective.

**Why:**

- Lexilla is the native lexer companion to Scintilla and the reference source already demonstrates `ILexer5`/`SCI_SETILEXER` integration.
- Replacing Lexilla styling with Tree-sitter would require an additional incremental parse-to-Scintilla-style pipeline, injection handling, error recovery policy, and duplicated language packaging before basic NPP parity is reached.
- Tree-sitter remains valuable for structural selection, syntax-aware transformations, and languages where a concrete feature cannot be delivered reliably by Lexilla/LSP. It should be introduced behind an analysis port with measurements and a feature owner, not as a second universal syntax source.

Language contributions declare extensions, filenames, shebangs, a bundled Lexilla lexer/theme mapping, comment/fold rules, semantic feature registrations, and an optional LSP descriptor. A third-party package cannot contain or inject a lexer dylib or native language-server executable. A new native lexer must be reviewed, pinned, licensed, signed, and shipped as a trusted Duckpad component; otherwise language-specific computation runs in the same capability-less WebAssembly runtime described in section 6.1.

LSP is owned by `LanguageServiceBroker`, not launched by plugin code. V1 supports two provider forms without adding a second plugin topology:

1. a reviewed Duckpad-bundled, Developer-ID-signed language server launched as a signed helper under the app sandbox;
2. a language provider compiled to the plugin WebAssembly ABI when its implementation supports that target.

A language manifest may name a logical bundled-server requirement and initialization options, but never a raw executable or shell command. A user-installed external LSP is unavailable in v1 because `process.runTool` is Unavailable/Missing; it may be added only after the future enablement contract and every section 6.6 gate pass. If no approved provider is available, Lexilla highlighting/folding and plain-text editing still work while LSP features report unavailable; this preserves broad Notepad++-class language coverage without pretending every language has a shippable sandboxed server. The broker owns stdio framing, translates UTF-8 Scintilla positions to UTF-16 LSP positions, synchronizes by document revision/version, redacts paths outside granted workspace scope, debounces changes, bounds server output, and terminates servers on workspace/plugin shutdown. Diagnostics are mapped back only if their document version is current.

## 8. Compatibility and native UX ADRs

### ADR-001 — Native macOS shell

- **Decision:** Swift/AppKit owns the product shell.
- **Accepted trade-off:** macOS menu placement, Command shortcuts, document/window conventions, Services, IME, accessibility, and drag/drop may visibly differ from Notepad++.
- **Parity rule:** differing appearance is acceptable; loss of the corresponding user outcome is not.

### ADR-002 — Scintilla behind a bridge

- **Decision:** retain the editing semantics that make a 90% port achievable while containing C++/Objective-C++ details.
- **Rejected:** rewriting the text engine in Swift for the first milestone; exposing generic `sendMessage` to the app or plugins.
- **Exit condition:** replace Scintilla only through ports and compatibility tests, never through a presentation rewrite.

### ADR-003 — Clean boundaries before feature breadth

- **Decision:** each ported feature enters through a use case and a boundary contract, even when the reference implementation is a single Win32 command path.
- **Guardrail:** this must not become architecture ceremony that delays parity. A feature may begin with one focused use case and one adapter; abstractions require a real boundary, not anticipated reuse.
- **Enforcement:** dependency tests/lint reject AppKit/Scintilla imports in Domain/Application and direct infrastructure calls from Presentation.

### ADR-004 — Behavior compatibility, not source compatibility

- **Decision:** maintain a feature/behavior matrix with `reference behavior`, `Duckpad behavior`, `native divergence`, automated/manual evidence, and status.
- **90% calculation:** use agreed weighted user-visible behaviors, not menu count or copied code. Core editing, search/replace, buffers/tabs, sessions/recovery, encodings/EOL, languages, file-change handling, split views, macros/commands, and plugin extensibility cannot be omitted from the denominator.
- **Gate:** a behavior counts as ported only when its current-state evidence passes on supported macOS versions. “Implemented” without UX/test evidence is incomplete.

### ADR-005 — Safe extensibility over NPP ABI compatibility

- **Decision:** provide the sandboxed WebAssembly Duckpad SDK, broker APIs, declarative panels, and a migration guide; do not emulate `NppData`, `HWND`, DLL exports, native plugin execution, or unrestricted Scintilla messages.
- **Consequence:** existing Notepad++ binary plugins do not run unchanged. Recreating the Win32 ABI would undermine macOS integration and enforceable least privilege, and is not required to preserve the user experience target.

## 9. Test boundaries and release gates

| Boundary | Required evidence |
| --- | --- |
| Domain | State-machine/property tests for untitled/save/conflict/missing, tab ownership, revision monotonicity, close policy, and session invariants. No AppKit test host. |
| Application | Use-case tests with fake ports for open/paste/edit/save/save-as/close/recover/restore/external-change/split/plugin edit. Cancellation and error outcomes are explicit. |
| Scintilla bridge | Objective-C++ contract tests for lifecycle, notification copying, UTF-8 offsets, shared documents, undo/save points, selections, wrap, folds, encoding/EOL, and lexer changes. Run with Address/Thread Sanitizer where supported. |
| Language | Golden highlighting/folding fixtures per bundled language family; LSP broker/provider-form tests; no-provider fallback; tool/workspace scope denial; stale-diagnostic and UTF-8↔UTF-16 conversion tests. |
| Persistence | Crash-injection tests at every recovery atomic-write stage, checksum corruption, previous-generation fallback, schema migration, large scratch buffers, and restore idempotency. |
| Files | Integration tests for atomic save, permissions, rename/delete, external edits, network/removable volumes, security-scoped bookmarks, and conflict preservation. |
| Tabs/AppKit | Layout unit tests plus snapshot/XCUITests for multiline reflow, reorder, split/window drag, accessibility actions, focus, shortcuts, selected visibility, and 1/50/500 tabs. |
| Plugins | Every section 6.6 MUST gate: exact XPC entitlements/signing/notarization; forbidden-import and direct filesystem/network/process denial; broker scope/revocation; stale edit; malformed ABI/fuzz; limits/backpressure; trap/crash/restart; package signature/update; declarative-panel lifecycle/safety/accessibility. Mock-only denial is insufficient. |
| End-to-end parity | Scenario tests derived from the compatibility matrix on every supported macOS major version and both Apple Silicon and supported Intel builds, if Intel remains in the product matrix. |
| Performance | Typing latency, launch/restore, search, recovery overhead, 50/500 tabs, large-file memory, lexer/LSP load, and plugin event storms against published budgets. |
| Licensing/supply chain | Dependency lock/hash verification, SBOM, license-notice bundle, GPL-copy detector/review checklist, signing/notarization, and plugin package provenance. |

No plugin timeout, LSP crash, session-write failure, or syntax-highlighting failure may block typing or automatic recovery. Save failures must be visible and preserve the buffer. Performance tests report percentile distributions rather than a single warm run.

## 10. License boundary

This is an engineering boundary, not legal advice:

- The Notepad++ application tree is distributed under GNU GPL v3 **with the clarifications and exceptions described below in its local license text** ([`LICENSE:1-14`](../../notepad-plus-plus/LICENSE#L1-L14)). Duckpad may study its behavior, data concepts, and public interaction patterns, but contributors must not paste or mechanically translate NPP application implementation into Duckpad unless the project deliberately accepts the resulting license obligations after legal review.
- New Duckpad source should cite behavior specifications or local reference locations in design/review notes, not carry NPP code comments or structurally translated Win32 functions.
- Scintilla and Lexilla use the permissive notice license shown in [`scintilla/License.txt:1-20`](../../notepad-plus-plus/scintilla/License.txt#L1-L20) and [`lexilla/License.txt:1-20`](../../notepad-plus-plus/lexilla/License.txt#L1-L20). Preserve copyright and permission notices in source distributions, application acknowledgements, and third-party notices.
- Keep imported Scintilla/Lexilla sources in clearly identified dependency targets. Record upstream version/commit, local patches, build flags, and license text. Do not mix Duckpad domain code into the vendored tree.
- Every port review includes a provenance question: “Was any implementation copied or translated from GPL-covered NPP code?” An uncertain answer blocks merge until resolved.
- Plugin packages declare their own license. The marketplace/installer displays it and does not imply compatibility with Duckpad’s license.

## 11. First-milestone build order

1. Establish module targets and automated dependency rules.
2. Prove the Objective-C++ bridge with one Scintilla view, native IME, accessibility, notifications, and typed edit/snapshot operations.
3. Implement `Document`/`TextBufferState` use cases for untitled creation, paste, dirty state, explicit save, recovery, and restore.
4. Implement `NSCollectionView` single-line and multiline tab modes over the same `TabGroup` model; validate 50-tab reflow and split sharing.
5. Integrate bundled Lexilla and a first broker-owned LSP adapter without exposing either to domain/presentation; retain the no-provider plain-text fallback.
6. Spike the complete section 6.1 XPC/non-JIT-WebAssembly topology and pass every section 6.6 direct-access, entitlement, signing, broker, crash, panel, and update MUST gate before freezing Plugin API v1.
7. Establish the signed package/manifest/WIT SDK with sample command, document edit, language, and declarative-panel plugins; no sample may use an alternate runtime.
8. Expand from the compatibility matrix, requiring code review and evidence before each local Git commit.

## 12. Agent Work Log

| Field | Record |
| --- | --- |
| Agent | `/root/clean_architecture` — macOS/Clean Architecture/plugin-design sub-agent |
| Date | 2026-09-02 (Asia/Seoul) |
| Assigned scope | Produce the architecture wiki; resolve first-review M-02/M-03/m-02 and re-review m-01/m-02/m-05; no implementation, staging, or commit. |
| Skill used | `source-command-sc-design` to structure requirements, boundaries, ADRs, contracts, validation, and documentation. |
| Sources inspected | Local Notepad++ commit `dda973d2b`: `Buffer.h`, `Parameters.h`, `DocTabView.h`, `TabBar.cpp`, Scintilla Cocoa, NPP plugin manager, Lexilla interface, and NPP/Scintilla/Lexilla licenses at section 2 links; first review M-02/M-03/m-02; re-review m-01/m-02/m-05; Apple XPC, App Sandbox violation diagnostics, sandboxed helper, Hardened Runtime, and notarization documentation; WebAssembly Core security considerations. |
| Key findings | NPP's Win32 in-process plugin ABI cannot enforce macOS least privilege; direct helpers inherit parent access; XPC plus no-WASI WebAssembly creates a testable boundary; panels need a host-rendered v1 contract; a future approved native tool is still a confused-deputy/TOCTOU surface unless its arguments, discovery, identity, I/O, workdir, and resources are host-typed and adversarially tested. |
| Decisions produced | Preserve prior Swift/AppKit/Clean Architecture/model/tab/Lexilla+LSP decisions; use the fixed XPC/non-JIT-WebAssembly topology and `duckpad.panel.v1`; keep `process.runTool` Unavailable/Missing in v1 and external LSP disabled; require a separate reviewed ToolDefinition/immutable-vault/escape-fixture gate before future enablement; namespace all example contribution IDs under `com.example.symbol-tools`; remove duplicate LSP rationale; retain pinned source/license evidence. |
| Validation | Confirm all local Markdown targets exist, heading structure is unique, example command/panel/action IDs are manifest-owned, duplicate LSP rationale is absent, whitespace checks pass, and no file is staged. |
| Files changed | `docs/wiki/02-clean-architecture-and-plugins.md` only. |
| Commit | None, as required. |
