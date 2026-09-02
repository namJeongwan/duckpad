# Milestone 01 Governance Approval Review

> **Status: REJECTED — 0 Blockers, 1 Major, 1 Minor**
>
> Date: 2026-09-02 (Asia/Seoul)
>
> Reviewer: `/root/clean_architecture/governance_approval_reviewer`
>
> Verdict: **CONTENT NOT APPROVED**

## 1. Scope and independence

This was an independent adversarial re-review of the requested Milestone 01 governance/content candidate. The reviewer did not build the remediation and did not treat builder test counts or prior closure statements as evidence.

The reviewed scope was limited to `.gitignore`, wiki documents 00-03, all existing `docs/wiki/reviews/`, all `docs/parity/`, all `scripts/`, governance/parity tests, and the ignored pinned Notepad++ reference. The review specifically retested F-02a, F-02b, C-01, C-02, C-03, README absence, direct integration cleanliness, and candidate-tree rejection of Notepad++ paths and gitlinks.

Reviewed source was not edited, staged, or committed. The pinned Notepad++ worktree was used read-only.

## 2. Commands and evidence

Representative commands executed:

```sh
python3 -B -m unittest -v tests/test_parity_baseline.py
python3 -B -m unittest -v tests/governance/test_review_gate.py
DUCKPAD_NPP_REFERENCE=notepad-plus-plus \
  python3 -B -m unittest -v tests/test_parity_integration.py
python3 -B scripts/check_parity_baseline.py
python3 -B scripts/check_parity_baseline.py \
  --integration-reference notepad-plus-plus
(cd docs/parity && shasum -a 256 -c \
  notepad-plus-plus-command-baseline.v1.sha256)
(cd docs/parity && shasum -a 256 -c \
  notepad-plus-plus-workflow-inventory.v1.sha256)
find . -path './.git' -prune -o -path './notepad-plus-plus' -prune -o \
  \( -type d \( -name __pycache__ -o -name .pytest_cache \) \
  -o -type f \( -name '*.pyc' -o -name '*.pyo' \) \) -print
git -C notepad-plus-plus rev-parse HEAD
git -C notepad-plus-plus status --porcelain --untracked-files=all
git diff --cached --name-only
```

Observed results:

| Validation | Result |
| --- | --- |
| Reference-free parity | **30/31 passed; 1 failed** (`test_python_bytecode_is_excluded_from_candidate`) |
| Governance | **7/7 passed** |
| Pinned integration | **7/7 passed** |
| Isolated clean-copy parity + governance | **37/38 passed; same hygiene failure** |
| Default checker | PASS; truthful `release_pass=false`, score `0.0` |
| Direct pinned checker | PASS; `integration_reference_audited=true` |
| Baseline/workflow sidecars | PASS |
| Notepad++ reference | HEAD `dda973d2b2da6bdcc7db9f18a7f5d2fbf6b07248`; clean before and after |
| Root README | absent |
| Staged paths / product commits | none / unborn `main` |

The direct integration dirty-tree test passed and the explicit checker preserved the reference HEAD and clean state. Code inspection also confirmed `validate_candidate_tree` rejects every mode `160000`/commit entry and every case-folded `notepad-plus-plus` path component; prepare, current-candidate verification, and commit audit all invoke that check.

## 3. Adversarial findings

### Blocker

None.

### Major

`scripts/check_parity_baseline.py:102-159,456-501` / `tests/test_parity_baseline.py:383-408`: **F-02a remains partially open — a subsequent parity release is not bound to its actual parent commit.** The resolver verifies only that the declared `parent_oid` names some commit object containing a registry with the declared digest. Neither the release candidate manifest nor the resolver connects that OID to the candidate's immediate parent or ancestry.

A temporary repository was created with commit A containing an active reviewer and later commit B revoking that reviewer. With B as the current lineage point, `approval_registry_source.parent_oid` was set back to A. The resolver accepted A and returned the revoked reviewer's registry:

```text
ATTACK_ACCEPTED stale_non_parent_registry=true
declared_old=df90ce9a4f97a1889780db5ac84b1ed90f4757f6
actual_current_parent=cb8196615ee5fea847078326e2346d5dfcc96210
resolved_contains_old_reviewer=true
```

This is directly within the requested “subsequent parent-commit registry two-step” requirement: an arbitrary old or side-branch commit can currently be selected instead of the exact parent, restoring an ineligible or revoked reviewer. Bind the release candidate to a Duckpad Git commit identity and require the declared registry commit to be its exact parent before resolving the registry.

The ROOT half is fixed: the commit gate resolves the read-only external `genesis-reviewers.json` plus filename-bound digest, and an externally keyed reviewer present only in the candidate registry cannot approve the same ROOT commit. Parity evidence and a separately reproduced Reviewed-N/A candidate-only signature were likewise rejected against the external genesis snapshot.

### Minor

`tests/test_parity_baseline.py:107-117,590-602`: **C-02 remains open — the hygiene assertion exists but the standard suite creates the artifact it then rejects.** `python3 -B` applies to the unittest process, while parity fixture helpers spawn `sys.executable` without `-B` or `PYTHONDONTWRITEBYTECODE`. Those child imports create:

```text
scripts/review/__pycache__/
scripts/review/__pycache__/review_common.cpython-312.pyc
```

Consequently the normal suite failed 30/31 in the working copy, and a cache-free isolated copy independently failed 37/38 after generating the same files. Ensure child Python invocations also disable bytecode and remove the generated cache before candidate freeze.

## 4. Previous finding disposition

| Finding | Disposition | Evidence |
| --- | --- | --- |
| F-02a | **PARTIAL / OPEN Major** | External ROOT snapshot and candidate-only ROOT commit/parity evidence/N-A rejection pass. Commit follow-up uses its exact manifest parent. Subsequent parity accepts any committed registry OID without exact-parent binding. |
| F-02b | **CLOSED** | The non-self-referential canonical projection covers source/workflows, state ratios, category weights, feature priorities/acceptance/mappings, gates, and release/defect policy. Typed results, evidence, and Reviewed-N/A payloads bind its digest. Recomputed-digest post-sign mutations for all requested normative classes were rejected; candidate, state, evidence IDs/envelopes, and live defect count do not change the digest. |
| C-01 | **CLOSED** | Signed negative receipts reject bool/float schemas and counts, whitespace/padded scope or validation entries, and noncanonical UTC offsets. Exact non-bool integers, trimmed nonempty arrays, and `YYYY-MM-DDTHH:MM:SS.ffffffZ` are enforced in verify and audit paths. |
| C-02 | **OPEN Minor** | Ignore rules and an assertion exist, but normal execution creates `.pyc` and fails that assertion. |
| C-03 | **CLOSED** | Document 01 says `Pending approval`; index status is consistent. No root or wiki README was created. |

The parity-contract differential audit observed digest changes for weight, priority, feature acceptance, mapping, workflow acceptance, gate acceptance, release threshold, and defect policy. It observed no digest change for feature/gate state, evidence IDs/envelopes, candidate metadata, or the live open-defect count. Existing signed attestations then failed after every normative mutation even when the unsigned contract digest and sidecar were refreshed.

## 5. Final verdict

**REJECTED: 0 Blockers, 1 Major, 1 Minor. CONTENT APPROVED is not issued.**

The approval criterion is zero Blockers and zero Majors. F-02a's exact subsequent-parent requirement is still bypassable, so the candidate cannot be approved despite the closure of F-02b, C-01, and C-03 and the fixed ROOT genesis behavior. No exact candidate receipt or commit authorization is granted by this Markdown review.

## 6. Agent Work Log

- **Task:** `/root/clean_architecture/governance_approval_reviewer`
- **Role:** independent adversarial governance/content reviewer, separate from the builder
- **Skill:** `source-command-sc-analyze`
- **Date:** 2026-09-02 (Asia/Seoul)
- **Reviewed:** requested Milestone 01 governance/parity/wiki scope and ignored pinned reference
- **Static audit:** trust-source resolution, canonical contract projection, signed payload schemas, receipt validation, cache hygiene, candidate tree exclusions, status/README rules
- **Dynamic audit:** 31 normal parity tests, 7 governance tests, 7 pinned integration tests, default/direct checkers, two sidecars, isolated 38-test simulation, candidate-only Reviewed-N/A probe, stale non-parent registry attack, contract differential matrix
- **Files created:** `docs/wiki/reviews/2026-09-02-milestone-01-governance-approval.md` only
- **Reviewed source changes:** none
- **NPP changes:** none; pinned HEAD and clean status preserved
- **Stage/commit:** none
- **Verdict:** REJECTED; content approval withheld
