# Phase 26 — macOS distribution and sandboxed XPC runtime

Status: **Approved, committed and pushed** (`9a4c856845b75568e4fb599149cf79c112a8abed`)

## User-facing result

`scripts/build_macos_app.sh` now produces a native macOS `Duckpad.app`. The
default artifact is Universal 2 (`arm64` + `x86_64`); `--architecture native`
is available for quick local iteration. The application has the supplied
Duckpad ICNS, a productivity-app category, macOS 13 minimum, and Editor/Open
With declarations for plain text and source documents. The executable inside
the bundle is named `Duckpad`, so Finder, Dock, menu ownership, recent files,
and process presentation use the product name rather than the SwiftPM target
name.

SwiftPM resource bundles for the language registry, bundled signed extension,
and Scintilla cursors are installed under `Contents/Resources`. Runtime
resource lookup first resolves that packaged location and falls back to
`Bundle.module` for `swift run` and tests. The icon follows the same packaged
main-bundle-first rule.

## Security and process topology

The app is signed with Hardened Runtime and these exact sandbox entitlements:

- App Sandbox
- user-selected file read/write
- app-scoped security bookmarks

The embedded `DuckpadPluginRuntime.xpc` is signed before the outer app and has
App Sandbox as its **only** entitlement. It receives length-bounded Codable
value frames through an Objective-C `NSXPCConnection` protocol. File URLs,
bookmarks, descriptors, environment, AppKit objects, Scintilla handles, and
native plugin code never cross that protocol. The development-only
`DuckpadPluginHost` Process executable is not copied into the app.

`DuckpadPluginRuntimeCore` contains the single non-JIT WAMR execution path used
by both the development host and XPC service. The service runs requests on one
serial worker queue so its XPC listener remains responsive to interruption and
invalidation. The application transport permits one logical request at a time
and converges reply, proxy failure, interruption, invalidation, timeout, and
cancellation through a first-wins continuation. Timeout/cancel atomically sets
the current interpreter instruction budget to zero, which traps even a tight
branch loop; a short clean-process retirement is retained only as a final
fallback. A cancelled logical request remains cancelled across connection
restart attempts, and its original wall-clock deadline is never reset.

Pinned WAMR previously added `MAP_JIT` to every Apple Silicon mapping even when
JIT, Fast JIT, and AOT were compiled out. That made the least-privilege XPC
sandbox correctly reject linear-memory creation. The Darwin mapping condition
now adds `MAP_JIT` only when one of those execution modes is enabled. Duckpad
keeps all three disabled and grants no JIT or unsigned-executable-memory
entitlement.

Both Duckpad WAMR changes are generated, not hand-maintained exceptions.
`scripts/vendor_wamr_2_4_5.sh --verify` downloads the pinned official archive,
validates its SHA-256 and archive safety, applies the exact `MAP_JIT` and atomic
instruction-poll patches, then byte-compares all 168 generated files with the
vendored tree. `PROVENANCE.md` records normalized-upstream and patched hashes.

Ordinary Finder, Open panel, drag/drop, Save As, and recovered documents now
share an owner-refcounted security-scope authority. Each successful access
embeds an app-scoped bookmark in the recovered file binding and updates a
private, bounded 100-entry/4 MiB bookmark archive. Relaunch resolves stale or
moved bookmarks before the editor becomes interactive. Close, window teardown,
Save As rebinding, and Clear Recent Documents release or reconcile exact
leases. Sandboxed writes use coordinated Foundation safe-save semantics and
sync the resulting file before reporting success.

## Build, signing, and notarization

The default build uses ad-hoc signing so every local artifact still exercises
the complete nested signing, entitlement, Hardened Runtime, and verification
pipeline:

```sh
scripts/build_macos_app.sh --output /absolute/new/path/Duckpad.app
scripts/verify_macos_app.sh /absolute/new/path/Duckpad.app
scripts/smoke_macos_app.sh /absolute/new/path/Duckpad.app
```

The builder stages on the resolved output parent filesystem and publishes with
Darwin `RENAME_EXCL`. It rejects an existing or concurrently appearing output,
cross-volume staging, symlink/identity drift, nested merge, and partial-copy
publication, then re-verifies the exact final inode and signature. A release
operator supplies `--identity` with a Developer ID
Application identity. Supplying `--notary-profile` additionally creates a
temporary ZIP, submits it with `notarytool --wait`, staples the accepted ticket,
validates the staple, and runs Gatekeeper assessment. No credential, private
key, profile, archive, or built application is tracked.

Source validation can prove the pipeline and ad-hoc artifact. It cannot claim a
Developer ID/notarization success without the external certificate and notary
profile; that credentialed invocation remains a final release-operation gate.

## Validation evidence

- Debug modules: **349/349 PASS**.
- Release modules: **349/349 PASS**. Presentation tests run one per helper
  process because macOS 26.5 AppKit can crash a long-lived test helper while
  retiring a previous test's private window transform; every exact test passes
  in isolated Debug and Release helpers.
- Governance: exclusive bundle publication and review gate **10/10 PASS**.
- WAMR clean regeneration: **168/168 byte-identical PASS**.
- Shared runtime frame/executor equivalence and malformed trailing-frame test:
  PASS.
- Native packaged static verifier: resource/icon/XPC layout, document metadata,
  matching executable architectures, exact three-key app entitlement allowlist,
  exact one-key XPC allowlist, Hardened Runtime, nested and outer signature:
  PASS.
- Universal packaged static verifier: `x86_64 arm64` for app and XPC, PASS.
- LaunchServices `open -a` Finder/Open With smoke: queued delegate request binds
  the requested document, PASS.
- Two-launch packaged bookmark smoke: Finder opens an external file, recovery
  persists its bookmark, a fresh launch restores authority without a new URL,
  and Save updates the exact external file, PASS.
- Packaged signed extension smoke: bundled signature → XPC service → non-JIT
  WAMR → selection-scoped grouped Scintilla edit → undo, PASS.
- Packaged adversarial XPC smoke: nonterminating module timeout, explicit
  cancellation, and immediate valid Sort Lines recovery through the same
  on-demand service, PASS.
- The original content review's P26-01 through P26-04 were remediated and
  independently closed with 0 Blocker/Major/Minor findings.
  The smoke also exposed hidden Search panel constraint conflicts. Collapsed state
  now deactivates its vertical content constraints and reactivates them only
  while expanded; the repeated packaged smoke emitted no conflict.

## Delivery

The exact candidate
`a1fc44da20be62ad053b9fa3f7303b18eb2c3ffc0fbdf6e449598eba976446e1`
was independently approved, committed as `9a4c856`, post-commit audited, and
pushed to `origin/main`. The immutable receipt SHA-256 is
`ef219178995122613d0ed138726c490dd54d7ce601a932787c726cf3abcfbc86`.

## Scope boundaries

Open tabs remain unlimited; only recently-closed history is bounded to 100.
Macros remain excluded. Notarization is not asserted without credentials.
README and the ignored Notepad++ checkout are not part of this slice. The
user-owned doc04 and untracked Scintilla vendor script remain unstaged and
unchanged by this work.
