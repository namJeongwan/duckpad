# Milestone 01 Independent Final Review

> Status: **REJECTED — changes required**
>
> Date: 2026-09-02 (Asia/Seoul)
>
> Reviewer: `/root/workflow_roadmap/milestone_final_review`
>
> Review type: independent full-candidate final review after schema-v2 remediation
>
> Reference source: local Notepad++ commit `dda973d2b2da6bdcc7db9f18a7f5d2fbf6b07248`
>
> Content verdict: **REJECTED**
>
> Commit authorization: **not granted**

## 1. Scope and independence

This reviewer is a grandchild reviewer independent of the milestone builders and of the first two reviewers. No candidate source was modified, staged, or committed. This review created only this final-review document.

The complete current contents of the following milestone candidate were read and checked:

- `.gitignore`
- `docs/wiki/00-wiki-index.md`
- `docs/wiki/01-product-philosophy-and-parity.md`
- `docs/wiki/02-clean-architecture-and-plugins.md`
- `docs/wiki/03-development-workflow-and-roadmap.md`
- `docs/wiki/reviews/2026-09-02-milestone-01-review.md`
- `docs/wiki/reviews/2026-09-02-milestone-01-rereview.md`
- every artifact under `docs/parity/`
- `scripts/check_parity_baseline.py`
- `scripts/setup_notepadpp_reference.sh`
- `scripts/verify_parity_review_receipt.py`
- `tests/test_parity_baseline.py`
- every artifact under `tests/fixtures/`

The review revalidates the re-review's M-01 through M-04 and m-01 through m-05 one requirement at a time. It also distinguishes content review from the exact-candidate pre-commit receipt specified by document 03. This file is ordinary versioned review documentation, not the out-of-worktree canonical receipt described by that protocol.

Out of scope:

- editing remediation or application code
- staging or committing candidate files
- creating a local review receipt or authorizing a commit
- legal advice

## 2. Repository and candidate state

- Duckpad is on an unborn local `main` branch with **0 commits**.
- `git remote -v` returns no entries.
- `.gitignore`, `docs/`, `scripts/`, and `tests/` are untracked; `notepad-plus-plus/` is ignored.
- The Git index contains **0 staged paths**.
- The local Notepad++ reference currently has full HEAD `dda973d2b2da6bdcc7db9f18a7f5d2fbf6b07248` and a clean worktree.
- No `scripts/review/verify_candidate.py`, `scripts/review/local_commit.py`, or `tests/governance/review-receipt-e2e.sh` exists. The two-artifact pre-commit protocol is a coherent design, but it is not implemented or enforceable yet.
- `scripts/verify_parity_review_receipt.py` exists only for parity `Reviewed-N/A` records. It is not the exact staged-candidate verifier required by document 03.

Commands:

```sh
git status --short --ignored
git remote -v
git rev-list --all --count
git diff --cached --name-only
git -C notepad-plus-plus rev-parse HEAD
git -C notepad-plus-plus status --porcelain
find scripts tests -type f -print | sort
```

Observed values: Duckpad remotes `0`, commits `0`, staged paths `0`; reference dirty entries `0`.

## 3. Validation commands and evidence

### 3.1 Normal suite and default checker

```sh
python3 -B -m unittest -v tests/test_parity_baseline.py
python3 -B scripts/check_parity_baseline.py
python3 -B scripts/check_parity_baseline.py --report
(cd docs/parity && shasum -a 256 -c notepad-plus-plus-command-baseline.v1.sha256)
```

Results:

- **PASS: exactly 18 tests**.
- Default checker: **PASS structurally**.
- JSON sidecar: **PASS**, SHA-256 `a7fbc47eb649b602a3a4b8d718d3c2b02156a1f8703649a31ba55aa57807754d`.
- Symbol fixture: 530 lines, 530 unique symbols, SHA-256 `ce5e411f47c2308eb32aa4b96c54af3987f35a0b24eea1b83199a2ac9339b793`.
- Sorted symbol-set SHA-256: `4b6175a767b9f35f5f8451bb682b166b76232f9b9fcf601c600ac3043fa4a476`.
- Report: 530 source symbols = 492 feature commands + 13 pending `Reviewed-N/A` commands + 25 non-command symbols; 5 surfaces; 32 workflow records; 94 scoring features.
- Current implementation score is `0.0`; P0 and G1-G10 are not passed; five N/A rules remain pending; `release_pass=false`.
- `--require-release-pass` returns exit code **2** for the current baseline. An invalid/missing baseline returns exit code **1**.

### 3.2 Isolated clean-checkout simulation without the ignored reference

A fresh temporary root was populated only with the candidate's versionable parity artifacts, scripts, tests, and fixtures. No `notepad-plus-plus/` directory existed.

```sh
TEMP_ROOT=$(mktemp -d /tmp/duckpad-clean-checkout.XXXXXX)
mkdir -p "$TEMP_ROOT/docs/parity" "$TEMP_ROOT/scripts" "$TEMP_ROOT/tests/fixtures"
cp docs/parity/* "$TEMP_ROOT/docs/parity/"
cp scripts/check_parity_baseline.py scripts/verify_parity_review_receipt.py "$TEMP_ROOT/scripts/"
cp tests/test_parity_baseline.py "$TEMP_ROOT/tests/"
cp tests/fixtures/* "$TEMP_ROOT/tests/fixtures/"
test ! -e "$TEMP_ROOT/notepad-plus-plus"
(cd "$TEMP_ROOT" && python3 -B -m unittest -v tests/test_parity_baseline.py)
(cd "$TEMP_ROOT" && python3 -B scripts/check_parity_baseline.py)
```

Results: **PASS, exactly 18 tests**, followed by a structurally passing default checker with the same 530/492/13/25, 5-surface, 32-workflow, 94-feature, score-0.0 report. This closes the original ignored-reference dependency for normal validation.

### 3.3 Explicit source integration audit

```sh
scripts/setup_notepadpp_reference.sh notepad-plus-plus
python3 -B scripts/check_parity_baseline.py \
  --integration-reference notepad-plus-plus
git -C notepad-plus-plus rev-parse HEAD
git -C notepad-plus-plus status --porcelain
```

Results: **PASS** with `integration_reference_audited=true`; full pinned commit matched; current reference worktree had zero dirty entries. Header bytes, ordered fixture inventory, all five surface hashes, and the existence of each current selector were checked.

### 3.4 Ignore and setup boundaries

`git check-ignore` confirmed:

- ignored: `notepad-plus-plus/README.md`, `.env`, `.env.local`, `DerivedData/x`, `.build/x`
- not ignored/versionable: `.env.example`, setup/checker/verifier scripts, parity artifacts, tests, and fixtures

The literal `/` target is rejected. The setup target safety and clean-state claims are nevertheless incomplete; see F-03.

### 3.5 Semantic command mapping

The report and pinned resource labels establish these corrected mappings:

| Source command(s) | Pinned source label | Current feature mapping | Result |
| --- | --- | --- | --- |
| `IDM_VIEW_WRAP`, `IDM_VIEW_WRAP_SYMBOL` | Word wrap / Show Wrap Symbol | `C2.F12` editor word wrap and marker | Correct |
| `IDM_VIEW_ALL_CHARACTERS`, `IDM_VIEW_TAB_SPACE`, `IDM_VIEW_EOL`, `IDM_VIEW_NPC`, `IDM_VIEW_NPC_CCUNIEOL` | visible whitespace/EOL/control characters | `C3.F13` | Correct |
| `IDM_VIEW_HIDELINES` | Hide Lines | `C2.F13` hide/reveal selected lines | Correct |
| `IDM_VIEW_GOTO_START`, `IDM_VIEW_GOTO_END` | Move to Start / Move to End | `C2.F02` tab selection/reorder | Correct |
| `IDM_VIEW_TAB_START`, `IDM_VIEW_TAB_END` | First Tab / Last Tab | `C2.F02` tab navigation | Correct |

The concrete false mappings reported by the previous reviewer are fixed. The workflow-inventory completeness and ambiguity detector is still not fail-closed; see F-01.

### 3.6 Adversarial release, receipt, evidence, workflow, gate, and numeric probes

The following malformed isolated copies correctly failed:

- missing G10: exact G1-G10 error
- boolean category weight: strict JSON-number error
- string defect count: strict JSON-integer error
- unused command rule: zero-match error
- duplicate command mapping for `IDM_FILE_NEW`: ambiguous-source error
- workflow with unknown feature: unmapped-workflow error
- missing or mismatched sidecar, source commit/header/symbol/surface drift, false selector, invalid regex/disposition, pending N/A with receipt fields, receipt hash/identity/candidate mismatch: covered by and passing in the 18-test suite

Three internally consistent adversarial cases did **not** fail:

1. An arbitrary candidate hash with no candidate artifact, one builder-authored text file claiming both automated and manual success, all feature/gate states promoted, and builder-authored JSON receipts copying the public reviewer ID/fingerprint produced score `100.0`, no pending N/A, and **`release_pass=true`**.
2. Adding a second workflow ID with the exact same `(surface_id, selector)` as `WF.C1.F06`, mapped to another feature, passed both default and explicit integration validation with workflow count 33.
3. Removing `WF.C2.F12` or `WF.C3.F13` passed explicit integration validation with workflow count 31 because those features retained command mappings and each affected surface still had at least one other workflow.

These probes are reproducible by deep-copying the production JSON, updating its adjacent sidecar after each mutation, and invoking `validate_and_calculate`; the existing `ParityBaselineTests.release()` at `tests/test_parity_baseline.py:44-71` already constructs the same unsigned, self-authored evidence/receipt shape used by case 1 and asserts release success in `test_positive_release_fixture_passes`.

## 4. Previous re-review finding disposition

| Previous finding | Final-review disposition | Evidence |
| --- | --- | --- |
| M-01 user-visible denominator and semantic mappings | **Partially remediated; Major remains (F-01)** | All 530 fixture symbols map exactly once, five surfaces and 32 workflows now exist, and the listed wrap/visible-character/hide-line/tab-edge semantics are corrected. However workflow removal and duplicate selector-to-feature mappings pass even under explicit integration. Presence of at least one workflow per surface is not exhaustive or unambiguous coverage. |
| M-02 trusted release state/evidence/gates/N/A | **Partially remediated; Major remains (F-02)** | Owner/acceptance fields, exact G1-G10, non-vacuous P0, evidence paths/hashes, strict N/A shape, and a receipt verifier now exist. The candidate digest is not resolved to any candidate artifact; evidence `verifier` and `result` are self-asserted strings; receipts contain no reviewer-authenticating proof. A fully self-consistent forgery passes release. |
| M-03 ignored reference breaks default validation | **Normal-path resolved; integration cleanliness remains Major (F-03)** | The isolated reference-free suite and checker pass all 18 tests. Setup and explicit integration pass on the current clean pinned tree. The setup script accepts a pinned-but-dirty tree and only lexically compares unsafe target paths. |
| M-04 index falsely claims approval | **Resolved** | `docs/wiki/00-wiki-index.md:5-30` marks the milestone not commit-authorized, both reviews Rejected, and 01/02/03 plus parity artifacts/checker Pending approval. |
| m-01 future `process.runTool` escape | **Resolved as a v1 boundary** | Document 02:309-334 keeps it Unavailable/Missing, denies runtime/LSP access, and requires host-owned typed fields, forbidden discovery/environment paths, immutable-vault identity/TOCTOU controls, bounded resources, and a separate ADR/review before enablement. Section 6.6 makes the adversarial contract a MUST. |
| m-02 contribution IDs not manifest-owned | **Resolved** | Manifest ID is `com.example.symbol-tools`; command, panel, activation, and action examples all use that exact reverse-DNS prefix. No `example.sortLines`, `example.symbols`, or `example.openSymbol` remains. |
| m-03 numeric coercion | **Resolved** | Booleans/coerced strings/non-finite numbers are rejected; defect count requires an exact nonnegative JSON integer; category weights are finite positive JSON numbers summing to 100. Dedicated tests pass. |
| m-04 governance-critical fixture coverage | **Substantially expanded but incomplete; impacts included in F-01/F-02/F-03** | Suite grew from 5 to exactly 18 and covers the listed simple mutations and CLI code 2. It does not reject internally consistent forged authorship/evidence, removed/duplicate workflow selectors, or a pinned-but-dirty setup tree. |
| m-05 duplicate prose | **Resolved** | C2 has one table header. The duplicate LSP rationale is absent; one coherent LSP ownership/provider section remains. |

Earlier first-review findings B-01 and B-02 also remain correctly remediated at the design level: the two-artifact protocol removes staged-hash recursion, and document 01 plus its versioned JSON is the single parity formula. B-01 enforcement is explicitly deferred and absent, so it supplies no current commit authority.

## 5. User-requirement disposition

| User requirement | Result | Evidence and limitation |
| --- | --- | --- |
| 1. Fix simple scratch-first/deep-capability philosophy, broad language support, and VS Code-class plugin direction | **Pass for the decision baseline** | Document 01:11-42 prominently fixes scratch-first, loss-averse, many-language, working-memory tabs, plugin extensibility, and Mac-first principles. Document 02 fixes Swift/AppKit, Scintilla/Lexilla, LSP, and an isolated plugin direction. |
| 2. Present the main emphasis prominently after autonomous work | **Pass** | Document 01:11-15 gives the loss-averse paste-first promise its own top-level quotation and product explanation. |
| 3. Port at least 90% of Notepad++ feature/UX with mandatory macOS optimization | **Not achieved; milestone content rejected** | This milestone contains a target and scoring baseline, not an implementation; current score is 0.0. More importantly F-01/F-02 permit a future denominator/proof forgery, so `release_pass=true` is not yet authoritative. Native macOS gates are well specified but not implemented. |
| 4. Use Local Git | **Pass for current state and policy** | Root repository is local, unborn, remote-free, and keeps the reference tree ignored. No commit exists. |
| 5. Review before every commit | **Pass as design; unavailable as enforcement** | Document 03 defines independent exact-candidate review and a nonrecursive receipt. The required verifier, wrapper, hook, and E2E fixture do not exist, so no commit is currently authorized. With zero commits there is no historical violation to report. |
| 6. English commit header and content | **Pass as policy only** | Document 03:38-78 is explicit and gives English examples. There are no commits to audit. |
| 7. Apply Clean Architecture while porting | **Pass for architecture design; implementation not started** | Documents 02:49-105 and 03:262-285 agree on outer adapters to Application to Domain, typed identities, ports, and AppKit/Scintilla/plugin isolation. There is no product code yet to verify against this design. |
| 8. Use sub-agents and share each agent's work/design in Markdown wiki form | **Pass for this milestone's recorded work** | Documents 01-03, the wiki index, both earlier reviews, and this independent final review identify agents, roles, decisions, files, commands, results, and commit state. |

## 6. Findings

### Blocker

None.

### Major

`docs/parity/notepad-plus-plus-command-baseline.v1.json:47-335` / `scripts/check_parity_baseline.py:457-516` / `tests/test_parity_baseline.py:192-216`: **F-01 — workflow coverage is neither frozen nor one-to-one.** Removing current workflow records for word wrap or visible characters passes explicit integration, and duplicating one selector under another workflow/feature also passes. `used_surface_ids == surface_ids` proves only one record per surface, while integration proves only that every supplied regex appears at least once. Freeze the expected workflow ID/selector occurrence inventory independently, reject missing IDs and duplicate/overlapping selector ownership, validate expected match counts or stable source anchors, and add removal/ambiguity tests that run against the pinned source.

`docs/parity/notepad-plus-plus-command-baseline.v1.json:2833-2846` / `scripts/check_parity_baseline.py:221-250,264-318,382-398,544-557` / `scripts/verify_parity_review_receipt.py:56-106` / `tests/test_parity_baseline.py:44-71,108-111`: **F-02 — the release proof authenticates internal consistency, not candidate/evidence/reviewer provenance.** `candidate.sha256` is not computed from a resolvable candidate; an evidence artifact can be arbitrary text with self-declared `kinds`, `verifier`, and `result`; anyone can copy the public reviewer fingerprint into an unsigned receipt. The independent probe built exactly those files and obtained `release_pass=true`. Bind the candidate to a verifiably resolved build/tree/manifest, define machine-verifiable evidence result formats or trusted attestation receipts, bind reviewer authorship through the implemented local-review authority or a signature unavailable to builders, and add an internally consistent forgery test whose required result is rejection.

`scripts/setup_notepadpp_reference.sh:8-40` / `docs/wiki/00-wiki-index.md:62-69`: **F-03 — reference setup does not enforce its clean-tree or canonical-target boundary.** The dirty check runs only when HEAD differs from the pin. A local clone already at the pinned commit with one untracked dirty file returned exit code 0 and completed integration audit while remaining dirty. The root guard compares the caller's raw string, so `.` is not recognized as the absolute repository root and was rejected only later because this worktree happened to be dirty. Canonicalize and constrain the target before any Git operation, reject the Duckpad root and `/` by resolved identity, and require a clean reference before and after audit regardless of current HEAD; add dirty-at-pin, relative-root, symlink, and unrelated-repository fixtures.

### Minor

None.

### Notes

`docs/parity/notepad-plus-plus-command-baseline.v1.json` / `scripts/check_parity_baseline.py`: **N-01 — command-side coverage is materially improved.** All 530 fixture symbols are unique and exactly classified, zero-match and multiple-match command rules fail, the 492/13/25 partition sums to 530, and the corrected high-risk semantic mappings match the pinned menu labels.

`docs/wiki/02-clean-architecture-and-plugins.md:200-395`: **N-02 — plugin v1 is a coherent fail-closed architecture candidate.** XPC, non-JIT Core WebAssembly, no WASI/ambient OS access, broker mediation, host-rendered panels, entitlement/direct-access/crash/supply-chain gates, and future ToolBroker constraints are explicit MUSTs. This is design evidence, not implementation evidence.

`docs/wiki/03-development-workflow-and-roadmap.md:127-179`: **N-03 — receipt recursion is resolved in design but no commit gate exists yet.** The external immutable receipt avoids self-reference; absent verifier/wrapper/hook/E2E means the policy correctly forbids a commit today.

`docs/wiki/00-wiki-index.md:5-30`: **N-04 — index status is truthful.** Source self-labels such as `Binding` do not override the Pending approval index or the two Rejected reviews.

`tests/test_parity_baseline.py`: **N-05 — normal reproducibility is proven.** The suite has exactly 18 tests and runs without the ignored upstream tree. Passing tests do not close F-01/F-02/F-03 because their positive fixture and omitted adversarial cases define a weaker trust boundary than the release claim.

## 7. Residual risks

- The 32-entry workflow inventory is a curated list embedded in the same mutable JSON it is intended to validate; it does not prove exhaustive coverage of non-command user-visible behavior.
- A baseline editor can currently create a mutually consistent candidate hash, evidence file, reviewer receipt, state table, and sidecar without possessing any reviewer-only proof.
- The source integration audit establishes current selected-file hashes and selector presence, but not a clean reference invariant or full-tree provenance under the setup path.
- Product, architecture, security, UX, and performance behavior remain unimplemented. Current score 0.0 accurately reflects that state.
- Local Git governance remains manual until Phase 0 implements and independently reviews the exact-candidate verifier, commit wrapper, raw-commit hook, and E2E fixture.
- This review is not bound to an index tree, parent, staged binary diff, or English commit-message digest and cannot authorize a commit.

## 8. Verdict

**REJECTED.** Finding count: **0 Blockers, 3 Majors, 0 Minors, 5 Notes**.

The candidate has strong product, Clean Architecture, macOS, plugin, clean-checkout, semantic-command, numeric-validation, and index-status improvements. Content approval requires Blocker and Major counts of zero. F-01, F-02, and F-03 therefore prevent **CONTENT APPROVED**.

Required next review input:

1. fail-closed workflow inventory identity, removal detection, and selector ambiguity/occurrence enforcement with pinned-source negative tests;
2. actual candidate resolution plus evidence and reviewer provenance that an internally consistent builder forgery cannot satisfy;
3. canonical target containment and unconditional clean-worktree enforcement in reference setup, with adversarial fixtures;
4. a new independent full-candidate review after remediation.

Even after content approval, commit authorization remains a separate operation. It requires implementation of document 03's review verifier/wrapper/hook, a frozen staged candidate and English message, and a canonical receipt for that exact identity. None exists now. No stage or commit is authorized by this document.

## 9. Agent Work Log

- **Task:** `/root/workflow_roadmap/milestone_final_review`
- **Agent:** `/root/workflow_roadmap/milestone_final_review`
- **Role:** Independent grandchild reviewer; no builder role in the reviewed candidate
- **Goal:** Revalidate all schema-v2 remediation and the complete Milestone 01 candidate against the eight user requirements and pinned Notepad++ source.
- **Scope:** Root ignore/index, documents 01-03, both earlier reviews, all parity artifacts, all related scripts, test suite/fixtures, current Local Git state, and pinned ignored reference.
- **Explicit non-scope:** Candidate remediation, staging, commit creation, canonical receipt generation, application implementation, legal advice.
- **Skill:** `caveman-review` was used for concise, location-specific findings; architectural and trust-boundary findings retain full rationale as required by that skill's clarity exception.
- **Evidence:** Full-file reads; JSON structural inventory; exhaustive 530-command report; exact 18-test normal and isolated runs; default/required-release CLI codes; sidecar and symbol hashes; explicit pinned integration audit; Git/ignore/index inspection; semantic resource-label checks; forged release/evidence/receipt, removed/duplicate workflow, malformed gate/weight/numeric/rule, and dirty-reference probes.
- **Key decisions:** Accept the corrected concrete command semantics, clean-checkout normal path, index state, plugin/ToolBroker design, reverse-DNS examples, numeric strictness, and prose cleanup; reject the workflow and release proof because the stronger internally consistent adversarial cases pass; reject setup cleanliness as an enforced invariant despite the current reference happening to be clean.
- **Files changed by reviewer:** `docs/wiki/reviews/2026-09-02-milestone-01-final-review.md` only.
- **Validation result:** 18/18 normal tests pass; isolated 18/18 and default checker pass without reference; current explicit reference audit passes at clean full pin; three major adversarial trust/inventory/setup failures reproduced.
- **Findings:** 0 Blocker, 3 Major, 0 Minor, 5 Note.
- **Decision:** REJECTED; neither content approval nor commit authorization granted.
- **Commit:** None.
