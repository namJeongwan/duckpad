# Duckpad 제품 철학과 Notepad++ 패리티 기준선

> 상태: **Pending approval** — 최신 독립 review의 Blocker/Major가 0이 되고 exact candidate receipt가 발급되기 전까지 승인된 기준선이 아니다.
>
> 기준일: 2026-09-02
>
> 분석 기준: 로컬 `notepad-plus-plus` 저장소, commit `dda973d2b`
>
> 대상: macOS용 Duckpad가 Notepad++의 주요 기능과 사용자 경험을 90% 이상 이관했는지 판정하는 제품 기준선

## 1. 크게 찍는 방점

> # 먼저 붙여 넣고, 나중에 정리한다. 그리고 명시적으로 버리기 전에는 절대 잃지 않는다.

Duckpad는 IDE가 되기 위해 시작하는 앱이 아니다. 파일, 폴더, 프로젝트, 언어를 먼저 선택하게 하지 않고 실행 즉시 텍스트를 받을 수 있는 **macOS 네이티브 scratchpad**다. 그러나 “간단함”을 “기능이 적음”으로 해석하지 않는다. 사용자가 필요해지는 순간에는 Notepad++ 수준의 편집·검색·언어·자동화 기능과 VS Code처럼 확장 가능한 플러그인 구조가 드러나야 한다.

Notepad++ 자신도 제품을 “source code editor and Notepad replacement”로 정의하며 프로그래밍 언어와 자연어를 함께 지원한다([`README.md:7-10`](../../notepad-plus-plus/README.md#L7-L10)). Duckpad는 이 이중 정체성을 macOS에 맞게 계승한다.

### 확정 철학

1. **Scratch first** — 새 탭은 파일이 아니라 독립적인 문서다. 앱을 열면 즉시 쓰고 붙여 넣을 수 있다.
2. **Loss averse by default** — 저장하지 않은 탭도 세션과 복구의 정식 대상이다. 종료, 재실행, 비정상 종료가 작업 손실의 이유가 되어서는 안 된다.
3. **Simple surface, deep capability** — 첫 화면은 편집기와 탭에 집중하고, 고급 기능은 명령·메뉴·패널·플러그인으로 점진적으로 노출한다.
4. **Many languages, plain text always** — 텍스트가 본체이며 언어 기능은 텍스트 위에 얹힌다. 언어 감지, highlighting, folding, completion이 실패해도 원문 편집은 가능해야 한다.
5. **Tabs are working memory** — 탭 수가 많아지는 것을 예외로 취급하지 않는다. multiline wrap, 고정, 재정렬, 검색 가능한 문서 목록이 핵심 UX다.
6. **Keyboard-speed editing** — 검색·치환·다중 선택·줄/열 편집·명령 실행은 반복 작업을 끊지 않아야 한다.
7. **Extensible without surrendering the core** — 플러그인은 언어, 명령, 메뉴, 패널, 이벤트를 확장할 수 있지만 문서 저장·복구 무결성은 코어가 소유한다.
8. **Mac first, not Windows-shaped** — 기능의 결과와 흐름은 이관하되 Win32 UI를 복제하지 않는다. 메뉴 바, 표준 단축키, Finder, Services, Quick Look, 접근성, 다크 모드, 창/탭 동작은 macOS 관례를 따른다.
9. **Fast enough to disappear** — 실행, 탭 전환, 입력, 검색의 지연을 사용자가 의식하지 않게 한다. 대용량 파일에서는 기능을 선별적으로 낮추더라도 편집 가능성을 우선한다.
10. **Local by default** — 편집 내용과 세션은 기본적으로 로컬에 남고, 네트워크 계정이나 프로젝트 생성은 필수가 아니다.

Notepad++ 원본에는 이 철학의 기술적 근거가 명확하다. 세션은 파일명뿐 아니라 언어, encoding, bookmark, fold, pin, untitled rename, backup path, view 위치를 보존한다([`Parameters.h:121-169`](../../notepad-plus-plus/PowerEditor/src/Parameters.h#L121-L169)). snapshot/periodic backup 사양은 저장하지 않은 파일을 묻지 않고 종료한 뒤 다음 세션에 원래 상태로 복구하고, untitled 문서도 주기적으로 backup한다고 명시한다([`Buffer.cpp:1218-1259`](../../notepad-plus-plus/PowerEditor/src/ScintillaComponent/Buffer.cpp#L1218-L1259)).

### 비목표

- 전체 IDE(빌드 시스템, debugger, source control, remote development)를 코어에 내장하지 않는다. 필요하면 플러그인으로 확장한다.
- VS Code UI나 Electron 런타임을 복제하지 않는다.
- Windows DLL 기반 Notepad++ plugin ABI의 binary compatibility를 제공하지 않는다. 같은 확장 능력은 Duckpad의 versioned, capability-based API로 제공한다.
- Win32 전용 shell, registry, UAC, system tray 동작을 그대로 이식하지 않는다.
- cloud account, collaboration, telemetry를 기본 사용 조건으로 만들지 않는다.
- 서식 있는 문서 편집기, Markdown WYSIWYG, 프로젝트 관리 도구가 되지 않는다.
- 기능 수를 맞추기 위해 macOS 접근성·입력기·표준 동작을 훼손하지 않는다.

## 2. 원본에서 읽은 사용자 경험

### 2.1 문서는 파일보다 먼저 존재한다

Notepad++는 snapshot에서 원본 파일이 없는 경우를 `UNTITLED`로 명시하고 backup만으로 문서를 다시 연다([`NppIO.cpp:291-317`](../../notepad-plus-plus/PowerEditor/src/NppIO.cpp#L291-L317)). 따라서 Duckpad의 domain model에서도 `Document`와 `FileBinding`은 분리해야 한다. `FileBinding == nil`인 문서는 임시 상태가 아니라 정상 상태다.

### 2.2 탭은 많은 문서를 다루는 기본 장치다

원본은 `TCS_MULTILINE`을 초기 style과 runtime toggle 양쪽에서 사용한다([`TabBar.cpp:40-52`](../../notepad-plus-plus/PowerEditor/src/WinControls/TabBar/TabBar.cpp#L40-L52), [`TabBar.cpp:616-623`](../../notepad-plus-plus/PowerEditor/src/WinControls/TabBar/TabBar.cpp#L616-L623)). multi-line일 때는 single-line용 wheel scrolling을 하지 않는 별도 동작도 둔다([`TabBar.cpp:700-772`](../../notepad-plus-plus/PowerEditor/src/WinControls/TabBar/TabBar.cpp#L700-L772)). Duckpad는 이를 단순히 “탭이 두 줄로 보임”이 아니라 선택·drag reorder·pin·close·keyboard navigation·행 재배치까지 포함한 working-memory UX로 이관한다.

### 2.3 검색은 대화상자 하나가 아니라 작업 흐름이다

원본 검색 모델은 normal/extended/regex, whole word, case, wrap, selection, recursion, hidden directory, project 범위, dot-newline을 한 모델에 둔다([`FindReplaceDlg.h:63-89`](../../notepad-plus-plus/PowerEditor/src/ScintillaComponent/FindReplaceDlg.h#L63-L89)). Find/Replace/Count/Mark/Find-in-results와 열린 문서 전체 치환도 별도 operation으로 제공한다([`FindReplaceDlg.h:65`](../../notepad-plus-plus/PowerEditor/src/ScintillaComponent/FindReplaceDlg.h#L65), [`FindReplaceDlg.h:283-297`](../../notepad-plus-plus/PowerEditor/src/ScintillaComponent/FindReplaceDlg.h#L283-L297)). Duckpad의 패리티는 `Cmd-F`가 뜨는지만으로 판정하지 않는다.

### 2.4 강력한 언어 지원은 텍스트 편집을 대체하지 않는다

원본 메뉴 command에는 C/C++부터 Swift, Rust, TypeScript, Go, TOML 등 약 90개의 built-in language 항목이 있고, external/user-defined language 범위가 별도로 존재한다([`menuCmdID.h:481-584`](../../notepad-plus-plus/PowerEditor/src/menuCmdID.h#L481-L584)). 사용자 정의 언어도 runtime menu에 추가된다([`Notepad_plus.cpp:606-613`](../../notepad-plus-plus/PowerEditor/src/Notepad_plus.cpp#L606-L613)). Duckpad는 broad syntax coverage와 user grammar 설치를 모두 패리티 대상으로 삼는다.

### 2.5 확장은 명령 추가만이 아니라 host와의 양방향 계약이다

Notepad++ plugin 계약은 host 및 두 Scintilla view handle, command array, notification, message procedure를 노출한다([`PluginInterface.h:28-69`](../../notepad-plus-plus/PowerEditor/src/MISC/PluginsManager/PluginInterface.h#L28-L69)). manager는 command ID, marker, indicator를 할당하고 notification을 broadcast한다([`PluginsManager.h:87-139`](../../notepad-plus-plus/PowerEditor/src/MISC/PluginsManager/PluginsManager.h#L87-L139)). Duckpad는 binary ABI는 버리되 **commands + document/editor API + events + decorations + panels + language contributions**라는 능력 표면은 유지한다.

### 2.6 macOS 변환은 동등한 결과를 목표로 한다

원본의 main/sub view는 동적 splitter를 사용하고([`Notepad_plus.cpp:437-443`](../../notepad-plus-plus/PowerEditor/src/Notepad_plus.cpp#L437-L443)), 두 view가 모두 보일 때 synchronized horizontal/vertical scrolling을 제공한다([`Notepad_plus.cpp:2733-2750`](../../notepad-plus-plus/PowerEditor/src/Notepad_plus.cpp#L2733-L2750)). Duckpad에서는 AppKit split view, native window/tab semantics와 표준 focus ring으로 같은 작업 결과를 제공한다. Windows widget 모양이나 shortcut을 그대로 복제하는 것은 패리티가 아니다.

## 3. 단일 규범 패리티 알고리즘

### 3.1 권위와 재현 가능한 입력

이 절만 Duckpad의 “기능 및 UX 90%” 판정 공식이다. 다른 roadmap, report, test plan은 공식을 재정의하지 않고 이 절과 다음 versioned artifact를 참조해야 한다.

- 규범 baseline: [`notepad-plus-plus-command-baseline.v1.json`](../parity/notepad-plus-plus-command-baseline.v1.json)
- byte-for-byte checksum: [`notepad-plus-plus-command-baseline.v1.sha256`](../parity/notepad-plus-plus-command-baseline.v1.sha256)
- extractor/validator/calculator: [`check_parity_baseline.py`](../../scripts/check_parity_baseline.py)
- 독립 N/A receipt verifier: [`verify_parity_review_receipt.py`](../../scripts/verify_parity_review_receipt.py)
- reviewer authority/attestation tools: [`scripts/review/`](../../scripts/review/)
- reviewer identity registry: [`reviewer-identities.v1.json`](../parity/reviewer-identities.v1.json)
- clean-checkout command fixture: [`menuCmdID.v1.symbols`](../../tests/fixtures/menuCmdID.v1.symbols)
- independently frozen workflow fixture: [`notepad-plus-plus-workflow-inventory.v1.json`](../parity/notepad-plus-plus-workflow-inventory.v1.json) + [`SHA-256`](../parity/notepad-plus-plus-workflow-inventory.v1.sha256)
- pinned reference setup: [`setup_notepadpp_reference.sh`](../../scripts/setup_notepadpp_reference.sh)
- reference-free tests: [`test_parity_baseline.py`](../../tests/test_parity_baseline.py)
- explicit pinned-source tests: [`test_parity_integration.py`](../../tests/test_parity_integration.py)

baseline schema v3는 Notepad++ commit `dda973d2b2da6bdcc7db9f18a7f5d2fbf6b07248`의 `menuCmdID.h`에서 주석 처리되지 않은 모든 `IDM_*` define을 추출한다. 다섯 사용자 노출 surface도 stable workflow ID와 feature ID로 열거하고 file hash를 고정한다. 기본 검증은 versioned 530-symbol fixture만 사용하므로 ignored reference tree가 없는 clean checkout에서도 재현된다. explicit integration audit는 source commit, command header SHA-256, symbol 순서/집합/count, 다섯 surface SHA-256과 모든 selector의 실제 존재를 검증한다. 각 symbol은 정확히 하나의 stable feature ID, `Reviewed-N/A`, 또는 non-command namespace/range/sentinel로 분류되어야 하며 0개 rule은 unmapped, 2개 이상은 ambiguous failure다.

| 고정 surface | stable workflow 수 | workflow ID → feature ID |
|---|---:|---|
| `SURFACE.MAIN_MENU` | 4 | `WF.C9.F01→C9.F01`, `WF.C10.F05→C10.F05`, `WF.C2.F13→C2.F13`, `WF.C3.F13→C3.F13` |
| `SURFACE.DEFAULT_COMMANDS` | 8 | `WF.C2.F01→C2.F01`, `WF.C5.F02→C5.F02`, `WF.C5.F09→C5.F09`, `WF.C6.F03→C6.F03`, `WF.C6.F08→C6.F08`, `WF.C8.F05→C8.F05`, `WF.C9.F03→C9.F03`, `WF.C10.F02→C10.F02` |
| `SURFACE.TAB_CONTEXT` | 1 | `WF.C2.F02.CONTEXT→C2.F02` |
| `SURFACE.TOOLBAR` | 3 | `WF.C7.F06→C7.F06`, `WF.C8.F06→C8.F06`, `WF.C2.F12→C2.F12` |
| `SURFACE.DYNAMIC_HOST` | 16 | recovery, regex/all-doc search, indent/function list, external-file state, panel restore, plugin discovery/API/event/capability/isolation/compatibility/migration의 `WF.<feature-id>→<feature-id>` |

각 workflow record는 selector, expected occurrence count와 acceptance를 함께 가진다. 동일 JSON의 자기 주장만 검사하지 않도록 별도 versioned fixture가 32개 workflow의 ID, surface ID/path/hash, feature ID, selector, expected occurrences를 동결한다. checker는 baseline과 fixture의 identity/count를 exact compare하고 missing/extra/duplicate ID, duplicate selector ownership, 실제 source match span이 겹치는 selector ownership, occurrence drift를 fail closed로 처리한다. command/workflow 어느 쪽에도 연결되지 않은 feature, unknown feature mapping, unused surface, invalid regex도 실패다.

```sh
python3 -B -m unittest -v tests/test_parity_baseline.py
python3 -B scripts/check_parity_baseline.py
python3 -B scripts/check_parity_baseline.py --report > parity-report.json
scripts/setup_notepadpp_reference.sh notepad-plus-plus
python3 -B scripts/check_parity_baseline.py --integration-reference notepad-plus-plus
DUCKPAD_NPP_REFERENCE=notepad-plus-plus python3 -B -m unittest -v tests/test_parity_integration.py
```

현재 고정 source에서 checker가 도출한 값은 활성 symbol 530개, feature command 492개, provisional `Reviewed-N/A` command 13개, non-command meta symbol 25개, stable workflow 32개다. 다섯 `Reviewed-N/A` rule은 `pending`이므로 release는 강제로 실패한다. 현재 `not_built`/0% 상태에는 release artifact가 없어도 되지만 `release_candidate`를 주장하면 candidate SHA-256을 실제 manifest bytes에서 재계산하고 manifest가 가리키는 source tree와 하나 이상의 build artifact도 다시 hash한다. Full/Pass evidence는 candidate, parity contract, feature/UX-gate subject, typed machine/manual result artifact에 묶인 OpenSSH Ed25519 attestation만 허용한다. active approval-registry key와 builder workflow 전에 독립적으로 provision된 `.git/duckpad-review-trust/v1/allowed_signers`의 동일 키가 함께 맞아야 하며 builder 본인은 승인할 수 없다. shipped reviewer bootstrap은 없고 reviewer private-key 생성은 reviewer-only operational 범위다.

최초 ROOT approval registry는 candidate JSON의 `reviewer_registry_path`를 신뢰하지 않는다. orchestrator가 worktree 밖 `$GIT_COMMON_DIR/duckpad-review-trust/v1/genesis-reviewers.json`과 filename-bound `.sha256`을 read-only로 먼저 provision해야 하며 checker/verifier가 그 exact bytes를 resolve한다. 후속 approval은 선언된 parent commit의 registry blob과 digest를 resolve한다. candidate registry는 다음 commit을 위한 onboarding 결과일 뿐 현재 candidate signer eligibility가 아니므로, 외부 allowed-signers key가 있어도 candidate에만 새로 등장한 reviewer는 같은 ROOT commit이나 parity release를 승인할 수 없다.

JSON의 `features` 배열이 scoring denominator의 유일한 machine-readable 원본이다. schema v3는 command와 stable-workflow 감사를 연결한 결과 현재 94개 feature를 산출하지만, “94”라는 문서 숫자 자체는 규범 입력이 아니다. feature 분할·병합, source 변경, command/workflow 추가·삭제, N/A 승인에는 baseline version 증가, 새 sidecar checksum, 전후 점수, 독립 review가 필요하다. JSON 안에는 checksum을 넣지 않고 별도 sidecar가 JSON bytes를 hash하므로 자기참조하지 않는다.

`parity_contract_sha256`는 deterministic key-sorted compact canonical JSON의 SHA-256이다. projection에는 baseline/source와 frozen workflow identity, implementation ratio, category weight, feature identity·priority·acceptance·command/workflow mapping, UX-gate scenario·acceptance, release threshold와 Blocker/Critical defect policy를 포함한다. 계산 중인 digest 필드 자체, candidate, feature/gate의 mutable state·evidence ID, Reviewed-N/A receipt 상태와 evidence envelope는 제외하므로 자기참조하지 않는다. 반대로 typed result와 모든 evidence/Reviewed-N/A signed payload는 이 digest를 필수로 포함한다. 따라서 서명 뒤 weight, priority, acceptance, mapping, workflow, gate 또는 defect policy를 바꾸고 sidecar/digest만 다시 계산해도 기존 서명은 재사용할 수 없다.

### 3.2 판정 공식

패리티는 **가중 기능 점수**와 **핵심 UX 게이트**를 함께 만족해야 한다.

```text
Weighted Feature Parity (%)
  = Σ(category weight × category earned ratio)

Release Parity Pass
  = Weighted Feature Parity >= 90.0
    AND all Core UX Gates pass
    AND all P0 items pass
    AND all Reviewed-N/A rules independently approved
    AND no open Blocker/Critical data-loss or security defect
```

각 inventory item의 획득률은 acceptance test 증거로만 정한다.

별도 subweight가 없는 한 category 내부의 각 feature는 같은 비중이며, category earned ratio는 `해당 category feature 획득률 합 / feature 수`다. 한 feature에 여러 command가 연결되어 있으면 그 command 묶음이 하나의 사용자 workflow이므로 모두 충족해야 1.00이다. 다른 category에서 같은 component를 소비하더라도 acceptance 결과가 다르면 별도 점수다. 예를 들어 C5는 symbol provider의 정확성, C7은 function-list panel의 탐색/복원 UX를 각각 판정한다.

| JSON state | 점수 | 판정 |
|---|---:|---|
| `Missing` | 0.00 | 미구현 또는 동작 불능 |
| `Partial-0.25` | 0.25 | UI/타입 skeleton만 존재; 실제 workflow 불가 |
| `Partial-0.50` | 0.50 | 기본 happy path만 동작; 명시된 주요 범위가 빠짐 |
| `Partial-0.75` | 0.75 | 실사용 가능; edge case/세부 command 일부가 빠짐 |
| `Full` | 1.00 | 명시된 acceptance와 macOS 변환 기준을 자동/수동 시험으로 모두 통과 |

부분 구현 점수는 담당자가 임의로 올리지 않는다. 각 item의 test matrix와 evidence link가 wiki에 있어야 한다. feature flag 뒤에 있어도 사용자 build에서 활성화되고 시험 가능해야 획득한다.

### 3.3 카테고리 가중치

| ID | 카테고리 | 가중치 | 이유 |
|---|---|---:|---|
| C1 | 문서·파일·세션·복구 | 16 | “아무거나 붙이고 잃지 않음”의 핵심 |
| C2 | 탭·창·분할 뷰 | 14 | 많은 scratch 문서를 다루는 기본 UX |
| C3 | 기본/고급 편집 | 14 | Notepad++의 반복 편집 생산성 |
| C4 | 검색·치환·표시 | 14 | 핵심 power-user workflow |
| C5 | 언어·highlighting·completion | 12 | 다언어 편집기 정체성 |
| C6 | encoding·EOL·파일 무결성 | 8 | 텍스트 손상 방지 |
| C7 | 탐색·workspace·패널 | 7 | 문서가 많아진 이후의 발견 가능성 |
| C8 | 플러그인·확장성 | 9 | 장기 기능 확장의 기반 |
| C9 | macro·명령·도구 | 4 | 반복 자동화와 외부 도구 연결 |
| C10 | 설정·theme·접근성 | 2 | 개인화와 macOS 품질 |
|  | **합계** | **100** |  |

`제외` 항목은 분모에서 조용히 삭제하지 않는다. Windows 전용 기능에 macOS 동등 기능이 명시된 경우는 제외가 아니라 해당 카테고리에서 점수를 받는 **변환 항목**이다. 진짜 N/A는 rationale과 독립 승인 receipt를 baseline에 기록한 뒤에만 제외된다.

### 3.4 핵심 UX 게이트

아래 항목은 가중 점수가 90을 넘어도 하나라도 실패하면 목표 미달이다.

| Gate | 필수 시나리오 | 통과 기준 |
|---|---|---|
| G1 Instant scratch | cold launch → 입력/붙여넣기 | project/file 선택 없이 바로 편집 가능; release 기준 launch/first-input 성능 budget 충족 |
| G2 Untitled survival | 3개 untitled 탭 편집 → 강제 종료 → 재실행 | 내용, 탭 순서, 선택 탭, custom title, cursor/scroll이 마지막 완료 snapshot까지 복구 |
| G3 Explicit discard | untitled/dirty 탭 닫기 | 저장·버리기·취소가 명확하며 “버리기” 전에는 recovery artifact 삭제 금지 |
| G4 Multiline tabs | 50개 탭 생성, 3행 이상 | wrap, selection, pin, close, drag reorder, keyboard traversal이 안정적이고 활성 탭이 항상 보임 |
| G5 Search workflow | current/opened/folder 범위 regex 검색·치환 | 결과 탐색, cancel, progress, undo 가능한 범위, binary/permission error 처리가 일관됨 |
| G6 Text fidelity | UTF-8/BOM, UTF-16, legacy Korean/Japanese/Western, CRLF/LF/CR round-trip | 사용자가 명시적으로 변환하지 않으면 byte-significant 속성을 보존하고 손실 가능 시 차단/경고 |
| G7 External change safety | 외부 수정/삭제와 내부 dirty 상태 충돌 | 자동 덮어쓰기 금지; reload/keep/compare 또는 동등한 안전 선택 제공 |
| G8 Language breadth | 대표 20개 언어 + 전체 grammar smoke test | detection/highlight/fold/comment가 문서를 손상시키지 않고 grammar 실패 시 plain text fallback |
| G9 Plugin isolation | 정상, hang, crash, 과권한 plugin | editor process와 recovery가 생존; 권한이 선언/집행되고 plugin 비활성화·복구 가능 |
| G10 macOS native | keyboard, IME, accessibility, window/menu | Command 계열 표준 shortcut, 한·중·일 IME composition, VoiceOver labels, dark mode, Retina, sandbox/bookmark workflow 통과 |

성능 숫자는 구현 benchmark 문서에서 hardware profile과 함께 고정한다. 숫자가 아직 고정되지 않았다는 이유로 G1을 임의 통과시킬 수 없다.

## 4. 주요 기능 inventory와 우선순위

우선순위 정의:

- **P0** — Duckpad 정체성과 첫 usable milestone에 필수. 모두 통과해야 어떤 패리티 release도 가능하다.
- **P1** — 90% release에 원칙적으로 포함. 누락 시 가중 점수와 UX gate를 동시에 위협한다.
- **P2** — long-tail parity. 일부는 90% 이후 가능하지만 100% roadmap과 inventory에는 남긴다.
- **제외** — Windows 종속이며 macOS 사용자 결과가 없거나 다른 native workflow에 흡수된다.

### C1. 문서·파일·세션·복구 — 16점

원본의 File command 범위에는 new/open/close variants, save/save all/save as/copy, reload, rename/delete, session load/save, recent restore, workspace가 포함된다([`menuCmdID.h:22-55`](../../notepad-plus-plus/PowerEditor/src/menuCmdID.h#L22-L55)).

| 기능 | 우선순위 | macOS 최적화/acceptance |
|---|---|---|
| 즉시 생성되는 untitled document | P0 | launch/new command 즉시 focus; 파일명 요구 없음 |
| open, recent, drag/drop, Open With | P0 | `NSDocument` 관례, Finder integration, security-scoped bookmark |
| save, save as, save copy, save all | P0 | atomic replace, native save panel, extension 제안; copy는 binding을 바꾸지 않음 |
| close/current/all/others/left/right/unchanged/unpinned | P1 | native confirmation과 복구 정책을 유지 |
| session 자동 저장·복원 | P0 | window, view, tab order, active tab, cursor, scroll, fold, mark, language, encoding 복원 |
| untitled/dirty periodic recovery | P0 | debounce + atomic snapshot; crash test 필수 |
| named session import/export | P1 | portable manifest와 누락 파일 보고 |
| tab rename과 restore last closed | P1 | untitled custom title 포함; recently closed stack |
| file rename/move-to-trash | P1 | Finder semantics; trash는 recoverable operation 사용 |
| print | P2 | macOS print panel과 pagination |

### C2. 탭·창·분할 뷰 — 14점

원본 session은 main/sub view를 독립적으로 보존하고([`Parameters.h:157-169`](../../notepad-plus-plus/PowerEditor/src/Parameters.h#L157-L169)), view command에는 pin, document list/map, tab 이동, monitoring, 색상, 다른 view로 이동/clone이 포함된다([`menuCmdID.h:332-411`](../../notepad-plus-plus/PowerEditor/src/menuCmdID.h#L332-L411)).

| 기능 | 우선순위 | macOS 최적화/acceptance |
|---|---|---|
| **multiline wrapping tab bar** | P0 | custom AppKit layout; 1~N행, resize reflow, active-tab visibility, VoiceOver order |
| tab select/close/reorder/drag | P0 | pointer와 keyboard 모두 지원; unsaved state 유지 |
| pin/unpin, close-unpinned | P0 | pinned 영역과 order가 session 복원 |
| unsaved/dirty/read-only/monitoring 표시 | P0 | 색상만 의존하지 않는 icon + accessibility value |
| tab overflow document switcher/search | P1 | filename/path/fuzzy search, keyboard-only 전환 |
| per-tab color/group marker | P2 | system accent/dark mode contrast 보장 |
| split view horizontal/vertical | P1 | `NSSplitView`; tab을 move/clone, 독립 scroll/cursor |
| synchronized scroll/zoom | P1 | clone 및 서로 다른 문서 모두 명확한 on/off 상태 |
| document map/minimap | P2 | 큰 파일에서 graceful degradation |
| multiple windows/new instance equivalent | P1 | macOS window lifecycle, same document 충돌 정책 |
| distraction-free/full screen/always-on-top equivalent | P2 | native full screen; floating은 명시적 utility behavior |
| editor word wrap/wrap marker | P0 | viewport resize와 large-file policy 포함; wrap/marker를 독립 toggle하고 document bytes, selection, undo history 보존 |
| hide/reveal selected lines | P2 | content 삭제 없이 숨김/복원; selection anchor 보존 |

### C3. 기본/고급 편집 — 14점

원본 Edit command는 undo/redo, line operations, case, comments, whitespace trim, column mode, sort/deduplicate, multi-selection, clipboard history까지 폭넓다([`menuCmdID.h:86-197`](../../notepad-plus-plus/PowerEditor/src/menuCmdID.h#L86-L197)).

| 기능 | 우선순위 | macOS 최적화/acceptance |
|---|---|---|
| cut/copy/paste/delete/select all, undo/redo | P0 | standard Edit menu/selector와 Command shortcut |
| line duplicate/move/transpose/split/join | P1 | multi-cursor selection에서도 deterministic |
| indent/unindent, tabs↔spaces, trim whitespace | P1 | language/editor setting 반영 |
| line/block comment toggle | P1 | grammar comment metadata, plain text fallback |
| case conversion | P1 | Unicode-aware; locale edge case test |
| multi-selection/multi-cursor/select next/all/skip/undo | P1 | IME와 undo transaction 안정성 |
| rectangular/column selection and column editor | P1 | proportional font 제약을 명확히 하고 monospace path 완전 지원 |
| sort numeric/lexical/locale/length/random/reverse | P2 | selected lines scope와 stable-sort 명세 |
| remove empty/duplicate/consecutive duplicate lines | P2 | EOL 보존 |
| clipboard history | P2 | local-only 기본, sensitive-content clear option |
| date/time insert, path/name copy, rich/binary copy | P2 | macOS pasteboard types로 변환 |
| read-only/redaction | P2 | document state와 filesystem permission 구분 |
| whitespace/EOL/control-character 표시 | P1 | tab/space, EOL, non-printing indicator를 content 변경 없이 독립 toggle |

### C4. 검색·치환·표시 — 14점

원본 command 표면은 find/previous/next, replace, go-to, incremental search, find in files, bookmark, mark styles, changed-lines navigation을 포함한다([`menuCmdID.h:202-275`](../../notepad-plus-plus/PowerEditor/src/menuCmdID.h#L202-L275)).

| 기능 | 우선순위 | macOS 최적화/acceptance |
|---|---|---|
| find next/previous, selection prefill, wrap | P0 | `Cmd-F`, `Cmd-G`, `Shift-Cmd-G`; inline focus 회복 |
| replace/replace all/count all | P0 | current selection/document/open docs 범위 |
| regex, extended escapes, case, whole word, dot-newline | P0 | search engine semantics와 timeout/cancel 명세 |
| find in all open documents | P0 | untitled/dirty buffers도 검색 대상 |
| find/replace in files | P1 | include/exclude glob, recursion, hidden files, progress/cancel/error report |
| results panel and result-in-result search | P1 | 결과에서 원문 이동, stale result 표시 |
| mark all, five style sets, copy/cut/delete marked lines | P1 | persistent/nonpersistent 구분, color accessibility |
| bookmarks and next/previous/clear | P1 | session 복원 |
| go to line/offset, matching brace | P1 | Unicode byte/character offset 의미 명확화 |
| change-history next/previous/clear | P2 | undo history와 시각적 구분 |

### C5. 언어·highlighting·completion — 12점

| 기능 | 우선순위 | macOS 최적화/acceptance |
|---|---|---|
| built-in broad language grammar set | P0 | 원본 built-in 목록과 mapping table 유지; 최소 대표 20개 deep test + 전체 smoke test |
| extension/shebang/content 기반 language detection | P0 | 오탐 시 instant plain-text override |
| syntax highlighting and theme styles | P0 | light/dark, high contrast, large document degradation |
| folding and fold-state session restore | P1 | keyboard/VoiceOver control 제공 |
| language-aware comment/indent/brace matching | P1 | grammar metadata 기반 |
| current-document word completion | P1 | large-file disable/limit과 cancel |
| API/function completion and call tips | P1 | language contribution으로 공급 가능 |
| user-defined/importable language grammar | P1 | schema validation, versioning, safe reload |
| external lexer equivalent | P2 | in-process native module 대신 sandboxed grammar/provider API |
| function list/symbol outline | P1 | language parser contribution과 plain-text fallback |

### C6. encoding·EOL·파일 무결성 — 8점

원본은 DOS/Unix/legacy Mac EOL 변환, UTF-8/UTF-16 및 다양한 Windows/ISO/DOS/CJK encoding command를 갖는다([`menuCmdID.h:413-478`](../../notepad-plus-plus/PowerEditor/src/menuCmdID.h#L413-L478)). 외부 삭제/수정 후 reload하지 않은 buffer는 별도의 unsynchronized 상태로 관리한다([`Buffer.h:458-469`](../../notepad-plus-plus/PowerEditor/src/ScintillaComponent/Buffer.h#L458-L469)).

| 기능 | 우선순위 | macOS 최적화/acceptance |
|---|---|---|
| UTF-8/BOM, UTF-16 LE/BE read/write/convert | P0 | decode와 convert를 구분; lossy save 차단 |
| legacy Western/CJK encoding read/write/convert | P1 | Korean EUC-KR/CP949, Shift-JIS, Big5/GB 계열 포함 |
| encoding auto-detection and manual override | P1 | confidence가 낮으면 사용자에게 nonmodal 표시 |
| LF/CRLF/CR preserve and convert | P0 | mixed EOL 탐지/정책 포함 |
| external modification/deletion detection | P0 | dirty conflict에서 silent reload/save 금지 |
| reload from disk and compare/keep choice | P0 | undo/recovery 안전망 유지 |
| read-only filesystem/user state | P1 | filesystem permission, locked file, app-level lock 구분 |
| large-file safe mode | P1 | 원본도 large file에서 completion, snapshot, save backup, word wrap 등을 제한한다([`Buffer.h:469`](../../notepad-plus-plus/PowerEditor/src/ScintillaComponent/Buffer.h#L469)); Duckpad는 제한 상태를 명시하고 text access를 유지 |

### C7. 탐색·workspace·패널 — 7점

원본 view command에는 document list/map, 세 개의 project panel, function list, file browser가 있다([`menuCmdID.h:355-392`](../../notepad-plus-plus/PowerEditor/src/menuCmdID.h#L355-L392)).

| 기능 | 우선순위 | macOS 최적화/acceptance |
|---|---|---|
| searchable open-document list | P0 | 탭 수와 무관하게 filename/path/status 검색 |
| recent files and recently closed tabs | P1 | missing file와 permission 상태 표시 |
| folder as workspace/file browser | P1 | Finder reveal, drag/drop, security-scoped persistence |
| project/workspace saved roots | P1 | N개 root, expanded/selected state 복원 |
| function list/symbol outline | P1 | C5 parser contribution을 소비 |
| document map/minimap | P2 | C2와 동일 component, dock/visibility restore |
| character/ASCII panel | P2 | Unicode scalar/character inspector로 확대 변환 |
| dockable panels | P1 | AppKit sidebar/inspector/bottom panel; layout session restore |

### C8. 플러그인·확장성 — 9점

원본은 DLL architecture를 검사하고 exported function을 resolve한 후 plugin command와 notifications를 연결한다([`PluginsManager.cpp:99-174`](../../notepad-plus-plus/PowerEditor/src/MISC/PluginsManager/PluginsManager.cpp#L99-L174)). 이 binary mechanism은 macOS에 이식하지 않지만 확장 결과는 패리티 범위다.

| 기능 | 우선순위 | macOS 최적화/acceptance |
|---|---|---|
| versioned manifest and extension discovery | P0 | app-managed extension directory, deterministic enable/disable |
| command/menu/keybinding contribution | P0 | command registry가 core와 plugin을 동일하게 노출 |
| document/editor read-edit API | P0 | transactional edit, undo boundary, selected ranges, active document |
| lifecycle/document/editor events | P0 | open/save/close/change/selection/theme; backpressure 명세 |
| language/grammar/completion/function-list contribution | P1 | declarative 우선, provider timeout/cancel |
| decorations/markers/status/panel contribution | P1 | namespaced resource, accessibility metadata |
| permission/capability model | P0 | filesystem/network/process/clipboard를 명시적 분리; least privilege |
| isolation and crash recovery | P0 | out-of-process host 또는 동등 격리; hang/crash가 editor/recovery를 중단하지 않음 |
| plugin install/update/disable/remove UI | P1 | signature/notarization 또는 trust 표시; safe mode |
| compatibility diagnostics | P1 | API version과 실패 원인을 사용자에게 표시 |
| Notepad++ plugin source migration guide | P2 | binary compatibility가 아닌 concept/API mapping 제공 |

### C9. macro·명령·도구 — 4점

원본은 macro record/stop/play/save/multiple-run command를 제공하고([`menuCmdID.h:104-118`](../../notepad-plus-plus/PowerEditor/src/menuCmdID.h#L104-L118)), UI 상태도 recording/macro availability에 따라 제어한다([`Notepad_plus.cpp:2725-2730`](../../notepad-plus-plus/PowerEditor/src/Notepad_plus.cpp#L2725-L2730)).

| 기능 | 우선순위 | macOS 최적화/acceptance |
|---|---|---|
| command palette/검색 가능한 command registry | P0 | core/plugin/menu command를 keyboard로 실행 |
| macro record/play/save/run N times | P1 | deterministic editor actions, cancel, undo grouping |
| configurable keybindings | P1 | macOS 예약 shortcut 충돌 진단 |
| run external command | P1 | opt-in process permission, quoted arguments, output panel |
| hash tools | P2 | SHA 계열을 command/plugin으로 제공 |

### C10. 설정·theme·접근성 — 2점

| 기능 | 우선순위 | macOS 최적화/acceptance |
|---|---|---|
| editor, tab, session/recovery preferences | P0 | 안전 기본값은 변경 가능하되 data-loss warning 제공 |
| light/dark/system theme and syntax themes | P1 | system appearance live update, contrast test |
| shortcut editor | P1 | core/plugin conflicts 및 default reset |
| localization/RTL | P2 | UI와 editing direction을 구분 |
| VoiceOver/full keyboard access/Reduced Motion | P0 | tabs, gutters, panels, dialogs에 semantic labels/actions |
| settings import/export | P2 | secret/permission state 제외, schema migration |

## 5. 제외 및 macOS 변환 목록

| Notepad++/Windows 기능 | 판정 | Duckpad 처리 |
|---|---|---|
| Windows registry file association | 제외 | Finder/Open With 및 document type declaration로 흡수 |
| UAC elevation save/move helper | 제외 | sandbox permission과 native authorization/error workflow 사용 |
| PowerShell/CMD 직접 열기 | 변환(C9) | Terminal에서 열기 또는 권한 있는 external command contribution |
| Explorer에서 폴더 열기 | 변환(C7) | Finder에서 보기 |
| IE/Edge/Chrome/Firefox 고정 메뉴 | 변환(C9) | default browser로 열기 + plugin/command 확장 |
| Windows system tray lifecycle | 제외 | 필요할 경우 별도 menu bar extra로 설계; editor parity 점수에는 미포함 |
| Windows task list/Jump List | 변환(C7) | Dock recent items, app reopen, Spotlight/Finder integration |
| Win32 `TCS_MULTILINE` widget | 변환(C2) | custom AppKit multiline tab layout; UX 결과는 필수 |
| Win32 docking manager | 변환(C7) | native split/sidebar/inspector/panel layout |
| Notepad++ DLL plugin ABI | 제외(ABI만) | C8의 기능 표면은 Duckpad extension API로 반드시 구현 |
| Windows code page UI 명칭 | 변환(C6) | IANA/사용자 친화 이름을 표시하되 byte compatibility 보존 |
| legacy Mac CR 메뉴의 역사적 명칭 | 변환(C6) | `CR (Classic Mac)`으로 명시하고 round-trip 지원 |
| updater executable/GPG release flow | 변환(C10) | notarized Sparkle 또는 Mac App Store에 맞는 signed update flow |

## 6. 제품 완료 조건

“Notepad++ 90% 포팅”은 다음 증거가 모두 있을 때만 완료다.

1. versioned JSON baseline의 모든 source symbol과 stable workflow ID가 feature, independently approved `Reviewed-N/A`, non-command meta 중 허용된 하나로 매핑되고 checker가 unmapped/ambiguous command와 unmapped/false workflow를 0개 보고한다.
2. JSON의 각 feature에 owner, acceptance, automated/manual evidence, 구현 state가 연결되고 sidecar checksum 검증 후 calculator가 **90.0 이상**을 산출한다.
3. P0 항목이 모두 1.00이고 G1~G10이 release candidate에서 모두 통과한다.
4. Notepad++ 원본과 Duckpad를 나란히 수행하는 golden workflow test가 최소 다음 범위를 덮는다: scratch/restore, 50-tab multiline, open/save/encoding/EOL, edit/multi-cursor/column, search scopes/regex, language detection/highlight/fold, split/clone, workspace, plugin lifecycle/isolation, macro.
5. macOS 2개 이상의 지원 OS major version과 Intel/Apple Silicon 지원 방침에 맞는 hardware matrix에서 검증한다. 실제 지원 matrix가 단일 architecture라면 그 결정과 대안을 별도 ADR로 기록한다.
6. 한글·일본어·중국어 IME, emoji/grapheme cluster, RTL 혼합, VoiceOver, full keyboard access, dark mode, Retina를 포함한 native UX test를 통과한다.
7. force quit, disk full, permission loss, corrupted recovery, plugin crash/hang, external file conflict를 포함한 fault-injection test에서 문서 무결성을 확인한다.
8. Blocker/Critical data-loss 및 plugin sandbox escape 취약점이 0개이고, High issue에는 명시적 release decision이 있다.
9. local Git history의 각 commit 직전에 review evidence가 있고 commit header/content가 영어라는 repository policy를 만족한다.
10. architecture와 중요한 구현 판단, agent work log, test 결과가 `docs/wiki`에서 서로 링크된다.

## 7. 다음 설계로 넘기는 불변 조건

이 문서는 제품 기준선이며 구현 세부를 고정하지 않는다. 다만 다음은 architecture가 바꿀 수 없는 invariant다.

- `Document` 생명주기는 filesystem path 존재 여부와 독립적이다.
- recovery write와 file save는 실패 시 이전의 유효한 사본을 파괴하지 않는 atomic protocol을 사용한다.
- UI, application use case, domain, platform/storage/plugin adapter 경계를 분리한다.
- plugin은 domain object나 editor memory를 직접 소유하지 않고 versioned port를 통해 접근한다.
- multiline tab layout은 view concern이지만 tab identity/order/pin/dirty state는 UI widget에 저장하지 않는다.
- 검색, 저장, indexing, plugin provider는 cancel 가능하고 main thread를 장시간 점유하지 않는다.
- macOS adapter가 Finder, security-scoped bookmark, menu/command routing, accessibility를 책임지며 domain에 AppKit 타입을 누출하지 않는다.

## 8. 소스 근거 색인

| 근거 | 확인한 의미 |
|---|---|
| [`README.md:7-10`](../../notepad-plus-plus/README.md#L7-L10) | source editor이면서 Notepad replacement라는 이중 정체성 |
| [`menuCmdID.h:22-197`](../../notepad-plus-plus/PowerEditor/src/menuCmdID.h#L22-L197) | file/edit/macro/autocomplete command surface |
| [`menuCmdID.h:202-275`](../../notepad-plus-plus/PowerEditor/src/menuCmdID.h#L202-L275) | search/bookmark/mark/change navigation surface |
| [`menuCmdID.h:284-411`](../../notepad-plus-plus/PowerEditor/src/menuCmdID.h#L284-L411) | view/tab/split/panel/document-map surface |
| [`menuCmdID.h:413-584`](../../notepad-plus-plus/PowerEditor/src/menuCmdID.h#L413-L584) | EOL/encoding/built-in/external/user language surface |
| [`menuCmdID.h:603-642`](../../notepad-plus-plus/PowerEditor/src/menuCmdID.h#L603-L642) | preference/plugin admin/tool/system-tray commands |
| [`Parameters.h:121-169`](../../notepad-plus-plus/PowerEditor/src/Parameters.h#L121-L169) | session에 보존되는 document/view 상태 |
| [`Parameters.h:735-869`](../../notepad-plus-plus/PowerEditor/src/Parameters.h#L735-L869) | editor/search/backup/completion/panel/snapshot 기본 설정 |
| [`Buffer.cpp:1218-1259`](../../notepad-plus-plus/PowerEditor/src/ScintillaComponent/Buffer.cpp#L1218-L1259) | saved/untitled snapshot 및 periodic backup 사양 |
| [`NppIO.cpp:2490-2644`](../../notepad-plus-plus/PowerEditor/src/NppIO.cpp#L2490-L2644) | backup fallback과 session 상태 복구 |
| [`TabBar.cpp:40-52`](../../notepad-plus-plus/PowerEditor/src/WinControls/TabBar/TabBar.cpp#L40-L52) | vertical/multiline tab 초기화 |
| [`TabBar.cpp:616-623`](../../notepad-plus-plus/PowerEditor/src/WinControls/TabBar/TabBar.cpp#L616-L623) | multiline runtime toggle |
| [`FindReplaceDlg.h:63-106`](../../notepad-plus-plus/PowerEditor/src/ScintillaComponent/FindReplaceDlg.h#L63-L106) | search option과 regex flag model |
| [`Notepad_plus.cpp:437-443`](../../notepad-plus-plus/PowerEditor/src/Notepad_plus.cpp#L437-L443) | main/sub split view |
| [`PluginInterface.h:28-69`](../../notepad-plus-plus/PowerEditor/src/MISC/PluginsManager/PluginInterface.h#L28-L69) | plugin host data, commands, notifications, messages |
| [`PluginsManager.h:87-139`](../../notepad-plus-plus/PowerEditor/src/MISC/PluginsManager/PluginsManager.h#L87-L139) | plugin lifecycle 및 resource allocation surface |

## 9. Agent Work Log

### 2026-09-02 — `/root/philosophy_parity`

- **작업**: 로컬 Notepad++ commit `dda973d2b`의 README, command inventory, buffer/session/backup, tab bar, search, split view, language/UDL, plugin manager 소스를 정적 분석했다.
- **산출물**: Duckpad 철학/비목표, 가중 패리티 공식, 10개 필수 UX gate, 10개 기능 카테고리 inventory, P0/P1/P2/제외·변환 기준, 제품 완료 조건을 이 문서에 확정했다.
- **핵심 판단 1**: Duckpad의 차별점은 기능 축소가 아니라 **scratch-first + loss-averse + deep-on-demand**의 조합이다.
- **핵심 판단 2**: 90%는 menu command 개수 비율이 아니다. 중요도 가중 기능 점수 90점 이상과 P0/UX gate 전부 통과의 교집합이다.
- **핵심 판단 3**: Notepad++ DLL ABI는 Windows 종속이므로 제외하지만, command/event/editor/language/panel 확장 능력은 C8에서 점수를 받는 필수 macOS-native 재설계 대상이다.
- **핵심 판단 4**: multiline tab은 장식이 아니라 많은 untitled 문서를 작업 기억으로 사용하는 제품 정체성이므로 P0와 G4에 동시에 배치했다.
- **핵심 판단 5**: Windows widget/shell 동작은 모양이 아니라 사용자 결과를 기준으로 native equivalent에 매핑했다.
- **변경 범위**: 요청에 따라 이 wiki 파일 하나만 추가했으며 원본 Notepad++ 파일은 수정하지 않았다. 커밋하지 않았다.

### 2026-09-02 — `/root/philosophy_parity` review follow-up

- **검토 입력**: 독립 review의 B-02(충돌하는 공식)와 M-01(추적 불가능한 denominator) 증거를 읽고 문서 01을 유일한 normative algorithm으로 지정했다. review finding을 해결 완료로 선언하지 않았으며 독립 재리뷰가 남아 있다.
- **machine-readable baseline**: `docs/parity/notepad-plus-plus-command-baseline.v1.json`에 version, pinned source commit/path/hash, 다섯 user-visible workflow surface hash, category weights, 91 stable feature IDs, workflow sources, command mapping rules, UX gate state를 기록했다.
- **추적 결과**: `menuCmdID.h`의 활성 `IDM_*` 530개를 feature command 490개, provisional `Reviewed-N/A` command 13개, non-command meta 27개로 전부 분류했다. N/A rationale 다섯 개는 독립 승인 전까지 `pending`이며 checker가 `release_pass=false`를 강제한다.
- **checksum 결정**: JSON 내부에 checksum을 저장하지 않고 `docs/parity/notepad-plus-plus-command-baseline.v1.sha256`가 JSON bytes만 hash한다. v1 checksum은 `0a8a720e3affeea752b0b7bda63dee3a1edecbf17e08c46b2a088f318b3abfee`다.
- **checker**: `scripts/check_parity_baseline.py`가 source/file/symbol-set checksum, schema, weights, feature evidence, 정확히 하나인 command mapping, Reviewed-N/A approval shape를 검증하고 규범 공식을 계산한다.
- **tests**: `tests/test_parity_baseline.py`와 최소 fixture가 active define extraction, complete mapping, unmapped failure, ambiguous failure, order-independent symbol checksum을 검증한다.
- **실행 증거**: `python3 scripts/check_parity_baseline.py` 통과(구조 검증 성공, 현재 구현 점수 `0.0`, release 미통과); `python3 -m unittest -v tests/test_parity_baseline.py` 통과(5 tests).
- **변경 제약**: stage와 commit은 수행하지 않았다.

### 2026-09-02 — `/root/philosophy_parity` parity schema v2 재리뷰 대응

- **검토 입력**: 독립 재리뷰의 M-01/M-02/M-03 및 m-03/m-04/m-05를 근거로 작업했다. 이 기록은 finding을 임의로 닫는 선언이 아니라 다음 독립 재리뷰가 판정할 evidence다.
- **M-01 evidence**: checksum-only였던 다섯 surface를 32개 stable workflow/behavior record로 열거하고 selector, feature ID, acceptance를 결합했다. `IDM_VIEW_WRAP/WRAP_SYMBOL→C2.F12`, visible characters→`C3.F13`, hide lines→`C2.F13`, `IDM_VIEW_GOTO_START/END→C2.F02`로 수정하고 new-instance mapping에서 tab-edge command를 제거했다. command 530개와 workflow 32개 모두 누락/중복/false selector를 검사한다.
- **M-02 evidence**: 모든 feature와 정확히 G1~G10에 owner, acceptance, candidate-bound evidence ID를 요구한다. `Full`은 automated+manual evidence를 모두 요구한다. release candidate, 90점, non-vacuous P0 전부 Full, G1~G10 Pass, Blocker/Critical 0, pending N/A 0을 동시에 만족해야 한다. 현재 구현은 거짓 승격 없이 전부 `Missing`, score `0.0`, release false다.
- **N/A receipt evidence**: `scripts/verify_parity_review_receipt.py`와 hash-pinned `docs/parity/reviewer-identities.v1.json`을 추가했다. verifier가 receipt 파일/bytes hash, candidate SHA-256, baseline version, rule ID, reviewer ID/role/fingerprint/status와 builder-reviewer 분리를 검증한다.
- **M-03 evidence**: normal suite는 versioned 530-symbol fixture를 사용해 ignored `notepad-plus-plus/` tree 없이 실행된다. setup script가 full pinned commit을 clone/fetch/detached-checkout하고 dirty tree를 보호한 뒤 integration audit를 실행한다.
- **strictness evidence**: numeric string/bool/fraction/NaN, defect-count coercion, sidecar missing/mismatch, missing P0/gates/evidence/receipt, candidate drift, forged reviewer, unmapped/ambiguous/unused rule, invalid regex/disposition, unknown workflow/unused surface/false selector, source commit/header/surface drift, CLI exit code 2를 negative fixture로 검증했다. 모든 Full+G1~G10+verified receipts를 갖춘 synthetic candidate는 positive fixture에서 release true를 검증했다.
- **실행 증거**: `python3 -B -m unittest -v tests/test_parity_baseline.py` 통과(18 tests); default checker 통과(530 symbols, 32 workflows, 94 features, score `0.0`, release false); setup script와 explicit integration audit 통과; pinned HEAD `dda973d2b2da6bdcc7db9f18a7f5d2fbf6b07248`, reference worktree clean.
- **checksum**: schema v2 JSON sidecar SHA-256은 `a7fbc47eb649b602a3a4b8d718d3c2b02156a1f8703649a31ba55aa57807754d`다.
- **m-05 확인**: C2 table header는 한 번만 존재한다. 함께 확인한 inventory 중복 행도 제거된 상태다.
- **변경 제약**: source reference, Git stage, commit은 변경하지 않았다.

### 2026-09-02 — `/root/philosophy_parity` final-review F-01/F-03 대응

- **검토 범위**: final review의 F-01 workflow freeze/ownership과 F-03 reference setup boundary만 수정했다. F-02 candidate/evidence authority는 별도 담당 범위이므로 해당 authority/verifier 구현을 변경하지 않았다. 이 기록은 후속 독립 review를 위한 evidence이며 finding 종료 선언이 아니다.
- **F-01 결정**: baseline 내부 inventory와 독립된 `docs/parity/notepad-plus-plus-workflow-inventory.v1.json` 및 byte sidecar를 추가했다. pinned source의 5 surface와 32 workflow에 대해 stable ID, surface, selector, feature, exact occurrence count를 동결했다. baseline도 같은 expected count를 가지며 checker가 두 artifact를 exact compare한다.
- **F-01 fail-closed 검사**: missing/extra/duplicate workflow ID, duplicate `(surface, selector)` ownership, 서로 다른 selector match span overlap, expected occurrence drift를 거부한다. fixture schema/count는 strict integer이며 fixture 자체 sidecar와 baseline에 기록된 hash를 모두 검증한다.
- **F-03 결정**: setup target은 첫 Git 명령 전에 physical canonical path로 해석한다. `/`, Duckpad root, symlink target/escape, root 밖 또는 nested unsafe parent를 거부하고 Duckpad root의 direct child만 관리한다. 기존 repository는 standalone Git top-level과 공식 origin URL이 모두 일치해야 한다.
- **F-03 clean invariant**: pinned HEAD 여부와 무관하게 checkout/fetch 전, integration audit 전, audit 후에 `status --porcelain --untracked-files=all`이 비어야 한다. audit 후 HEAD도 full pin과 다시 비교한다. dirty-at-pin 거부는 dirty file과 HEAD를 변경하지 않는다.
- **tests**: reference-free normal suite는 root `.`, symlink escape, unsafe parent, unrelated repository 및 frozen inventory removal/extra/duplicate를 포함해 20 tests다. `DUCKPAD_NPP_REFERENCE=notepad-plus-plus python3 -B -m unittest -v tests/test_parity_integration.py`는 실제 pinned source에서 positive control, removal, duplicate ownership, occurrence drift, overlap, dirty-at-pin을 검증하는 6 tests다.
- **실행 증거**: normal 20/20 및 explicit integration 6/6 통과; setup→integration audit 통과; source HEAD `dda973d2b2da6bdcc7db9f18a7f5d2fbf6b07248`, pre/post clean; `git diff --check` 통과; stage/commit 없음.
- **sidecars at handoff**: workflow fixture `ab18ceb959ff90a4a61efb12dec23beefa472b11027d546185308647c5d23a28`; baseline `a3a738a49c60000824ef20d894915a9297bc7b8cf7d4b637f98362d3242984e7`. 이후 F-02 연동이 baseline bytes를 바꾸면 adjacent sidecar와 이 로그의 handoff 이후 값도 함께 갱신해야 한다.

### 2026-09-02 — `/root/workflow_roadmap` final-review F-02 대응

- **역할/검토 입력**: builder. 독립 final review F-02와 `/root/workflow_roadmap/f02_investigator`의 read-only 결과를 입력으로 사용했다. finding 종료/승인은 후속 독립 reviewer만 판정한다.
- **candidate provenance**: schema v3 `release_candidate`는 hash가 실제로 해석되는 manifest bytes와 같아야 한다. checker는 manifest의 builder identity, deterministic source-tree hash, 하나 이상의 build artifact 경로/bytes hash를 재계산한다. 현재 baseline은 `not_built`, score `0.0`, release false이므로 artifact 부재가 정상이다.
- **evidence authority**: fingerprint/self-declared verifier/result를 제거했다. active versioned Ed25519 공개키와 `.git` 내부 allowed-signers가 동시에 일치하는 독립 reviewer만 `duckpad-parity-attestation-v1` namespace에 서명할 수 있다. evidence payload는 candidate/baseline/evidence type/feature·gate subjects/typed result artifact를 묶고, Reviewed-N/A는 candidate/baseline/rule/rationale를 묶는다.
- **adversarial coverage**: 실제 임시 private key로 positive release를 서명한다. unsigned internally-consistent release, manifest/source/build artifact tamper·missing, attestation/result tamper, wrong/inactive/builder signer, candidate/feature replay를 fail-closed로 검증한다.
- **baseline integrity**: F-01 workflow sidecar `ab18ceb959ff90a4a61efb12dec23beefa472b11027d546185308647c5d23a28`은 변경하지 않았다. schema v3 baseline sidecar는 `b3aaf80aa79e6d4eda21d05c932194f6cf23dc2889866545823a0c2cea8127cb`이며 검증을 통과했다.
- **실행 증거**: reference-free parity 24/24, governance E2E 3/3, pinned integration 6/6, default checker, setup+explicit integration과 두 sidecar 검증이 모두 통과했다. production baseline은 530 symbols/32 workflows/94 features, score `0.0`, release false를 유지한다.
- **변경 제약**: stage/commit하지 않았다. 이 변경은 새 독립 review와 exact-candidate receipt 전까지 Pending approval이다.

### 2026-09-02 — `/root/workflow_roadmap` approval-review trust remediation

- **역할/입력:** builder; read-only investigator `/root/workflow_roadmap/trust_boundary_investigator`. approval review F-02와 m-01~m-04를 수정하되 승인 판정은 하지 않는다.
- **Reviewer lifecycle:** repository-shipped key bootstrap을 제거했다. genesis trust와 read-only `genesis-reviewers.json` snapshot/digest는 worktree 밖 `.git/duckpad-review-trust/v1`에 먼저 provision되고, subsequent commit은 parent registry에 이미 active인 reviewer만 허용한다. candidate가 추가한 reviewer는 onboarding commit 다음 경계부터 사용할 수 있다.
- **Identity/scope:** commit builder ID는 prepare CLI 문자열이 아니라 orchestrator-provisioned local identity에서 읽는다. 이는 agent 조직 분리 evidence이며 same-UID malicious owner/root에 대한 OS security boundary가 아니다.
- **Strict evidence:** baseline/release manifest/workflow fixture/typed result가 duplicate JSON key를 모두 거절한다. direct integration checker는 pre/post clean과 pinned HEAD 불변을 검증한다.
- **Integrity:** workflow sidecar `ab18ceb959ff90a4a61efb12dec23beefa472b11027d546185308647c5d23a28`은 보존했다. baseline sidecar는 `08c0fdc79f80cded7149d3997006cdcf95b871fb704220993171731189ce897e`다.
- **Initial candidate preflight update:** `git diff --cached --check`를 만족시키기 위해 workflow fixture의 의미 없는 EOF blank line만 제거했고 내용/ID/selector는 바꾸지 않았다. 갱신된 workflow sidecar는 `d0d5e650145c0b28c9c82561cf46d528531e33d83235b46e38a7b0f35cfe96b4`, 이를 참조하는 baseline sidecar는 `ce1af4e91b31db376145d9bd5b34bb4fc3bbab1c6759ffd3dcee8d99a4a44739`, parity contract digest는 `80f57a3342b7e8df138650f8d37d6a1544896e2cc7f9cf87f60a9bdb9b80b6dc`다.
- **Validation:** normal 26/26, governance 4/4, pinned integration 7/7, setup/default/sequential explicit checker와 sidecars가 통과했다. isolated clean copy의 normal+governance 30/30과 default checker도 통과했다.
- **변경 제약:** stage/commit 없음; latest approval review verdict는 계속 Rejected다.
