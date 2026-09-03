# Phase 26 macOS Distribution — Independent Code Review

- **Reviewer:** `/root/phase1_code_review` (independent; did not implement Phase 26)
- **Date:** 2026-09-03
- **Candidate:** `5c146afc9cceab4ace3ef44a89c3e6a84d4c6954932c099a31e34d17c1a654db`
- **Current remediation candidate:** `fe0defaa277eb4f2d7b76565fc2826f1deadf6b9e470467fca39cf2fcdabf11e`
- **Current verdict:** **APPROVED — CONTENT REVIEW**
- **Current findings:** 0 Blocker, 0 Major, 0 Minor
- **Initial findings:** 0 Blocker, 4 Major, 0 Minor

## Scope

Reviewed all 25 exact staged paths: SwiftPM target composition, app/XPC
Info.plists and entitlements, Universal assembly/sign/notary scripts, packaged
resource lookup, application transport selection and Finder smoke, XPC protocol,
transport, listener and shared WAMR executor, the non-JIT Darwin mapping change,
Search panel constraints, extension tests, and Phase 26 acceptance documents.
The review emphasized production-byte execution, sandbox file authority, XPC
trust/topology and cancellation, continuation races, artifact publication,
Hardened Runtime, resource/document declarations, provenance, and test honesty.

User-owned `docs/wiki/04-implementation-foundation.md` and untracked
`scripts/vendor_scintilla_5_6_6.sh` remained excluded. README, ignored
Notepad++, product/source/test/work-document bytes, stage, receipt, commit, and
push were not modified by this review.

## Findings

- **P26-01 Major** — `Sources/DuckpadInfrastructure/LocalExtensionPlatform.swift:433-485`, `Sources/DuckpadPluginRuntime/main.swift:5-16`: timeout/cancel wins only the client continuation and invalidates its connection; the service keeps executing synchronous WAMR under `executionLock`, so a looping module can survive timeout and block every later request. Add a production-XPC adversarial looping-module test and make execution cooperatively interruptible with teardown joined before returning, or use an actually disposable per-invocation service boundary whose termination is proven.
- **P26-02 Major** — `Packaging/Duckpad.entitlements:5-10`, `Sources/DuckpadApp/DuckpadMain.swift:572-621`, `Sources/DuckpadPresentation/FilePanels.swift:50-92`: the newly sandboxed app opens Finder/panel/drop URLs without owning and releasing their implicit security scopes, and persists only canonical paths rather than scoped bookmarks; repeated opens leak kernel sandbox extensions and restored/recent documents lose authority after relaunch. Add a bounded per-document security-scope lease/bookmark authority, stop exact leases on close/teardown, persist and resolve app-scoped bookmarks for later save/reopen, and test packaged relaunch plus scope-count balance.
- **P26-03 Major** — `Vendor/WAMR/2.4.5/core/shared/platform/common/posix/posix_memmap.c:44-47`, `scripts/vendor_wamr_2_4_5.sh:73-151`, `Vendor/WAMR/2.4.5/PROVENANCE.md:16-20`: the semantic no-`MAP_JIT` patch is absent from the pinned vendor generator and provenance still claims whitespace-only normalization, so an official regeneration silently restores unconditional Apple-Silicon `MAP_JIT` and breaks the shipped sandbox fix. Apply the exact reviewed patch in the generator, document it with upstream/current hashes and rationale, and add a clean 168-file reproduction gate.
- **P26-04 Major** — `scripts/build_macos_app.sh:30-33,47-50,93-107`: output nonexistence is checked before a long build, then ordinary `mv` publishes from a potentially different filesystem; a concurrent creator makes `mv` nest `Duckpad.app` inside the existing output and exit successfully with a signature-invalid/stale artifact, while cross-device publication can expose a partial bundle. Stage beside the resolved output parent and publish with Darwin `RENAME_EXCL`/verified inode identity, then verify the final path and add concurrent-appearance plus cross-volume failure tests.

## Evidence

- Candidate preparation independently recomputed exactly to
  `5c146afc9cceab4ace3ef44a89c3e6a84d4c6954932c099a31e34d17c1a654db`.
  Parent is `34c3ef83b66eb8af16f968007d3752841bac76be`, tree is
  `6886f0d7d4ed1c92a126bf6dcfa78bed77b104a2`, diff SHA-256 is
  `de771f9bb668898a4c389c322bd6cabde2fc06634311c956abe04b17fe9d4e69`,
  and message SHA-256 is
  `bedffd084fa926ccf099a4be41752e2ba7dc477a42d9540aec931f82a0f77394`.
- `git diff --cached --check` and `sh -n` for all three new scripts passed.
- Independent focused runtime/framing/policy validation passed 3/3. The only
  timeout/cancel test exercises `ProcessPluginHostTransport`; no test invokes
  production `XPCPluginHostTransport` with a nonterminating module.
- Independent verification of the built Universal app passed: app and XPC are
  both `x86_64 arm64`, resources are present, the app has exactly the three
  declared sandbox entitlements, the XPC has only App Sandbox, Hardened Runtime
  flags/signatures validate, and the Process helper is absent.
- Downloaded official `WAMR-2.4.5` archive SHA-256 independently matched
  `1ab09d51099f276ca4a1d6629f6b589aab2bd0caa01445e05031a4bed22c199b`.
  Applying the generator's documented whitespace normalization and comparing
  `posix_memmap.c` produced the exact three-line semantic diff in P26-03.
- Static continuation inspection found first-wins locking prevents a double
  resume, and shared executor/frame validation remains bounded; the defect is
  lack of remote execution teardown after that safe local resume.
- Apple's sandbox guidance states implicit scopes from system file interactions
  must be relinquished and explicit security-scoped bookmarks are required for
  access across launches; current source has scope handling only for folder
  search/workspace roots, not ordinary documents. See
  [Apple: Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox).
- Builder Debug/Release 348/348, native/Universal verification, Finder smoke,
  valid signed-extension XPC smoke, parity 31/31, and governance 8/8 are
  supporting evidence. The successful extension smoke contains no timeout,
  cancellation, or poisoned-service recovery branch.

## Verdict

**CHANGES REQUIRED — 0 Blocker, 4 Major, 0 Minor.** P26-01 through P26-04
block content approval and receipt authorization. This review/index evidence
invalidates candidate `5c146afc…`; remediation needs a newly frozen candidate.

## Agent Work Log

- Recomputed exact identity and inspected all staged files plus the existing
  security-scope, extension admission, file lifecycle, and vendor-generation
  authorities needed to evaluate the changed production boundary.
- Ran independent focused 3/3, packaged Universal static verification, exact
  entitlement/architecture inspection, script syntax checks, and an official
  upstream archive/hash/normalized-byte comparison.
- Used `caveman-review` location/problem/fix form for findings while retaining
  rationale for sandbox, XPC, provenance, and artifact-publication risks.
- Modified only this independent review record and the wiki-index review
  evidence; candidate product/source/tests/work docs and stage remain unchanged.

## Focused Remediation Re-review

### Finding closure

- **P26-01 CLOSED** — `Sources/DuckpadPluginRuntime/main.swift:20-77`,
  `Sources/DuckpadWAMRBridge/DuckpadWAMRBridge.c:7-32,84-101,142-147`, and
  the two pinned WAMR interpreter patches make timeout/cancel visible inside a
  tight classic-interpreter loop through an atomic instruction-limit poll.
  XPC invalidation requests that trap, the 50 ms fallback retires a still-busy
  service process, and the client preserves timeout/cancel authority while
  retrying only restartable connection failures. An exact newly assembled app
  passed timeout, explicit cancel, and immediate valid-command reuse 3/3; no
  runtime service remained after the runs.
- **P26-02 CLOSED** — `FileDocumentUseCase` acquires authority before path
  canonicalization/read, owns one idempotent lease per window, embeds the
  bookmark in `FileBinding`, refreshes recovered bindings before interaction,
  and reconciles leases after close/restore/rebind/window teardown. The shared
  `LocalTextFileStore` owner set preserves another window's lease. The bounded
  private bookmark archive supplies relaunch fallback, while the recovered
  binding remains backward compatible when the optional bookmark is absent.
  Independent owner-balance/relaunch validation passed 1/1 and the exact
  packaged two-launch Finder-open -> recovery -> save smoke passed.
- **P26-03 CLOSED** — the generator now fail-closed applies and documents all
  three semantic changes: interpreter-only no-`MAP_JIT`, atomic instruction
  limit store, and classic-interpreter atomic polling. Independent
  `scripts/vendor_wamr_2_4_5.sh --verify` regenerated and compared all 168
  published files byte-for-byte; the recorded normalized/patched hashes match
  the current files.
- **P26-04 CLOSED** — `build_macos_app.sh` creates staging under the resolved
  output parent, and `macos_bundle_publish.py` rejects different devices,
  symlink staging, an existing destination, and a race via Darwin
  `renameatx_np(..., RENAME_EXCL)`, then checks the moved inode. Independent
  governance tests passed 2/2; an additional real Darwin race-after-precheck
  probe preserved both source and destination and returned the expected
  publication failure.

### Exact scope and evidence

- Remediation candidate preparation independently recomputed exactly to
  `fe0defaa277eb4f2d7b76565fc2826f1deadf6b9e470467fca39cf2fcdabf11e`.
  Parent is `34c3ef83b66eb8af16f968007d3752841bac76be`, tree is
  `6fd0af5e3a27e4479be39c9875d7e8ebfe93c365`, diff SHA-256 is
  `fd4bbbf3fbad32f9857aac55ab164d65b531905978154d52e2a0c2f227bef56d`,
  and message SHA-256 is
  `bedffd084fa926ccf099a4be41752e2ba7dc477a42d9540aec931f82a0f77394`.
  The exact stage contained 42 paths and `git diff --cached --check` passed.
- Excluding this review record and the mixed builder/reviewer wiki index, the
  exact 40-path product/test/work-document path-list SHA-256 is
  `a6a7ec7abeb8827fb35af2e52bc289f26faf2f32116086fca3c3f494cb48c033`;
  its sorted `SHA-256  path` staged-blob manifest SHA-256 is
  `8bb7f50892f1a9957445176f798d4af82193c42b05dccc288df22caa70e8b1b2`.
- Independent focused validation passed: security-scope owner/relaunch 1/1,
  shared runtime frame equivalence 1/1, bundle publication adversaries 2/2,
  real Darwin exclusive-rename race 1/1, WAMR reproduction 168/168, and script
  syntax/cached-diff checks. A newly built current-byte native app passed
  static signature/resource/entitlement verification and the complete Finder,
  two-launch bookmark-save, valid XPC, and isolation smoke; its isolation
  timeout/cancel/immediate-reuse branch then passed three additional runs.
- Builder Debug modules 349/349 and Release modules 349/349, governance 10/10,
  Universal/native verification, parity 31/31, and checker evidence are
  supporting evidence. Presentation's documented macOS 26.5 long-lived helper
  transform crash was isolated by module; no individual exact test failed.
- User-owned `docs/wiki/04-implementation-foundation.md` and untracked
  `scripts/vendor_scintilla_5_6_6.sh` remain outside the candidate. No README,
  ignored Notepad++, gitlink, product/source/test/work-document, stage, commit,
  push, or receipt was modified by this re-review.

## Final Verdict

**APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** P26-01 through
P26-04 are closed. This review/index evidence changes the candidate bytes, so
the builder must refreeze a new exact candidate before receipt authorization.

### Focused Re-review Work Log

- Recomputed the exact 42-path candidate and inspected every remediation hunk
  plus XPC/WAMR, document lifecycle, recovery, multi-window lease, and bundle
  publication authority surrounding it.
- Ran the independent focused/static/adversarial validations listed above. A
  pre-existing packaged artifact once stalled in the security-scope smoke; a
  clean current-byte native assembly passed the full smoke immediately and is
  the evidence used for this verdict.
- Updated only this reviewer-owned record and the Phase 26 wiki-index
  status/work log. Reviewed product/test/work-doc bytes and the index itself
  were not staged or committed by the reviewer.
