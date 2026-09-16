# Security and architecture audit — 2026-09-16

Baseline: `a0b54c1b6a05a73022dba1f320577e1c7ac11d2e` (`origin/main`).
Working branch: `fix/security-architecture-audit`.

The audit inspected package dependencies, extension import/verification/storage,
native installation/loading, update downloads, Markdown rendering/resources,
and representative document/recovery filesystem boundaries. It combines static
inspection with the regression tests below; it is not a penetration-test or a
proof that the entire application is free of vulnerabilities. Existing changes
in the primary checkout and other task worktrees were excluded.

## Fixed findings

| ID | Priority | Finding and effect | Resolution |
| --- | --- | --- | --- |
| SEC-01 | P1 | A `.duckpad-plugin` containing a FIFO can block package discovery/import before signature verification. Policy and service-state readers also open FIFOs before checking file type, so a corrupt local file can stall these actors. | Open with `O_NONBLOCK`, then retain the existing descriptor-based regular-file checks. Add `O_CLOEXEC` to the state reader. |
| SEC-02 | P2 | App update checking used `URLSession.data(for:)`; its 1 MiB check ran after the complete response was buffered. A faulty/compromised response from the fixed GitHub endpoint could exceed the intended memory bound. This is not an arbitrary-URL/SSRF finding. | Stream the response, reject oversized advertised lengths, enforce the same limit when length is unknown or inaccurate, and reject HTTP errors before reading the body. |
| ARCH-01 | P2 | `LocalExtensionPlatform.swift` contained four independent actors: package verification, durable policy storage, XPC transport, and development process transport. This violated the repository's one-main-component-per-file rule and made security changes harder to review. | Extract the preference store and two transports into their own files without changing their public types or dependencies. This is responsibility separation, not a claim that the original SwiftPM dependency graph was inverted. |
| DOC-01 | P2 | The architecture proposal still described all plugins as WASM-only and stated signing/notarization guarantees that are not established by the local build. Native SDK 1.3.0 already supports in-process dylibs. | Add a prominent current-implementation notice and correct the runtime decision. Keep the historical proposal clearly distinguished from implemented guarantees. |
| SEC-03 | P1 | An image-named FIFO stalls the Markdown resource reader. | Use the injected Infrastructure reader to inspect opened descriptors and reject special files. Preserve large regular files and symlink images, with 64 KiB reads and cancellation. |
| ARCH-02 | P2 | Presentation compared complete native package files synchronously on `MainActor`. | Move verification behind an Application port into Infrastructure, pin the verified descriptors temporarily, and perform metadata revalidation immediately before native loading. |
| ARCH-03 | P2 | The Markdown panel owned global preference writes and security-scoped bookmark persistence. | Inject the image-access port; preserve the existing bookmark key/format in Infrastructure and balance grants on reload/close. |
| ARCH-04 | P2 | WindowController combined preview scheduling and several standalone UI components. | Extract `MarkdownPreviewCoordinator`, file-drop handling, persistence banner, path actions, notification observation, and smoke models. The controller decreased from 4,952 to 4,677 lines. |


Evidence:

- SEC-01: [package snapshot](../Sources/DuckpadInfrastructure/LocalExtensionPlatform.swift)
  `snapshotPackage`, [policy reader](../Sources/DuckpadInfrastructure/LocalExtensionPreferenceStore.swift)
  `loadPolicy`, and [service state](../Sources/DuckpadInfrastructure/LocalExtensionServiceStorage.swift)
  `load`. Before the fix, all three [FIFO regressions](../tests/DuckpadInfrastructureTests/ExtensionFIFOTests.swift)
  needed the rescue writer after two seconds and failed. After the fix, they
  rejected the FIFO in milliseconds. The package fixture needs no valid signature.
  Policy/state attacks additionally require access to the app's local storage;
  this finding does not demonstrate a sandbox escape or code execution.
- SEC-02: [release client](../Sources/DuckpadInfrastructure/GitHubReleaseClient.swift)
  `latestRelease`, with [download tests](../tests/DuckpadInfrastructureTests/GitHubReleaseDownloadTests.swift).
  An oversized declared response with a small valid body was accepted before
  the fix and rejected afterward. Unknown-length valid and oversized responses
  are also covered. No live GitHub attack or process-memory exhaustion was attempted.
- ARCH-01: [XPC transport](../Sources/DuckpadInfrastructure/XPCPluginHostTransport.swift),
  [development transport](../Sources/DuckpadInfrastructure/ProcessPluginHostTransport.swift),
  and the policy reader above. Extracted bodies were compared against the baseline;
  only the policy FIFO open flag changed.
- DOC-01: [architecture proposal](wiki/02-clean-architecture-and-plugins.md),
  [native SDK](plugins/native-sdk.md), [native loading](../Sources/DuckpadPresentation/NativePluginImage.swift),
  and [app entitlements](../Packaging/Duckpad.entitlements).

## Follow-up fixes and evidence

- SEC-03 / ARCH-03: [resource reader](../Sources/DuckpadInfrastructure/LocalPreviewResourceReader.swift),
  [image access](../Sources/DuckpadInfrastructure/LocalMarkdownImageAccess.swift),
  and their [ports](../Sources/DuckpadApplication/PreviewResourceReading.swift).
  The real loader's FIFO test failed before the fix and passed afterward.
  Tests also cover growing files, symlink targets, replacing a path after open,
  persistent bookmark compatibility, and grant release on reload/invalidation.
- Compatibility review: the initially added 32 MiB image and 50,000-character /
  500-edge Mermaid caps rejected previously supported input. They were removed;
  the Mermaid source and generated bundle now match the baseline. Regression
  tests exercise a resource larger than 32 MiB, a diagram longer than 50,000
  characters, and a diagram with 501 edges. All failed against the capped draft.
- ARCH-02: [verifier port](../Sources/DuckpadApplication/NativePluginInstallationVerifying.swift),
  [Infrastructure verifier](../Sources/DuckpadInfrastructure/LocalNativePluginInstallationVerifier.swift),
  and [pinned snapshot](../Sources/DuckpadInfrastructure/LocalVerifiedNativeInstallation.swift).
  Tests detect same-size edits even when modification time is restored,
  replaced files/directories, symlinks, FIFOs, and unexpected inventory.
  [Activation tests](../tests/DuckpadPresentationTests/NativePluginActivationTests.swift)
  verify revocation/re-enable races and load an isolated C ABI fixture to check
  multi-command activation, reuse, deactivation, and destruction. This fixture
  does not access clipboard, documents, UI, or the network.
- ARCH-04: [preview coordinator](../Sources/DuckpadPresentation/MarkdownPreviewCoordinator.swift)
  owns its panel, debounce task, buffer identity, and teardown. Window menu
  actions delegate to it. Real Scintilla/WebKit tests cover debounced captures,
  live typing, close/reopen, image drops, and preserved document state.

## Behavior-preservation review

The final runtime contract preserves existing large-content support, image
bookmark keys, automatic retry on native-service reconciliation, and normal
editor/plugin workflows. Resource readers reject special files that cannot be
handled as ordinary images/packages; the update client enforces its existing
1 MiB decoded-response policy while receiving data.

`DuckpadWindowController` now requires `previewResourceReader` and
`markdownImageAccess`; `ExtensionListServiceHost` requires `nativeVerifier`.
These are source-level constructor changes for clients of the Swift package.
All repository app, benchmark and test construction sites explicitly supply
providers. This includes `BuiltInMarkdownSmoke`, which was missed by the draft's
optional-nil defaults. No silent disabled-feature defaults remain.

Mermaid and decoded-image resource exhaustion remain possible for sufficiently
complex content. Fixed arbitrary content cutoffs are excluded to preserve
existing rendering behavior; process isolation or interruption mechanisms need
a separate design and validation effort.

## Remaining limits

The 4,677-line window controller still contains substantial search, editor-group,
and close/save coordination; the 2,361-line editor adapter also warrants future
workflow-specific refactoring. File length alone does not establish a defect,
so those unrelated workflows were not rewritten in this patch.

Native verification still ends in path-based `dlopen`. Metadata revalidation
catches the tested replacements and edits, but does not prove elimination of
all races with a process that can mutate the same user's private files between
validation and loading. Native plugins still intentionally execute with host
process authority. No sandbox escape or arbitrary-file exfiltration was
established. The existing remote-image policy is unchanged.

The Domain target has no project-target dependencies; Application depends on
Domain. No AppKit, WebKit, Scintilla, or Infrastructure imports were found in
those inner layers. UI-owned window geometry is not, by itself, a domain-layer
violation. Native plugins intentionally share Duckpad's authority after native
code consent; signatures establish package provenance, not isolation or benign
behavior. Redesigning that trust model would be a separate compatibility change.

## Validation

- Before/after evidence: three extension FIFO cases, the release response-size
  check, and the Markdown FIFO case failed before their fixes and passed after.
- Behavior review reproduced failures against the draft for a resource larger
  than 32 MiB, Mermaid diagrams over 50,000 characters / 500 edges, and automatic
  retry after native activation failure. These now pass.
- Final targeted selection: **25 tests in six suites passed**, covering Markdown
  resources/rendering, real Scintilla preview and image drops, native first
  install/reuse/multiple commands, automatic retry, and revoked activation.
- The native ABI test compiles and loads a self-contained C fixture. It does
  not access clipboard, user documents, plugin UI, or the network.
- Independent reviewer rechecked the final tracked diff and new files: **no
  remaining Blocker or Major found**. Signed candidate approval is handled
  separately by the repository commit-review gate.
- Final broad run: `swift test --no-parallel --filter
  'DuckpadInfrastructureTests|DuckpadPresentationTests|MarkdownPreviewIntegrationTests|NativeFileDropTests'`:
  **571 selected, no failures**, in 151.599 seconds. **565 exercised their bodies
  successfully**; one native-menu probe was explicitly skipped and five cases
  returned early for missing live-catalog / external Clipboard fixtures.
- `swift build --product DuckpadApp`: **passed**.
- `DUCKPAD_MARKDOWN_SMOKE=1 .build/debug/DuckpadApp`: **passed**. The built app
  opened and closed Markdown preview three times, rendered Rust highlighting,
  math fonts and Mermaid, and preserved source bytes and editor revision.
  This used the development executable, not a packaged sandboxed application.
- Native release app build (`--architecture native`): **passed**, version
  **0.6.3 (41)**. `verify_macos_app.sh` passed bundle, resource and signature
  checks. The packaged app launched with an active visible window, and the user
  confirmed the build. This is an ad-hoc-signed local build, not a notarized or
  universal release.
- `python3 scripts/verify_localizations.py`: **passed**, 698 strings and four
  plural entries across eight languages. Existing messages are reused.
- Mermaid source, bundled `preview.js`, and its provenance file match the
  baseline byte-for-byte. Earlier `npm test` passed four tests; rebuilding and
  auditing the same lockfile found zero registered vulnerabilities among 153
  dependencies. The final patch does not change JavaScript or dependencies.
- Extracted transport bodies match baseline apart from the policy FIFO flag;
  the six extracted UI/support component bodies match with visibility changes.
- The existing folder-search test was repaired to use the separate search panel
  and explicitly submit Return. No production search behavior changed.
- `git diff --check`: **passed**.

Not run: full application/editor suites, live catalog/Clipboard integration,
packaged sandbox/XPC installer smoke, third-party native plugin UI, universal
release packaging, Intel hardware, Developer ID signing, or notarization.
Real WebKit compatibility tests ran, but not an exhaustive hostile-render benchmark.
Tests used temporary documents and isolated image-bookmark preferences. No UI
strings changed; long-translation UI/accessibility was not manually rechecked in
every language. This change does not alter the app version or create a release.
