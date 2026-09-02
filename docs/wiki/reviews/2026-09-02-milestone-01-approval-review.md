# Milestone 01 Independent Approval Review

> Status: **REJECTED — changes required**
>
> Date: 2026-09-02 (Asia/Seoul)
>
> Reviewer: `/root/clean_architecture/milestone_approval_reviewer`
>
> Review type: new independent full-candidate content and governance review
>
> Reference: local Notepad++ commit `dda973d2b2da6bdcc7db9f18a7f5d2fbf6b07248`
>
> Content verdict: **REJECTED**
>
> Commit authorization: **not granted**

## 1. Independence, authorization, and scope

This reviewer did not build or remediate the candidate and did not rely on previous verdicts, work-log test counts, or builder summaries. The review read the current bytes and exercised the current tools. The only authorized and created file is this review document. No reviewed source was edited, no file was staged, and no commit was created in the Duckpad repository.

The reviewed candidate comprises:

- `.gitignore`;
- `docs/wiki/00-wiki-index.md`, documents 01, 02, and 03 in full;
- all three pre-existing files under `docs/wiki/reviews/`;
- every JSON and SHA-256 artifact under `docs/parity/`;
- every source, hook, shell script, and generated file under `scripts/`;
- every test, fixture, shell entry point, and generated file under `tests/`;
- the ignored local Notepad++ reference tree where cited by the candidate.

The review distinguishes this content verdict from the candidate-specific protocol in document 03. At review start Duckpad had no staged paths, no commit, no canonical candidate manifest/receipt, and an empty versioned reviewer registry. This Markdown file is not an Ed25519 local receipt and cannot authorize a commit even if the content verdict were approval.

## 2. Repository and reference state

Commands and observed results:

```sh
git status --short
# ?? .gitignore
# ?? docs/
# ?? scripts/
# ?? tests/

git branch --show-current
# main

git rev-list --all --count
# 0

git remote -v
# no output

git diff --cached --name-only
# no output

git config --local --get core.hooksPath
# scripts/review/hooks

git -C notepad-plus-plus rev-parse HEAD
# dda973d2b2da6bdcc7db9f18a7f5d2fbf6b07248

git -C notepad-plus-plus status --porcelain --untracked-files=all
# no output
```

`scripts/setup_notepadpp_reference.sh notepad-plus-plus` completed with exit 0, performed the explicit integration audit, left the full pinned HEAD unchanged, and left zero dirty entries. Both parity sidecars passed `shasum -a 256 -c`.

A local-link/range audit traversed all Markdown files: **114 local links, 0 missing targets, 0 out-of-range `#L...` anchors**. The pinned README, command/workflow, buffer/session, Cocoa/Scintilla/Lexilla, plugin, and license files support the material claims. The Notepad++ license wording and the separate Scintilla/Lexilla notice-license boundary are accurately represented.

## 3. Test discovery, inspection, and execution

An AST inventory was used before execution so counts could not substitute for selection review. It found exactly 24 `test_*` methods in `tests/test_parity_baseline.py`, 6 in `tests/test_parity_integration.py`, and 3 in `tests/governance/test_review_gate.py`. The bodies and their negative assertions were read. In particular, the review confirmed that each expected failure checks a nonzero result or a specific `BaselineError`/`ReviewError`, rather than merely executing a mutation.

| Suite / command | Result | Substance independently confirmed |
| --- | --- | --- |
| `python3 -B -m unittest -v tests/test_parity_baseline.py` | **PASS, 24/24**, 12.900 s | deterministic reference-free baseline; exact G1-G10 and non-vacuous P0; evidence/receipt/candidate bindings; unsigned and same-ID builder rejection; artifact/source/manifest tamper; replay; wrong/inactive signer; strict numbers; sidecars; command/workflow mapping; setup boundaries; CLI exit 2 |
| `DUCKPAD_NPP_REFERENCE=notepad-plus-plus python3 -B -m unittest -v tests/test_parity_integration.py` | **PASS, 6/6**, 0.835 s | real pinned-source positive control; frozen removal; duplicate and overlapping ownership; occurrence drift; dirty-at-pin setup rejection with preserved HEAD/file |
| `python3 -B -m unittest -v tests/governance/test_review_gate.py` | **PASS, 3/3**, 3.116 s | reviewed unborn commit and follow-up; raw hook rejection; `--no-verify` commit then audit detection; candidate/receipt tamper; wrong role; same-ID builder; inactive reviewer |
| `python3 -B scripts/check_parity_baseline.py` | **PASS structurally** | 530 symbols = 492 feature + 13 Reviewed-N/A + 25 non-command; 5 surfaces; 32 workflows; 94 features; score 0.0; release false |
| `python3 -B scripts/check_parity_baseline.py --integration-reference notepad-plus-plus` | **PASS structurally** | same result plus `integration_reference_audited=true`; full source commit/header/symbol order/surfaces/selectors checked |
| both `shasum -a 256 -c` parity sidecars | **PASS** | baseline `b3aaf80aa79e6d4eda21d05c932194f6cf23dc2889866545823a0c2cea8127cb`; workflow `ab18ceb959ff90a4a61efb12dec23beefa472b11027d546185308647c5d23a28` |

The normal production baseline remains intentionally honest: candidate `not_built`, weighted parity `0.0`, every feature and UX gate `Missing`, five Reviewed-N/A rules pending, and `release_pass=false`. Passing structural checks do not claim that the product has reached 90%.

## 4. Adversarial reproduction

All mutation probes were run in `/tmp/duckpad-approval-review.KbTD95` or temporary repositories created by the tests, never against reviewed candidate bytes. The external copy included the same `docs/`, `scripts/`, and `tests/`; the integration copy used a shared clone of the pinned reference. Candidate source remained unchanged.

| Required adversarial case | Direct evidence | Result |
| --- | --- | --- |
| Workflow removal | `test_removed_frozen_workflow_fails` against the real reference | **Rejected as required** |
| Duplicate workflow ID | changed workflow 2's ID to workflow 1's ID, updated only the copied sidecar, ran the checker | **Rejected**, exit 1: `workflow IDs must be unique` |
| Duplicate selector ownership | `test_duplicate_selector_ownership_fails` | **Rejected as required** |
| Overlapping selector ranges | `test_overlapping_selector_ownership_fails` | **Rejected as required** |
| Occurrence/count drift | `test_expected_occurrence_drift_fails` | **Rejected as required** |
| Unsigned evidence | `test_unsigned_internally_consistent_release_is_rejected` | **Rejected as required** |
| Same declared builder/reviewer ID | normal `test_cryptographically_signed_self_authored_release_is_rejected` and governance same-ID case | **Rejected as required** |
| Inactive reviewer | parity replay/signer table and governance inactive case | **Rejected as required** |
| Locally revoked reviewer key | removed the active key from copied `allowed_signers`, then ran `verify_candidate.py verify` | **Rejected**, exit 1: key not active in local trust root |
| Receipt tamper | governance candidate/receipt tamper case | **Rejected as required** |
| Candidate/feature replay and wrong candidate | parity replay table plus receipt candidate binding case | **Rejected as required** |
| Missing/hashed-forged evidence | evidence-table, receipt-hash, attestation-hash, and result-artifact mutations | **Rejected as required** |
| Manifest/source/build artifact mismatch, missing file, symlink | `test_release_candidate_artifact_tamper_and_missing_artifact_fail` | **Rejected as required** |
| Actual manifest binding positive control | `test_positive_release_fixture_passes`; inspected `validate_candidate` | Manifest bytes, source-tree bytes/modes, and at least one regular build-artifact byte stream are rehashed; **binding passes** |
| Dirty repository already at pin through setup | pinned shared clone plus untracked sentinel | **Rejected**, sentinel and HEAD preserved |
| Relative Duckpad-root target `.` | setup boundary test | **Rejected before Git mutation** |
| Symlink target / symlink-parent escape | setup boundary test | **Rejected before Git mutation** |
| Unrelated existing repository | direct-child repository with non-official origin | **Rejected before fetch/checkout** |
| Raw `git commit` | installed hook route | **Rejected as required** |
| `git commit --no-verify` | bypass commit followed by `audit --all` | Commit is detected; audit **rejects** with missing immutable mapping |
| Unborn first commit and reviewed follow-up | governance E2E | Both wrapper commits and post-commit audits **pass** |
| Self-created reviewer alias/key | one actor ran bootstrap, prepared as `/builder/bob`, signed as `/reviewer/selfsigned`, verified, committed, and audited | **INCORRECTLY ACCEPTED**; see Major F-02 below |

The failing self-sign probe was reproduced with the shipped commands:

```sh
python3 scripts/review/bootstrap_authority.py \
  --repo "$PROBE" --reviewer-id /reviewer/selfsigned \
  --role independent_commit_reviewer
CID=$(python3 scripts/review/verify_candidate.py \
  --repo "$PROBE" prepare --message-file "$PROBE/.git/message.txt" \
  --builder-id /builder/bob)
python3 scripts/review/create_receipt.py \
  --repo "$PROBE" --candidate-id "$CID" \
  --reviewer-id /reviewer/selfsigned --scope candidate --validation probe
python3 scripts/review/verify_candidate.py \
  --repo "$PROBE" verify --candidate-id "$CID"
python3 scripts/review/local_commit.py --repo "$PROBE" --candidate-id "$CID"
python3 scripts/review/verify_candidate.py --repo "$PROBE" audit --all
```

Observed identity and result:

```text
candidate = 9eebc7e5bea14496ddd3d27886b0d14ed34e3b7e2a72b0ec7e41642f8be4763d
commit    = d7683adbbdfa3fd6a47e17199e0678f83a5b6db2
verify    = PASS
audit     = PASS: audited 1 commit(s)
key mode  = 0600, owner namjeongwan, readable by the candidate-builder process
```

This is not a signature forgery: it proves the current system cannot establish that the signing principal is independent from the builder. The same process can also read an existing reviewer key stored under the shared Git common directory. The release positive fixture uses the same trust assumption when it bootstraps `/reviewer/fixture` and signs all parity results in one process.

Two additional robustness probes found nonblocking defects:

- A copied baseline with duplicate top-level `schema_version` keys (`999` first, `3` last) and a recomputed sidecar exited **0** because the parity loader accepts duplicate JSON names.
- A dirty pinned reference passed direct `check_parity_baseline.py --integration-reference` with `integration_reference_audited=true`, while the setup wrapper correctly rejected the same repository before mutation.

## 5. Prior F-01/F-02/F-03 disposition

| Finding | Disposition | Closure evidence |
| --- | --- | --- |
| F-01 — workflow inventory was removable/ambiguous | **Closed** | Independent frozen fixture + sidecar now exact-compare 32 IDs, surfaces, selectors, features, and occurrence counts. Removal, duplicate ID, duplicate selector, overlapping real match span, and count drift all fail. |
| F-02 — candidate/evidence/reviewer provenance was forgeable | **Open — Major** | Manifest/source/artifact hashing, typed result hashes, Ed25519 envelopes, role/status checks, receipt binding, and normal tamper/replay tests are real improvements. However the signer authority is created and stored by the same OS principal as the builder, and both `builder_id` and `reviewer_id` are self-declared strings. A builder can create a reviewer alias/key and obtain verify/commit/audit success. Therefore signatures are not unavailable to builders and forged review/evidence remains possible. |
| F-03 — setup canonical-path/clean-tree boundary was unsafe | **Closed for the setup entry point; Minor direct-audit gap remains** | Physical direct-child resolution, symlink/escape/root rejection, official-origin check, pre/audit/post clean checks, and post-audit pin checks work. Dirty-at-pin, relative root, symlink, unsafe parent, and unrelated-origin probes fail without destructive mutation. The checker invoked directly does not enforce the documented clean invariant; see m-02. |

## 6. Plugin architecture reconfirmation

Document 02 remains a coherent architecture decision candidate:

- one `DuckpadPluginRuntime.xpc` topology with a non-JIT WebAssembly Core interpreter;
- no WASI, ambient imports, plugin native code, JIT/AOT fallback, direct AppKit/Scintilla handles, or file descriptors;
- main-app broker revalidation for all allowed effects;
- `process.runTool` explicitly `Unavailable / Missing` in v1 and absent from runtime/LSP routes;
- future host-owned typed `ToolDefinition`, immutable-vault identity and TOCTOU defense, argument/discovery/environment denial, bounded I/O/resources, cancellation, and escape fixtures before enablement;
- required host-rendered declarative `duckpad.panel.v1` lifecycle/action/accessibility contract;
- package and nested-code signing/notarization requirements;
- direct filesystem, network, and process-route denial as MUST gates, not optional guidance.

This is design evidence only; no plugin runtime implementation exists in this milestone. No plugin security gate is being claimed as executed.

## 7. Original user-goal disposition

| Original goal | Result | Evidence / limitation |
| --- | --- | --- |
| 1. Fix scratch-first simplicity, broad languages, and VS Code-like plugin direction | **Pass for the decision baseline** | Document 01 fixes scratch-first, loss avoidance, simple surface/deep capability, broad language coverage, working-memory tabs, and extensibility. Document 02 fixes the plugin and language architecture. |
| 2. Show the main emphasis prominently after autonomous work | **Pass** | Document 01:11-15 gives the paste-first, explicit-discard promise a top-level emphasized quotation. |
| 3. Achieve at least 90% Notepad++ feature/UX parity with required macOS optimization | **Not achieved** | The authoritative denominator now has 530 commands, 32 workflows, 94 features, and ten native UX gates, but the honest implementation score is 0.0 and all gates are Missing. F-02 also prevents future release evidence from being authoritative until reviewer independence is enforceable. |
| 4. Use Local Git | **Pass for current state/policy** | Unborn local `main`, zero remotes, zero commits; reference Git remains ignored and separate. |
| 5. Independent review before every commit | **No historical violation, but enforcement fails** | There are zero commits. The exact tree/parent/diff/message receipt design and ordinary negative tests work, but the self-created reviewer alias bypass violates independence. |
| 6. English commit header and body | **Pass as policy; no history to audit** | Document 03 and `validate_message` require ASCII English Conventional Commit shape. No Duckpad commit exists. |
| 7. Apply Clean Architecture while porting | **Pass for architecture design; implementation absent** | Documents 02/03 agree on outer adapters → Application → Domain, stable IDs, ports, AppKit/Scintilla isolation, and recovery/session ownership. There is no product code yet. |
| 8. Use sub-agents for all work and preserve each agent's work/design in Markdown wiki form | **Pass for recorded Milestone 01 work** | Documents 01-03, README work logs, and independent review files name agents/roles, decisions, evidence, tests, and commit state. This reviewer is itself an independent sub-agent and records this work here. |

## 8. Findings

### Blocker

None.

### Major

`scripts/review/bootstrap_authority.py:28-76` / `scripts/review/review_common.py:149-170,262-276` / `scripts/review/candidate_identity.py:60-63` / `scripts/review/create_receipt.py:20-57` / `tests/test_parity_baseline.py:65-144` / `docs/wiki/03-development-workflow-and-roadmap.md:136-155`: **F-02 — reviewer independence is still a self-asserted alias, not an authenticated boundary.** Any process that can build the candidate can run `bootstrap_authority.py`, choose a fresh reviewer ID, create/read its private key in the same-user Git common directory, declare a different builder ID during `prepare`, sign its own receipt/evidence, and pass verify, wrapper commit, and audit. The direct reproduction above did exactly that. Store reviewer signing authority behind a principal unavailable to the builder (separate OS identity/ACL, hardware-backed key, or an external/orchestrator signer), pre-provision the local trust root outside builder control, authenticate rather than accept free-form builder/reviewer IDs, and add a test where one actor self-registers an alias whose required outcome is rejection. Until then neither parity attestations nor pre-commit receipts prove independent review.

### Minor

`scripts/check_parity_baseline.py:80-88` / `scripts/review/review_common.py:32-57`: **m-01 — governance JSON parsing is inconsistent and the parity authority accepts duplicate member names.** A copied baseline containing both `"schema_version": 999` and `"schema_version": 3` passed after its sidecar was updated. Use the same duplicate-pair rejection for the baseline, release manifest, workflow fixture, and typed result artifacts, then add parser-differential fixtures.

`scripts/check_parity_baseline.py:554-603` / `docs/wiki/00-wiki-index.md:58-74` / `docs/wiki/01-product-philosophy-and-parity.md:458`: **m-02 — direct explicit integration audit does not enforce the documented clean-reference invariant.** An untracked dirty file still produced exit 0 and `integration_reference_audited=true`; only the setup wrapper checks cleanliness. Check `status --porcelain --untracked-files=all` before and after direct integration validation, or narrow the documentation/result field to state that cleanliness is guaranteed only through setup.

`.gitignore:1-60` / `scripts/__pycache__/` / `scripts/review/__pycache__/` / `tests/governance/__pycache__/`: **m-03 — Python bytecode is not ignored.** Thirteen current `.pyc` files are untracked under candidate directories and would be included by a broad `git add`. Add `__pycache__/` and `*.py[cod]` ignores and remove generated caches from the intended candidate before freeze.

`docs/wiki/00-wiki-index.md:18-20,25-32` / `docs/wiki/03-development-workflow-and-roadmap.md:3`: **m-04 — document 03 self-labels as `Binding` while the authoritative index says it is Pending approval.** Change the source status to Pending approval until an independent content approval and exact-candidate receipt exist; reserve Binding for the approved version.

### Notes

`docs/parity/notepad-plus-plus-workflow-inventory.v1.json` / `scripts/check_parity_baseline.py:460-603`: **N-01 — F-01 is materially closed.** The independently frozen identity and real-source span ownership checks reject all mandated workflow mutations.

`scripts/setup_notepadpp_reference.sh:10-104`: **N-02 — F-03 setup remediation is safe in the exercised cases.** Target resolution and cleanliness occur before fetch/checkout, and dirty-at-pin rejection preserves both sentinel and HEAD.

`scripts/check_parity_baseline.py:309-429`: **N-03 — release files are byte-bound, not just named.** The checker resolves and hashes manifest, complete non-symlink source tree, and regular build artifact, then binds typed result artifacts and signed subjects. This does not cure F-02's signer-identity failure.

`docs/wiki/02-clean-architecture-and-plugins.md:200-395`: **N-04 — plugin v1 retains the requested strict topology and MUST gates.** Preserve this architecture through implementation; it is not yet runtime evidence.

`docs/parity/notepad-plus-plus-command-baseline.v1.json`: **N-05 — current parity status is truthful.** Structural validation passes while the score remains 0.0 and release remains false.

## 9. Final disposition

**REJECTED: 0 Blockers, 1 Major, 4 Minors, 5 Notes.** Approval requires exactly zero Blockers and zero Majors. F-01 is closed and the setup portion of F-03 is closed, but F-02 remains open because self-created reviewer authority passes the candidate-specific governance protocol. Minor findings are explicitly nonblocking in isolation, but should be resolved during the required remediation because they affect candidate hygiene and evidence clarity.

No content approval or commit authorization is granted. There is also no staged candidate or canonical signed local receipt to authorize. After F-02 is redesigned, the candidate must be re-reviewed adversarially; any remediation changes invalidate this content snapshot.

## 10. Agent Work Log

- **Task:** `/root/clean_architecture/milestone_approval_reviewer`
- **Agent:** `/root/clean_architecture/milestone_approval_reviewer`
- **Role:** New independent final content reviewer; not a builder of reviewed source
- **Date:** 2026-09-02 (Asia/Seoul)
- **Goal:** Approve only if the complete current Milestone 01 candidate has zero Blocker/Major findings and every required adversarial condition fails closed.
- **Scope:** Full current `.gitignore`, wiki/index/reviews, parity artifacts, scripts, tests/fixtures/generated artifacts, and pinned local Notepad++ reference.
- **Method:** Full-file inspection; AST test inventory; normal/integration/governance execution; sidecar/reference/link/source/license verification; external temporary-copy mutation; explicit self-sign, duplicate-ID, duplicate-JSON, and dirty-direct-audit probes.
- **Skill:** `caveman-review` was used for terse, location-specific findings; security and architecture findings retain the fuller rationale required by that skill's exception.
- **Key decision:** Cryptographic integrity is present, but independence is not: same-user, self-bootstrapped aliases can sign and commit their own candidate. This is a Major and bars approval.
- **Files changed by reviewer:** `docs/wiki/reviews/2026-09-02-milestone-01-approval-review.md` only.
- **Reviewed source changes:** None.
- **Stage/commit:** None.
- **Finding count:** 0 Blocker, 1 Major, 4 Minor, 5 Note.
- **Verdict:** REJECTED; no commit authorization.
