# Phase 8 extension-platform independent code review

## Verdict

**CHANGES_REQUIRED — 0 Blocker, 2 Major, 0 Minor.**

## Scope

Reviewed only the current Phase 8 extension-platform product/acceptance change: `Package.swift`; one sample source; 16 `Sources` files; two existing Scintilla bridge files; the 168-file WAMR 2.4.5 subset; three Phase 8 scripts; four test files; and `docs/wiki/11-extension-platform.md`. The pre-existing `docs/wiki/04-implementation-foundation.md` and `scripts/vendor_scintilla_5_6_6.sh` changes were excluded and preserved. README and the ignored Notepad++ reference were not accessed. Reviewed source/test files were not edited, staged, or committed.

The 196-path product/acceptance manifest excluding the mutable wiki index has sorted-path SHA-256 `2bdb07824db766fc8da73c77d9893d437e4408ad0bb49bd0a24a20663bc6b02b` and sorted `sha256  path` manifest SHA-256 `4bb70fda4f73795df5bbe74e54182998e977e66b0b0ce160a117ad370f5ffbba`.

## Evidence

- Official `WAMR-2.4.5` HTTPS tar SHA-256 independently matched `1ab09d51099f276ca4a1d6629f6b589aab2bd0caa01445e05031a4bed22c199b`; running the current vendor script in an isolated temporary repository produced a `diff -qr` byte-identical 168-file subset.
- Package/build inspection confirmed classic interpreter sources only and disabled AOT/JIT/WASI/libc/thread/shared-memory/multi-module features. The Swift preflight enforces zero imports, no start section, one bounded exported memory, a bounded optional table, ordered unique sections, and exact required function signatures; the C bridge validates module/input/output pointers and WAMR application ranges.
- Descriptor-based package enumeration, no-follow opens, regular-file/identity/size rechecks, exact signed inventory, Ed25519 verification, bundled digest attestation, user-root trust downgrade, and bundled precedence were inspected. The signed sample inventory/module/signature passed the real loader and host.
- Editor capture rejects the 500 MiB document before snapshotting and reads only a four-byte selection inside a 50 MiB Scintilla document. Returned ranges, UTF-8 boundaries, revision/identity, authority, reservation, grouped undo, and recovery paths were inspected and exercised.
- Independent debug focused gates passed 26/26 (Application 10, Infrastructure 13, Presentation 1, EditorAdapter 2); release focused gates passed 26/26. `swift build` passed. Additional debug Domain 13/13 and Application 59/59 passed. The real `DUCKPAD_EXTENSION_SMOKE=1 swift run DuckpadApp` signed-loader → Process → WAMR → scoped edit → native undo path exited 0. The builder-reported full debug/release/fresh 178/178 and x86 build were treated as supporting evidence, not substituted for code inspection.

## Findings

- **Major P8-01 — `Sources/DuckpadApplication/ExtensionPlatform.swift:263-280,543-550`; `Sources/DuckpadInfrastructure/LocalExtensionPlatform.swift:312-336`:** post-rename `durabilityUncertain` clears current grants but sets no fail-closed latch and leaves the store high-water generation unchanged, so an immediate same-generation Enable/Grant/Reset retry can restore authority despite the UI claiming “disabled until restart”; record the published generation on rename, latch policy authority unavailable, cancel any active request, and reject every authority mutation/invocation until an explicit successful reload establishes a newer durable snapshot, with adversarial retry tests.
- **Major P8-02 — `Sources/DuckpadPresentation/DuckpadWindowController.swift:344-350,487-535`; `Sources/DuckpadApplication/ExtensionPlatform.swift:366-426`:** Cmd-Q/red-close performs dirty review and final recovery flush without cancelling and awaiting the active extension request, allowing a host response/reservation to apply a new edit after the final durable snapshot and immediately before termination; add a request-scoped cancel-and-quiesce lifecycle gate before termination review/final flush, then re-review current revisions, and test both host-response and held-reservation interleavings with exactly one reply and no late edit/orphan.

## Notes

- The documented Process transport remains a Developer Preview and user extensions remain compile-time disabled in release. Signed XPC/helper identity hardening is explicitly deferred and did not block this verdict.
- The sample signature helper authenticates `SHA256SUMS`; the runtime loader, not the helper script alone, verifies every inventory hash. Keeping a standalone build-time inventory check would improve diagnostics but is non-blocking here.

## Agent Work Log

### 2026-09-03 — `/root/phase1_code_review`

Performed the independent Phase 8 content/security review, official archive and isolated subset reproduction, focused debug/release gates, selected full-target gates, and real production-composition smoke. Recorded two current-scope Major lifecycle/authority findings. Modified only this review record and the wiki index; did not modify reviewed source/tests, stage, or commit.

## Focused remediation re-review — 2026-09-03

### Verdict

**APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** Exact staged-candidate receipt remains pending.

### Closure

- **P8-01 closed:** `LocalExtensionPreferenceStore.savePolicy` consumes the generation immediately after successful rename, before directory sync. `ExtensionWorkspaceUseCase` permanently latches user authority off after `.durabilityUncertain`; refresh cannot clear it, and Enable, consent-token creation, grant, revocation-token creation, revoke, reset, and user-package invocation fail closed until a new use-case/process loads the published policy. Bundled attested commands remain separately trusted.
- **P8-02 closed:** termination atomically disables editor input and suspends new invocation admission before cancelling the exact active request. It awaits transport teardown and the invocation defer path before dirty review and final recovery flush. The queued UI task rechecks termination state, while the use-case gate independently rejects pre-entry work. Denied/cancelled termination reopens editor and invocation admission; successful termination keeps both closed. A request waiting behind a workspace transaction releases without mutation after the holder finishes, so the lifecycle gate creates no reservation deadlock.
- **Process teardown stress closed:** the transport now installs one `ProcessExitSignal` termination handler before `process.run()`. Completion, timeout, explicit cancellation, and cleanup share that multi-waiter reap signal instead of racing multiple blocking `waitUntilExit` calls. Terminal cause remains first-wins and PID absence is asserted after timeout/cancel.

### Re-review evidence

- Independently inspected all remediation source and test bodies plus unchanged Clean Architecture boundaries. No new dependency inversion was introduced: Presentation owns lifecycle orchestration through Application ports; Process/filesystem remain Infrastructure.
- Independent current focused debug: **32/32 PASS** (Application 13, Infrastructure 14, Presentation 3, EditorAdapter 2).
- Independent closure repetition: original four policy/termination tests **20/20 PASS**; held-reservation join **10/10 PASS**; current Process timeout/cancel/reap **3/3 PASS** with no hang or surviving PID.
- Independent release remediation: Application 13/13, Process teardown 1/1, Presentation 3/3; **17/17 PASS**.
- Independent signed loader → Process host → WAMR → scoped grouped edit → undo smoke: **PASS, exit 0**.
- Frozen-candidate supporting gates from `/root`: debug/release/fresh **184/184** each; parallel Infrastructure 40/40 three times; x86_64 macOS 13 release build; sample signature/fingerprint; diff/hygiene all PASS.
- Final frozen product/acceptance manifest: **196 paths** = Package 1, Samples 1, Sources 16, Vendor/WAMR 168, Vendor/Scintilla bridge 2, scripts 3, tests 4, docs 1. Mutable index/review evidence and the two preserved unrelated files are excluded. Sorted-path SHA-256 is `2bdb07824db766fc8da73c77d9893d437e4408ad0bb49bd0a24a20663bc6b02b`; sorted `sha256  path` manifest SHA-256 is `24942d5e3a05013c598c7721982ef040eeb23747efcda88453ca62a8cb484088`.

### Agent Work Log

`/root/phase1_code_review` independently re-reviewed P8-01/P8-02 and the stress-discovered shared-exit remediation, ran focused/adversarial debug and release checks, and approved the frozen content. Only this review record and the wiki index were changed; product/source/tests were not edited, staged, or committed. README, the ignored Notepad++ reference, `docs/wiki/04-implementation-foundation.md`, and `scripts/vendor_scintilla_5_6_6.sh` were not accessed or modified during re-review.

## Upstream whitespace normalization focused re-approval — 2026-09-03

### Verdict

**APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** Exact staged-candidate receipt remains pending.

### Evidence

- Downloaded the official `WAMR-2.4.5` archive independently and reverified SHA-256 `1ab09d51099f276ca4a1d6629f6b589aab2bd0caa01445e05031a4bed22c199b`.
- Compared every upstream-backed file in the 168-file vendored subset against that archive. Exactly the declared 14 files differ, and each staged blob exactly equals the upstream blob after only `s/[ \t]+(?=\r?\n)//g` plus collapse of multiple terminal blank lines to one newline. No token, instruction, preprocessor directive, license text, or line ordering changed.
- The staged `scripts/vendor_wamr_2_4_5.sh` applies that normalization after subset selection and before atomic publication; `PROVENANCE.md` documents the transform. `sh -n` passed, and executing the staged script in a fresh temporary repository reproduced all **168/168 files byte-identically** to the current vendor tree.
- `git diff --cached --check` passed. All 16 relevant paths have no staged/worktree divergence. The staged candidate contains 198 paths: the approved 196-path product/acceptance manifest plus this review record and the wiki index.
- Updated approved product/acceptance manifest: **196 paths**; sorted-path SHA-256 `2bdb07824db766fc8da73c77d9893d437e4408ad0bb49bd0a24a20663bc6b02b`; sorted staged `sha256  path` manifest SHA-256 `498e8b7acf348011532fb394f433187045033dd2600239742a6def06632b6dfc`.

### Agent Work Log

`/root/phase1_code_review` independently reviewed only the 14 normalized WAMR blobs plus the reproducibility script and provenance update. Only this review record and the wiki index were edited; product/source/tests, staging, signing, and commit state were not changed.
