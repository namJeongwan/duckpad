# Duckpad 개발 워크플로와 로드맵

> Status: **Pending approval**
> Scope: Duckpad의 모든 설계, 구현, 테스트, 문서 및 로컬 커밋
> North star: macOS에 최적화된 “열고, 아무거나 붙이고, 잃지 않는” 편집 경험으로 Notepad++ 기능과 사용자 경험의 90% 이상을 제공한다.

## 1. 이 문서의 역할

이 문서는 제품 철학을 반복 설명하는 문서가 아니라, 그 철학을 매 작업마다 지키기 위한 실행 프로토콜이다. 모든 작업은 조사, 구현, 독립 리뷰, 검증, 기록, 로컬 커밋 순서를 따른다. 일정 압박이나 변경 크기는 이 순서를 생략할 이유가 되지 않는다.

최우선 개발 원칙은 다음과 같다.

1. **Scratch first:** 파일명, 프로젝트, 저장 위치를 정하기 전에 즉시 입력하고 붙여 넣을 수 있어야 한다.
2. **Never lose work:** 명시적으로 버리지 않은 버퍼는 정상 문서로 취급하고, 종료·충돌·재실행 뒤에도 복구한다.
3. **Power without ceremony:** 기본 사용은 메모장처럼 단순하되, 언어 지원과 플러그인은 점진적으로 확장한다.
4. **Mac-native:** Windows 화면을 복제하지 않는다. 기능의 의도를 유지하면서 메뉴, 단축키, 접근성, IME, Finder, 창 동작을 macOS 관례에 맞춘다.
5. **Clean boundaries:** UI 프레임워크, Scintilla, 파일 시스템, 세션 저장소, 플러그인 런타임을 도메인 정책과 분리한다.
6. **Evidence before commit:** 리뷰와 검증 기록이 없는 변경은 완료된 변경이 아니며 커밋할 수 없다.

## 2. 변경 불가 개발 규칙

### 2.1 Reviewed local commits and controlled GitHub delivery

- Duckpad 변경은 먼저 로컬 Git에서 review receipt, verified commit과 post-commit audit를 완료한다.
- 2026-09-03 사용자 승인에 따라 canonical remote는 `https://github.com/namJeongwan/duckpad.git`, delivery branch는 `main`이다. 검증이 끝난 로컬 commit만 `origin/main`에 push한다.
- force-push, history rewrite, 다른 remote/branch publication과 원격 PR 생성은 별도 명시적 승인 전까지 금지한다.
- `notepad-plus-plus/`처럼 참고용으로 가져온 저장소의 내부 Git 이력과 Duckpad 제품 이력을 혼합하지 않는다.
- 커밋 전 `git status --short`, `git diff --check`, staged diff와 포함 파일을 확인한다.
- 사용자 변경과 다른 에이전트 변경을 임의로 되돌리거나 함께 커밋하지 않는다.
- 비밀, 개인 데이터, 빌드 산출물, 복구 테스트 데이터가 staged 상태에 포함되지 않았는지 확인한다.

초기 저장소 bootstrap에서 다음 조건을 확정해야 한다.

- Duckpad 제품 루트가 단 하나의 명확한 Git 경계다.
- 참고 소스의 보관 방식과 라이선스 출처가 문서화되어 있다.
- ignore 규칙이 Xcode 사용자 상태, DerivedData, 세션 테스트 산출물과 비밀 파일을 제외한다.
- `origin` fetch/push URL은 canonical Duckpad remote와 정확히 일치해야 한다. Notepad++ reference repository의 remote나 객체를 Duckpad delivery에 혼합하지 않는다.

### 2.2 English-only commit messages

모든 커밋의 header와 body는 영어로 작성한다. Conventional Commits 형식을 권장한다.

```text
<type>(<optional-scope>): <imperative summary>

<why the change is needed>
<important behavior, trade-off, or migration note>
```

허용 type의 기본 집합은 `feat`, `fix`, `docs`, `refactor`, `test`, `build`, `chore`, `perf`이다.

규칙:

- header는 명령형 현재 시제로 쓰고 가능하면 72자 이내로 유지한다.
- body는 구현 목록보다 이유, 사용자 영향, 중요한 절충을 설명한다.
- breaking change는 `!`와 `BREAKING CHANGE:` footer로 표시한다.
- 한글 커밋 메시지, 의미 없는 `update`, 여러 독립 목적을 섞은 커밋은 허용하지 않는다.

예시:

```text
feat(session): recover unsaved buffers after relaunch

Persist scratch buffers with atomic replacement so an interrupted write cannot
replace the last known-good recovery snapshot.
```

```text
fix(tabs): preserve the active tab during multiline reflow

Keep selection stable when resizing the window changes the number of tab rows.
```

```text
docs(governance): define the independent review gate

Require reviewer approval for the exact candidate identity before every local
commit.
```

### 2.3 Independent review before every commit

모든 커밋은 구현에 참여하지 않은 **독립 reviewer 서브 에이전트**의 승인을 받아야 한다. 문서 한 줄, 테스트만의 변경, 긴급 수정도 예외가 아니다.

독립 reviewer의 조건:

- 해당 변경의 builder가 아니어야 한다.
- 해당 staged diff를 직접 읽고 요구사항, 설계, 회귀 위험, 테스트 적합성을 평가해야 한다.
- builder의 요약만으로 승인해서는 안 된다.
- 발견 사항이 없더라도 검토 범위와 남은 위험을 기록해야 한다.
- 승인 대상 candidate의 tree, parent, staged diff, 영어 commit message digest를 별도 local receipt에 기록해야 한다.

리뷰 결과의 분류와 처리:

| 등급 | 의미 | 커밋 조건 |
| --- | --- | --- |
| Blocker | 데이터 손실, 보안, 아키텍처 위반, 빌드/핵심 기능 실패 | 반드시 수정 후 전체 재검증·재리뷰 |
| Major | 요구사항 누락, 사용자 회귀, 잘못된 경계, 중요한 테스트 누락 | 반드시 수정 후 영향 범위 재검증·재리뷰 |
| Minor | 유지보수성 또는 비핵심 품질 문제 | 수정하거나 reviewer가 근거 있는 follow-up으로 승인해야 함 |
| Note | 질문, 제안, 비차단 관찰 | 결정과 근거를 기록하면 승인 가능 |

**승인은 candidate identity 하나에만 유효하다.** 리뷰 후 파일, stage, parent commit, 생성 파일, 의존성 lockfile 또는 commit message가 하나라도 바뀌면 identity가 바뀌고 승인은 무효다. builder는 검증을 다시 실행하고 새 identity로 reviewer의 재승인을 받아야 한다.

## 3. 작업별 에이전트 프로토콜

모든 변경은 최소 세 역할로 수행한다. 작은 작업에서도 역할을 생략하지 않으며, 여러 역할을 같은 에이전트가 맡더라도 reviewer는 반드시 독립되어야 한다.

| 역할 | 책임 | 필수 산출물 |
| --- | --- | --- |
| Investigator | 관련 코드, Notepad++ 동작, macOS 관례, 위험 및 검증 지점을 조사 | 근거 경로, 관찰 결과, 선택지와 권고안을 wiki 작업 로그에 기록 |
| Builder | 승인된 범위 안에서 Clean Architecture 경계를 지키며 구현하고 테스트 | 변경 파일, 설계 결정, 실행한 검증, 알려진 제한을 기록 |
| Reviewer | 구현에 참여하지 않고 frozen candidate를 검토 | finding, 해결 상태, 테스트 확인, candidate-bound local receipt, 승인/거절 기록 |

권장 작업 순서는 다음과 같다.

1. **Task record 생성:** `docs/wiki/work-logs/<task-id>.md`를 만들고 목표, 범위, 수용 조건, 역할별 에이전트 ID를 기록한다.
2. **Investigation:** 사용자 동작과 근거 코드를 조사하고, 구현 선택지와 위험을 기록한다.
3. **Design checkpoint:** 의존성 방향, 도메인 모델, adapter 경계, 테스트 전략을 기록한다. 불명확한 요구를 코드로 숨기지 않는다.
4. **Build:** builder가 좁은 수직 단위로 구현하고 자동 테스트를 추가한다.
5. **Builder validation:** 관련 단위·통합·UI·성능·접근성 테스트를 실행하고 결과를 작업 로그에 남긴다.
6. **Stage and freeze:** 의도한 versioned artifact만 stage하고 영어 commit message file을 고정한다. verifier가 candidate manifest와 identity를 생성한다.
7. **Independent review:** reviewer가 frozen candidate와 작업 로그를 직접 검토한다. finding을 versioned wiki에 반영해야 하면 candidate를 다시 만들고 이전 identity를 폐기한다.
8. **Resolve and reverify:** 모든 차단 finding을 해결한다. 변경이 생기면 검증, stage, identity 생성, 리뷰를 반복한다.
9. **External approval receipt:** reviewer가 승인한 정확한 candidate identity의 canonical Ed25519-signed JSON receipt를 Git worktree 밖에 생성한다.
10. **Verified local commit:** 전용 verifier/commit wrapper가 candidate와 receipt를 다시 대조하고, 승인된 tree와 message로만 local commit을 생성한다.
11. **Attestation:** wrapper가 receipt bytes를 변경하지 않고 commit OID 경로로 이동한 뒤 commit/tree/message를 재검증한다.

### 3.1 Two-artifact review receipt protocol

리뷰 증거는 자기 자신을 검토 대상에 넣지 않는다. 다음 두 artifact와 별도 신뢰 루트가 유일한 표준이다.

| Artifact | Canonical location | 역할 |
| --- | --- | --- |
| A — Versioned candidate | Git index tree + `$GIT_COMMON_DIR/duckpad-review-messages/v1/`의 영어 commit message file | 제품 코드, 테스트, wiki 작업/설계 로그와 commit message를 묶은 실제 commit 후보 |
| B — Local review receipt | `$GIT_COMMON_DIR/duckpad-review-receipts/v1/` 아래 canonical signed JSON | reviewer가 A를 승인했다는 worktree 밖의 Ed25519 attestation |

Artifact B는 `.git` 내부에 있으므로 Git index에 stage할 수 없고 candidate tree를 바꾸지 않는다. local trust root는 `$GIT_COMMON_DIR/duckpad-review-trust/v1/allowed_signers`, orchestrator-provisioned builder identity는 같은 디렉터리의 `builder_identity`다. ROOT signer eligibility는 같은 디렉터리에 미리 provision된 read-only `genesis-reviewers.json`과 filename-bound digest만 사용한다. 이 파일들은 builder workflow가 시작되기 전에 독립 reviewer/orchestrator가 worktree 밖에서 provision하며 repository verifier와 commit wrapper는 생성·수정하지 않는다. reviewer private key 생성·보관은 reviewer-only operational 책임이고 이 repository는 bootstrap/generation 명령을 제공하지 않는다. versioned [`reviewer-identities.v1.json`](../parity/reviewer-identities.v1.json)은 공개키와 active role을 고정하고 candidate 이후 onboarding 결과만 제공한다. `docs/wiki/reviews/` 문서는 일반 documentation이며 Artifact B가 아니다. Git notes도 사용하지 않는다.

이 프로토콜은 **조직적 agent 역할 분리와 증거 무결성**을 위한 것이며 동일 macOS 계정의 악성 owner/root에 대한 OS security boundary가 아니다. 같은 UID의 owner는 `.git` local files나 process memory를 변조할 수 있다. 실제 독립성 evidence는 orchestrator가 provision한 local identity/trust, 독립 agent review log, exact-candidate signature receipt의 결합이다. 더 강한 적대 모델은 별도 OS identity, ACL, hardware/external signer가 필요하며 현재 범위에서 보장한다고 주장하지 않는다.

표준 절차:

1. 최초 builder 실행 전 independent reviewer/orchestrator가 worktree 밖 local trust root와 builder identity를 provision한다. shipped `bootstrap_authority.py`는 존재하지 않으며 candidate가 trust root를 생성·갱신할 수 없다.
2. builder는 작업 로그와 public registry까지 stage하고 영어 Conventional Commit message file을 준비한다.
3. `python3 scripts/review/verify_candidate.py prepare --message-file <path>`가 local builder identity를 읽고 다음 값을 계산한다. free-form builder override는 허용하지 않는다.
   - `treeOID`: `git write-tree` 결과
   - `parentOID`: 현재 `HEAD`, 최초 commit이면 `ROOT`
   - `diffSHA256`: `git diff --cached --binary --no-ext-diff --full-index`의 raw bytes SHA-256
   - `messageSHA256`: message file raw bytes SHA-256
   - `candidateID`: 아래 byte sequence의 SHA-256

   ```text
   DuckpadReviewCandidate/v1\0<treeOID>\0<parentOID>\0<diffSHA256>\0<messageSHA256>\0
   ```

   각 placeholder는 lowercase ASCII hex이고 `ROOT`만 literal ASCII다. `\0`은 두 문자가 아니라 한 byte NUL이며 어떤 newline이나 공백도 삽입하지 않는다.
4. candidate manifest는 candidate-tree registry hash와 **approval registry source/hash**를 따로 기록한다. unborn candidate는 외부 `genesis-reviewers.json` snapshot에 이미 있는 signer만 사용할 수 있다. 후속 candidate는 manifest의 exact `parentOID`, 즉 candidate 직전 `HEAD` commit의 registry만 approval registry로 사용한다. 임의의 더 오래된 ancestor/side-branch registry는 거절한다. candidate가 추가/변경한 key는 그 candidate에 사용할 수 없고, parent-active reviewer가 onboarding commit을 승인한 다음 commit부터 사용할 수 있다.
5. reviewer는 exact candidate와 finding/validation을 검토한 뒤 reviewer-only signing action으로 `create_receipt.py --candidate-id <id> --reviewer-id <id> --scope ... --validation ...`를 실행한다. 도구는 `duckpad-commit-review-v1` namespace로 canonical payload를 서명하고 `<candidateID>.<receiptSHA256>.json`으로 read-only seal한다.
6. `python3 scripts/review/local_commit.py --candidate-id <id>`만 commit을 만든다. wrapper는 signature, parent-pinned registry/local trust의 동일 키, reviewer active role과 provisioned builder 분리, Blocker/Major 0, index/tree/parent/diff/message를 다시 검증한 뒤 `git commit-tree`와 원자적 ref 갱신을 수행한다.
7. wrapper는 receipt의 **동일 bytes**를 `$GIT_COMMON_DIR/duckpad-review-receipts/v1/committed/<commitOID>.<candidateID>.<receiptSHA256>.json`으로 보존한다.
8. `verify_candidate.py audit --all`은 모든 local commit의 parent-pinned registry, mapping, signature와 commit bytes를 다시 검사한다. receipt가 없거나 digest가 맞지 않으면 실패하며 hook을 건너뛴 `git commit --no-verify`도 탐지된다.

이 구조에서 receipt는 candidate commit에 포함되지 않고, receipt를 보존하기 위한 follow-up commit도 만들지 않는다. 따라서 “receipt를 넣는 다음 commit도 다시 review해야 하는” 재귀가 발생하지 않는다. commit ID와 receipt SHA-256은 receipt 내용에 사후 기입하지 않고 immutable receipt의 최종 파일명으로 결합한다.

### 3.2 Verifier와 end-to-end fixture

Phase 0에서 다음 artifact를 설치·검증하고 독립 리뷰해야 한다.

- 사전 provision된 `$GIT_COMMON_DIR/duckpad-review-trust/v1`: repository tooling이 만들거나 바꿀 수 없는 genesis allowed-signers와 orchestrator builder identity
- `scripts/review/review_common.py`: trust/identity를 read-only로 소비하는 canonical OpenSSH signature 검증
- `scripts/review/verify_candidate.py`, `candidate_identity.py`, `create_receipt.py`: candidate 생성, 독립성/signature/finding/digest 검증, post-commit audit
- `scripts/review/local_commit.py`, `install_hooks.py`, `hooks/pre-commit`: 승인된 tree만 commit하는 entry point와 raw commit 차단
- `tests/governance/review-receipt-e2e.sh`: 임시 로컬 저장소에서 root commit과 후속 commit을 실제 생성하는 end-to-end fixture

fixture는 최소한 다음 시나리오를 자동 검증해야 한다.

- 승인된 candidate가 exact tree/parent/message로 commit되고 receipt bytes가 commit OID 경로에 그대로 남는다.
- 리뷰 뒤 staged file, file mode, parent 또는 message를 바꾸면 commit이 거절된다.
- reviewer와 builder가 같거나 reviewer가 inactive/wrong role이거나 versioned key와 local trust root가 다르거나 unresolved Blocker/Major가 있으면 거절된다.
- receipt 누락, 잘못된 schema, 다른 candidate의 receipt, 변경된 receipt는 거절된다.
- 최초 commit의 `ROOT` parent와 일반 commit parent를 모두 검증한다.
- unborn trust 부재, shipped bootstrap/self-register alias, candidate-injected reviewer의 즉시 사용을 거절하고 parent-pinned reviewer와 two-step onboarding만 통과시킨다.
- raw `git commit`은 repository-managed hook에 의해 거절되고 wrapper 경로만 통과한다. `--no-verify` 사용은 정책 위반이다.
- 성공 뒤 post-commit audit가 통과하고, candidate와 commit tree가 byte-for-byte 동일하다.

`python3 scripts/review/install_hooks.py`가 local `core.hooksPath`를 설치해야 한다. verifier/fixture/hook이 없거나 실패하면 local commit을 허용하지 않는다.

### 3.3 Wiki 작업 기록 규칙

각 에이전트의 작업과 핵심 설계는 반드시 Markdown wiki에 남긴다. 대화 메시지나 터미널 출력만으로는 기록 요건을 충족하지 않는다.

각 작업 로그에는 최소한 다음 내용이 있어야 한다.

- task ID, 상태, 목표, 범위 및 명시적 비범위
- 수용 조건과 사용자 가치
- investigator, builder, reviewer의 에이전트 ID
- 조사한 코드/문서 경로와 확인한 동작
- 핵심 설계 결정, 대안, 선택 이유
- Clean Architecture 의존성 영향
- 변경 파일과 데이터/호환성 영향
- 수행한 테스트 명령, 결과, 미검증 영역
- 영어 commit header/body 초안
- final candidate 이전의 reviewer finding과 각 해결 근거
- canonical local receipt의 candidate ID와 commit 후 attestation 경로

작업 로그는 결정 일지이지 활동의 장황한 중계가 아니다. 재현 가능한 근거와 나중에 설계를 바꿀 때 필요한 이유를 보존한다.

## 4. Commit evidence와 local receipt 템플릿

다음 candidate evidence를 모든 versioned 작업 로그의 commit 단위마다 복사한다. 승인 digest와 verdict는 이 파일에 사후로 기입하지 않는다.

```markdown
## Commit Evidence: <task-id>/<sequence>

- Status: Draft | Ready for Freeze
- Scope: <single coherent change>
- Investigator: <agent-id>
- Builder: <agent-id>
- Reviewer: <independent-agent-id>
- Acceptance criteria: <links or checklist>
- Intended files: <name-status list>
- Validation:
  - `<command>` — PASS/FAIL — <summary>
- Pre-freeze findings:
  - `<severity> <location>: <finding>` — Resolved/Deferred — <evidence>
- Residual risks: <none or explicit list>
- Proposed commit header: `<English Conventional Commit header>`
- Proposed commit body:

  ```text
  <English rationale and important behavior>
  ```

- Local receipt: assigned outside the worktree after candidate freeze
```

reviewer가 생성하는 canonical local receipt의 signed payload는 다음 JSON shape를 가진다. 사람이 읽는 review 문서는 별도 wiki evidence이며 서명 payload를 대신하지 않는다.

```json
{
  "signed": {
    "schema_version": 1,
    "namespace": "duckpad-commit-review-v1",
    "signer_id": "/reviewer/id",
    "payload": {
      "schema_version": 1,
      "kind": "duckpad-commit-review",
      "candidate": "<exact candidate manifest object>",
      "decision": "approved",
      "unresolved_blockers": 0,
      "unresolved_majors": 0,
      "scope": ["<reviewed scope>"],
      "validation": ["<witnessed command/result>"],
      "issued_at": "<UTC timestamp>"
    }
  },
  "signature": "<OpenSSH SSH SIGNATURE armor>"
}
```

receipt는 reviewer-owned immutable artifact다. builder가 receipt를 수정하거나 파일명만 바꿔 다른 candidate/commit에 재사용하면 verifier가 거절해야 한다.

## 5. Clean Architecture 적용 기준

Duckpad의 초기 속도를 해치지 않으면서 교체 가능한 경계를 유지한다.

다음 방향은 [문서 02 §3.1 Modules and dependency direction](02-clean-architecture-and-plugins.md#31-modules-and-dependency-direction)과 동일하며, architecture 세부의 source of truth는 문서 02다.

```text
Presentation ─┐
Infrastructure ├──> Application ──> Domain
EditorAdapter ─┤
PluginBroker ──┘
```

의존성 규칙:

- Domain은 AppKit, SwiftUI, Scintilla, SQLite, 파일 시스템, 플러그인 구현을 import하지 않는다.
- Application은 사용 사례와 port를 정의하고 외부 효과는 protocol 뒤로 숨긴다.
- Presentation은 사용자 이벤트를 use case로 전달하며 복구·저장·탭 정책을 직접 소유하지 않는다.
- Presentation, Infrastructure, EditorAdapter, PluginBroker는 Application이 정의한 port를 구현하거나 호출하는 outer module이다.
- Scintilla는 편집 adapter이지 문서 생명주기나 세션 진실의 원천이 아니다.
- 플러그인 API는 내부 타입을 노출하지 않는 버전된 경계다.
- 모든 아키텍처 예외는 범위, 이유, 제거 조건을 wiki의 ADR 형식으로 기록한다.

핵심 도메인 후보는 `Buffer`, `DocumentIdentity`, `DirtyState`, `Session`, `TabGroup`, `RecoverySnapshot`, `EditorCommand`이다. 이름은 구현 중 변경할 수 있지만 책임과 의존성 방향은 유지한다.

## 6. 단계별 제품 로드맵

각 단계는 사용자에게 보이는 수직 기능, 자동 검증, wiki 증거, 독립 리뷰가 함께 끝나야 완료된다. 다음 단계의 탐색은 병렬로 할 수 있지만, 선행 단계의 gate를 통과하지 않은 기반 위에 제품 코드를 누적하지 않는다.

### Phase 0 — Bootstrap and governance

**목표:** 재현 가능한 macOS 앱 골격과 강제 가능한 개발 규칙을 만든다.

주요 범위:

- Swift/AppKit 중심 프로젝트와 테스트 target 생성
- Domain/Application/Presentation/Infrastructure module 경계 수립
- 로컬 Git 경계, ignore, 라이선스/third-party inventory 확정
- wiki index, ADR, work-log 구조 및 리뷰 체크리스트 준비
- 빌드·단위 테스트·lint 또는 format의 로컬 검증 명령 표준화

Gate:

- clean clone에 해당하는 새 로컬 checkout에서 명령 한 번으로 Debug build와 unit test가 성공한다.
- Domain/Application target이 AppKit, SwiftUI, Scintilla를 의존하지 않는지 검증한다.
- `git remote get-url origin`이 canonical Duckpad URL과 일치하고 참고 소스 출처 및 라이선스가 기록되어 있다.
- review verifier, local commit wrapper, repository-managed raw-commit rejection hook이 설치되어 있다.
- governance end-to-end fixture가 root/후속 commit 성공과 mutation/identity/receipt 실패 시나리오를 모두 통과한다.
- 예제 변경 하나가 investigator → builder → independent reviewer → two-artifact receipt → verified local commit → post-commit audit 흐름을 통과한다.

권장 커밋 경계:

1. `chore(project): bootstrap the macOS application`
2. `refactor(architecture): establish clean module boundaries`
3. `docs(governance): add local review and evidence workflow`

### Phase 1 — Scintilla Cocoa spike

**목표:** 기술 선택의 가장 큰 위험인 Swift/AppKit ↔ Objective-C++ ↔ Scintilla Cocoa 경계를 실제 입력기로 검증한다.

주요 범위:

- 단일 창에 Scintilla 편집기 표시
- UTF-8, 한글 IME 조합, 복사/붙여넣기, undo/redo, selection 검증
- 다크 모드, Retina, focus, VoiceOver 기초 확인
- bridge의 메모리 소유권과 이벤트 전달 계약 문서화
- 10 MB 및 100 MB 텍스트의 기초 benchmark 수집

Gate:

- 한글/영문 혼합 입력 중 조합 문자열이 깨지거나 중복 commit되지 않는다.
- 기본 편집 명령이 macOS 표준 메뉴와 단축키로 동작한다.
- bridge 누수·use-after-free가 sanitizer 또는 Instruments 검증에서 발견되지 않는다.
- 기준 Mac, OS, 빌드 설정, 파일 fixture와 결과를 benchmark 문서에 기록한다.
- spike 결과로 Scintilla 채택/수정/대체 결정을 ADR로 확정한다.

권장 커밋 경계:

1. `build(editor): integrate the Scintilla Cocoa bridge`
2. `feat(editor): expose native text editing commands`
3. `test(editor): add input and large-file smoke coverage`

### Phase 2 — Scratch buffers and session recovery

**목표:** Duckpad의 핵심 약속인 “먼저 쓰고, 명시적으로 버리기 전에는 잃지 않는다”를 완성한다.

주요 범위:

- 실행 즉시 편집 가능한 untitled buffer
- 파일 문서와 미저장 scratch buffer의 공통 생명주기
- atomic recovery snapshot, debounce, version/migration 정책
- 정상 종료, 강제 종료, crash, 저장 실패, 디스크 부족 시나리오
- Open/Save/Save As, 인코딩·EOL 보존의 최소 경로
- 외부 파일 변경과 복구 snapshot 충돌 정책

Gate:

- 프로세스 강제 종료를 주입한 반복 테스트에서 마지막 성공 snapshot의 모든 buffer가 복원된다.
- snapshot 쓰기 중 중단되어도 이전 정상 snapshot을 손상하지 않는다.
- 저장하지 않은 탭을 닫거나 복구 데이터를 폐기할 때 명시적 사용자 의도가 필요하다.
- UTF-8/UTF-16 및 LF/CRLF fixture를 열고 저장했을 때 정책에 따른 round trip이 검증된다.
- 복구 데이터 포맷 버전과 migration/fallback 테스트가 존재한다.

권장 커밋 경계:

1. `feat(buffer): introduce scratch document lifecycle`
2. `feat(session): persist atomic recovery snapshots`
3. `feat(files): add native open and save workflows`
4. `test(session): cover crash and corruption recovery`

### Phase 3 — Multiline tabs

**목표:** 많은 임시 문서를 숨기지 않고 여러 행에 자연스럽게 배치하는 Duckpad의 대표 경험을 완성한다.

주요 범위:

- `NSCollectionView` 기반 또는 동등한 native custom multiline tab layout
- 창 너비에 따른 row reflow, active/dirty/pinned 상태
- drag reorder, close, keyboard navigation, context menu
- 탭 수가 많을 때 overflow 탐색과 접근성 순서
- 복원 후 tab order, active tab, pinned state 유지

Gate:

- 1, 10, 50, 200개 탭 fixture에서 clipping, 겹침, 선택 소실이 없다.
- 창 resize로 행 수가 바뀌어도 active tab과 scroll visibility가 유지된다.
- drag, 키보드 탐색, VoiceOver 순서가 동일한 논리 순서를 따른다.
- close/quit 중 dirty buffer를 잃지 않으며 Phase 2 복구 정책과 통합된다.
- layout 성능 benchmark와 회귀 기준을 기록한다.

권장 커밋 경계:

1. `feat(tabs): add multiline tab layout`
2. `feat(tabs): support reorder and keyboard navigation`
3. `feat(tabs): restore tab state across sessions`
4. `test(tabs): cover reflow and high-tab-count behavior`

### Phase 4 — Search and editing parity

**목표:** Notepad++를 일상적으로 대체할 수 있는 빠른 검색과 고급 편집 동작을 제공한다.

주요 범위:

- find/replace, regex, case/whole-word, wrap search
- 현재 문서, 열린 문서 전체, 폴더 범위 검색
- 결과 탐색과 원본 위치 복귀
- multi-selection, column editing, duplicate/move lines, comment toggle
- line/column jump, bookmarks, split view, zoom
- macOS 메뉴, command validation, shortcut customization 기반

Gate:

- 검색 옵션 조합과 Unicode/zero-width regex 회귀 suite가 통과한다.
- 대량 결과에서 UI가 block되지 않고 cancel이 일관되게 동작한다.
- replace-all은 undo 가능한 명확한 transaction이며 실패 시 부분 손상을 방지한다.
- 키보드 전용 핵심 사용자 여정과 split-view focus 테스트가 통과한다.
- Notepad++ 동작 차이는 parity matrix에 macOS 적응 이유와 함께 기록한다.

권장 커밋 경계:

1. `feat(search): add document find and replace`
2. `feat(search): search across tabs and folders`
3. `feat(editing): add multi-selection and line commands`
4. `feat(workspace): add split editing views`

### Phase 5 — Languages and plugin platform

**목표:** 기본 앱은 가볍게 유지하면서 많은 언어와 VS Code와 유사한 점진적 확장 경로를 제공한다.

주요 범위:

- Lexilla 기반 bundled language catalog와 자동 언어 감지
- 구문 강조, folding, comment/indent metadata
- 버전된 plugin manifest와 capability 선언
- 명령, 메뉴, language provider, formatter 등 최소 extension point
- 플러그인 discovery, enable/disable, 오류 표시, 호환성 검사
- App Sandbox + Hardened Runtime 아래의 bundled `DuckpadPluginRuntime.xpc`와 non-JIT WebAssembly worker 격리
- WASI와 ambient import를 제공하지 않고 모든 허용 효과를 `duckpad:v1/*` allowlisted import → XPC → `PluginCapabilityBroker`로 중개
- 권한, 파일 접근, 성능 budget 및 API deprecation 정책

플러그인 보안 topology와 세부 계약은 [문서 02 §6.1 Enforceable v1 topology](02-clean-architecture-and-plugins.md#61-enforceable-v1-topology)가 유일한 architecture source of truth다. 이 topology를 구현하기 전에는 SDK v1을 freeze하거나 third-party plugin을 활성화할 수 없다.

Gate:

- 대표 언어 fixture가 감지, highlighting, folding, comment 동작을 통과한다.
- 샘플 플러그인이 공개 SDK만 사용해 설치 없이 로컬 discovery되고 command를 등록한다.
- 잘못되거나 호환되지 않는 manifest가 앱을 crash시키지 않고 설명 가능한 오류를 낸다.
- 임의 executable/dylib, JavaScript/JIT runtime, WASI 및 allowlist 밖 import는 로드 단계에서 거절된다.
- worker/XPC entitlement allowlist에는 file-user-selection, network 및 process-expanding 권한이 없고, spawn API/import route도 없다. 직접 filesystem/network/process 접근을 시도하는 negative plugin fixture는 module validation, missing import, broker denial 또는 sandbox enforcement 중 의도한 경계에서 모두 실패해야 한다. platform이 생성한 sandbox violation log와 각 validation/trap/denial result를 테스트 증거로 보존한다.
- 미선언, 미승인, scope 밖, 취소된 capability와 update로 새로 요구된 capability는 broker에서 모두 거절된다. 과권한 요청은 부분 허용으로 조용히 축소하지 않고 명시적 진단을 낸다.
- 허용된 효과도 allowlisted `duckpad:v1/*` import와 XPC를 거쳐 main-app broker가 현재 grant/scope를 재검사한 경우에만 수행된다.
- plugin trap/crash/hang, worker crash/restart가 editor process, 입력, save, 문서 버퍼와 recovery snapshot을 중단하거나 손상하지 않는다.
- entitlements, code signature, Hardened Runtime 및 notarization 결과를 machine-verifiable gate로 검사한다.
- API version negotiation, disable/uninstall, launch-with-plugins-disabled 경로가 검증된다.
- bundled language/third-party 라이선스 inventory가 최신이다.

위 isolation, direct OS access denial, over-permission denial, failure containment, signing/distribution 조건과 [문서 02 §6.6 MUST security and distribution gates](02-clean-architecture-and-plugins.md#66-must-security-and-distribution-gates)의 전체 항목은 모두 **MUST release gate**다. 하나라도 미검증 또는 실패이면 기능 동작 여부와 무관하게 Phase 5 및 90% release는 실패다.

권장 커밋 경계:

1. `feat(languages): add bundled syntax definitions`
2. `feat(plugins): define the versioned extension manifest`
3. `feat(plugins): load isolated command extensions`
4. `test(plugins): cover failure and compatibility boundaries`

### Phase 6 — 90% Notepad++ parity and macOS optimization

**목표:** 느낌에 의존하지 않고 단일 규범 알고리즘과 frozen machine-readable baseline으로 90% 이상을 입증한다.

주요 범위:

- frozen command/workflow baseline의 unmapped/duplicate/source-drift audit
- 각 stable item ID의 구현 상태, acceptance evidence와 macOS native divergence 갱신
- Reviewed-N/A 근거와 독립 승인 감사
- startup, typing, large-file, many-tab, search benchmark 최적화
- 접근성, localization, sandbox/file access, code signing/notarization 준비
- migration guide, keyboard map, recovery troubleshooting 문서

Normative parity authority:

- 공식과 판정 규칙: [문서 01 §3 단일 규범 패리티 알고리즘](01-product-philosophy-and-parity.md#3-단일-규범-패리티-알고리즘)
- 유일한 machine-readable 분모와 상태 입력: [Notepad++ command baseline v1](../parity/notepad-plus-plus-command-baseline.v1.json)

[baseline checksum](../parity/notepad-plus-plus-command-baseline.v1.sha256)과 [deterministic validator/calculator](../../scripts/check_parity_baseline.py)는 두 normative artifact의 무결성과 계산 재현 수단이다. 이 roadmap은 별도 점수, 가중치, 부분 점수 또는 UX 백분율 공식을 정의하지 않는다. 불일치 시 문서 01과 versioned JSON baseline만 권위를 가진다.

Parity release manifest는 검증 시점의 exact Git `HEAD`를 `source_commit_oid`로 고정하고, manifest의 source directory bytes가 해당 commit의 같은 subtree bytes와 일치해야 한다. root source commit만 외부 genesis approval registry를 쓸 수 있다. parent가 있는 source commit은 `git show -s --format=%P <source_commit_oid>`로 얻은 유일한 즉시 parent OID와 `approval_registry_source.parent_oid`가 정확히 같아야 하며, 그 parent commit의 registry blob/hash만 evidence 및 Reviewed-N/A signer eligibility에 사용한다. 따라서 revocation 전의 오래된 ancestor registry나 candidate-tree registry를 선택하는 우회는 실패한다.

최종 Gate:

- deterministic validator가 baseline schema/checksum/source coverage를 검증하고 문서 01의 공식으로 release pass를 산출한다.
- 독립 reviewer가 machine-readable baseline의 전체 stable item, evidence, Reviewed-N/A와 unmapped/duplicate report를 검증한다.
- 문서 01의 모든 P0와 Core UX Gate 및 data-loss/security defect 조건이 통과한다.
- 기준 Mac에서 warm launch, 입력 latency, 100 MB open, 200-tab reflow, folder search benchmark budget을 충족한다. 구체 budget은 Phase 1 baseline 이후 성능 ADR에서 고정하며 release 직전에 완화할 수 없다.
- 최신 macOS와 지원 최저 버전에서 IME, VoiceOver, native menu/shortcut, drag and drop, Finder Open With, sandbox file access를 검증한다.
- 전체 release candidate가 독립 reviewer의 exact candidate receipt와 post-commit audit evidence를 갖는다.

권장 커밋 경계:

1. `docs(parity): verify the frozen capability baseline`
2. 범주별 `feat`/`fix` 커밋
3. `perf(macOS): meet the native interaction budgets`
4. `test(parity): verify the macOS workflow suite`
5. `chore(release): attest ninety-percent parity`

## 7. 공통 품질 게이트

모든 Phase는 다음 공통 조건을 통과해야 한다.

- **Build:** 지원하는 macOS configuration에서 warning 정책을 만족하며 빌드된다.
- **Test:** 변경된 use case의 unit test와 adapter integration test가 통과한다.
- **Data safety:** 저장·복구·변환 경로 변경은 failure injection과 corruption case를 포함한다.
- **UX:** keyboard-only, IME, focus, undo, cancel 동작을 검증한다.
- **Accessibility:** 새 interactive control에 label, role, state, keyboard path가 있다.
- **Performance:** hot path 변경은 같은 fixture와 기준 Mac에서 전후 수치를 남긴다.
- **Architecture:** dependency rule 위반이 없고 새 예외는 ADR을 가진다.
- **Documentation:** agent work log, 핵심 결정, 테스트 결과, parity matrix 영향이 갱신되어 있다.
- **Review:** unresolved Blocker/Major가 0건이고 독립 reviewer의 canonical local receipt가 exact candidate identity를 승인했다.
- **Commit:** verifier가 승인 identity와 일치함을 확인한 tree/message만 전용 wrapper로 local commit하고 post-commit audit를 통과한다.

## 8. README-free wiki index 전략

현재 milestone에서는 README를 작성하지 않는다. root README와 과거 wiki README 이름을 모두 생성하지 않으며, 문서 진입점은 `docs/wiki/00-wiki-index.md` 하나다.

### Root README 보류

Root README 작성은 명시적인 후속 결정 전까지 금지한다. 다음 항목은 향후 승인 시 검토할 내용일 뿐 현재 파일을 만들 근거가 아니다.

- 한 문장의 제품 약속과 macOS 지원 범위
- 현재 milestone 및 실제로 동작하는 기능
- build/test 시작 명령
- 라이선스와 third-party attribution 링크
- 상세 설계, parity, roadmap을 wiki index로 연결

README에 긴 설계 기록이나 일별 진행 로그를 넣지 않는다.

### Wiki Home / index

`docs/wiki/00-wiki-index.md`를 단일 탐색 허브로 삼는다. README/Home alias는 만들지 않는다.

- Product: 철학, 사용자 원칙, UX 원칙
- Architecture: Clean Architecture, editor bridge, recovery, plugins, ADR index
- Delivery: 이 workflow/roadmap, phase status, parity matrix
- Evidence: work-log index, review evidence, benchmarks, test reports
- Reference: Notepad++ 조사와 macOS adaptation mapping

각 문서는 상단에 status, owner/agent, last reviewed date, 관련 문서를 두고, index에는 중복 설명 대신 링크와 현재 상태만 기록한다.

## 9. Agent Work Log

### 2026-09-02 — Development governance and roadmap

- **Agent:** `/root/workflow_roadmap`
- **Role:** Investigator + documentation builder
- **Assigned scope:** 개발 거버넌스와 macOS Duckpad 단계별 로드맵을 이 wiki 문서 하나로 작성
- **Actions:** Local Git 규칙, 독립 pre-commit review, finding 해결/재검증, 영어 커밋 메시지, investigator/builder/reviewer 역할, wiki 증거, commit evidence를 실행 프로토콜로 변환
- **Key design decisions:**
  - reviewer 승인을 사람/대화 단위가 아니라 exact candidate identity 단위로 고정
  - versioned candidate와 `.git` 내부 canonical signed JSON receipt를 분리해 staged checksum/commit ID 자기참조를 제거
  - receipt를 별도 commit이나 Git notes로 이관하지 않아 pre-commit review 재귀를 종료
  - verifier, commit wrapper, raw-commit rejection hook과 root/후속 commit end-to-end fixture를 Phase 0 필수 gate로 지정
  - 리뷰 뒤 변경은 크기와 무관하게 승인 무효 및 재리뷰
  - 90% 판정은 문서 01의 단일 공식과 versioned machine-readable baseline만 규범으로 참조
  - macOS native 적응은 N/A 남용이 아니라 동등한 사용자 가치와 테스트로 입증
  - Scintilla를 adapter로 제한하고 buffer/session 정책을 Domain/Application에 유지
  - 문서 02와 동일한 inward dependency diagram으로 outer adapter가 Application port를 우회하지 못하게 함
  - XPC + non-JIT WebAssembly, ambient OS access 제거, broker-mediated capability와 direct-access negative test를 plugin MUST gate로 지정
- **Files changed:** `docs/wiki/03-development-workflow-and-roadmap.md` only
- **Validation:** 최초 요구사항 대조 완료; 문서 구조와 요구 section 확인 완료
- **Commit:** 이 에이전트는 커밋하지 않음. 상위 작업의 독립 review gate 이후에만 local commit 가능

### 2026-09-02 — Independent review remediation

- **Agent:** `/root/workflow_roadmap`
- **Role:** Review finding investigator + documentation builder
- **Findings in scope:** B-01, B-02 linkage, M-02 linkage, m-01 from `docs/wiki/reviews/2026-09-02-milestone-01-review.md`
- **Changes:**
  - staged receipt 자기참조를 없애는 versioned candidate + `.git` local receipt의 two-artifact protocol 확정
  - candidate/tree/parent/diff/message identity, immutable receipt filename, verifier, commit wrapper, raw-commit rejection과 end-to-end fixture 요구 정의
  - receipt follow-up commit과 Git notes를 사용하지 않아 review recursion을 명시적으로 종료
  - 중복 parity 공식을 제거하고 문서 01 + versioned JSON baseline만 normative authority로 직접 연결
  - architecture diagram을 문서 02의 outer modules → Application → Domain 방향과 일치시킴
  - XPC + non-JIT WebAssembly topology, ambient access 제거, over-permission/direct-access denial과 signing/isolation을 Phase 5 MUST gate로 강화
- **Validation:**
  - 금지된 5/3/1, 별도 UX 90% 공식과 optional plugin isolation 문구가 제거되었음을 text scan으로 확인
  - 문서 01 §3, 문서 02 §3.1/§6.1/§6.6 및 parity JSON/checksum/calculator 경로 확인
  - local Markdown target/anchor 7개, code fence balance, required/forbidden phrase와 whitespace scan — PASS
  - `python3 -m unittest tests/test_parity_baseline.py` — PASS, 5 tests
  - `python3 scripts/check_parity_baseline.py` — PASS, 530 source symbols fully classified; current implementation score가 0이므로 release false는 expected
  - `shasum -a 256 -c notepad-plus-plus-command-baseline.v1.sha256` in `docs/parity` — PASS
  - review verifier와 governance end-to-end fixture는 이 문서가 Phase 0 구현 gate로 요구하는 후속 artifact이며 아직 실행됐다고 주장하지 않음
- **Files changed by this agent:** `docs/wiki/03-development-workflow-and-roadmap.md` only
- **Commit:** None; stage/commit prohibited for this task

### 2026-09-02 — Phase-0 signed commit gate and F-02 authority

- **Agent/role:** `/root/workflow_roadmap`, builder; read-only investigator `/root/workflow_roadmap/f02_investigator`. 이 작업의 승인 reviewer 역할은 수행하지 않는다.
- **Review input:** `reviews/2026-09-02-milestone-01-final-review.md`의 F-02와 이 문서 §3 protocol. 구현 완료 주장은 후속 독립 review 전까지 Pending이다.
- **Commit gate design:** reviewer-only Ed25519 private key와 allowed-signers를 `$GIT_COMMON_DIR/duckpad-review-authority/v1/`에 둔다. versioned registry key와 local trust key가 모두 맞아야 한다. candidate는 exact index tree, parent/ROOT, binary diff digest와 영어 message digest로 식별되며 signed JSON receipt는 candidate bytes 밖에 둔다.
- **Recursion termination:** wrapper가 `git commit-tree`로 exact candidate만 만들고 동일 receipt bytes를 commit OID mapping으로 보존한다. mapping은 후속 commit에 넣지 않으므로 재귀가 없다. raw `git commit`은 local hook이 막고 `--no-verify` 우회는 `audit --all`에서 missing mapping으로 탐지한다.
- **Files:** `scripts/review/` authority/candidate/receipt/verifier/wrapper/hook tools와 `tests/governance/` E2E fixture. parity schema v3도 동일 reviewer authority를 사용한다.
- **Validation:** unborn repository approved root/follow-up commit, candidate/receipt tamper, wrong-role/inactive/self-review rejection, raw commit block와 `--no-verify` audit detection을 governance 3/3으로 검증했다. parity 24/24, pinned integration 6/6, default/explicit checker와 sidecars도 통과했다. local `core.hooksPath=scripts/review/hooks` 설치를 확인했다.
- **Commit:** none; stage/commit explicitly prohibited.

### 2026-09-02 — Approval-review trust boundary remediation

- **Agent/roles:** builder `/root/workflow_roadmap`; cavecrew read-only investigator `/root/workflow_roadmap/trust_boundary_investigator`. 새 독립 reviewer가 별도로 판정해야 한다.
- **Findings:** approval review F-02와 m-01~m-04. 문서 status를 Pending approval로 맞추고 finding closure를 자가 선언하지 않는다.
- **Trust decision:** shipped bootstrap을 삭제하고 `$GIT_COMMON_DIR/duckpad-review-trust/v1`을 read-only input으로 만들었다. builder identity는 orchestrator provision 값만 읽으며 CLI override가 없다. root는 pre-existing trust가 없으면 실패하고 이후 signer는 parent registry에서 선택한다.
- **Two-step onboarding:** candidate registry와 approval registry digest/source를 분리했다. newly injected key는 현재 candidate를 승인할 수 없으며 parent-active reviewer가 먼저 onboarding change를 승인해야 한다.
- **Boundary statement:** 이 설계는 same-UID owner/root 방어가 아니라 조직적 sub-agent 분리의 audit evidence다. stronger hostile-local-user model은 별도 OS/ACL/hardware/external signing 경계가 필요하다.
- **Minor remediation:** duplicate JSON names fail closed, direct pinned integration은 pre/post clean+HEAD invariant를 강제하며 Python caches are ignored.
- **Validation:** normal 26/26, governance 4/4, pinned integration 7/7, setup/default/sequential explicit checker와 sidecars가 통과했다. reference-free clean copy의 normal+governance 30/30과 default checker도 통과했다. baseline SHA-256은 `08c0fdc79f80cded7149d3997006cdcf95b871fb704220993171731189ce897e`다.
- **Commit:** none; staging/commit prohibited.

### 2026-09-02 — Notepad++ reference exclusion and index rename

- **Agent/role:** `/root/philosophy_parity`, governance implementation builder.
- **Rule:** `notepad-plus-plus/`는 분석용 ignored checkout일 뿐 Duckpad 제품 artifact가 아니다. candidate tree의 어느 위치든 `notepad-plus-plus` path component 또는 mode `160000` gitlink가 있으면 prepare/verify/audit를 실패시킨다.
- **README policy:** root README와 wiki README는 현재 작성하지 않는다. 기존 wiki index는 `docs/wiki/00-wiki-index.md`로 이동했으며 모든 현재 문서 참조도 새 경로를 사용한다.
- **README candidate gate:** `.gitignore`의 case-insensitive-style pattern과 candidate tree validator가 어느 디렉터리든 `README*` basename을 fail-closed로 거부한다. `git add -f`로 ignore를 우회해도 prepare/verify/audit에서 거절된다.
- **Initial candidate message:** 첫 exact candidate는 두 body paragraph가 있는 영어 Conventional Commit message를 사용한다. validator는 header 뒤 blank separator와 paragraph 사이 한 줄을 허용하지만 leading/trailing/consecutive empty paragraph와 잘못된 trailing newline은 거부한다.
- **Implementation evidence:** `scripts/review/candidate_identity.py`가 Git tree의 NUL-delimited entries를 검사하고 `scripts/review/verify_candidate.py`의 commit audit도 동일 검사를 호출한다.
- **Validation:** governance 6/6, reference-free parity 26/26, pinned integration 7/7, parity checker와 Swift 8/8가 통과했다. README old-path scan, prohibited file absence와 ignore rule도 통과했다.
- **Commit:** 없음. stage/commit하지 않았다.

### 2026-09-02 — Exact-parent parity registry remediation

- **Agent/role:** `/root/clean_architecture`, focused governance builder; 이 candidate를 review하지 않는다.
- **Review input:** `reviews/2026-09-02-milestone-01-governance-approval.md`의 F-02a Major와 C-02 Minor.
- **Decision:** release manifest의 `source_commit_oid`는 검증 시점 exact `HEAD`이며, source directory와 committed subtree의 deterministic hashes가 같아야 한다. root source만 external genesis를 쓰고 follow-up은 그 source commit의 유일한 즉시 parent registry만 쓴다. 오래된 ancestor 또는 side branch registry는 승인 source가 될 수 없다.
- **Cache remediation:** parity signer child process에도 `-B`와 `PYTHONDONTWRITEBYTECODE=1`을 전달하고 기존 generated cache를 제거했다.
- **Validation:** parity 31/31, governance 7/7, pinned integration 7/7, default/direct checker 및 clean simulation 38/38 통과. clean simulation의 post-suite cache scan은 0건이다.
- **Safety:** README, stage, commit, Notepad++ reference 변경 없음. reference HEAD는 `dda973d2b2da6bdcc7db9f18a7f5d2fbf6b07248`이다.
