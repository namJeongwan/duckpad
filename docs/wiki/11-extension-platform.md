# Phase 8 — Secure extension platform MVP

Status: **CHANGES_REQUIRED review remediated; independent re-review pending**. The prior review remains authoritative until a new exact-candidate approval. This page does not authorize staging or commit.

## Supported boundary

Duckpad loads declarative `.duckpad-plugin` directories and runs a WebAssembly module in the separate `DuckpadPluginHost` executable. The MVP supports commands, keybinding metadata, snippets, themes, and language metadata. Command execution is the only active contribution today; declarative metadata is parsed and bounded but runtime merge remains deferred until each subsystem has a conflict policy.

User packages are disabled by default. They require explicit enablement and an immutable consent review bound to extension ID, publisher fingerprint, exact version/package digest, capability-schema digest, typed scope, and policy generation. An update or identity/capability change invalidates grants. Publisher revoke is a durable tombstone affecting every current package with that fingerprint; Reset only removes the tombstone and leaves packages disabled and ungranted.

The current SwiftPM `Process` helper transport is deliberately labeled **Developer Preview**. It is a separate crash/fault boundary with framed IPC and process teardown, but it is not XPC and is not an App Sandbox proof. Production composition executes only the exact built-in signed sample with the canonical self-owned sibling helper. User-extension execution remains disabled in release builds until a signed embedded helper/XPC target can be verified by Team ID and designated requirement without a path-to-exec race.

Deferred: WASI, JIT/AOT, native libraries, filesystem/network/process/environment/clock imports, zip/network installer, background extension activation, arbitrary webviews, debugger API, full VS Code/Notepad++ plugin API compatibility, and XPC signing/entitlements packaging.

## Runtime provenance

- Runtime: Bytecode Alliance WAMR `WAMR-2.4.5`, interpreter only.
- Official archive: `https://github.com/bytecodealliance/wasm-micro-runtime/archive/refs/tags/WAMR-2.4.5.tar.gz`
- Archive SHA-256: `1ab09d51099f276ca4a1d6629f6b589aab2bd0caa01445e05031a4bed22c199b`.
- License: Apache-2.0 WITH LLVM Exceptions; upstream `LICENSE` and notices are in `Vendor/WAMR/2.4.5`.
- Reproduction: `scripts/vendor_wamr_2_4_5.sh` requires an absent, non-symlink target, validates TLS/checksum/archive paths and vendored-subset links, stages privately, and publishes with Darwin `RENAME_EXCL`. An absent-target regeneration was byte-compared with the checked-in tree; both file trees have digest `1c7117d7bf9c394f312da79c80a199b27450d2e480f7f958cf528632e9b99ead`, including `PROVENANCE.md`.
- Build: classic interpreter, no JIT/AOT/WASI/libc/native imports/thread manager/shared memory/multi-module. Bulk-memory and reference-types decoding are enabled because pinned Rust output requires them; they add no host import. Raw module policy still requires zero imports and bounded explicit memory/table maxima.

The bundled sample is built by pinned `rustc 1.91.1` for `wasm32-unknown-unknown`, with bulk-memory codegen disabled where possible and fixed linker memory limits. Its module digest is `f73060b3d52a468ce1d804b741ce65a45465bc3d6f280f4e69a2aef677994278`. `SHA256SUMS` inventories every package entry and an embedded Ed25519 publisher key verifies the exact inventory. The stable public-key fingerprint is `18d068f648c2dac6ff0bed7f1bf92acef3c7c89fa54ca5ab028531cbb161773e`. `scripts/build_duckpad_text_tools_wasm.sh` is verification-only by default and never creates or rotates a publisher key; an optional explicitly supplied raw private seed must be outside the tracked worktree (normally `.git/duckpad-extension-signing/release-sample-1.private`) and mode `0600`, and is used only to prove that the existing signature has the same identity. No private key is present or shipped in this checkout. Bundled trust additionally requires the immutable `Bundle.module` path and an allowlisted package digest; a byte-identical copy in the user root remains user-imported.

## Architecture and security invariants

- Domain owns IDs, semver/API ranges, manifests/contributions, typed capability scopes, policy identities, invocation context, UTF-8 edits, and typed failures. It has no AppKit/process/filesystem dependency.
- Application resolves packages/commands deterministically, quarantines ambiguous IDs or command ownership, issues immutable consent/revoke tokens, persists authority before publishing it, captures one TabID/BufferID/revision/selection/text tuple, and reserves the workspace transaction before applying edits. The editor port reads only the selected Scintilla byte range for selection scope; document scope checks native byte length before any full copy. The 1 MiB command cap was exercised with a real 50 MiB buffer and a virtual 500 MiB document.
- Infrastructure opens a package directory with `O_NOFOLLOW|O_DIRECTORY`, enumerates that exact descriptor including dotfiles, reads each regular file once with `openat` and size/identity rechecks, then verifies exact inventory, checksums, signature, manifest, and the same immutable module bytes. Package count/per-file/aggregate caps are enforced.
- Manifest preflight rejects duplicate JSON keys recursively, unknown keys at every defined object level, duplicate capabilities/commands, oversized strings/arrays, unowned command IDs, unknown capabilities, and unsupported API/runtime.
- WAMR preflight rejects imports (including WASI), start functions, missing/unbounded/excess memory, excessive tables, LEB/section overflow, wrong ABI signatures, and oversized modules before `wasm_runtime_load`. The C facade also validates null/length and all module/output pointers.
- IPC is protocol-versioned JSON with a four-byte big-endian length, exact EOF, request/response/stderr caps, single-flight request IDs, and per-request timeout/cancel. Terminal cause is first-wins; teardown closes pipes, sends TERM, waits a bounded grace, sends KILL, and awaits one shared exit signal installed before launch. Read, timeout, cancellation, and catch paths share that signal instead of racing multiple `waitUntilExit` calls.
- `selection` commands receive only the selected UTF-8 slice. `activeDocument` commands require their separate exact grants. The host derives the absolute output range only from the validated typed scope; the numeric operation is opaque module dispatch.
- Returned edits must be bounded, valid UTF-8, scalar-boundary aligned, in range, uniquely positioned and non-overlapping. A selection transform may return an empty no-op or exactly one edit equal to the originally captured selection; before/after/straddling/extra edits are rejected before reservation. Duckpad sorts the canonical plan descending, rechecks identity/revision/capability after IPC and again after awaiting the workspace reservation, and applies one Scintilla undo group. Cancel, disable, publisher revoke, grant removal, close, tab, and edit races cannot publish a late edit. Cmd-Q and red-window close atomically close the use-case invocation admission gate and lock editor input, cancel the exact active request, and await transport teardown plus invocation completion before dirty review and the final recovery flush. A denied termination reopens both gates; an approved termination keeps them closed.
- Extension policy storage uses an owned non-symlink `0700` directory, `0600` file, strict byte/count/string caps, increasing generations, file fsync, atomic rename, and directory fsync. Because rename has already published the candidate, its generation is consumed even if directory fsync fails. A post-rename durability uncertainty permanently latches user authority off for that process; refresh and immediate retries cannot clear it, and only a new process may load the published policy.

## User experience

The native Extensions manager shows enabled state, publisher identity/fingerprint, version/package digest, exact capability+scope pairs, data destination, duration, and durable publisher-wide revoke consequence. Only enabled and currently authorized commands appear in the dynamic Extensions menu; items expose accessible labels. The bundled Text Tools sample provides **Sort Selected Lines** and **Trim Trailing Whitespace**, and traverses the same loader, signature, policy, IPC, WAMR, validation, reservation, undo, and recovery path as other packages.

## Verification

Primary commands:

```sh
scripts/build_duckpad_text_tools_wasm.sh
swift build
swift test --filter 'ExtensionPlatformTests|ExtensionWorkspaceUseCaseTests|ExtensionPresentation'
DUCKPAD_EXTENSION_SMOKE=1 swift run DuckpadApp
swift test
swift test -c release
```

Acceptance covers signed-bundle/runtime resolution; user-root trust downgrade; hidden/tampered/duplicate/nested/oversized packages; zero-import/memory/table/start/ABI/LEB policy; null bridge input; strict framing; private generation policy; identity-bound consent, disable/revoke/reset, least-privilege payload and output containment, busy/cancel and stale-tab behavior; held-transaction authority withdrawal; process timeout/cancel PID reap; dynamic authorized menu and disclosure; bounded 50/500 MiB capture; and a real Scintilla grouped-edit/undo/recovery round trip. The P8-01/P8-02 remediation adds direct tests for consumed uncertain generations, an in-process restart latch, queued invocation admission, denial resume, held-reservation idle joining, and termination ordering. The current debug, release, and empty-scratch debug inventories each passed all 184 tests split by SwiftPM test target (13 Domain, 62 Application, 40 Infrastructure, 38 Presentation, 31 EditorAdapter), avoiding cumulative AppKit test-process memory while executing the complete inventory. The helper lifecycle test now waits for explicit PID readiness and uses one shared exit signal; the full parallel Infrastructure target passed three consecutive 40-test stress rounds without the prior orphaned Swift task. The macOS 13 x86_64 release app/helper build, signed sample verification, and real signed-loader → Process host → WAMR → scoped grouped-edit smoke passed on the current bytes.

## Agent Work Log

### 2026-09-03 — P8-01/P8-02 direct remediation

- **Builder:** `/root` directly remediated the independent review findings; no implementation sub-agent was used.
- **P8-01:** policy rename now consumes the published generation before directory fsync. Any resulting durability uncertainty latches user authority off for the remaining process lifetime; reload/retry, consent, grant, revoke/reset, and user command invocation stay fail-closed until a new process instance.
- **P8-02:** termination now closes invocation admission, disables editor input, cancels the exact request, and joins transport plus the invocation defer path before dirty-tab review and final recovery flush. This also rejects a UI Task queued before termination but not yet admitted. A denied termination reopens admission; ordinary cancel/authority withdrawal remains non-blocking so a workspace reservation holder cannot deadlock.
- **Regression evidence:** new Application/Infrastructure/Presentation tests cover restart-only recovery, same-generation retry rejection, queued admission blocking, denial resume, held-reservation idle joining, and termination approval ordering. Current-byte debug/release/fresh each passed 184/184; Infrastructure passed three additional 40/40 stress rounds; macOS 13 x86_64 release build, sample signature verification, and real extension smoke passed.
- **Lifecycle hardening:** full-target stress exposed a Foundation `Process.waitUntilExit` multi-caller hang after the child had already exited. `/root` replaced competing wait paths with a pre-launch, lock-protected, multi-waiter exit signal and made the timeout/cancel test readiness-driven. This was direct root implementation, not delegated work.
- **Preservation:** the independent review verdict document was not rewritten. README and the ignored Notepad++ reference remain untouched; pre-existing unstaged doc04/old Scintilla vendor-script changes remain outside this remediation.

### 2026-09-03 — implementation and security hardening

- **Builder:** `/root/philosophy_parity` selected/pinned WAMR, implemented vendoring, Domain/Application/Infrastructure/host/Presentation/sample/tests, and ran the build/test/smoke commands. It did not stage or commit.
- **Architecture/security guards:** `/root` and `/root/clean_architecture` supplied fail-closed findings during construction: descriptor-based package identity, exact signed inventory and bundled attestation, Wasm import/memory/table/ABI limits, request-scoped cancellation/reap, durable identity-bound authority, bounded atomic editor capture/reservation, selection payload/output scoping, duplicate edit rejection, current-configuration helper resolution, publisher-key continuity, reproducible provenance, production Developer Preview boundary, dynamic UI consent, and adversarial acceptance coverage. The builder incorporated these findings before handoff.
- **Preservation:** no Notepad++ source was inspected/copied/modified. No README was created. Existing unstaged `docs/wiki/04-implementation-foundation.md` and `scripts/vendor_scintilla_5_6_6.sh` remain outside Phase 8 scope. No stage/commit operation was performed.
