# Duckpad Wiki

Duckpad의 제품 결정, 아키텍처, 개발 규칙과 에이전트 작업 근거를 찾는 진입점이다. 제품 목표는 macOS에 최적화된 scratchpad 경험을 유지하면서 Notepad++의 기능과 사용자 경험을 90% 이상 이관하는 것이다.

> **Milestone 01 status: PENDING APPROVAL — NOT COMMIT-AUTHORIZED**
>
> 최초 리뷰, 재리뷰, final review와 latest approval review가 모두 `REJECTED`다. F-02/m-01~m-04 remediation은 새 독립 승인과 exact-candidate receipt 전까지 승인된 baseline 또는 commit authorization이 아니다.

## 읽는 순서와 현재 상태

상태는 원문이 스스로 붙인 표현이 아니라 독립 review evidence의 최신 verdict에서 도출한다. 현재 읽는 순서는 다음과 같다.

| 순서 | Artifact | 현재 상태 | 읽는 이유와 근거 |
| ---: | --- | --- | --- |
| 1 | [Milestone 01 최초 독립 리뷰](reviews/2026-09-02-milestone-01-review.md) | **Rejected** | 최초 판정과 B-01/B-02, M-01~M-03, m-01/m-02를 확인한다. commit authorization은 부여되지 않았다. |
| 2 | [Milestone 01 독립 재리뷰](reviews/2026-09-02-milestone-01-rereview.md) | **Rejected** | M-01~M-04와 m-01~m-05 검증 결과다. commit authorization은 부여되지 않았다. |
| 3 | [Milestone 01 final review](reviews/2026-09-02-milestone-01-final-review.md) | **Rejected** | 0 Blocker, F-01/F-02/F-03 Major 판정이다. |
| 4 | [Milestone 01 approval review](reviews/2026-09-02-milestone-01-approval-review.md) | **Rejected — latest review evidence** | F-02 self-registration Major와 m-01~m-04를 확인한다. 현재 remediation은 새 독립 review 전까지 pending이다. |
| 5 | [제품 철학과 Notepad++ 패리티 기준선](01-product-philosophy-and-parity.md) | **Pending approval** | 제품 철학과 schema v3 단일 parity 알고리즘 candidate다. immutable contract digest가 서명 증거를 규범에 고정하며, 현재 not-built/0%/release false다. |
| 6 | [Clean Architecture와 Plugin Platform](02-clean-architecture-and-plugins.md) | **Pending approval** | Swift/AppKit, Scintilla, domain/session/tab, XPC/WebAssembly plugin 설계 candidate다. 독립 승인 전이므로 `Accepted`가 아니다. |
| 7 | [개발 워크플로와 로드맵](03-development-workflow-and-roadmap.md) | **Pending approval** | parent-pinned registry, pre-provisioned trust, 영어 commit, signed receipt와 roadmap candidate다. |
| 8 | [Parity baseline JSON](../parity/notepad-plus-plus-command-baseline.v1.json) + [SHA-256 sidecar](../parity/notepad-plus-plus-command-baseline.v1.sha256) + [public reviewer registry](../parity/reviewer-identities.v1.json) | **Pending approval** | candidate artifact와 signed evidence provenance를 강제하는 machine-readable denominator다. |
| 9 | [Parity checker](../../scripts/check_parity_baseline.py) + [reference-free tests](../../tests/test_parity_baseline.py) + [pinned integration tests](../../tests/test_parity_integration.py) + [command fixture](../../tests/fixtures/) + [frozen workflow fixture](../parity/notepad-plus-plus-workflow-inventory.v1.json) | **Pending approval** | duplicate-key fail-closed parsing, clean direct audit, workflow identity와 signed-release adversarial audit를 재현한다. |
| 10 | [Review gate tools](../../scripts/review/) + [governance E2E](../../tests/governance/review-receipt-e2e.sh) | **Pending approval** | shipped bootstrap 없이 pre-provisioned trust, authenticated builder identity, parent-pinned reviewer onboarding, wrapper/hook/audit를 구현한다. |
| 11 | [Phase 1 구현 foundation](04-implementation-foundation.md) | **Implemented; review pending** | Swift 6/AppKit executable, inward-only modules, typed scratch model, multiline tabs와 현재 Scintilla gap을 기록한다. |

상태 정의:

- **Pending approval:** 작성 또는 remediation은 진행됐지만 승인 verdict와 exact-candidate receipt가 없다. 구현의 승인 근거 또는 commit 권한으로 단독 사용하지 않는다.
- **Rejected:** 독립 reviewer가 변경 필요를 판정했다. 후속 수정이 있어도 새 독립 review가 승인하기 전까지 rejected evidence는 그대로 유효하다.
- **Approved:** 독립 review의 Blocker/Major가 0이고 정확한 candidate에 대한 canonical local receipt가 있을 때만 사용한다.
- **Superseded:** 승인된 새 결정이 대체했으며 대체 문서와 review evidence를 링크한다.

원문 상태와 index가 충돌하면 이 index도 임의로 승격하지 않는다. 최신 독립 review와 canonical receipt를 먼저 확인하고, 승인 evidence를 같은 변경에 포함해 index를 갱신한다.

## Wiki 기록 규칙

**모든 에이전트 작업과 핵심 설계 결정은 Markdown wiki에 남긴다.** 대화나 터미널 출력만으로 작업 완료를 주장할 수 없다. 구현 작업은 가능한 한 `docs/wiki/work-logs/<task-id>.md`에 목표, 범위, 담당 에이전트, 조사 근거, 설계 결정, 변경 파일, 검증 결과, 리뷰 finding과 commit evidence를 기록한다. 여러 에이전트가 참여하면 각 에이전트의 역할과 산출물을 구분한다.

참고용 `notepad-plus-plus/`는 분석 근거일 뿐 Duckpad 제품 이력이 아니다. 내부 Git 저장소를 수정하거나 Duckpad 루트 저장소에 포함하지 않는다.

## Notepad++ reference와 clean-checkout 재현성

`notepad-plus-plus/` reference tree는 [root `.gitignore`](../../.gitignore)에 의해 의도적으로 제외된다. 일반적인 clean Local Git checkout에는 이 디렉터리가 없어야 하며, normal validation은 네트워크와 reference tree 없이 versioned baseline/fixture만으로 실행되어야 한다.

Normal clean-checkout validation:

```sh
python3 -B -m unittest -v tests/test_parity_baseline.py
python3 -B -m unittest -v tests/governance/test_review_gate.py
python3 -B scripts/check_parity_baseline.py
```

실제 upstream source와 pinned hashes/workflow surface를 다시 감사할 때만 ignored reference tree를 설치한다. [reference setup script](../../scripts/setup_notepadpp_reference.sh)는 공식 Notepad++ 저장소를 `notepad-plus-plus/`에 clone/fetch하고, full commit `dda973d2b2da6bdcc7db9f18a7f5d2fbf6b07248`을 detached checkout한 뒤 integration audit를 실행한다.

```sh
scripts/setup_notepadpp_reference.sh notepad-plus-plus
```

이미 올바른 reference tree가 있으면 explicit audit만 다시 실행할 수 있다.

```sh
python3 -B scripts/check_parity_baseline.py \
  --integration-reference notepad-plus-plus
DUCKPAD_NPP_REFERENCE=notepad-plus-plus \
  python3 -B -m unittest -v tests/test_parity_integration.py
```

정책 경계:

- normal test/checker가 ignored reference tree의 존재를 요구하면 재현성 회귀이며 실패다.
- setup/integration audit는 reference commit, source symbols, user-visible workflow surfaces와 고정 checksum의 drift를 검사한다. 별도 workflow fixture가 ID/surface/selector/feature/expected occurrence를 동결하며 missing/extra/duplicate/overlap을 거부한다.
- direct `--integration-reference` checker도 시작/종료 시 clean worktree와 unchanged pinned HEAD를 강제한다.
- setup target `/notepad-plus-plus/`만 ignore되고 `scripts/setup_notepadpp_reference.sh`, baseline, checker, tests와 fixtures는 versioned 대상이어야 한다.
- setup은 첫 Git 명령 전에 target을 physical canonical path로 해석한다. `/`, Duckpad root, symlink/escape, root 밖 또는 nested unsafe parent를 거부하고 root direct child만 허용한다.
- 기존 repository는 canonical target과 standalone Git top-level이 같고 official origin URL이 일치해야 한다. pinned 여부와 무관하게 setup 전, audit 전, audit 후 모두 clean이어야 하며 audit 후 HEAD도 full pin과 다시 일치해야 한다.
- 최초 clone/fetch에는 네트워크가 필요하지만 normal validation에는 네트워크가 필요하지 않다.
- reference tree의 upstream commit을 바꾸려면 baseline version, checksum, mapping audit, 문서 및 독립 review를 함께 갱신한다.

## Agent Work Log

### repository-bootstrap

- **Status:** Builder task completed; milestone approval and commit pending
- **Date:** 2026-09-02
- **Agent:** `/root/repository_bootstrap`
- **Role:** Builder / repository bootstrap
- **Scope:** Duckpad 제품 루트에 원격 없는 Local Git 경계를 만들고, 참고 저장소·macOS/Swift/Xcode 산출물·사용자별 상태·복구 시험 산출물·비밀을 제외하는 ignore 정책과 wiki 진입점을 추가한다.
- **Out of scope:** 참고용 Notepad++ 저장소 변경, staging, commit, remote 설정, 애플리케이션 코드 또는 기존 결정 문서 변경.
- **Decisions:** 기본 브랜치는 `main`이다. `/notepad-plus-plus/`는 루트에서 완전히 ignore하여 nested Git 이력과 제품 이력을 분리한다. 재현에 필요한 shared project 설정과 dependency resolution 파일은 ignore하지 않고 사용자별 Xcode 상태와 로컬 비밀만 제외한다.
- **Files changed:** `.gitignore`, `docs/wiki/00-wiki-index.md` (처음의 wiki README 이름은 이후 README 금지 결정에 따라 rename).
- **Validation:** `git status --short --ignored`로 두 새 파일이 untracked이고 참고 저장소가 ignored임을 확인한다. `git remote -v`는 출력이 없어야 한다. 이 bootstrap은 요청에 따라 stage하거나 commit하지 않는다.
- **Commit evidence:** Not applicable; staging과 commit은 이 작업 범위에서 명시적으로 금지되었다.

### 2026-09-02 — review-state and reference-reproducibility remediation

- **Agent:** `/root/workflow_roadmap`
- **Role:** Review finding investigator + wiki index builder
- **Findings in scope:** independent re-review M-04 and M-03 documentation/reproducibility portion
- **Evidence read:** source-document status headers, both rejected review documents, parity JSON/sidecar/checker/tests/fixtures, setup script, root Git state and `.gitignore`
- **Key decisions:** review verdict outranks self-declared source status; 01/02/03 remain Pending approval; reference checkout is optional for normal tests and required only for explicit pinned integration audit
- **Coordination:** `/root/philosophy_parity` provided and completed the actual setup path, pinned commit, clean-checkout fixture and final normal/integration CLI
- **Files changed by this agent:** 당시 wiki index only; 현재 경로는 `docs/wiki/00-wiki-index.md`
- **Validation:**
  - isolated temporary copy containing only versioned parity/scripts/tests artifacts: normal suite and default checker PASS without `notepad-plus-plus/`; 20 tests
  - `scripts/setup_notepadpp_reference.sh notepad-plus-plus` and explicit `--integration-reference notepad-plus-plus`: PASS, `integration_reference_audited=true`
  - pinned-source adversarial suite: 6 tests PASS (workflow removal, duplicate/overlap ownership, occurrence drift, dirty-at-pin 포함)
  - reference HEAD equals `dda973d2b2da6bdcc7db9f18a7f5d2fbf6b07248` and reference worktree is clean
  - baseline sidecar checksum: PASS
  - `.gitignore` ignores `/notepad-plus-plus/` while setup script, baseline, checker, tests and fixtures remain unignored
  - README local file/anchor links, required status phrases, code-fence balance and whitespace scan: PASS
- **Commit:** None; staging and commit are prohibited for this task

### 2026-09-02 — F-02 and Phase-0 gate implementation

- **Agent/role:** `/root/workflow_roadmap`, builder; `/root/workflow_roadmap/f02_investigator`, read-only investigator. Builder는 이 candidate를 review하지 않는다.
- **Evidence:** latest independent final review remains Rejected with F-01/F-02/F-03 Major findings. F-01/F-03 philosophy-agent remediation과 F-02 signed-authority implementation은 모두 새 독립 review 전까지 Pending approval이다.
- **Design:** `.git/duckpad-review-authority/v1/` reviewer-only Ed25519 key/local trust root + versioned public registry의 이중 확인, exact index/tree/parent/diff/English-message candidate, canonical signed receipt, wrapper-created commit와 immutable local mapping을 채택했다.
- **Parity:** schema v3 release proof는 resolvable manifest/source tree/build artifact를 재hash하고, active independent reviewer가 candidate/feature·gate/typed result에 서명한 evidence만 허용한다. unsigned/self-authored/fingerprint-copy 증거와 replay/tamper/missing artifact는 실패한다.
- **Validation:** reference-free parity 24/24, governance unborn-repo E2E 3/3, pinned integration 6/6, setup+default/explicit checker와 baseline/workflow sidecars가 모두 통과했다. local `core.hooksPath=scripts/review/hooks`도 확인했다.
- **Clean-checkout simulation:** `/tmp/duckpad-clean.yuPV8d`의 parity/scripts/tests-only copy에서 ignored Notepad++ tree 없이 normal 24/24과 default checker가 통과했다.
- **Commit:** stage/commit하지 않았다. 후속 독립 reviewer만 approval과 commit authorization을 판정한다.

### 2026-09-02 — reference-tree exclusion and README-free index

- **Agent/role:** `/root/philosophy_parity`, governance implementation builder.
- **Decision:** Duckpad history에는 `notepad-plus-plus`라는 path component를 가진 staged entry를 대소문자와 관계없이 포함하지 않는다. 외부 저장소가 다른 이름으로 들어오는 우회까지 차단하기 위해 모든 Git gitlink도 금지한다.
- **Defense in depth:** root `.gitignore`의 `/notepad-plus-plus/`를 유지하면서 candidate prepare, verify, commit audit가 staged/committed tree 전체를 fail-closed로 검사한다.
- **Index policy:** README는 아직 작성하지 않는다. 기존 wiki entry point를 이 파일 `docs/wiki/00-wiki-index.md`로 이동했고 root `README.md`는 만들지 않았다.
- **Candidate enforcement:** `.gitignore`와 exact-candidate tree validator가 대소문자와 확장자에 관계없이 basename이 `README`로 시작하는 모든 path를 거부한다. force-add도 prepare에서 실패하며 governance fixture가 이를 검증한다.
- **Initial candidate preflight:** authenticated ROOT builder staging 전에 README/NPP/gitlink exclusion을 NUL-safe index 검사와 tree validator 양쪽에서 강제했다. commit message validator는 Conventional Commit body의 단일 빈 줄 paragraph 구분을 허용하되 비어 있거나 연속된 빈 paragraph는 계속 거부한다.
- **Tests:** governance fixture가 nested/lowercase path, macOS case-insensitive collision, prepare/verify 시점 및 arbitrary gitlink 거부를 검증한다.
- **Generated cache:** repository-owned source가 아닌 `scripts/**/__pycache__`, `tests/**/__pycache__`만 안전하게 정리했다. 이후 검증은 `python3 -B`로 실행한다.
- **Validation:** governance 6/6, reference-free parity 26/26, pinned integration 7/7, parity checker, Swift 8/8가 통과했다. old wiki README 경로 scan은 0건이고 root/wiki README는 존재하지 않으며 `/notepad-plus-plus/` ignore rule은 유지된다.
- **Commit:** 없음. stage/commit하지 않았다.

### 2026-09-02 — approval-review F-02/m-01..m-04 remediation

- **Agent/role:** `/root/workflow_roadmap`, builder; `/root/workflow_roadmap/trust_boundary_investigator`, cavecrew read-only investigator. 이 candidate의 독립 reviewer 역할은 수행하지 않는다.
- **Review input/status:** latest `2026-09-02-milestone-01-approval-review.md`는 Rejected다. 이번 수정은 새 독립 review와 exact receipt 전까지 Pending approval이다.
- **Trust boundary:** shipped authority bootstrap과 free-form commit builder ID를 제거했다. unborn은 `.git/duckpad-review-trust/v1`의 사전 allowed-signers/builder identity가 필요하고, 후속 candidate는 parent commit registry만 signer eligibility에 사용한다. 새 reviewer는 parent-active reviewer가 onboarding commit을 승인한 다음 candidate부터 사용할 수 있다.
- **Security scope:** 같은 macOS UID의 악성 owner/root 방어를 주장하지 않는다. 조직적 독립성은 orchestrator-provisioned identity/trust, independent agent review log와 exact signed receipt를 함께 근거로 한다.
- **Minors:** 모든 governance JSON loader에서 duplicate key를 거절하고, direct integration pre/post clean 및 unchanged HEAD를 강제했다. `.gitignore`가 `__pycache__/`와 `*.py[cod]`를 제외하며 document 03은 Pending approval이다.
- **Validation:** normal parity 26/26, governance 4/4, pinned integration 7/7, setup/default/sequential explicit checker와 두 sidecar가 통과했다. `/tmp/duckpad-clean-v2.3agQv8` reference-free copy에서도 normal+governance 30/30과 default checker가 통과했다. direct integration dirty probe와 Python cache ignore도 확인했다.
- **Integrity:** candidate preflight whitespace normalization 뒤 baseline sidecar `ce1af4e91b31db376145d9bd5b34bb4fc3bbab1c6759ffd3dcee8d99a4a44739`; workflow sidecar `d0d5e650145c0b28c9c82561cf46d528531e33d83235b46e38a7b0f35cfe96b4`; parity contract digest `80f57a3342b7e8df138650f8d37d6a1544896e2cc7f9cf87f60a9bdb9b80b6dc`.
- **Commit:** stage/commit하지 않았다.

### 2026-09-02 — content-approval F-02a/F-02b/C-01..C-03 remediation

- **Agent/role:** `/root/clean_architecture`, governance/parity builder. 이 변경을 승인하거나 commit하지 않는다.
- **Review input/status:** `reviews/2026-09-02-milestone-01-content-approval.md`의 F-02a, F-02b, C-01, C-02, C-03. 수정 결과는 새 독립 review 전까지 Pending approval이다.
- **Genesis trust:** ROOT commit과 최초 parity release는 candidate-tree registry가 아니라 orchestrator가 미리 둔 `$GIT_COMMON_DIR/duckpad-review-trust/v1/genesis-reviewers.json` 및 filename-bound `.sha256` snapshot만 signer eligibility에 사용한다. candidate에만 추가된 외부 키 보유 reviewer도 같은 ROOT candidate를 승인할 수 없다. 후속 commit/parity release는 parent commit의 registry blob과 digest를 resolve하는 two-step onboarding을 유지한다.
- **Parity contract:** `parity_contract_sha256`는 canonical JSON으로 source/workflow identities, state ratios, category weights, feature priorities·acceptance·mappings, UX gates와 release/defect policy를 묶는다. feature/gate 상태, evidence IDs, review receipt 상태, candidate와 evidence envelope는 제외하여 비자기참조이며, typed result와 모든 evidence/Reviewed-N/A 서명이 digest를 포함한다.
- **Receipt/hygiene/status:** commit receipt는 bool을 integer로 받지 않고 exact integer counts, 공백 없는 nonempty scope/validation, `YYYY-MM-DDTHH:MM:SS.ffffffZ` UTC를 강제한다. candidate tree의 Python cache/bytecode 부재를 test가 검사한다. 문서 01은 Pending approval로 정정했고 README는 생성하지 않았다.
- **Files changed:** governance/parity scripts and tests, baseline JSON/sidecar, 문서 01, 이 wiki index. Swift `Sources/`, `Tests/`, 문서 04와 Notepad++ reference는 변경하지 않았다.
- **Validation:** reference-free parity 31/31, governance 7/7, pinned integration 7/7, default/explicit checker, baseline/workflow sidecar가 통과했다. `.git`과 ignored reference가 없는 임시 copy를 새 Git repository로 초기화한 clean simulation에서도 normal+governance 38/38 및 default checker가 통과했다. cache/bytecode scan은 0건, pinned reference는 clean하며 HEAD는 `dda973d2b2da6bdcc7db9f18a7f5d2fbf6b07248`이다.
- **Commit:** stage/commit하지 않았다. 검증 결과는 최종 실행 후 기록한다.

### 2026-09-02 — governance-approval exact-parent/cache remediation

- **Agent/role:** `/root/clean_architecture`, focused governance builder; 독립 reviewer 역할은 수행하지 않는다.
- **Review input:** `reviews/2026-09-02-milestone-01-governance-approval.md`의 F-02a 잔여 Major와 C-02 Minor만 수정했다.
- **Exact parent:** parity release manifest가 검증 시점의 exact Git `HEAD` source commit과 committed source subtree를 함께 고정한다. root commit만 외부 genesis snapshot을 사용하고, 후속 release의 registry OID는 source commit의 유일한 즉시 parent와 같아야 한다. 오래된 ancestor/side-branch 선택은 거절된다.
- **Cache:** parity attestation test child process에도 `-B`와 `PYTHONDONTWRITEBYTECODE=1`을 전달한다. reviewer 실행이 남긴 exact `scripts/review/__pycache__/review_common.cpython-312.pyc`와 빈 directory를 제거했다.
- **Preserved gates:** candidate-only ROOT commit/parity rejection, parent onboarding, parity-contract signature binding, strict commit receipt, Notepad++ path/gitlink rejection, README 금지와 pinned reference 불변을 유지한다.
- **Validation:** parity 31/31, governance 7/7, pinned integration 7/7, default/direct checker가 통과했다. reference와 `.git` 없는 clean copy를 새 repository로 초기화한 simulation도 normal+governance 38/38, default checker와 post-suite cache scan 0건으로 통과했다.
- **Commit:** stage/commit하지 않았다. 최종 검증 수치는 실행 후 기록한다.

### 2026-09-02 — initial ROOT reviewer registry onboarding

- **Agent/role:** `/root/clean_architecture`, registry onboarding builder; reviewer 역할은 수행하지 않는다.
- **Source:** independent reviewer가 worktree 밖에 provision한 read-only `$GIT_COMMON_DIR/duckpad-review-trust/v1/genesis-reviewers.json` snapshot/digest.
- **Change:** `/root/phase1_code_review`의 exact Ed25519 public key, `independent_commit_reviewer` role과 active status record를 byte-identical하게 versioned `docs/parity/reviewer-identities.v1.json`에 추가했다. baseline의 candidate-registry 및 external-genesis digest를 함께 갱신했으며 parity contract projection은 review policy를 제외하므로 contract digest는 불변이다.
- **Authorization boundary:** 이 candidate의 ROOT 승인은 candidate registry가 아닌 이미 provision된 external genesis snapshot만 사용한다. versioned record는 이 commit 이후 parent-pinned candidate부터 onboarding 효력이 있다.
- **Validation:** external/versioned registry byte equality와 digest `11a02a452b525a9081d754be6cd143f39d8dee6dd41a59ca88299c4ee4fa6b3d`, unchanged parity contract digest, parity 31/31, governance 7/7, pinned integration 7/7 및 default/direct checker 통과를 확인했다.
- **Commit:** stage/commit하지 않았다. 최종 validation은 실행 후 기록한다.
