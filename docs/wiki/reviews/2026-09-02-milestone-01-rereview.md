# Milestone 01 Independent Re-review

> Status: **REJECTED — changes required**
>
> Date: 2026-09-02 (Asia/Seoul)
>
> Reviewer: `/root/milestone_one_rereview`
>
> Review type: independent remediation, parity-baseline, architecture, and governance re-review
>
> Reference source: local Notepad++ commit `dda973d2b`
>
> Commit authorization: **not granted**

## Review scope

This re-review independently inspected the complete current contents of:

- `.gitignore`
- `docs/wiki/00-wiki-index.md`
- `docs/wiki/01-product-philosophy-and-parity.md`
- `docs/wiki/02-clean-architecture-and-plugins.md`
- `docs/wiki/03-development-workflow-and-roadmap.md`
- `docs/parity/notepad-plus-plus-command-baseline.v1.json`
- `docs/parity/notepad-plus-plus-command-baseline.v1.sha256`
- `scripts/check_parity_baseline.py`
- `tests/test_parity_baseline.py`
- `tests/fixtures/menuCmdID.fixture.h`
- `docs/wiki/reviews/2026-09-02-milestone-01-review.md`

The source files were not modified. This review checks every finding from the first review, all eight user requirements, the 530-symbol coverage claim, user-visible denominator/mapping rules, Reviewed-N/A release blocking, the single 90% formula, sidecar integrity, checker failure modes and fixtures, XPC/non-JIT-WebAssembly isolation, `ToolBroker` escape risk, panel v1, license links, and the local review-receipt recursion/implementability claim.

Out of scope:

- changing reviewed source or remediation code
- staging or committing any file
- implementing the future review wrapper or application
- legal advice

## Evidence and commands

Repository evidence:

- Duckpad is an unborn local `main` branch with no commits and no remotes.
- All reviewed Duckpad artifacts are untracked; `notepad-plus-plus/` is ignored.
- The reference repository is clean at `dda973d2b2da6bdcc7db9f18a7f5d2fbf6b07248`.
- All local Markdown link targets in the reviewed wiki files exist.
- The linked Notepad++, Scintilla, Lexilla, plugin, tab, session, and license ranges exist at the pinned reference revision.

Commands run:

```sh
git status --short --branch
git remote -v
git log --oneline --decorate -5
git -C notepad-plus-plus status --short
git -C notepad-plus-plus rev-parse HEAD
git check-ignore -v notepad-plus-plus/README.md .env .env.example DerivedData/x .build/x docs/wiki/00-wiki-index.md
git diff --check

python3 -m unittest -v tests/test_parity_baseline.py
python3 scripts/check_parity_baseline.py
python3 scripts/check_parity_baseline.py --report
python3 -m py_compile scripts/check_parity_baseline.py tests/test_parity_baseline.py
(cd docs/parity && shasum -a 256 -c notepad-plus-plus-command-baseline.v1.sha256)

rg -n '^\s*#define\s+IDM_' notepad-plus-plus/PowerEditor/src/menuCmdID.h
rg -n '^\s*#\s*(if|ifdef|ifndef|elif|else|endif)' notepad-plus-plus/PowerEditor/src/menuCmdID.h
rg -n 'IDM_VIEW_GOTO_START|IDM_VIEW_GOTO_END|IDM_VIEW_WRAP' \
  notepad-plus-plus/PowerEditor/src/menuCmdID.h \
  notepad-plus-plus/PowerEditor/src/Notepad_plus.rc
```

Validation results:

- Unit suite: **PASS, 5 tests**.
- Baseline checker: **PASS structurally**, 530 symbols = 490 feature commands + 13 provisional Reviewed-N/A commands + 27 metadata symbols; current score `0.0`, release false.
- Sidecar verification: **PASS**, JSON SHA-256 `0a8a720e3affeea752b0b7bda63dee3a1edecbf17e08c46b2a088f318b3abfee`.
- Local-link target check: **PASS**, zero missing paths.
- Workflow-source path/range audit: all file paths and numeric ranges exist; `macOS native acceptance workflow` is intentionally a non-file placeholder.
- Adversarial checker probe: setting all feature states and one UX gate to `Full`/`Pass`, and replacing each N/A review with arbitrary nonempty `reviewer` and nonexistent `receipt` strings, produced `release_pass=true`. A baseline containing only G1 also produced `release_pass=true`.
- `git log` failed as expected because `main` has no commits; this is repository-state evidence, not a test failure.

## First-review finding disposition

| First finding | Result | Evidence |
| --- | --- | --- |
| B-01 staged-checksum self-reference | **Design resolved; enforcement unimplemented** | Document 03:127-179 keeps the receipt outside the worktree, leaves immutable receipt bytes unchanged, and binds commit/candidate/receipt hashes through filenames. This terminates the recursive follow-up-commit problem. Required verifier, wrapper, hook, and E2E fixture do not exist yet, so no current commit is authorized under the binding policy. |
| B-02 conflicting 90% formulas | **Resolved** | Document 01:70-139 is the only formula; document 03:480-485 links to it and explicitly refuses a second score/weight/UX-percentage formula. |
| M-01 denominator precedes exhaustive inventory | **Open; see M-01** | Every `menuCmdID.h` symbol is classified, but the five non-header workflow surfaces are only hash-pinned, not enumerated or mapped, and concrete command-to-feature mappings are semantically wrong. |
| M-02 plugin isolation topology | **Resolved with m-01 residual risk** | Document 02:200-233 fixes an XPC + non-JIT Core WebAssembly/no-WASI topology; 353-368 makes direct OS access, entitlements, broker scope, crash containment, and supply-chain denial release gates. |
| M-03 panel v1 missing | **Resolved with m-02 correction** | Document 02:312-351 defines a finite host-rendered panel tree, revisioned lifecycle/actions, quotas, safety, and accessibility. |
| m-01 dependency diagram | **Resolved** | Document 03:262-283 now matches document 02:51-88: outer modules point to Application, then Domain. |
| m-02 source/license precision | **Resolved** | Document 02 pins `dda973d2b`, uses navigable local links, states the GPLv3 clarification/exception wording, and preserves the independent-implementation/legal-review boundary. |

## User-requirement disposition

| Requirement | Result | Evidence |
| --- | --- | --- |
| 1. Fix scratch-first/simple/deep, broad-language, plugin philosophy | Pass | Document 01:11-39 fixes the product promise and ten principles; document 02 fixes Swift/AppKit, Scintilla/Lexilla, and plugin direction. |
| 2. Present the emphasis prominently | Pass | Document 01:11 makes the loss-averse scratch promise a top-level display statement. |
| 3. Prove at least 90% Notepad++ feature/UX parity with macOS optimization | Reject | M-01 and M-02 mean neither the denominator nor a future `release_pass=true` is yet trustworthy. |
| 4. Use Local Git | Pass as current state/policy | Root Git is local, has no remote, and excludes the nested reference history. M-03 prevents clean-checkout reproduction of the parity checks. |
| 5. Review before every commit | Pass as design; not implemented | The nonrecursive protocol is coherent, but its mandatory tools/tests are absent and no commit exists. The current review is not an exact staged-candidate receipt. |
| 6. English commit header/content | Pass as policy | Document 03:38-78 is explicit. There are no commits to audit. |
| 7. Apply Clean Architecture | Pass | Documents 02:49-88 and 03:262-285 agree on inward dependencies, ports, adapters, typed identities, and application-owned policy. |
| 8. Use sub-agents and record all work/design in Markdown wiki | Pass as policy/evidence | Documents 01-03 and both reviews identify agent roles, evidence, decisions, changes, and validation in Markdown. |

## Findings

### Blocker

None.

### Major

`docs/parity/notepad-plus-plus-command-baseline.v1.json:14-20,54-64,66-77,143-225` / `scripts/check_parity_baseline.py:222-246`: **M-01 — the 530-symbol report is exhaustive only for header defines, not for the user-visible denominator, and some mappings are false.** The five workflow surfaces are checksum-only inputs: the checker never extracts or maps their user-visible workflows. Twenty-eight scoring features have no command mapping and rely on manually entered source strings. More importantly, `IDM_VIEW_WRAP`, whitespace markers, and hide-lines are mapped to C3.F03 “Indent, tabs and spaces, whitespace trim,” while `IDM_VIEW_GOTO_START/END` (“Move to Start/End” in `Notepad_plus.rc:806-807`) are mapped to C2.F10 “Multiple windows.” Thus a feature can become `Full` without satisfying the commands assigned to it, and word-wrap has no correctly named acceptance item. Enumerate stable workflow/behavior IDs from every pinned surface, map each to a feature with explicit acceptance, correct these mappings, and fail validation on unmapped workflow IDs as well as unmapped header symbols.

`docs/wiki/01-product-philosophy-and-parity.md:109-121,346-355` / `docs/parity/notepad-plus-plus-command-baseline.v1.json:42-143,205-239` / `scripts/check_parity_baseline.py:111-125,173-190,256-296`: **M-02 — `release_pass` trusts unverified state, evidence, UX-gate, and N/A strings.** Document 01 requires owner, acceptance, automated/manual evidence, all G1-G10, and independent N/A receipts, but feature records contain only `workflow_sources` and `state`; the checker does not verify owner/acceptance/test evidence, receipt existence/hash/reviewer identity, or the exact G1-G10 set. The adversarial probe accepted a nonexistent N/A receipt and a one-gate baseline as release-passing. Extend the versioned schema and validator to require resolvable candidate-bound evidence, authenticate/resolve N/A receipts through the review verifier, require exactly G1-G10, reject vacuous P0 sets, and add positive/negative release fixtures.

`.gitignore:1-2` / `docs/wiki/00-wiki-index.md:22,30-34` / `scripts/check_parity_baseline.py:192-242` / `tests/test_parity_baseline.py:71-79`: **M-03 — the required reference tree is ignored but the default tests hard-require it.** A fresh Local Git checkout contains neither `notepad-plus-plus/` nor a bootstrap/acquisition mechanism, so the advertised deterministic validator and its only end-to-end unit test fail before source verification. Add a documented, checksum-verified reference setup command pinned to `dda973d2b`, or make normal tests use a versioned minimal source/workflow fixture while an explicit integration test audits the external reference tree.

`docs/wiki/00-wiki-index.md:7-15` / `docs/wiki/01-product-philosophy-and-parity.md:3,405-414` / `docs/wiki/02-clean-architecture-and-plugins.md:3`: **M-04 — the wiki index marks pending/rejected decisions as accepted.** The index calls document 01 “fixed” and document 02 “Accepted,” while both source documents say re-review is pending and the only completed independent review is rejected. This lets readers implement unapproved architecture as authoritative. Derive index status from the reviewed document state and change it only after an approving independent receipt/review exists.

### Minor

`docs/wiki/02-clean-architecture-and-plugins.md:296-310,361-363`: **m-01 — `process.runTool` can become a confused-deputy escape through an approved native tool.** The document correctly treats the tool as a separate trust boundary and keeps the feature unavailable until a spike passes, so this is not a current sandbox bypass. Before enabling it, require per-tool typed argument schemas, forbid plugin-controlled response/config/plugin paths and unsafe environment/config discovery, bind executable identity without TOCTOU, constrain stdin/stdout and working resources, and add argument-level escape fixtures—not only signature/environment tests.

`docs/wiki/02-clean-architecture-and-plugins.md:251-288,312-351`: **m-02 — panel examples violate the stated reverse-DNS ID rule.** `example.sortLines`, `example.symbols`, and `example.openSymbol` are not scoped under the manifest ID `com.example.symbol-tools`, weakening collision guarantees. Use manifest-owned IDs such as `com.example.symbol-tools.sortLines` consistently in the manifest, panel document, actions, and lifecycle examples.

`scripts/check_parity_baseline.py:165-171,268-280`: **m-03 — numeric schema coercion accepts malformed governance data.** `float(weight)` and `int(open_blocker_or_critical_defects)` accept booleans, numeric strings, fractional truncation, and non-finite weights; NaN also bypasses the sum comparison. Require exact JSON number/integer types, finite positive weights, and reject booleans/non-finite values with fixtures.

`tests/test_parity_baseline.py:19-79`: **m-04 — fixture coverage does not exercise the checker’s governance-critical failure paths.** The five tests omit sidecar missing/mismatch, source commit/file/symbol/workflow drift, duplicate/unused rules, invalid dispositions/regex, N/A pending/approved receipt behavior, malformed weights, exact gate set, missing P0, evidence resolution, and CLI exit code 2. M-02’s forged-pass scenario demonstrates why these are not optional. Add table-driven temporary-baseline tests plus CLI integration tests.

`docs/wiki/01-product-philosophy-and-parity.md:190` / `docs/wiki/02-clean-architecture-and-plugins.md:380`: **m-05 — duplicate prose rows remain.** Remove the duplicated C2 table header and duplicate LSP rationale line to keep the frozen decision record unambiguous.

### Note

`docs/wiki/03-development-workflow-and-roadmap.md:127-179`: **N-01 — the two-artifact local receipt design ends self-reference and recursion.** Candidate bytes never include the receipt, receipt bytes are immutable, and commit/receipt association lives in the final filename. The design is implementable, but the named verifier, wrapper, hook, and E2E fixture do not exist; line 179 therefore correctly means no local commit is currently allowed under this policy.

`docs/wiki/02-clean-architecture-and-plugins.md:200-233,312-368`: **N-02 — XPC + non-JIT Core WebAssembly and panel v1 are strong, testable remediations.** No WASI/native/JIT fallback exists; effects cross allowlisted imports and a main-app broker; entitlements, direct-access probes, crash recovery, and panel accessibility are MUST gates. Preserve the rule that unsupported `process.runTool` stays Missing rather than widening the XPC service.

`docs/parity/notepad-plus-plus-command-baseline.v1.sha256:1` / `scripts/check_parity_baseline.py:40-49`: **N-03 — the baseline sidecar is non-self-referential and currently valid.** It hashes only the JSON bytes and the checker verifies the expected filename and digest.

`docs/wiki/02-clean-architecture-and-plugins.md:26-47,442-451`: **N-04 — pinned source and license links are present and navigable.** The GPL boundary is stated precisely enough for an engineering decision record, and Scintilla/Lexilla notice retention is explicit.

## Disposition

**REJECTED.** There are **0 Blockers, 4 Majors, 5 Minors, and 4 Notes**. Approval requires Blocker/Major zero; M-01 through M-04 remain open. The prior review’s formula conflict, plugin topology, panel contract, dependency diagram, license-link, and receipt-recursion design findings are remediated, but the user-visible denominator and release proof are not yet authoritative.

Required next review input:

1. a versioned workflow/behavior inventory with corrected command mappings and a checker that proves both command and non-command coverage;
2. schema/evidence/N/A receipt enforcement and adversarial release fixtures;
3. reproducible pinned reference setup or a versioned normal-test fixture plus explicit reference integration audit;
4. truthful wiki status labels;
5. reasoned dispositions or fixes for m-01 through m-05.

No reviewed source was changed, no file was staged, and no commit was created. This re-review document itself is not a canonical exact-candidate receipt and does not authorize a commit.

## Agent Work Log

- **Task:** `milestone_one_rereview`
- **Agent:** `/root/milestone_one_rereview`
- **Role:** Independent reviewer; not a builder of any reviewed source
- **Goal:** Revalidate every first-review finding and all eight user requirements against the full milestone source and Notepad++ `dda973d2b`.
- **Scope:** `.gitignore`, wiki index/documents 01-03, parity JSON/sidecar, checker/tests/fixture, and first review.
- **Explicit non-scope:** Remediation edits, staging, commits, application implementation, and legal advice.
- **Evidence:** Full-file reads; local Git/reference state; source/link/range checks; baseline report; sidecar verification; five unit tests; Python compilation; adversarial forged-release and reduced-gate probes.
- **Key decisions:** Keep B-01/B-02/M-02/M-03/m-01/m-02 remediations where valid; leave original M-01 open; reject machine release proof that does not resolve evidence or receipts; treat ToolBroker as unavailable until its explicitly required spike proves a safe per-tool contract.
- **Files changed by reviewer:** `docs/wiki/reviews/2026-09-02-milestone-01-rereview.md` only.
- **Validation:** Existing suite passed 5/5; checker and sidecar passed on the current baseline; adversarial probe demonstrated false release acceptance; no missing local link targets or invalid cited source ranges were found.
- **Findings:** 0 Blocker, 4 Major, 5 Minor, 4 Note.
- **Decision:** REJECTED; no commit authorization.
- **Commit:** None.
