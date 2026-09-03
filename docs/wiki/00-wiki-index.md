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
| 12 | [Scintilla 5.6.6 integration](05-scintilla-integration.md) | **Implemented; review pending** | 공식 standalone source provenance, 좁은 Objective-C++ façade, UTF-8/revision 계약, 실제 AppKit editor 검증을 기록한다. |
| 13 | [Phase 3 file I/O](06-file-io.md) | **Implemented; review pending** | strict Unicode/EOL 보존, atomic save, external-conflict policy와 native macOS file commands를 기록한다. |
| 14 | [Phase 4 session recovery](07-session-recovery.md) | **Content approved; exact receipt pending** | generation별 UTF-8 recovery, corrupt fallback, editor view state, crash autosave와 durable close/termination ordering candidate다. |
| 15 | [Phase 4 independent code review](reviews/2026-09-02-phase-4-session-recovery-code-review.md) | **Rejected — superseded review evidence** | 최초 P4-01~P4-06 Major 판정과 당시 debug/release/smoke/adversarial evidence다. |
| 16 | [Phase 4 remediation re-review](reviews/2026-09-02-phase-4-session-recovery-rereview.md) | **Content approved; exact receipt pending — latest Phase 4 evidence** | P4-01~P4-06 closure, focused/debug/release/fresh/smoke evidence와 exact 19-file scope를 기록한다. |
| 17 | [Phase 5 multiline tab workspace](08-multiline-tabs.md) | **Content approved; exact receipt pending** | native multiline wrapping, pin/MRU/order, shared loss-safe close gate, drag/context/accessibility와 500-tab layout contract를 기록한다. |
| 18 | [Phase 5 independent code review](reviews/2026-09-02-phase-5-multiline-tabs-code-review.md) | **Rejected — superseded review evidence** | 최초 P5-01~P5-03 Major와 당시 debug/release/smoke/adversarial evidence를 기록한다. |
| 19 | [Phase 5 remediation re-review](reviews/2026-09-02-phase-5-multiline-tabs-rereview.md) | **Rejected — superseded review evidence** | P5-01/P5-02 closure와 P5-03 termination Retry 잔여 Major를 기록한다. |
| 20 | [Phase 5 final remediation re-review](reviews/2026-09-02-phase-5-multiline-tabs-final-rereview.md) | **Content approved; exact receipt pending — latest Phase 5 evidence** | P5-01~P5-03 closure, 새 native terminate cycle/latest revision/final flush와 repeated debug/release/AppKit evidence를 기록한다. |
| 21 | [Phase 6 search and replace](09-search-replace.md) | **Implemented; review pending** | non-modal macOS search UI, ICU hard-budget regex, UTF-8 result model, open-document results, and revision-reserved grouped replacement를 기록한다. |
| 22 | [Phase 6 independent code review](reviews/2026-09-03-phase-6-search-replace-code-review.md) | **Rejected — superseded review evidence** | regex Whole Word, terminal zero-length progress, fixed selection Replace All의 최초 3 Major와 당시 debug/release/smoke/probe evidence를 기록한다. |
| 23 | [Phase 6 remediation re-review](reviews/2026-09-03-phase-6-search-replace-rereview.md) | **Rejected — superseded review evidence** | P6-01/P6-02 closure와 당시 selection nil/invalidation이 전체 문서 치환으로 확장되던 P6-03 잔여 Major를 기록한다. |
| 24 | [Phase 6 final remediation re-review](reviews/2026-09-03-phase-6-search-replace-final-rereview.md) | **Content approved — latest Phase 6 evidence** | 공통 typed selection preflight, 무변경/undo/recovery 보존, P6-01~P6-03 closure와 132-test evidence를 기록한다. |
| 25 | [Phase 7 language and Lexilla integration](10-language-support.md) | **Implemented; review pending** | official Lexilla 5.5.3 provenance, 78-language registry/detection, exact 20-language keyword-complete tier, persisted overrides, bounded semantic styling, fold/brace/indent/comment UX를 기록한다. |
| 26 | [Phase 8 secure extension platform](11-extension-platform.md) | **Approved, committed and audited** | official WAMR 2.4.5 interpreter, signed package identity, durable scoped consent, isolated Process-host Developer Preview와 termination-safe grouped edits를 기록한다. commit `1f60bedd`와 exact signed receipt가 audit를 통과했다. |
| 27 | [Phase 8 independent code review](reviews/2026-09-03-phase-8-extension-platform-code-review.md) | **Approved — latest Phase 8 evidence** | P8-01/P8-02와 Process teardown remediation, WAMR 168/168 재현을 0 Blocker/Major/Minor로 승인했다. receipt SHA-256은 `bd5dfc59a078fc9170ce1112ff9797e8108471d42dd7cf9c1ff02a2112e15e3e`다. |
| 28 | [Phase 9 editor view options](12-editor-view-options.md) | **Approved, committed and audited** | 탭별 word wrap, Scintilla wrap symbols, recovery 호환성, lifecycle-gated native View menu를 기록한다. commit `268c0e1`과 exact signed receipt가 audit를 통과했다. |
| 29 | [Phase 9 independent code review](reviews/2026-09-03-phase-9-editor-view-options-code-review.md) | **Approved — latest Phase 9 evidence** | view/recovery/Scintilla/menu/close-race와 P9-01 remediation을 0 Blocker, 0 Major, 0 Minor로 승인했다. receipt SHA-256은 `b43abeabd167a748b25bad4d72f6951703188f973275995b920515808a979f8b`다. |
| 30 | [Phase 10 standard editing commands and shortcuts](13-standard-editing-shortcuts.md) | **Content approved; exact receipt pending** | native Edit menu, Cmd-N/Z/Shift-Z/X/C/V/A, shortcut collision 검사, editor별 undo/clipboard command 계약과 세 review remediation을 기록한다. |
| 31 | [Phase 10 independent code review](reviews/2026-09-03-phase-10-standard-editing-shortcuts-code-review.md) | **Content approved — latest Phase 10 evidence** | Cmd-N termination join, Scintilla IME responder semantics, fallback revision-exhaustion remediation을 0 Blocker, 0 Major, 0 Minor로 승인했다. candidate freeze/signing이 허가됐고 exact receipt는 pending이다. |
| 32 | [Phase 11 workspace chrome and document dropdown](14-workspace-chrome-and-document-dropdown.md) | **Approved, committed and pushed** | 상단 blank-space 제거, compact multiline tabs, stable-ID document dropdown, 실제 status bar, language dropdown, Scintilla gutter/palette polish와 84% footprint 교체 앱 아이콘을 기록한다. commit `fff6c1c`가 exact receipt/audit 후 `origin/main`에 push됐다. |
| 33 | [Phase 11 independent code review](reviews/2026-09-03-phase-11-workspace-chrome-code-review.md) | **Approved — latest Phase 11 evidence** | dropdown O(1) 증분 갱신, synchronous termination chrome admission, 네 모서리·전체 ICNS round-trip을 0 Blocker/Major/Minor로 독립 재검증했다. |
| 34 | [Phase 12 searchable document switcher](15-searchable-document-switcher.md) | **Approved, committed and pushed** | title/path ranked filtering, stable-ID keyboard activation, adaptive native popover, `Command-Shift-O`, 5,000-tab budget와 termination admission을 기록한다. commit `5f816e0`가 exact receipt/audit 후 `origin/main`에 push됐다. |
| 35 | [Phase 12 independent code review](reviews/2026-09-03-phase-12-searchable-document-switcher-code-review.md) | **Content approved — latest Phase 12 evidence** | 최초 2 Major/1 Minor, 두 remediation round와 exact-tier/popover lifecycle closure를 기록하며 최종 0 Blocker/Major/Minor로 승인한다. |
| 36 | [Phase 13 recently closed tab restoration](16-recently-closed-tabs.md) | **Approved, committed and pushed** | 최근 닫은 탭 기록을 최대 100개까지 보관하며 stable metadata와 UTF-8/view snapshot 복구, `Command-Shift-T`, durable restore, 종료 경쟁 및 자동 빈 탭 치환을 기록한다. Phase 13은 commit `8d7ecca`로 전달됐고 100-entry 정책은 후속 탭 lifecycle slice에서 확장한다. |
| 37 | [Phase 13 independent code review](reviews/2026-09-03-phase-13-recently-closed-tabs-code-review.md) | **Content approved — latest Phase 13 evidence** | 최초 2 Major와 automatic-replacement/stable-retry remediation, off-main capture materialization 및 duplicate-path safety를 재검증해 최종 0 Blocker/Major/Minor로 승인한다. |
| 38 | [Phase 14 tab lifecycle commands](17-tab-lifecycle-commands.md) | **Content approved; exact receipt pending** | 최근 닫은 탭 기록 100개, Close All/Others/Left/Right/Unchanged/Unpinned의 native 메뉴·우클릭 경로, pinned 보호, dirty review 및 종료 경쟁 처리를 기록한다. |
| 39 | [Phase 14 independent code review](reviews/2026-09-03-phase-14-tab-lifecycle-code-review.md) | **Content approved — latest Phase 14 evidence** | 초기 accepted-close termination race Major와 LIFO test Minor를 remediation 후 재검증해 최종 0 Blocker/Major/Minor로 승인한다. |
| 40 | [Phase 15 advanced editing commands](18-advanced-editing-commands.md) | **Content approved; exact receipt pending** | 줄 복제/이동/삭제/합치기, 들여쓰기, 대소문자 변환, 후행 공백 제거와 충돌 없는 native shortcut surface를 기록한다. |
| 41 | [Phase 15 independent code review](reviews/2026-09-03-phase-15-advanced-editing-code-review.md) | **Content approved — latest Phase 15 evidence** | 최초 3 Major의 Join 경계, revision exhaustion 원자성, fallback selection/EOL 결함을 focused remediation 재검증으로 모두 닫아 최종 0 Blocker/Major/Minor로 승인한다. |
| 42 | [Phase 16 external file Compare](19-external-file-compare.md) | **Content approved; exact receipt pending** | 외부 변경 충돌에서 비파괴 local/external 비교, 32 MiB 표시 한도와 Compare 이후 Reload/Overwrite/Cancel 재결정을 기록한다. |
| 43 | [Phase 16 independent code review](reviews/2026-09-03-phase-16-external-file-compare-code-review.md) | **Content approved — latest Phase 16 evidence** | 최초 2 Major의 comparison-read stale snapshot과 post-panel/reload-read data-loss race를 authoritative revision/binding transaction으로 닫아 최종 0 Blocker/Major/Minor로 승인한다. |
| 44 | [Phase 17 folder search](20-folder-search.md) | **Content approved; exact receipt pending** | `Command-Shift-F` user-selected recursive search, structured results, bounded/cancellable descriptor-relative scan과 identity-checked result activation을 기록한다. |
| 45 | [Phase 17 independent code review](reviews/2026-09-03-phase-17-folder-search-code-review.md) | **Content approved — latest Phase 17 evidence** | 최초 5 Major/2 Minor의 TOCTOU, regex validation, result-memory/MainActor, directory-metadata, termination activation race를 remediation 후 재검증해 최종 0 Blocker/Major/Minor로 승인한다. |
| 46 | [Phase 18 persistent bookmarks](21-persistent-bookmarks.md) | **Implemented; review pending** | 문서별 line bookmark, 편집/undo 추적, 복구 검증, 순환 탐색과 `Command/F2` 단축키를 기록한다. |
| 47 | [Phase 18 independent code review](reviews/2026-09-03-phase-18-persistent-bookmarks-code-review.md) | **Content approved — latest Phase 18 evidence** | 최초 4 Major의 first-line backward wrap, fallback temporary-attribute ownership, CRLF mapping, maximum-marker MainActor budget을 remediation 후 재검증해 최종 0 Blocker/Major/Minor로 승인한다. |
| 48 | [Phase 19 shared-document split editing](22-split-editing.md) | **Implemented; review pending** | 같은 Scintilla document/undo를 공유하면서 cursor·selection·scroll은 독립적인 좌우/상하 pane, 복구와 native 단축키를 기록한다. |
| 49 | [Phase 19 independent code review](reviews/2026-09-03-phase-19-split-editing-code-review.md) | **Content approved — latest Phase 19 evidence** | 최초 3 Major/1 Minor의 rejected-edit 전환, per-buffer exhaustion, 양 pane language, secondary eviction 결함을 remediation 후 재검증해 최종 0 Blocker/Major/Minor로 승인한다. |
| 50 | [Phase 20 saved workspace file browser](23-workspace-file-browser.md) | **Content approved; exact receipt pending** | security-scoped folder roots, native outline browser, navigation restoration, drag/drop, Finder reveal과 `Command-Control-O`/`Command-Shift-E` 명령을 기록한다. |
| 51 | [Phase 20 independent code review](reviews/2026-09-03-phase-20-workspace-file-browser-code-review.md) | **Content approved — latest Phase 20 evidence** | descriptor-relative file authority, serialized/reconciled root mutation, security-scope lifetime, accepted file-open termination ordering과 corrupt-state preservation을 remediation 후 재검증해 최종 0 Blocker/Major/Minor로 승인한다. |
| 52 | [Phase 21 native multiple windows](24-native-multiple-windows.md) | **Approved, committed and pushed** | `Command-Shift-N` native window, key-window command routing, window별 recovery, 전체-window quit review와 same-file identity conflict 정책을 기록한다. commit `58d6772`가 exact receipt/audit 후 `origin/main`에 push됐다. |
| 53 | [Phase 21 independent code review](reviews/2026-09-03-phase-21-native-multiple-windows-code-review.md) | **Content approved — latest Phase 21 evidence** | 최초 3 Major/1 Minor의 late-window admission, close-reset join, recovery-root TOCTOU 및 test gap을 remediation 후 재검증해 최종 0 Blocker/Major/Minor로 승인한다. |
| 54 | [Phase 22 current-document completion and symbols](25-document-intelligence.md) | **Approved, committed and pushed** | `Control-Space` bounded local completion, `Command-Option-O` searchable symbol outline, streamed 4 MiB analysis와 exact split-pane authority를 기록한다. commit `83dcb74`가 exact receipt/audit 후 `origin/main`에 push됐다. |
| 55 | [Phase 22 independent code review](reviews/2026-09-03-phase-22-document-intelligence-code-review.md) | **Content approved — latest Phase 22 evidence** | 최초 2 Major/1 Minor의 analyzer CPU/memory, split-pane stale routing, CR-only outline 결함을 bounded streaming/raw prefilter/cancellation, exact-pane identity, mixed-EOL scanner로 닫아 최종 0 Blocker/Major/Minor로 승인한다. |
| 56 | [Phase 23 encoding and line endings](26-encoding-and-line-endings.md) | **Approved, committed and pushed** | Format menu/status control, explicit BOM-less UTF-16 open, UTF-8/BOM/UTF-16 및 LF/CRLF/CR durable conversion과 exact binding/lifecycle authority를 기록한다. commit `703b89c`가 exact receipt/audit 후 `origin/main`에 push됐다. |
| 57 | [Phase 23 independent code review](reviews/2026-09-03-phase-23-encoding-eol-code-review.md) | **Content approved — latest Phase 23 evidence** | 최초 2 Major의 conflict/post-write binding authority와 accepted format-task termination join 결함을 remediation 후 재검증해 최종 0 Blocker/Major/Minor로 승인한다. |
| 58 | [Phase 24 settings, themes, and accessibility](27-settings-themes-accessibility.md) | **Content approved; exact receipt pending** | 표준 `Command-,` 설정 창, versioned preference 저장, 시스템/라이트/다크 appearance, 실행 중 테마 재적용, 새 탭 wrap 기본값과 접근성 계약을 기록한다. |
| 59 | [Phase 24 independent code review](reviews/2026-09-03-phase-24-settings-code-review.md) | **Approved — 0 findings** | Descriptor-bound durable settings authority, live accessibility, zero-window Settings ownership, accepted-update termination join을 독립 재검증했다. |

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

### 2026-09-03 — Phase 24 settings, themes, and accessibility

- **Agent/role:** `/root`, direct investigator and builder; no new implementation agent was added.
- **Implementation:** native reusable Settings window and standard `Command-,`; versioned Domain settings, async Application load/update state, descriptor-bound atomic Application Support store; system/light/dark appearance shared across every native window; live effective-appearance refresh; new-tab-only word-wrap/wrap-symbol defaults with recovered/existing per-buffer state preservation.
- **Failure/accessibility:** corrupt or unsupported settings degrade without rewriting unknown storage; failed writes preserve authoritative live state and roll controls back. Native controls and status expose stable accessibility identifiers and labels; increased contrast remains macOS-owned.
- **Validation:** focused settings/menu/editor tests, including live effective-appearance propagation, pass. Latest full-matrix evidence is recorded by the remediation logs below; independent approval, exact receipt, commit, and push remain pending.
- **Boundary:** macros, localization catalogs, final distribution signing/notarization, README, ignored Notepad++, and user-owned doc04/vendor script are excluded.

### 2026-09-03 — Phase 24 independent code review

- **Agent/role:** `/root/phase1_code_review`, independent content reviewer; Phase 24 구현에는 참여하지 않았다.
- **Scope:** exact 18-path candidate의 settings schema/store, multi-window/new-window propagation, native Settings/lifecycle/menu/accessibility, effective theme와 per-buffer default/recovery invariants를 검토했다.
- **Validation:** exact candidate/tree/diff/message/exclusions/cached check PASS; independent focused 8/8와 fresh Swift 6 build PASS. Wrong-type UserDefaults와 weak menu-target external probes, installed SDK contracts로 세 결함을 재현했다.
- **Verdict:** **CHANGES REQUIRED — 0 Blocker, 3 Major, 0 Minor.** P24-01은 corruption/write durability 계약, P24-02는 live High Contrast 갱신, P24-03은 last document close 후 Settings 접근을 깨뜨린다. 상세 evidence는 [Phase 24 review](reviews/2026-09-03-phase-24-settings-code-review.md)에 있다.
- **Safety:** review 문서와 index review row/work log만 수정했다. product/source/tests/work doc/stage/commit/sign은 변경하지 않았고 user-owned doc04/vendor script를 보존했다. Evidence edit로 frozen candidate는 invalidated됐다.

### 2026-09-03 — Phase 24 remediation independent re-review

- **Agent/role:** `/root/phase1_code_review`, independent focused re-reviewer; remediation 구현에는 참여하지 않았다.
- **Closure:** P24-02의 teardown-safe accessibility notification과 P24-03의 app-lifetime Settings target/zero-window→new-window defaults는 닫혔다.
- **Residual/new finding:** P24-01 Local settings는 path lstat 뒤 unbounded/path read와 post-rename chmod ordinary failure가 남는다. P24-04는 accepted async settings update가 application termination barrier에 등록/join되지 않는다.
- **Validation:** exact candidate/tree/diff/message/exclusions/cached check PASS; independent focused 10/10 PASS. Injected post-write probe는 `.writeFailed` 뒤 새 JSON이 visible한 상태를 exit 24로 재현했다. Exact 18-path product/test/work-doc path+byte digest는 `341653569744167d5b44d9dfe312b1f7a674f7d43f79b606f96536f124041630`이다.
- **Verdict:** **CHANGES REQUIRED — 0 Blocker, 2 Major, 0 Minor.** Receipt는 authorize하지 않으며 review/index evidence 반영으로 candidate `57fb25d…`는 invalidated됐다.
- **Safety:** review doc/index만 수정했다. product/source/tests/work doc/stage/commit/sign/push는 변경하지 않았고 user-owned doc04/vendor script를 보존했다.

### 2026-09-03 — Phase 24 P24-01/P24-02/P24-03 remediation

- **Agent/role:** `/root`, direct remediation builder; independent reviewer evidence는 수정하지 않았다.
- **P24-01:** best-effort `UserDefaults`를 제거하고 1 MiB 제한, regular-file 검사, canonical JSON, private permission과 acknowledged atomic write를 갖는 async Application Support store로 교체했다. Application은 성공한 write 뒤에만 state를 publish하며 실제 non-regular/read/write failure regressions가 rollback을 검증한다.
- **P24-02:** 각 document window가 `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`을 teardown-safe token으로 관찰해 system contrast 변경 시 effective palette를 즉시 다시 적용한다.
- **P24-03:** Settings menu는 document controller가 아니라 app-lifetime target을 사용한다. 마지막 document close 뒤에도 target이 유지되고, application termination review 동안은 app-owned validation이 명령을 막는다.
- **Validation:** remediation-focused settings/store/theme/menu 10/10, real-archive production composition smoke, exact-current Debug/Release each 329/329 PASS; independent re-review는 pending이다.
- **Boundary:** README, ignored Notepad++, user-owned doc04/vendor script와 reviewer verdict 문서는 보존했다.

### 2026-09-03 — Phase 24 P24-01/P24-04 final remediation

- **Agent/role:** `/root`, direct remediation builder; reviewer verdict 문서는 수정하지 않았다.
- **P24-01:** settings load는 directory-relative `O_NOFOLLOW` descriptor에서 최대 1 MiB+1만 stream하고 동일 fd의 dev/inode/size/mtime/ctime snapshot을 재검증한다. Save는 mode 0600 temp에 write, fsync/F_FULLFSYNC, chmod, close를 모두 완료한 뒤 `renameat`하고 directory를 sync한다. pre-rename failure는 기존 archive를 유지하며, post-rename uncertainty는 runtime도 visible 새 값으로 유지하고 warning outcome을 낸다.
- **P24-04:** Settings action이 생성한 Task를 같은 MainActor turn에서 application-lifetime coordinator에 등록한다. Cmd-Q는 accepted task를 join한 뒤 reply하고 review 시작 뒤 새 settings mutation을 거절한다.
- **Validation:** descriptor/symlink/oversize/before+after rename/uncertainty/blocked-save success·failure termination을 포함한 focused 14/14, production smoke, exact-current Debug/Release each 333/333 PASS; independent re-review는 pending이다.
- **Boundary:** README, ignored Notepad++, user-owned doc04/vendor script와 reviewer evidence를 보존했다.

### 2026-09-03 — Phase 24 final remediation independent re-review

- **Agent/role:** `/root/phase1_code_review`, independent focused re-reviewer; remediation 구현에는 참여하지 않았다.
- **Closure:** P24-01의 no-follow 1 MiB+1 same-fd read, private fully-synced temp, pre/post-rename typed authority와 P24-04의 synchronous accepted-task registration/termination join을 현재 bytes에서 닫았다. P24-02/P24-03 closure도 유지된다.
- **Validation:** candidate/tree/diff/message, exact 20-path stage, exclusions, cached check PASS; independent Debug/Release focused 14/14, termination interleave 5회 반복 10/10 PASS. Builder Debug/Release 333/333과 production smoke/parity/governance/checker는 supporting evidence로 확인했다.
- **Manifest:** exact 18-path product/test/work-doc path digest `d07b499054472caebaa2986ba83042312df0823911961f3ba7e5d5d81a5322c8`, byte digest `50a5ced36952165005b32942f4a5ecb1cabff813a8c7f2c8194265127bb629a4`.
- **Verdict:** **APPROVED — 0 Blocker, 0 Major, 0 Minor.** Content is authorized for refreeze/exact receipt review; review/index evidence edits invalidate `56e800dc…`, so this turn did not sign.
- **Safety:** review doc/index만 수정했다. Product/source/tests/work doc/stage/commit/sign/push는 변경하지 않았고 user-owned doc04/vendor script를 보존했다.

### 2026-09-03 — Phase 23 P23-01/P23-02 remediation

- **Agent/role:** `/root`, direct remediation builder; independent reviewer verdict 문서는 수정하지 않았다.
- **P23-01:** conflict overwrite는 write 전에 exact `FileWorkspaceContext`를 재검증하고, receipt publication은 workspace transaction 안에서 expected BufferID와 prior `FileBinding`을 비교한다. rebind-before-write는 old bytes를 보존하며, rebind-during-durable-write는 newer binding/dirty authority를 보존하고 typed invalidation으로 끝난다.
- **P23-02:** native Open/Save/Save As/format actions를 synchronous file-task registry에 등록하고 accepted save는 later termination lock을 통과시킨다. application/window termination은 이 task를 dirty review와 final recovery flush 전에 join한다.
- **Validation:** adversarial remediation 3/3 및 surrounding file/lifecycle focused 9/9 PASS. Exact-current Debug/Release each 320/320 PASS; independent remediation re-review remains pending.
- **Boundary:** README, ignored Notepad++, user-owned doc04/vendor script와 reviewer verdict는 보존했다.

### 2026-09-03 — Phase 23 encoding and line endings

- **Agent/role:** `/root`, direct investigator and builder; no new implementation agent was added.
- **Implementation:** authoritative `FileBinding`-driven format status, native Format/status menus, explicit UTF-8/UTF-16 open hints, UTF-8/BOM/UTF-16 and LF/CRLF/CR durable conversion routing through existing atomic save/conflict retry.
- **Safety:** selecting the active format is a no-op; encoding and EOL choices preserve one another; scratch conversion requires Save As; startup/termination admission disables all commands. Exact context capture rejects Save-panel and serialized-operation tab-switch races without writing the rejected destination. No new shortcut is assigned, so existing shortcut uniqueness remains intact.
- **Validation:** focused menu/routing/race tests pass. Exact-current Debug and Release each pass 317/317 tests; the real local-store production smoke verifies UTF-16 LE open to exact UTF-8 BOM/CRLF bytes; parity 31/31, governance 8/8, default checker, and diff-check pass. Independent review remains pending.
- **Boundary:** legacy guessed code pages, macros, README, ignored Notepad++, and user-owned doc04/vendor-script changes are excluded.

### 2026-09-03 — Phase 23 independent code review

- **Agent/role:** `/root/phase1_code_review`, independent content reviewer; Phase 23 구현에는 참여하지 않았다.
- **Scope:** exact nine-path candidate의 explicit UTF-16 open, durable encoding/EOL conversion, scratch Save As, conflict/context authority, termination ordering, native menus/status/accessibility/shortcut을 검토했다.
- **Initial verdict:** **CHANGES REQUIRED — 0 Blocker, 2 Major, 0 Minor.** P23-01은 stale conflict/write가 newer binding을 덮고, P23-02는 accepted format Task가 termination barrier에 등록/join되지 않았다.
- **Focused closure:** exact transactional BufferID/binding publication이 pre-write 및 post-write rebind를 안전하게 거절한다. synchronous file-task registry와 accepted-before-termination path가 즉시 Cmd-Q에도 blocked write를 join한 뒤 final recovery를 flush한다.
- **Validation:** remediation candidate/tree/diff/message 및 exclusion/cached check PASS; independent adversarial 3/3, combined focused 10/10 PASS. Original stale-binding probe는 typed invalidation과 B binding 보존/exit 0으로 전환됐다. Exact product/test/work-doc path+byte digest는 `2a38aa0a8e8c9aee5e7cd4c1d9296d27e3d3841d0e5e8fd3b0c16d7c5cc06edc`이다.
- **Final verdict:** **APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** Review/index evidence 반영 후 exact candidate refreeze와 receipt는 별도 단계다. 상세 evidence는 [Phase 23 review](reviews/2026-09-03-phase-23-encoding-eol-code-review.md)에 있다.
- **Safety:** review 문서와 index review row/work log만 수정했다. product/source/tests/work doc/stage/commit/receipt는 변경하지 않았고 user-owned doc04/vendor script를 보존했다.

### 2026-09-03 — Phase 22 current-document completion and symbols

- **Agent/role:** `/root`, direct investigator and builder; no new implementation agent was added.
- **Implementation:** Application-owned bounded analyzer and editor port, native Scintilla completion list, language keyword supplementation, searchable AppKit symbol popover/status control, UTF-8 exact reveal, menu routing and production composition/smoke.
- **Safety:** 4 MiB pre-capture limit, 200 completion and 500 symbol caps, off-main value scanning, buffer/revision/caret/IME revalidation, cancellation on lifecycle authority changes, and no editor mutation during analysis.
- **Shortcuts:** current-document completion uses `Control-Space`; document symbols use collision-free `Command-Option-O`. Existing `Command-Shift-O` document switcher and `Command-Shift-P` language chooser remain unchanged.
- **Validation:** focused Application/Scintilla/AppKit tests and production smoke PASS; post-remediation exact-current Debug/Release each 313/313, parity 31/31, governance 8/8, and default checker PASS. Independent remediation re-review remains pending.
- **Boundary:** semantic provider/API call tips, macros, README, ignored Notepad++, and user-owned doc04/vendor-script changes are excluded.
- **Review remediation:** completion은 256-byte word를 stream하며 deterministic top-200만 보관하고 supplemental scan을 256 KiB로 제한한다. Symbol outline은 line 전체 materialization 없이 CR/LF/CRLF를 stream하고, ASCII non-symbol line을 String allocation 전에 byte-prefilter하며 1,024줄마다 cancellation을 확인하고 500개에서 중단한다. Capture에는 exact pane context identity를 추가하여 same-caret split focus 전환도 stale로 거부한다. 4 MiB unique-word/two-million-line bounds, mixed-EOL UTF-8 ranges, split-pane regressions가 통과했으며 latest full matrix와 independent re-review는 pending이다.

### 2026-09-03 — Phase 22 independent code review

- **Agent/role:** `/root/phase1_code_review`, independent reviewer; Phase 22 구현에는 참여하지 않았다.
- **Verdict:** **CHANGES REQUIRED — 0 Blocker, 2 Major, 1 Minor.** Completion/symbol caps가 전체 intermediate collection을 제한하지 않아 adversarial 4 MiB 입력에서 4.76–5.51초 및 48–77 MB RSS를 사용했고, split-pane same-caret focus 전환 뒤 stale completion이 새 pane에 게시됐다. CR-only outline의 두 번째 symbol 누락도 기록했다.
- **Evidence:** candidate `9e3f0ecd…` identity와 14 staged paths/cached diff-check를 확인하고 independent focused 9/9 PASS 및 external analyzer/split/EOL probes를 기록했다. Builder Debug/Release 310/310, production smoke, parity 31/31, governance 8/8은 supporting evidence로 구분했다.
- **Boundary:** review 문서와 index review row/work log만 수정했다. source/tests/work doc, stage/commit/sign/push, doc04, vendor script, README, ignored Notepad++는 건드리지 않았다.
- **Focused remediation re-review:** P22-02 exact-pane context와 P22-03 CR/LF/CRLF byte scanner는 external probes로 닫았다. P22-01 completion은 0.23초 Release/18 MB, symbol memory는 15 MB로 개선됐지만, 4 MiB two-byte no-symbol outline은 transient line parse와 cancellation checkpoint 부재로 Release 1.92초가 걸려 Major residual로 남겼다. Independent exact-current focused 12/12 PASS; candidate `dc5569bc…` receipt는 승인하지 않았다.
- **Final remediation re-review:** `36cedcb5…`는 폐기했다. `9c4a37f…`의 raw-byte prefilter/cancellation으로 동일 4 MiB `a\n` probe가 Debug 0.26초/15 MB, Release 0.04초/15 MB가 됐고 cancelled task 5회는 0.07–0.15 ms에 종료됐다. accepted syntax matrix, split-pane, CR-only/mixed-EOL, oversized/supplemental bounds와 independent focused 12/12가 PASS하여 **APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor**로 갱신한다. Review/index 반영 후 새 exact candidate/receipt가 필요하다.

### 2026-09-03 — Phase 21 native multiple windows

- **Agent/role:** `/root`, direct investigator and builder; no new implementation agent was added.
- **Implementation:** `Command-Shift-N` creates an independently retained native window while `Command-N` remains New Scratch. Each window owns its session/editor/recovery/UI use cases; filesystem/workspace/extension infrastructure remains process-shared. The key window retargets the native menu, last-window close does not terminate the app, and Dock reopen restores or creates a window.
- **Data safety:** red-close reviews only its exact controller. `Command-Q` synchronously admits every current or late-attached window into one serialized coordinator and replies only after all dirty decisions, final recovery flushes, and explicit-close cleanup complete. Any cancellation reopens all admitted interaction surfaces. Failed close cleanup denies quit and is retried on the next request. Same-file buffers across windows rely on identity-checked atomic saves and surface the existing explicit conflict workflow.
- **Recovery/safety bounds:** the primary archive path is compatible with prior releases; additional UUID recovery directories are restored from a sibling container using bounded descriptor/no-follow enumeration. The accepted root descriptor remains authoritative for manifest/blob reads, writes, cleanup, and reset; symlink/file path replacement cannot redirect operations. Explicit window close unlinks only that archive; app termination preserves open-window archives. Live windows are capped at 32 and discovery at 31 additional roots/1,024 raw entries.
- **Validation:** focused new tests pass for all-window approval/flush, late attachment during dirty review and close cleanup, cancellation/reopen, exact red-close isolation, blocked/failed close cleanup, descriptor-bound symlink/file swap and pre-unlink replacement rejection, native close teardown, New Window/menu routing, and two-window same-file conflict. A production three-launch smoke creates/restores two windows, closes the restored window with joined cleanup, and verifies only one returns. Exact-current Debug/Release each pass 301/301, parity governance 31/31, and commit governance 8/8; independent re-review remains pending.
- **Boundary:** macro recording/playback, README, ignored Notepad++, and user-owned doc04/vendor-script changes remain excluded.

### 2026-09-03 — Phase 21 independent code review

- **Agent/role:** `/root/phase1_code_review`, independent reviewer; Phase 21 구현에는 참여하지 않았다.
- **Verdict:** **CHANGES REQUIRED — 0 Blocker, 3 Major, 1 Minor.** Cmd-Q 도중 late-restored window가 admission/flush에서 빠지는 경쟁, 명시적 close recovery reset이 종료 join 밖에 남는 내구성 경쟁, descriptor 검증 후 path store로 전환되는 recovery-root TOCTOU를 확인했다. 기존 테스트가 이 두 lifecycle interleave를 다루지 않는 점을 Minor로 기록했다.
- **Evidence:** exact candidate/tree/diff/message와 9 staged paths, cached diff-check를 확인했다. Independent focused 5/5 PASS와 builder Debug/Release 293/293, parity 31/31, governance 8/8, two-launch smoke를 구분해 기록했다. Receipt는 승인하지 않았다.
- **Boundary:** review 문서와 index review row/work log만 수정했다. source/tests/work doc, stage/commit/push, doc04, vendor script, README, ignored Notepad++는 건드리지 않았다.
- **Remediation re-review:** application review가 dirty-decision뿐 아니라 close-cleanup await 뒤에도 late attachment queue를 고정점까지 다시 비우는지 확인했다. 닫힌 창 reset은 detach 전에 등록되고 종료 reply 전에 join되며 실패 시 deny/retry된다. restored recovery는 parent/root FD와 no-follow descriptor 연산을 유지하고, 재귀 reset 후 최종 unlink 직전에도 dev/inode를 재검증한다.
- **Final verdict/evidence:** **APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** Independent focused 8/8 PASS. Builder exact Debug/Release 301/301, 3-launch production smoke, parity 31/31, governance 8/8 및 diff-check PASS를 supporting evidence로 기록했다. Review/index 반영 후 새 exact candidate와 receipt가 필요하다.

### 2026-09-03 — Phase 20 saved workspace file browser

- **Agent/role:** `/root`, direct investigator and builder; no new implementation agent was added.
- **Implementation:** user-selected folders persist as security-scoped bookmarks in a native `NSOutlineView` sidebar. Root/directory expansion is lazy and sorted folder-first; file activation reuses the existing loss-safe file-open use case. Folder drag/drop, removal, Finder reveal, unavailable-root state, and root-specific selection/expansion restoration are included.
- **Bounds and safety:** 32 roots, 1 MiB descriptor-bounded archive, 1,000 expanded paths per root, 10,000 raw immediate entries, 1 GiB open-file bytes, and 16 KiB relative paths are hard limits. Descriptor-relative `openat`/`fstatat` plus `O_NOFOLLOW` keeps validation and reading on the same filesystem objects. Hidden entries, packages, symbolic links, non-regular files, traversal, forged entry kinds, root replacement, duplicate IDs/paths, and corrupt archive retry are rejected or skipped. The archive uses atomic writes with `0700` directory and `0600` file permissions.
- **Shortcuts:** Add Folder uses `Command-Control-O`; Workspace Sidebar uses `Command-Shift-E`. Complete-menu collision coverage and sidebar visibility/routing coverage are included.
- **Validation:** focused Application/Infrastructure/AppKit tests pass, including concurrent Add serialization, cancellation-ignoring mutation suppression/reconciliation, corrupt-start failure preservation after termination denial, security-scope access-before-inspection and exact stop balancing, descriptor/file-swap rejection, pre-materialization raw-entry limit and cancellation, prepared open without a second path read, immediate termination during a blocked accepted workspace-file commit, delayed-root-load command admission, cancellation-ignoring panel teardown, persistent navigation, context actions, and exact shortcut routing. Production composition smoke opens a persisted root and lazily sees `smoke.txt`. Exact-current full Debug and Release suites each pass 288/288; independent content review is approved with exact receipt pending.
- **Boundary:** multiple windows, symbols/completion, settings UI, packaging/notarization, README, ignored Notepad++, and user-owned doc04/vendor-script changes are excluded from this slice.

### 2026-09-03 — Phase 20 independent code review

- **Agent/role:** `/root/phase1_code_review`, independent reviewer; Phase 20 구현/remediation에는 참여하지 않았다.
- **Findings/closure:** review 전 과정에서 0 Blocker, 8 Major, 1 Minor를 재현했다. descriptor TOCTOU, concurrent stale publication, unbounded enumeration, panel/UI lifetime, security-scope ordering, restore admission, late durable root publication, accepted file-open final-flush race, corrupt resume fabrication을 descriptor authority, FIFO/epoch reconciliation, explicit admission 및 accepted-open join으로 모두 닫았다.
- **Verdict/validation:** **APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** Independent exact-current focused 17/17과 external adversarial probe가 PASS다. Builder Debug/Release 288/288, production smoke, parity 31/31, governance 8/8, checker와 `git diff --check` PASS를 supporting evidence로 기록했다. Exact receipt는 pending이다.
- **Boundary:** review 문서와 index Phase 20 review row/work log만 수정했다. source/tests/work doc, stage/commit/push, doc04, 기존 vendor script, README, ignored Notepad++는 건드리지 않았다.

### 2026-09-03 — Phase 19 review remediation

- **Agent/role:** `/root`, direct builder; independent reviewer verdict remains authoritative until re-review.
- **Closure candidate:** P19-01 recovery is bound to the rejected BufferID and completed before buffer/snapshot/lifecycle transitions; P19-02 revision exhaustion is isolated per buffer; P19-03 language/indent/fold/brace/palette configuration applies to both pane views regardless of focus. P19-04 also invalidates and evicts a closed secondary native view.
- **Regression evidence:** immediate rejected-edit switch, exhausted-to-healthy split switch, primary/secondary-focused language parity, and split cache eviction tests pass. Editor-focused 39/39 and exact-current Debug/Release 270/270 pass; independent current-byte re-review is pending.
- **Boundary:** README, ignored Notepad++, and user-owned doc04/vendor script remain excluded. No stage/commit/push occurs before independent approval and exact receipt.

### 2026-09-03 — Phase 19 independent code review

- **Agent/role:** `/root/phase1_code_review`, independent reviewer; Phase 19 구현/remediation에는 참여하지 않았다.
- **Initial findings:** **CHANGES_REQUIRED — 0 Blocker, 3 Major, 1 Minor.** rejected secondary edit의 immediate-switch 유실, exhausted buffer의 global input poisoning, focused-pane-only language 불일치, closed-secondary retention을 재현했다.
- **Closure/verdict:** BufferID-bound synchronous boundary recovery, per-buffer exhaustion bookkeeping, 양 pane language 적용, close/hide native invalidation·cache eviction으로 P19-01~P19-04가 모두 닫혔다. **APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** Exact receipt는 pending이다.
- **Validation:** independent focused 6/6과 동일 external adversarial AppKit/Scintilla probe가 모두 current expected result로 전환됐다. builder current-byte editor-focused 39/39, Debug/Release 270/270를 supporting evidence로 기록했고 `git diff --check`는 PASS다.
- **Boundary:** review 문서와 index Phase 19 review row/work log만 수정했다. source/tests/work doc, stage/commit/push, doc04, 기존 vendor script, README, ignored Notepad++는 건드리지 않았다.

### 2026-09-03 — Phase 19 shared-document split editing

- **Agent/role:** `/root`, direct builder; no new implementation agent was added.
- **Implementation:** side-by-side/stacked panes share one reference-counted Scintilla document and undo history while retaining pane-local selection, cursor, scrolling, wrap, and focus. Only the primary watcher emits each shared-document mutation to Application; accepted revisions synchronize the secondary view.
- **Recovery/lifecycle:** optional orientation and secondary view state are legacy-compatible, UTF-8/range validated, per-buffer, and removed with the buffer. Unsupported NSTextView fallback drops only split metadata.
- **Shortcuts:** `Command-Backslash`, `Command-Option-Backslash`, `Command-Control-Backslash`, and `Command-Shift-Backslash` are collision-tested and lifecycle-gated.
- **Validation:** focused bridge/recovery/controller/menu tests pass, including rejected secondary-edit recovery and review regressions; exact-current full Debug and Release suites each pass 270/270. Independent re-review is pending.
- **Boundary:** workspace file browser/multiple windows follow separately. README, ignored Notepad++, and user-owned doc04/vendor script remain excluded.

### 2026-09-03 — Phase 18 persistent bookmarks

- **Agent/role:** `/root`, direct builder; independent review verdict is separate.
- **Implementation:** per-buffer bookmark state is owned by Scintilla marker 20 or the AppKit fallback, follows accepted edits, survives tab switching/recovery, and supports wrapping next/previous navigation plus clear-all.
- **Invariants:** bookmark commands never mutate text, revision, dirty state, or undo ownership. Recovery is legacy-compatible and rejects negative, over-10,000, or out-of-document lines; fallback highlighting uses namespaced temporary layout attributes outside active text-storage processing.
- **Shortcuts:** `Command-F2` toggle, `F2` next, `Shift-F2` previous, and `Command-Shift-F2` clear all; lifecycle and availability validation use the existing termination admission boundary.
- **Validation:** focused bookmark/menu/recovery coverage passes, including per-buffer isolation, CRLF/decoration ownership, first-line wrapping, bounded maximum-count capture, and Scintilla edit/undo/redo marker movement. Exact-current full Debug and Release suites each pass 261/261.
- **Boundary:** macro recording/playback, README, ignored Notepad++, and user-owned doc04/vendor-script changes are excluded.

### 2026-09-03 — Phase 18 independent review

- **Agent/role:** `/root/phase1_code_review`, independent reviewer; Phase 18 구현/remediation에는 참여하지 않았다.
- **Initial findings:** **CHANGES_REQUIRED — 0 Blocker, 4 Major, 0 Minor.** Scintilla first-line Previous가 current marker에 머무는 문제, fallback이 다른 temporary background를 제거하는 문제, split-CRLF line mapping 오류, 100,000-marker MainActor/per-bookmark scan 예산 부재를 재현·검토했다.
- **Closure:** strict backward wrap, namespaced TextKit temporary key/draw translation, one-pass CR/LF/CRLF offset rebase+binary lookup, 10,000 cap과 maximum native timing budget을 현재 bytes에서 재검증했다.
- **Validation:** independent focused 9/9와 external AppKit/Scintilla 전후 probe PASS; builder exact-current focused 8/8, Debug/Release 261/261 supporting evidence와 `git diff --check` PASS를 확인했다.
- **Verdict:** **APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** Exact staged-candidate review/receipt는 pending이다.
- **Boundary:** review 문서와 index Phase 18 review row/work log만 수정했다. source/tests/work doc, stage/commit/push, doc04, 기존 vendor script, README, ignored Notepad++는 건드리지 않았다.

### 2026-09-03 — Phase 17 folder search

- **Agent/role:** `/root`, direct investigator and builder; independent review verdict is separate.
- **Implementation:** user-selected recursive folder search reuses Duckpad's Unicode/regex engine and presents grouped relative paths, line/column snippets, and keyboard/double-click activation in the non-modal Find panel.
- **Safety/performance:** hidden/package/symlink/non-regular entries are excluded, file/input/match/result/pattern/regex caps are explicit, cancellation reaches enumeration and scan tasks, and result activation requires exact file identity plus clean revision-owned editor state.
- **Validation:** focused Domain/Application/Infrastructure/Presentation coverage passes for Unicode/UTF-16, bounds, cancellation, filesystem exclusions, shortcut uniqueness, routed activation, dirty buffers, and changed disk identity. Exact-current Debug/Release each pass 254/254 and `git diff --check` passes; independent content review approved 0 Blocker/Major/Minor and exact receipt is pending.
- **Boundary:** no folder Replace All, macro feature, README, ignored Notepad++, or user-owned doc04/vendor-script change is included.

### 2026-09-03 — Phase 17 independent review

- **Agent/role:** `/root/phase1_code_review`, independent reviewer; Phase 17 구현과 remediation에는 참여하지 않았다.
- **Initial findings:** **CHANGES_REQUIRED — 0 Blocker, 5 Major, 2 Minor.** Path-based TOCTOU/unbounded growth, empty-folder invalid-regex success, uncharged duplicated result metadata/eager MainActor rows, unbounded uncancellable directory listing, and unjoined late activation을 재현·검토했다. Root-path join과 hidden/package filtering도 Minor로 기록했다.
- **Closure:** descriptor-relative `openat`/`O_NOFOLLOW`, same-fd bounded read/identity, eager ICU validation, shared document metadata+saturating budget+lazy rows, aggregate listing limits/cancellation, and synchronously registered activation cancellation/join을 현재 bytes에서 재검증했다.
- **Validation:** independent final focused 22/22, exact-current full Debug 254/254와 `git diff --check` PASS. Builder exact-current Release 254/254, parity 31/31, review-gate 8/8, checker exit 0도 supporting evidence로 구분했다.
- **Verdict:** **APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** Exact staged-candidate review/receipt는 pending이다.
- **Boundary:** review 문서와 index Phase 17 row/work log만 수정했다. source/tests/work doc, stage/commit/push, doc04, 기존 vendor script, README, ignored Notepad++는 건드리지 않았다.

### 2026-09-03 — Phase 16 independent review

- **Agent/role:** `/root/phase1_code_review`, independent reviewer; Phase 16 구현/remediation에는 참여하지 않았다.
- **Initial findings:** 0 Blocker, 2 Major, 0 Minor. comparison disk-read 중 stale local snapshot 반환과 panel 표시 뒤/Reload read 중 edit 유실을 외부 blocking-store probe로 재현했다.
- **Closure:** post-read exact context/revision validation과 Domain transaction 내부 expected revision/binding 검증을 재검토했다. 같은 probe에서 read race는 `comparisonInvalidated`, post-panel Reload는 `editorRevisionMismatch`로 닫히며 local dirty bytes를 보존했다.
- **Validation:** independent focused adversarial 9/9, builder Debug/Release 232/232, `git diff --check` PASS.
- **Verdict:** **APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** exact staged review/receipt는 pending이다.
- **Boundary:** review doc/index만 수정했고 doc04, 기존 vendor script, README, ignored Notepad++, product/tests, stage/commit/push는 건드리지 않았다.

### 2026-09-03 — Phase 16 external file Compare

- **Agent/role:** `/root`, direct builder; independent review verdict is separate.
- **Implementation:** save-conflict UI now offers Compare and presents immutable local/external snapshots in a read-only native side-by-side panel before returning to the same unresolved decision.
- **Safety:** Compare performs no document or disk mutation, preserves the pending conflict, uses typed failures and a 32 MiB per-side guard, and routes subsequent Reload/Overwrite through existing file/workspace authority.
- **Validation:** focused use-case and presentation tests cover exact snapshot capture, non-mutating repeated decision flow, Reload completion, oversize rejection, and edit/close/rebind races. Final remediated Debug/Release suites each pass 232/232 and `git diff --check` passes; independent content review is approved 0/0/0 and exact receipt remains pending.
- **Boundary:** README, ignored Notepad++, and the existing user changes in doc04/vendor script are untouched.

### 2026-09-03 — Phase 15 independent review

- **Agent/role:** `/root/phase1_code_review`, independent reviewer; Phase 15 구현에는 참여하지 않았다.
- **Initial verdict:** **CHANGES_REQUIRED — 0 Blocker, 3 Major, 0 Minor.** External probes reproduced Join overreach, partial near-exhaustion trim, and fallback line-move selection/EOL corruption.
- **Focused re-review:** execution-time Join endpoint correction, conservative whole-command revision budget, UTF-16/terminal-empty fallback line model and rendered selection rebasing을 현재 바이트에서 확인했다. 동일 probe는 `a b\nc`, near-exhaustion 무변경, `{2,6}` selection/후속 Delete 보존, native와 같은 terminal `\na`를 산출했다.
- **Validation:** independent focused Debug 5/5 및 Release 5/5, `git diff --check` PASS.
- **Final verdict:** **APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** exact staged-candidate review/receipt는 pending이다.
- **Final doc consistency:** 제품/테스트 바이트 무변경, builder Debug/Release 224/224 및 corrected doc18 approval evidence를 확인했다. exact current 10-path digest는 `89590bbc2c5daf36f95507cf95fe33b5b192bec16175a08dcbfe22b1e8068b9d`다.
- **Boundary:** review evidence/index만 수정했으며 doc04, 기존 vendor script, README, ignored Notepad++, source/tests, stage/commit/push는 건드리지 않았다.

### 2026-09-03 — Phase 15 advanced editing commands

- **Agent/role:** `/root`, direct investigator and builder; independent review verdict is separate.
- **Implementation:** Application-owned `EditorCommand` intent, narrow Scintilla editing enum, native Edit menu routing, and behavior-compatible `NSTextView` fallback now cover duplicate/move/delete/join lines, indent/unindent, case conversion, and trailing whitespace removal.
- **Shortcuts:** `Command-D`, `Option-Up/Down`, `Command-Shift-K`, and `Control-J` follow established editor conventions. Commands without a reliable collision-free macOS convention have no default chord and remain native-menu searchable.
- **Safety:** all selectors and validation share ready/active/no-termination admission. Scintilla retains UTF-8 bytes, revision notifications, selection, and grouped undo; revision-exhausted/input-disabled documents reject all advanced mutations. Macro recording/playback remains excluded.
- **Validation:** final remediated Debug/Release 224/224와 independent focused Debug/Release 5/5 및 `git diff --check`가 PASS했다.
- **Initial review remediation:** Join은 exact selection-end normalization을 공유하고, native bridge는 mutation 전 conservative whole-command revision budget을 예약하며, fallback move는 terminal empty line과 destination-rendered selection range를 보존한다. LF/CRLF/Unicode, near-overflow, unequal-length, terminal-empty, follow-up Delete fixture를 독립 재검증해 3 Major를 모두 닫았다.
- **Boundary:** README, ignored Notepad++, and the existing user changes in doc04/vendor script are untouched by this phase.

### 2026-09-03 — Phase 14 tab lifecycle independent review

- **Agent/role:** `/root/phase1_code_review`, independent reviewer; Phase 14 구현과 remediation에는 참여하지 않았다.
- **Initial findings:** registered close Task가 later termination gate를 다시 검사해 same-actor Close-All → termination에서 accepted close를 100/100 누락하는 Major를 external public-API probe로 재현했다. 100-entry fixture가 최종 membership만 확인해 FIFO도 통과하는 test-strength Minor도 기록했다.
- **Closure:** close admission을 Task 등록 전에 동기 획득하고 admitted task는 termination이 join하도록 수정했다. approval/cancel-reopen 양쪽 테스트와 external probe 100/100을 확인했다. LIFO fixture도 매 pop의 reversed active TabID와 99...0 count를 검증한다.
- **Scintilla triage:** headless AppKit의 비동기 `firstVisibleLine` settle만 exact equality에서 제외했다. text/revision/selection/horizontal/wrap/recovery bytes/undo는 유지되고 별도 recovery test가 vertical viewport capture/restore를 계속 검증하므로 제품 회귀 은폐가 아니다.
- **Evidence:** independent initial focused 6/6, exact-final focused 8/8, external probe 100/100, `git diff --check` PASS. builder exact-final Debug/Release 221/221는 supporting evidence로 기록한다.
- **Verdict:** **APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** exact staged-candidate receipt는 pending이다.
- **Boundary:** review 문서와 index row/work log만 수정했다. source/tests/work docs/stage/sign/commit/push는 건드리지 않았고 doc04/vendor script/README/ignored Notepad++를 제외·보존했다.

### 2026-09-03 — Phase 14 tab lifecycle commands

- **Agent/role:** `/root`, direct investigator and builder; independent review verdict는 별도다.
- **User policy:** `Command-Shift-T` recent-close history는 열린 탭 제한이 아니며, process-local LIFO 보관 한도를 20에서 100으로 확장했다.
- **Implementation:** Application의 stable target scope에 `unchanged`를 추가하고 Tabs menu와 tab context menu에 All/Others/Left/Right/Unchanged/Unpinned close를 연결했다. shortcut이 없는 bulk 명령은 macOS 기본 chord와 충돌하지 않는다.
- **Safety:** pinned tab은 bulk target에서 보호되고 dirty tab은 기존 shared save/discard/cancel review를 그대로 통과한다. Presentation은 접수된 close task를 termination gate가 join한 뒤 dirty review와 final recovery flush를 진행한다.
- **Validation:** focused remediation 8/8와 Debug/Release full 221/221 PASS. headless Scintilla viewport의 비동기 first-visible-line settle을 문서 변이로 오인하던 기존 flaky assertion은 text/revision/selection/wrap/recovery byte 계약을 유지한 채 volatile layout 좌표만 제외했다. independent exact-byte review는 pending이다.
- **Boundary:** 기존 사용자 변경 `docs/wiki/04-implementation-foundation.md`, `scripts/vendor_scintilla_5_6_6.sh`, README와 ignored Notepad++ reference는 제외·보존한다.

### 2026-09-03 — Phase 13 recently closed tabs independent review

- **Agent/role:** `/root/phase1_code_review`, independent reviewer; Phase 13 구현과 remediation에는 참여하지 않았다.
- **Initial findings:** final automatic scratch의 pin/language/view-only customization 유실과 identity 없는 stale restore Retry의 다음 LIFO entry 오복구를 각각 Major로 판정했다. builder가 별도로 발견한 close-path snapshot materialization 동안 freeze를 보류했다.
- **Closure:** exact replacement metadata/default editor capture 검증, UUID-bound Retry preflight, immutable capture 보관과 explicit restore의 off-main materialization으로 두 Major와 hot path를 닫았다. reopened canonical path는 closed bytes를 dirty unbound restored scratch로 보존한다. pinned file/language, 20-entry LIFO/cap, durable recovery publication, termination join도 현재 bytes/tests에서 확인했다.
- **Evidence:** independent exact-final focused 9/9와 `git diff --check` PASS. final duplicate-path case 직전 independent Debug 214/214는 exact-final claim에서 제외하며, builder exact-final Debug/Release 215/215를 supporting evidence로 기록한다.
- **Verdict:** **APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** exact staged-candidate receipt는 pending이다.
- **Boundary:** review 문서와 index row/work log만 수정했다. source/tests/work docs/stage/sign/commit/push는 건드리지 않았고 doc04/vendor script/README/ignored Notepad++를 제외·보존했다.

### 2026-09-03 — Phase 12 searchable document switcher independent review

- **Agent/role:** `/root/phase1_code_review`, independent reviewer; Phase 12 구현과 remediation에는 참여하지 않았다.
- **Initial findings:** exact multi-word title보다 path-only 결과가 앞서는 ranking, host window close 뒤 남는 popover를 Major로, 제거된 flat-menu 설명을 Minor로 판정했다. 실제 compiled probes로 두 Major를 재현했다.
- **Remediation:** host-window/teardown dismissal과 historical documentation은 첫 re-review에서 닫혔다. scalar tier/offset 합산의 tier inversion을 추가 재현한 뒤, final tuple `tier → visual index` 정렬과 exact adversarial test로 P12-01까지 닫았다.
- **Evidence:** independent initial focused 9/9 + Debug 204/204, first re-review focused 11/11, final focused 8/8와 `git diff --check` PASS. builder Debug/Release 205/205는 supporting evidence로만 기록한다.
- **Verdict:** **APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** exact staged-candidate receipt는 pending이다.
- **Boundary:** 이 review 문서와 index row/work log만 수정했다. source/tests/other docs/stage/sign/commit/push는 건드리지 않았고 doc04/vendor script/README/ignored Notepad++를 제외·보존했다.

### 2026-09-03 — Phase 11 P11-01…P11-03 independent focused re-review

- **Agent/role:** `/root/phase1_code_review`, independent reviewer; remediation 구현에는 참여하지 않았다.
- **Closure:** dropdown edit 1-item/active max-2 갱신과 500/5,000-tab inspection, tab-strip cached active index, synchronous termination admission과 ready/direct/queued action lock, cancel-only restoration, four-corner/84%-bounds/full ICNS extraction 검증으로 P11-01…P11-03을 모두 닫았다.
- **Validation:** independent focused 9/9, Debug 200/200, isolated-scratch Release 200/200 PASS. builder macOS 13 x86_64 link와 production Scintilla 50-tab smoke는 supporting evidence다.
- **Verdict:** **APPROVED — 0 Blocker, 0 Major, 0 Minor.** Phase 11 content freeze와 exact staged-candidate review/signing 준비를 허가하며 receipt는 아직 없다.
- **Boundary:** review 문서와 이 index만 변경했다. source/tests/resources/work docs/stage/sign/commit은 건드리지 않았고 기존 doc04/vendor script/README/ignored Notepad++를 제외·보존했다.

### 2026-09-03 — Phase 11 P11-01…P11-03 remediation

- **Agent/role:** `/root`, direct builder; 독립 reviewer verdict를 변경하지 않는다.
- **Fix:** document dropdown edit는 1 item, active 전환은 최대 2 item만 configure하고 500/5,000-tab inspection을 계측한다. termination coordinator는 async task 전 chrome admission을 동기 잠그고 ready event와 queued/direct action이 이를 다시 열지 못하게 하며, cancel 뒤에만 복구한다. icon test는 네 모서리, 84% 중앙 alpha bounds와 전체 ICNS extraction을 검증한다.
- **ICNS detail:** modern PNG chunk는 RGBA exact equality를 요구한다. macOS `iconutil`의 legacy 1x `ic04`/`ic05` ARGB edge quantization은 동일 alpha bounds와 normalized RMSE `< 0.035`로 제한한다.
- **Validation:** focused remediation 8/8, Debug/Release 전체 각 200/200와 `git diff --check` PASS. 첫 전체 실행에서 startup 전 Find panel 표시 계약 회귀가 검출되어 non-mutating panel open은 허용하고 실제 search/replace admission만 ready로 유지한 뒤 focused/full을 재통과했다.
- **Boundary:** review verdict 문서, README, ignored Notepad++ checkout, 기존 unstaged doc04/vendor script를 변경하지 않았고 stage/sign/commit하지 않았다. 새 독립 re-review 전까지 직전 Changes Required verdict가 유효하다.

### 2026-09-03 — Phase 11 independent code review

- **Agent/role:** `/root/phase1_code_review`, independent reviewer; Phase 11 구현에는 참여하지 않았다.
- **Scope:** workspace chrome/layout/dropdown/status/language/palette와 최종 84% iconset/ICNS의 현재 바이트만 검토했다.
- **Findings:** 0 Blocker, 2 Major, 1 Minor. dropdown의 단일-item 계측 뒤 전체 menu state 순회와 termination 중 새 chrome action admission이 승인을 차단한다. 아이콘 테스트의 네 모서리/ICNS pixel-identity coverage는 Minor다.
- **Validation:** focused UI/palette 5/5, icon 1/1, Debug 197/197, Release 197/197, source SHA/10-size/four-corner alpha/ICNS RGBA round-trip와 diff check가 통과했다. exact 23-path manifest digest는 review 문서에 기록한다.
- **Boundary:** 제품/source/test/resource 및 stage/receipt/commit은 변경하지 않았고, doc04/vendor script/README/ignored Notepad++는 제외·보존했다.

### 2026-09-03 — Phase 11 workspace chrome and document dropdown

- **Agent/role:** `/root`, direct builder; 새 구현 subagent를 만들지 않았다.
- **Scope:** hidden error-banner collapse, 34pt multiline tab chrome, stable-ID Open Documents dropdown, 24pt non-overlapping status bar, clickable language/extension controls, semantic Scintilla gutter/caret-line palette와 fallback editor colors를 구현했다. 새 Duckpad duck-and-pencil 아이콘은 외부 canvas를 투명화하고 84% 중앙 정렬해 Dock visual footprint를 맞춘 표준 PNG/ICNS 리소스로 교체했다.
- **Performance/safety:** ordinary buffer edit는 tab item과 document-menu item을 각각 하나만 갱신한다. UI action은 `TabID`를 Presentation에서 workspace로 전달하고 revision/recovery/file authority를 우회하지 않는다.
- **Validation:** 신규 dropdown/chrome/palette focused tests, Debug/Release 전체 각 197/197, clean macOS 13 x86_64 release link와 production Scintilla 50-tab multiline smoke PASS. 첫 병렬 Debug의 기존 persistence timing test 1건은 isolated test와 clean full rerun에서 PASS했다.
- **Boundary:** README, parity baseline, ignored Notepad++ checkout과 기존 unstaged doc04/vendor script는 변경하지 않았다. 독립 reviewer 승인과 exact receipt 전에는 commit-authorized가 아니다.

### 2026-09-03 — Phase 10 P10-01/P10-02/P10-03 independent focused re-review

- **Agent/role:** `/root/phase1_code_review`, independent reviewer; remediation 구현에 참여하지 않았다.
- **Closure:** tracked Cmd-N termination join과 publication 후 input 재잠금, Scintilla Cocoa marked-text responder semantics, fallback revision-exhaustion read-only를 현재 bytes에서 모두 재검증했다.
- **Evidence:** independent focused 3/3, physical-input-lock external probe 1/1, debug/release 전체 각 195/195 PASS. builder fresh 195/195, x86_64 macOS 13 link, production 50-tab smoke는 supporting evidence다.
- **Verdict:** **APPROVED — 0 Blocker, 0 Major, 0 Minor.** Phase 10 candidate freeze와 exact signing을 허가한다.
- **Boundary:** review 문서와 이 index만 수정했다. source/tests/work docs/stage/sign/commit은 변경하지 않았고 기존 doc04/vendor script를 보존했다.

### 2026-09-03 — Phase 10 P10-01/P10-02/P10-03 remediation

- **Agent/role:** `/root`, direct builder; 추가 구현 agent를 만들지 않았다.
- **Fix:** accepted Cmd-N task를 동기 등록하고 termination final recovery 전에 join한다. Scintilla Undo/Paste는 Cocoa content responder의 marked-text 규칙을 사용하며, fallback은 revision `UInt64.max`에서 mutation command를 전부 닫는다.
- **Evidence:** adversarial 3/3, debug/release/fresh 전체 각 195/195, macOS 13 x86_64 release link, production 50-tab wrapped-layout smoke PASS. 첫 parallel release의 기존 viewport-state flake 1건은 isolated retry와 전체 rerun에서 PASS했다.
- **Boundary:** 기존 reviewer에게 focused re-review만 요청한다. README, ignored Notepad++ checkout, 기존 unstaged doc04/vendor script는 변경하지 않았다.

### 2026-09-03 — Phase 10 independent content review

- **Agent/role:** `/root/phase1_code_review`, independent reviewer; Phase 10 구현에 참여하지 않았다.
- **Scope:** 지정된 13개 Phase 10 경로의 Clean Architecture, native shortcuts/collision, validation/action lifecycle, Scintilla/`NSTextView` command semantics, revision/recovery/undo 및 Cmd-N durability를 검토했다.
- **Evidence:** independent focused 5/5, debug/release 전체 각 192/192 PASS. 외부 scratch adversarial probe에서 Cmd-N termination ordering, active-IME Undo/Paste, fallback revision exhaustion 결함을 각각 재현했다.
- **Verdict:** **CHANGES REQUIRED — 0 Blocker, 3 Major, 0 Minor.** 자세한 fix는 Phase 10 independent review에 기록했다.
- **Boundary:** 새 review 문서와 이 index만 수정했다. source/tests/work docs/stage/sign/commit은 변경하지 않았고 기존 doc04/vendor script를 보존했다.

### 2026-09-03 — Phase 10 standard editing commands and shortcuts

- **Agent/role:** `/root`, direct investigator/builder; 추가 구현 agent를 만들지 않았다.
- **Scope:** Application-owned standard edit-command port, Scintilla/`NSTextView` adapters, native Edit menu와 validation, Cmd-N, exact macOS shortcut/collision acceptance를 구현했다.
- **Safety:** workspace ready/active-buffer/no-termination predicate를 validation과 직접 selector action에 공통 적용한다. mutating command는 기존 revision/recovery/undo gate를 우회하지 않는다.
- **Validation:** focused behavior/shortcut/lifecycle 5/5, debug/release/fresh 전체 각 192/192, macOS 13 x86_64 release build/link와 production launch/exit smoke PASS. fresh 경고는 기존 vendored Scintilla Cocoa deprecation뿐이다. 독립 review는 candidate freeze 전에 수행한다.
- **Boundary:** README와 baseline score를 변경하지 않았다. ignored Notepad++ checkout은 read-only/clean이며 기존 unstaged doc04/vendor script를 보존한다.

### 2026-09-03 — Phase 9 P9-01 independent focused re-review

- **Agent/role:** `/root/phase1_code_review`, independent focused reviewer; builder의 P9-01 closure만 현재 bytes에서 재검증했다.
- **Closure:** shared `actionableEditorViewOptions`가 action/validation 모두에 `.ready`, active buffer, no termination review를 강제한다. delayed restore와 blocked termination에서 command는 disabled/inert이고 정상 admission 복귀 뒤 다시 활성화된다.
- **Validation:** independent debug focused pair 5회, 합계 10/10; release focused 2/2; full debug 189/189 PASS. builder full release 189/189는 supporting evidence로 구분했다.
- **Verdict:** **APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** exact staged receipt는 pending이다.
- **Safety:** review record/index만 수정했다. source/tests/work doc/stage/sign/commit과 기존 unrelated doc04/old vendor script는 변경하지 않았다.

### 2026-09-03 — Phase 9 P9-01 direct remediation

- **Agent/role:** `/root`, direct builder; 구현 subagent를 추가하지 않았다.
- **Closure:** View option action과 validation에 동일한 workspace `.ready`, active buffer, termination-review admission을 적용했다. delayed restore의 provisional state와 종료 검토 중에는 command가 disabled/inert이며, 이후 다시 활성화된다.
- **Validation:** 신규 startup/termination 회귀 2/2, debug/release 전체 각 189/189 PASS. `git diff --check` PASS 후 동일 independent reviewer의 focused re-review와 exact receipt를 기다린다.
- **Safety:** document bytes/revision/dirty/undo는 건드리지 않는다. README, ignored Notepad++ reference, 기존 unstaged doc04/old vendor script를 범위 밖으로 보존한다.

### 2026-09-03 — Phase 9 editor view-options independent code review

- **Agent/role:** `/root/phase1_code_review`, independent reviewer; 직접 구현한 `/root`와 분리해 현재 15-path diff만 판정했다.
- **Scope:** Application port/recovery migration, Scintilla flags와 buffer isolation, fallback capability, native View menu, view-only recovery signal, close-test synchronization을 검토했다.
- **Validation:** independent focused 7/7, close Retry 10/10, debug/release 188/188, production Scintilla tab smoke PASS. fresh 188/188와 macOS 13 x86_64 build는 builder supporting evidence로 구분했다.
- **Verdict:** **APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 1 Minor.** P9-01은 startup/termination 중 View menu readiness gating이 없어 provisional toggle이 유실될 수 있는 non-blocking lifecycle UX 결함이다.
- **Safety:** review record/index만 수정했다. source/tests/stage/sign/commit과 기존 doc04/old vendor script는 변경하지 않았다.

### 2026-09-03 — Phase 9 editor view options direct implementation

- **Agent/role:** `/root`, direct investigator and builder; 추가 구현 agent를 만들지 않았다.
- **Scope:** Application `EditorViewOptionsPort`, backward-compatible recovery view state, Scintilla wrap visual flags, `NSTextView` fallback behavior, native View menu/check state와 focused tests를 구현했다.
- **Invariant:** option toggle은 document bytes/revision/dirty/undo를 바꾸지 않으며 view-state 변경만 recovery autosave를 예약한다. marker를 동등하게 그릴 수 없는 fallback은 capability를 명시해 menu action을 disable한다.
- **Validation:** view/recovery/menu 및 close-race focused 7/7, close retry 10/10, debug/release/fresh 각 188/188, macOS 13 x86_64 release build/link PASS다. full-suite가 드러낸 기존 close-retry test timing은 이전 persistence를 drain하고 accepted revision/text를 즉시 단언하도록 결정화했다.
- **Boundary:** README, ignored Notepad++ reference, 기존 unstaged 문서 04와 old Scintilla vendor script는 범위 밖으로 보존한다. 독립 review와 exact receipt 전에는 commit하지 않는다.

### 2026-09-03 — Phase 8 verified local commit

- **Commit:** `1f60beddc60336b7a7d2b130887bb948f730437e` (`feat: add secure extension platform`).
- **Review gate:** candidate `a3f1b08f52e8097c42cc235789c310a0a2707de0c17d8376f5dae8ec6c1e6236`와 receipt SHA-256 `bd5dfc59a078fc9170ce1112ff9797e8108471d42dd7cf9c1ff02a2112e15e3e`가 exact identity 검증을 통과했다.
- **Audit/safety:** 전체 8 commits audit PASS, remote 없음, ignored Notepad++ reference clean, 사용자 변경 doc04/old Scintilla script 보존.

### 2026-09-03 — Phase 8 P8-01/P8-02 direct remediation

- **Agent/role:** `/root`, direct builder. 사용자의 지시에 따라 추가 구현 agent 없이 직접 수정했고, 독립 reviewer verdict는 변경하지 않았다.
- **P8-01:** rename 뒤 directory fsync 실패에도 published generation을 소비하고, 해당 프로세스에서는 user authority를 restart-required 상태로 영구 잠근다. refresh/즉시 재시도/consent/grant/revoke/reset/user invocation이 latch를 우회하지 못한다.
- **P8-02:** Cmd-Q와 red close가 use-case invocation admission과 editor input을 잠근 뒤 exact request cancel, transport teardown, invocation completion을 모두 기다리고 나서 dirty review/final recovery flush를 수행한다. 종료가 거절될 때만 두 gate를 다시 열어 queued-task 우회를 막는다.
- **Evidence:** restart-only recovery, same-generation retry 거절, queued admission 차단, denial resume, held-reservation idle join, termination approval ordering 회귀 테스트를 추가했다. debug/release/fresh가 각각 Domain 13 + Application 62 + Infrastructure 40 + Presentation 38 + EditorAdapter 31 = 184/184를 통과했고, Infrastructure 40/40 병렬 stress 3회, macOS 13 x86_64 release build, sample signature 검증, 실제 extension smoke도 통과했다.
- **Additional direct hardening:** full-target stress에서 child exit 뒤 중복 `Process.waitUntilExit` 경로가 Swift task를 남기는 경합을 재현했다. `/root`가 pre-launch shared multi-waiter exit signal로 read/timeout/cancel/catch teardown을 단일화하고 PID-readiness 기반 test로 고정했다.
- **Safety:** README/ignored Notepad++ reference/stage/commit을 건드리지 않았고, 기존 unstaged doc04/old Scintilla vendor script는 Phase 8 범위 밖으로 보존했다.

### 2026-09-03 — Phase 8 secure extension platform

- **Agent/role:** `/root/philosophy_parity`, product builder; stage/commit 또는 독립 review를 수행하지 않는다.
- **Implementation:** official WAMR 2.4.5 interpreter-only runtime, descriptor-bound signed package loader, durable identity/scope grants, request-scoped framed helper transport, bundled Text Tools Wasm sample, revision-reserved grouped edits, native Extensions manager/menu를 [Phase 8 문서](11-extension-platform.md)에 구현·기록했다.
- **Hardening and verification:** `/root` 및 `/root/clean_architecture` guard에 따라 50 MiB 실제/500 MiB 가상 bounded capture, selection 결과 containment, reservation 대기 중 cancel/disable/revoke/grant-removal 재검증, stable publisher fingerprint verification-only 계약, current SwiftPM configuration helper resolution, WAMR absent-target byte-identical regeneration을 추가했다. Phase 8 focused 26개, 전체 debug/release/fresh 각각 178개, x86_64 release build 및 실제 extension smoke가 통과했다.
- **Security collaboration:** `/root`의 construction guard를 반영해 no-import Wasm policy, memory/table/ABI caps, hidden exact inventory, immutable bundled attestation, consent/revoke tokens, selection-only payload, terminal first-wins cancel/timeout/reap, policy uncertainty fail-closed, dynamic authorized command UI와 adversarial tests를 추가했다.
- **Boundary:** SwiftPM Process helper는 Developer Preview이며 signed embedded XPC/helper identity gate 전에는 release user extension execution을 비활성화한다. README/NPP/stage/commit 없음; 기존 unstaged doc04/old Scintilla vendor script 보존.

### 2026-09-03 — Phase 7 language and Lexilla integration

- **Agent/role:** `/root/philosophy_parity`, product builder; independent review/staging/commit은 수행하지 않는다.
- **Implementation:** official standalone Lexilla 5.5.3을 pinned SHA로 재현 가능하게 vendor하고, Domain/Application/Infrastructure/EditorAdapter/Presentation에 language registry, deterministic detection, document override/recovery, semantic palette, line/fold/brace/indent/comment UX를 [Phase 7 문서](10-language-support.md)에 구현·기록했다.
- **Guard collaboration:** Russell (`/root/clean_architecture`)의 WIP architecture guard findings를 반영해 semantic style metadata, exact shebang, ambiguity, runtime lexer resolution, explicit support/capability tiers, large-file zero-sync fallback, full configuration cache, persistence/theme no-op, bounded grouped comment command로 hardening했다.
- **Validation:** focused Phase 7 18/18 PASS, 전체 debug/release/fresh 각 150/150 PASS, x86_64 macOS 13 release build/link PASS 및 production language smoke PASS를 확인했다. 상세 command/evidence는 Phase 7 문서의 final log에 기록했다. README/NPP/stage/commit 없음; 기존 unstaged 문서 04/vendor script 보존.

### 2026-09-03 — Phase 7 P7-01 remediation

- **Agent/role:** `/root/philosophy_parity`, product builder; 독립 review 문서는 수정하지 않았고 stage/commit 권한도 사용하지 않았다.
- **Finding/remediation:** reviewer의 P7-01에 따라 제거된 registry ID를 가진 persisted manual override를 typed unavailable 상태로 승격했다. Plain Text/null lexer 안전 fallback은 유지하되 ID를 Auto로 바꾸지 않고, controller status에 missing ID/fallback warning을 표시하며 메뉴에는 Auto와 현재 available choices를 유지한다.
- **Acceptance:** Application 및 hosted WindowController/status/menu 회귀 테스트가 unknown recovery, 무변경 text/revision/recovery, explicit Auto reset/redetection을 검증한다. focused Phase 7 20/20 PASS, full debug/release/fresh 각 152/152 PASS, native release language smoke PASS를 [Phase 7 문서](10-language-support.md)에 기록했다.

### 2026-09-03 — Phase 7 upstream whitespace policy correction

- **Agent/role:** `/root/philosophy_parity`, builder. 임시 whitespace 환경 우회로 생성한 candidate `00788bcd…`는 사용·commit하지 않고 index를 `HEAD`로 복원했다. task가 저장한 `core.whitespace`/`apply.whitespace` config는 없다.
- **Policy:** official byte identity를 깨는 source 정리 대신 tracked `.gitattributes`를 정확한 `Vendor/Lexilla/5.5.3/**`에만 한정했다. upstream에 이미 존재하는 blank-at-EOL/EOF 및 space-before-tab 진단만 비활성화하며 Duckpad/nonvendor 경로는 strict default를 유지한다. EOL/filter/content 변환은 없다.
- **Evidence/review boundary:** clean temp root의 vendor script 재실행 결과 165파일 `diff -qr` PASS, generated provenance를 제외한 164 official 파일의 current/reproduced digest는 동일한 `6c44a2b96fc27c52ebcedec5a2dfe5b8f5f62e7eb6c30b7d50773446c2b6162d`다. vendor attribute/no-diagnostic, nonvendor unspecified/strict rejection, normal-config isolated 192-path cached check와 real empty-index check가 모두 기대대로 동작했다. 새 `.gitattributes`와 문서 bytes가 independent review를 받기 전에는 stage/prepare/commit하지 않는다.

### 2026-09-03 — Phase 6 header EOF hygiene confirmation

- **Agent/role:** `/root/phase1_code_review`, independent final reviewer.
- **Evidence/result:** `DuckpadICUBridge.h`의 EOF extra blank line 1개 제거 전후 whitespace-token/preprocessor identity를 확인했다. Current header SHA-256 `47ebceea76a66224b7f08081cd716dc837600286a6d20f0fb54be78e74bbab61`, updated 18-file manifest `075ca691d0ab93fff63ac28bd9fcb2d1fca4a200fa103aa0d95ff3aa8af30f14`; diff-check/build PASS. Semantic/API/ABI change 없음, Phase 6 **APPROVED (0 Blocker, 0 Major)** 유지.
- **Mutation:** final review/index evidence만 갱신; source/test/stage/commit 없음.

### 2026-09-03 — Phase 6 final remediation re-review

- **Agent/role:** `/root/phase1_code_review`, independent final reviewer; source/test/staging/commit authority 없음.
- **Result:** 공통 throwing selection preflight가 Find/Find All/Replace/Replace All의 empty scope를 `.noSelection`, stale retained scope를 `.invalidSelection`으로 fail closed함을 확인했다. whole-document broadening 없이 text/revision/undo/recovery가 보존되고 기존 undo도 정상 동작했다. P6-01/P6-02 회귀도 없어 **APPROVED (0 Blocker, 0 Major)**.
- **Evidence:** focused 5/5, debug/release 132/132, production search smoke, independent debug/release typed-failure probes PASS. 상세는 [final remediation re-review](reviews/2026-09-03-phase-6-search-replace-final-rereview.md)에 기록했다.
- **Preserved:** 문서 04/vendor script와 모든 source/test bytes, README/ignored Notepad++ reference; stage/commit 없음. final review evidence와 index만 변경했다.

### 2026-09-03 — Phase 6 remediation re-review

- **Agent/role:** `/root/phase1_code_review`, independent remediation reviewer; source/test/staging/commit authority 없음.
- **Result:** P6-01 Unicode Whole Word directional과 P6-02 terminal/BOF zero-length progression은 closure 확인. P6-03 original selection reuse와 Replace Current revision/length rebase도 통과했으나, nil/empty 또는 revision-invalidated selection restriction이 unrestricted Replace All로 확장되어 **CHANGES_REQUIRED (0 Blocker, 1 Major)** 판정했다.
- **Evidence:** focused 3/3, debug/release 130/130, production search smoke PASS. 독립 probe에서 empty selection 3/3 전체 치환 및 invalidated selection의 old-scope 밖 치환을 재현했다. 상세 내용은 [remediation re-review](reviews/2026-09-03-phase-6-search-replace-rereview.md)에 기록했다.
- **Preserved:** 문서 04/vendor script와 모든 source/test bytes, README/ignored Notepad++ reference; stage/commit 없음. rereview evidence와 index만 변경했다.

### 2026-09-03 — Phase 6 independent content review

- **Agent/role:** `/root/phase1_code_review`, independent content reviewer; source/test/staging/commit authority 없음.
- **Scope/result:** Phase 6 product/acceptance 18 files와 index evidence만 검토했다. `SearchUseCase`의 regex Whole Word 누락(P6-01), terminal zero-length 재선택(P6-02), original selection scope 대신 current match만 치환(P6-03)을 독립 debug/release probe로 재현해 **CHANGES_REQUIRED (0 Blocker, 3 Major)** 판정했다.
- **Validation:** debug 127/127, release 127/127, production ICU/Scintilla search smoke, scoped `git diff --check` PASS. 세 probe는 양 configuration에서 동일 재현했다. 상세 evidence와 fix는 [독립 리뷰](reviews/2026-09-03-phase-6-search-replace-code-review.md)에 기록했다.
- **Preserved:** 기존 unstaged 문서 04와 vendor script, source/tests, README/ignored Notepad++ reference; stage/commit 없음. 리뷰 문서와 index evidence만 변경했다.

### 2026-09-03 — Phase 6 search/replace implementation

- **Agent/role:** `/root/philosophy_parity`, product builder; independent review/staging/commit은 수행하지 않는다.
- **Implementation:** AppKit-free search models and orchestration, ICU hard-budget regex Infrastructure adapter, narrow Scintilla target/search and grouped replacement façade, revision-reserved workspace transaction, non-modal search/results UI and native macOS menu routing을 [Phase 6 문서](09-search-replace.md)에 구현·기록했다.
- **Safety/performance:** recovery base+deltas를 off-main에서 materialize하고 open documents를 sequential bounded stream으로 처리한다. search generation/task cancellation과 TabID/BufferID/revision revalidation을 거치며 incomplete/capped replacement scan은 native mutation 전에 실패한다. Directional ICU edge search는 global result cap과 무관하게 한 match만 찾고, grouped Replace All은 native undo 한 번으로 원문과 recovery bytes를 복원한다. Delayed-store cancellation과 선행 tab activation adversary에서 reservation 전 native mutation이 없음을 검증했다.
- **Validation:** final reservation adversaries 2/2, debug/release/fresh scratch full 각각 127/127, production search smoke와 AppKit/Scintilla 50-tab/8-row/active-visible smoke PASS. Extended hex/octal/decimal, all-open Replace All, folder search, marks, persistent indicator highlight는 deferred이며 완료로 주장하지 않는다.
- **Preserved:** 기존 unstaged 문서 04와 vendor script, ignored Notepad++ reference. README/stage/commit 없음.

### 2026-09-03 — Phase 6 P6-01~P6-03 remediation

- **Agent/role:** `/root/philosophy_parity`, remediation builder. 독립 reviewer verdict 문서는 수정하지 않았다.
- **Fixes:** directional regex Whole Word를 동일 `L/M/N/Pc` ICU streaming predicate로 통일했다. terminal zero-length Find는 direction을 포함한 persistent identity와 explicit exhausted region으로 반복 재선택을 막는다. selection-only Find/Replace는 replacement field와 result selection에 흔들리지 않는 original tab/buffer/revision-bound scope를 공유하며 Replace Current 뒤 길이/revision을 rebase한다.
- **Validation:** focused 3/3, debug/release/fresh full 각각 130/130 PASS. Production search smoke 및 50-tab/8-row/active-visible smoke PASS. README/NPP/gitlink/cache/staging 없음; 기존 unstaged 문서 04/vendor script 보존.

### 2026-09-03 — Phase 6 selection fail-closed follow-up

- **Agent/role:** `/root/philosophy_parity`, residual P6-03 remediation builder.
- **Fix:** `.selection` Find/Find All/Replace/Replace All 공통 preflight가 initial/collapsed absence를 typed `.noSelection`, stale tab/buffer/revision/query scope와 collapsed current selection을 `.invalidSelection`으로 거부한다. nil restriction의 whole-document fallback은 불가능하며 UI도 no-match/success 대신 selection 조치 메시지를 표시한다.
- **Validation:** focused 2/2, debug/release/fresh full 각각 132/132 PASS; search smoke와 50-tab/8-row/active-visible smoke PASS. text/revision/undo/recovery 불변 및 기존 undo 보존을 실제 Scintilla adapter에서 검증했다. stage/commit 없음; 기존 unstaged 문서 04/vendor script 보존.

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

### 2026-09-02 — Phase 4 session/crash recovery

- **Agent/role:** `/root/philosophy_parity`, product builder; 독립 review나 commit authorization 역할은 수행하지 않는다.
- **Change:** [Phase 4 session recovery](07-session-recovery.md)에 recovery port/use case, generation/blob/manifest 저장소, startup restore, Scintilla view state, autosave/final flush와 forced-exit smoke 경계를 기록하고 실제 product composition에 연결했다.
- **Safety:** injected test/smoke root만 사용하며 production 기본값은 `Application Support/Duckpad/Recovery`다. explicit discard/close는 recovery manifest durability 이후 live session에 반영한다. README/Notepad++ reference를 변경하지 않는다.
- **Validation:** recovery-focused 19/19, debug full 86/86, release full 86/86, fresh scratch full 86/86 PASS. 강제 종료 write process(exit 86) 뒤 relaunch가 `crash 한글🙂`와 1 tab을 복구했다. forbidden README/gitlink/staging은 0건이고 ignored Notepad++ reference는 clean이다. 상세 명령과 evidence는 문서 07 Agent Work Log를 따른다.
- **Commit:** stage/commit하지 않았다.

### 2026-09-02 — Phase 4 independent code review

- **Agent/role:** `/root/phase1_code_review`, independent code reviewer; builder와 분리된 content verdict만 판정한다.
- **Scope:** 현재 unstaged Phase 4 recovery vertical slice의 데이터 유실/원자성, generation fallback, startup/close/Quit ordering, revision concurrency, Scintilla hot path, Clean Architecture, temp-root/permissions, manifest/blob validation과 tests. 기존 unrelated unstaged 문서 04/vendor script는 제외하고 보존했다.
- **Verdict:** **CHANGES_REQUIRED — 0 Blocker, 6 Major, 0 Minor.** P4-01 final-flush edit race, P4-02 missing blobs-directory sync, P4-03 duplicate tab/document ownership, P4-04 negative view-state crash, P4-05 O(file-size) recovery mirror edit, P4-06 unsurfaced corrupt-startup dead-end.
- **Validation:** focused recovery 17 test functions/19 cases PASS; debug 86/86 PASS; release 86/86 PASS; forced-exit write 86 + relaunch verify 0 PASS. Negative view-state production restore는 exit 133을 재현했고 duplicate tab/document manifest는 2 tabs로 잘못 수용됨을 재현했다.
- **Record:** 상세 finding/evidence는 [Phase 4 review](reviews/2026-09-02-phase-4-session-recovery-code-review.md). 리뷰 문서와 이 index 항목만 수정했으며 reviewed source/test를 수정·stage·commit하지 않았다.

### 2026-09-02 — Phase 4 P4-01..P4-06 remediation

- **Agent/role:** `/root/philosophy_parity`, product builder; 독립 reviewer verdict를 변경하지 않는다.
- **Scope:** [Phase 4 session recovery](07-session-recovery.md)에 final-flush freshness, blob-directory durability, one-tab/one-document ownership, safe view-state validation, bounded recovery delta journal, corrupt-only startup reset/retry를 구현했다.
- **Regression evidence:** targeted 9 test functions PASS(4-way interruption fault 포함), debug full 94/94, release full 94/94, fresh scratch full 94/94 PASS. forced-exit write(exit 86) 뒤 relaunch가 `remediated crash 한글🙂`와 1 tab을 복구했다.
- **Safety:** README/Notepad++ reference/review verdict 문서를 변경하지 않았고 stage/commit하지 않았다. 새 독립 review 전까지 기존 `CHANGES_REQUIRED` verdict는 유지된다.

### 2026-09-02 — Phase 4 remediation independent re-review

- **Agent/role:** `/root/phase1_code_review`, independent code reviewer; builder와 분리된 content verdict만 판정한다.
- **Scope:** 이전 review의 P4-01~P4-06만 현재 코드와 표적 테스트로 재검증했다. unrelated 문서 04/vendor script는 제외하고 보존했으며 새 기능 범위를 추가하지 않았다.
- **Closure:** final flush freshness loop/input gate, blobs-directory sync, tab/document ownership, 음수·범위초과·UTF-8 경계 validation, 1/10/50 MiB bounded delta hot path/off-main materialization, corrupt-only startup reset/retry가 모두 닫혔다.
- **Validation:** focused 24/24, debug 94/94, release 94/94, fresh scratch 94/94와 forced-exit/relaunch smoke가 통과했다. implementation/acceptance 19-file manifest SHA-256은 `a31d9408fa0844dbf397c2b4a17089f8591e753e3d578bd4542c3072cfaa3f03`이다.
- **Verdict:** **APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major.** exact-candidate receipt 전까지 commit authorization은 부여하지 않는다. 상세 범위와 파일 목록은 [Phase 4 remediation re-review](reviews/2026-09-02-phase-4-session-recovery-rereview.md)에 기록했다.
- **Safety:** 이 re-review 문서와 index status/work log만 수정했다. reviewed source/test를 수정·stage·commit하지 않았다.

### 2026-09-02 — Phase 5 multiline-tab workspace

- **Agent/role:** `/root/philosophy_parity`, product builder; 독립 review나 commit authorization 역할을 수행하지 않는다.
- **Change:** [Phase 5 multiline tab workspace](08-multiline-tabs.md)에 cached multirow layout, dynamic width/overflow, active visibility, pin/MRU/reorder, mouse/keyboard/context/accessibility와 shared loss-safe close coordinator를 구현·기록했다.
- **Safety decisions:** dirty decision은 reviewed revision을 workspace transaction 안에서 재검증한다. 중복 close/termination은 동일 gate를 사용하고, workspace failure의 actionable retry를 duplicate banner가 덮지 않는다. Phase 4 recovery에서 `activationHistory`가 없는 schema-v1 archive는 active-only MRU로 migration한다.
- **Architecture guard:** Russell `/root/clean_architecture`의 WIP findings(O(n²) layout, cache engine invalidation, close race/TOCTOU, active-close MRU, drag event/index, recovery compatibility, menu wiring, failure duplication)를 구현과 targeted tests에 반영했다.
- **Scope truth:** context menu는 Close/Others/Right만 이번 acceptance다. Close All/Left/Unchanged/Unpinned와 전체 Notepad++ close workflow Full 주장은 후속 review 전까지 deferred다.
- **Validation:** targeted Phase 5와 debug/release/fresh 전체 112/112 PASS. 실제 AppKit smoke는 temporary recovery root에서 50 tabs/17 wrapped rows, active visible, exit 0을 확인했다. 상세 명령은 문서 08의 Agent Work Log를 따른다.
- **Commit:** stage/commit하지 않았다.

### 2026-09-02 — Phase 5 independent code review

- **Agent/role:** `/root/phase1_code_review`, independent code reviewer; builder와 분리된 content verdict만 판정한다.
- **Scope:** 현재 unstaged Phase 5 multiline-tab 15-file implementation/acceptance slice의 wrap/cache/resize, 500 tabs, pin/MRU/recovery migration, single/bulk/termination close, AppKit mouse/drag/menu/context/accessibility/path wiring과 Clean Architecture를 검토했다. unrelated 문서 04/vendor script는 제외·보존했다.
- **Verdict:** **CHANGES_REQUIRED — 0 Blocker, 3 Major, 0 Minor.** P5-01 failed-activation selection divergence, P5-02 O(n) visible/cache query contract violation, P5-03 duplicate non-actionable close-save failure presentation.
- **Validation:** focused 32/32, debug 112/112, release 112/112와 production 50-tab/17-row/active-visible smoke가 통과했다. 별도 `/tmp` AppKit probe는 activation persistence failure 뒤 Domain active와 collection selection 불일치를 재현했다.
- **Record:** 상세 finding/evidence와 exact file list는 [Phase 5 review](reviews/2026-09-02-phase-5-multiline-tabs-code-review.md)에 기록했다. 이 review 문서와 index 항목만 수정했고 reviewed source/test를 수정·stage·commit하지 않았다.

### 2026-09-02 — Phase 5 P5-01..P5-03 remediation

- **Agent/role:** `/root/philosophy_parity`, focused product builder; reviewer verdict와 status를 임의로 변경하지 않는다.
- **Change:** [Phase 5 multiline tab workspace](08-multiline-tabs.md)의 세 Major만 수정했다. failed activation은 authoritative selection/accessibility/visibility로 되돌리며 delegate recursion을 막는다. layout은 cached row ranges와 binary search로 visible rect에 교차하는 row/item만 조회하고 rowCount를 O(1)로 반환한다. close-save failure는 file presenter의 functional retry 소유권을 typed `alreadyPresented/workspaceFailure`로 전달해 generic empty retry로 중복 표시하지 않는다.
- **Regression evidence:** failing session store AppKit selection test, 500/5,000-tab visible query work-count test, single close latest-revision retry와 termination exactly-once presentation test를 추가했다. focused 4/4와 debug/release/fresh full 각각 115/115가 통과했다. temporary recovery root AppKit smoke는 50 tabs/17 rows와 exit 0을 확인했다.
- **Safety:** README/Notepad++ reference와 review verdict를 변경하지 않고 stage/commit하지 않았다. 기존 unstaged 문서 04/vendor script를 보존했다.

### 2026-09-02 — Phase 5 remediation independent re-review

- **Agent/role:** `/root/phase1_code_review`, independent focused re-reviewer; builder와 분리된 content verdict만 판정한다.
- **Scope:** 이전 review의 P5-01~P5-03만 현재 코드와 targeted evidence로 재검증했다. unrelated 문서 04/vendor script는 제외·보존했고 새 기능 범위를 추가하지 않았다.
- **Closure:** P5-01 authoritative selection/accessibility/visibility 복구와 recursion 방지, P5-02 O(1) rowCount 및 O(log rows + visible) spatial query는 닫혔다. P5-03은 single-close exactly-once/latest-revision Retry는 닫혔지만 termination Retry가 ordinary single close로 전환되어 종료 review/final flush를 재개하지 않는 Major가 남았다.
- **Validation:** focused 4/4, debug 115/115, release 115/115, production 50-tab/17-row smoke와 external failed-activation AppKit probe가 통과했다. current 17-file product/acceptance manifest SHA-256은 `a4b5c225e9c0417df74df629b0bc6dda582fa418727e7ee1ec0b2ec4ac452ab3`이다.
- **Verdict:** **CHANGES_REQUIRED — 0 Blocker, 1 Major, 0 Minor.** 상세 위치/수정 방향은 [Phase 5 remediation re-review](reviews/2026-09-02-phase-5-multiline-tabs-rereview.md)에 기록했다.
- **Safety:** 이 re-review 문서와 index 항목만 수정했다. reviewed source/test, README/reference를 수정하지 않았고 stage/commit하지 않았다.

### 2026-09-02 — Phase 5 final remediation independent re-review

- **Agent/role:** `/root/phase1_code_review`, independent final focused re-reviewer; builder와 분리된 content verdict만 판정한다.
- **Scope/closure:** P5-03 termination Retry가 app-installed native termination handler를 통해 새 `.terminateLater`/reply cycle을 시작하고, 최신 accepted revision 저장, 남은 dirty tab review, durable recovery/final flush를 완료하는지 검증했다. stable ID와 weak capture, old-reply clear/deferred early Retry가 stale capture/double reply를 막는다. P5-01/P5-02도 closed 상태를 유지한다.
- **Synchronization evidence:** 최초 post-edit polling은 transaction-busy로 이미 reject된 test edit를 살릴 수 없어 full-suite debug 두 번/release 한 번에서 재현됐다. 새 edit 전에 pending workspace persistence를 drain하고 active tab/editor를 검증한 뒤 revision `+1`을 즉시 단언하도록 고친 현재 bytes를 다시 검증했다.
- **Validation:** focused 5/5 및 5회 반복 25/25, debug 116/116, release 116/116, external failed-activation AppKit probe와 production 50-tab/17-row smoke가 통과했다. exact 18-file product/acceptance manifest SHA-256은 `b2758b324d67e8a58e1bd7e0f315e8b3fe63960c79fc3091c50bb35e672110b1`이다.
- **Verdict:** **APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** exact staged candidate와 canonical signed receipt 전까지 commit authorization은 부여하지 않는다. 상세 evidence는 [Phase 5 final remediation re-review](reviews/2026-09-02-phase-5-multiline-tabs-final-rereview.md)에 기록했다.
- **Safety:** 이 final re-review 문서와 index status/work log만 수정했다. reviewed source/test, README/reference를 수정하지 않았고 stage/commit하지 않았다.

### 2026-09-02 — Phase 5 P5-03 termination Retry continuation remediation

- **Agent/role:** `/root/philosophy_parity`, focused product builder; latest reviewer verdict/status를 임의로 변경하지 않는다.
- **Change:** ordinary/bulk close Retry는 initiating stable TabID target set과 remaining order를 유지한다. termination Retry는 ordinary close로 전환하지 않고 App delegate handler를 통해 새 native terminate request를 시작하며, shared coordinator가 실패 tab의 최신 revision 저장, 남은 dirty review와 final recovery flush를 이어간다.
- **Regression evidence:** 실제 Retry closure invocation 뒤 initial false reply 1회, 새 `terminateLater`, newest revision file save, remaining tab review, recovery durable commit/final flush와 new true reply를 검증했다. ordinary single-close latest-revision test도 유지된다. focused 2/2와 debug/release/fresh full 각각 116/116 PASS; AppKit smoke는 50 tabs/17 rows와 exit 0을 확인했다.
- **Deterministic synchronization:** newest edit 전에 workspace pending persistence를 명시적으로 await하고 active tab/editor state를 확인한 뒤, edit 직후 revision 증가와 content 수용을 동기적으로 검증한다. termination completion은 checked continuation으로 기다린다. isolated 10/10, debug full 3회 연속, release/fresh 116/116과 AppKit smoke가 통과했다.
- **Safety:** [Phase 5 문서](08-multiline-tabs.md)와 P5-03 source/test만 수정했다. re-review verdict, README/Notepad++ reference, stage/commit은 건드리지 않았고 기존 unstaged 문서 04/vendor script를 보존했다.

### 2026-09-03 — Phase 7 language/Lexilla independent code review

- **Agent/role:** `/root/phase1_code_review`, independent Phase 7 content reviewer; builder와 분리된 verdict만 판정한다.
- **Scope:** 현재 unstaged Phase 7 language/Lexilla 188-file product/acceptance manifest의 official provenance/license/reproduction, 78-language registry/detection/migration, Clean Architecture, production wiring/menu/status, semantic style/fold/brace/comment, 16/50 MiB bounds, tests/build/smoke를 검토했다. 기존 unrelated 문서 04/vendor-Scintilla script는 제외·보존했다.
- **Verdict:** **CHANGES_REQUIRED — 0 Blocker, 1 Major, 0 Minor.** P7-01은 recovery의 unknown persisted manual language를 detector가 unavailable로 식별하고도 service/controller가 ordinary Plain Text ready 상태로 축소하여 unavailable ID/reason을 UI에서 숨기는 결함이다.
- **Validation:** official Lexilla 5.5.3 tar SHA와 165-file vendor subset/header identity PASS; registry 78 = keywordComplete 20 + structural 57 + plain 1, distinct lexer 64/runtime resolution PASS; focused 18/18, debug/release/fresh 150/150, language smoke, arm64 minOS 13 및 x86_64 cross-build를 검증했다.
- **Record:** 상세 finding/evidence와 exact manifest digest는 [Phase 7 review](reviews/2026-09-03-phase-7-language-lexilla-code-review.md)에 기록했다. 이 review 문서와 index entry만 수정했고 reviewed source/test를 수정·stage·commit하지 않았다.

### 2026-09-03 — Phase 7 P7-01 independent remediation re-review

- **Agent/role:** `/root/phase1_code_review`, independent focused re-reviewer; builder와 분리된 content verdict만 판정한다.
- **Scope/closure:** P7-01만 재검증했다. unknown persisted manual ID는 세션에 그대로 남고 typed `unavailableManual`로 노출되며, editor에는 안전한 Plain Text/null lexer가 적용된다. hosted UI는 missing ID와 fallback을 warning으로 표시하고 menu는 Auto와 현재 available choices만 제공한다. 명시적 Auto만 override를 제거하고 shebang 언어를 재감지한다.
- **Invariants:** unavailable refresh와 표시가 text/revision/undo/recovery를 바꾸지 않으며 line-comment edit도 실행하지 않는다. 기존 real Scintilla language/theme invariant test도 유지된다.
- **Validation:** focused 20/20, debug 152/152, release 152/152, production language smoke, official Lexilla subset/header byte identity와 diff/stage hygiene가 통과했다. current 188-file product/acceptance path+byte digest는 `5084e062667752851bc79a983b464588bc2d62d74cc4371beb38bf2368408f86`이다.
- **Verdict:** **APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** exact-candidate receipt 전까지 commit authorization은 부여하지 않는다. 상세 evidence는 [Phase 7 P7-01 re-review](reviews/2026-09-03-phase-7-language-lexilla-rereview.md)에 기록했다.
- **Safety:** 이 re-review 문서와 index entry만 수정했다. reviewed source/test를 수정·stage·commit하지 않았다.

### 2026-09-03 — Phase 7 upstream whitespace policy independent confirmation

- **Agent/role:** `/root/phase1_code_review`, independent reviewer; abandoned candidate나 builder의 환경 우회를 신뢰하지 않고 현재 bytes를 재검증했다.
- **Policy:** root `.gitattributes`의 `/Vendor/Lexilla/5.5.3/** whitespace=-blank-at-eol,-blank-at-eof,-space-before-tab`만 적용된다. 다른 version/vendor/Duckpad 경로는 `unspecified`이고 text/EOL/filter/encoding transform은 없다. 세 vendor diagnostic fixture는 허용되고 동등한 nonvendor fixture는 strict error로 거절됐다.
- **Reproduction/hygiene:** current vendor script를 새 temp root에서 실행하여 165/165 `diff -qr` byte identity PASS; official archive SHA 고정도 유지된다. eventual 192-path alternate index의 cached check PASS, real index 0, whitespace git config override 0이다.
- **Regression/content:** P7-01의 네 source/test SHA는 직전 approval과 동일하고 post-policy focused 20/20 PASS다. full current Phase 7 content approval을 유지한다.
- **Manifest/verdict:** 189-file product/acceptance path digest `c1dd9781d9212530d35290250def28264272308985538bf558830e52ea84f840`, path+byte digest `f17f16b381359b6c73e8d5a9395d2ddfd372da1e82d43a404b2d5fd45fa234be`; **APPROVED — 0 Blocker, 0 Major, 0 Minor.** 상세 evidence는 [Phase 7 re-review](reviews/2026-09-03-phase-7-language-lexilla-rereview.md)에 추가했다.
- **Safety:** review evidence/index만 수정했고 source/test/stage/commit은 변경하지 않았다.

### 2026-09-03 — Phase 8 extension-platform independent code review

- **Agent/role:** `/root/phase1_code_review`, independent Phase 8 content reviewer; builder와 분리된 verdict만 판정한다.
- **Scope:** current unstaged Phase 8 extension platform의 WAMR provenance/interpreter policy, descriptor-bound signed packages/trust, durable policy authority, Process framing/teardown, release user gate, bounded Scintilla capture/result transaction, lifecycle races, sample/UI/composition/tests를 검토했다. 기존 unrelated 문서 04/vendor-Scintilla script는 제외·보존했다.
- **Verdict:** **CHANGES_REQUIRED — 0 Blocker, 2 Major, 0 Minor.** P8-01은 post-rename durability uncertainty 뒤 restart latch가 없어 동일 generation으로 권한을 다시 활성화할 수 있고, P8-02는 termination final flush가 active extension request를 cancel/join하지 않아 flush 이후 late edit가 적용될 수 있다.
- **Validation:** official WAMR 2.4.5 tar SHA 및 isolated 168-file byte reproduction PASS; focused debug/release 26/26, 추가 debug Domain 13/13 + Application 59/59, build와 real signed-loader → Process → WAMR → grouped-edit/undo smoke PASS. 196-path product/acceptance path+byte manifest digest는 `4bb70fda4f73795df5bbe74e54182998e977e66b0b0ce160a117ad370f5ffbba`다.
- **Record:** 상세 evidence/fix는 [Phase 8 review](reviews/2026-09-03-phase-8-extension-platform-code-review.md). 이 review 문서와 index entry만 수정했고 reviewed source/test를 수정·stage·commit하지 않았다.

### 2026-09-03 — Phase 8 focused remediation independent re-review

- **Agent/role:** `/root/phase1_code_review`, independent focused re-reviewer; P8-01/P8-02 및 그 stress 과정에서 드러난 Process teardown hang만 재검증했다.
- **Closure:** rename 직후 generation 소비와 process-lifetime user-authority latch가 refresh/retry/consent/grant/revoke/reset/invoke 우회를 막는다. 종료는 editor/invocation admission을 먼저 잠그고 exact request transport teardown 및 invocation completion을 join한 뒤 dirty review/final recovery flush를 수행한다. pre-entry UI task와 held workspace reservation도 late mutation 없이 종료된다. pre-launch shared multi-waiter exit signal이 timeout/cancel cleanup의 중복 `waitUntilExit` hang을 제거한다.
- **Validation:** independent current focused debug 32/32, closure tests 20/20, held-reservation 10/10, Process teardown 3/3, release remediation 17/17, real signed extension smoke PASS. Frozen-candidate supporting evidence는 debug/release/fresh 184/184, Infrastructure 40/40 x3, x86_64 macOS 13 build, signature 및 hygiene PASS다.
- **Verdict:** **APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** final 196-path product/acceptance path digest는 `2bdb07824db766fc8da73c77d9893d437e4408ad0bb49bd0a24a20663bc6b02b`, path+byte digest는 `24942d5e3a05013c598c7721982ef040eeb23747efcda88453ca62a8cb484088`다. exact staged candidate receipt는 아직 발급하지 않았다. 상세 기록은 [Phase 8 review](reviews/2026-09-03-phase-8-extension-platform-code-review.md)의 focused re-review section에 있다.
- **Safety:** review doc/index만 수정했다. product/source/tests, README/reference, unrelated 문서 04/vendor-Scintilla script, stage/commit은 변경하지 않았다.

### 2026-09-03 — Phase 8 WAMR whitespace normalization independent re-approval

- **Agent/role:** `/root/phase1_code_review`, independent focused reviewer; upstream normalization과 재현 계약만 검토했다.
- **Scope:** WAMR 2.4.5 vendored blob 14개의 trailing horizontal whitespace/extra EOF blank-line 정규화와 `scripts/vendor_wamr_2_4_5.sh`, `PROVENANCE.md` 갱신이다.
- **Validation:** official archive SHA 재검증; raw upstream과 비교해 차이가 선언된 14개에만 존재하고 전부 정확한 정규화 결과임을 확인했다. staged script의 fresh reproduction은 168/168 byte-identical, `sh -n` 및 `git diff --cached --check` PASS다.
- **Manifest/verdict:** product/acceptance 196-path path digest `2bdb07824db766fc8da73c77d9893d437e4408ad0bb49bd0a24a20663bc6b02b`, staged path+byte digest `498e8b7acf348011532fb394f433187045033dd2600239742a6def06632b6dfc`; **APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** Receipt/sign은 아직 수행하지 않았다.
- **Safety:** review doc/index만 수정했다. product/source/tests/stage/commit은 변경하지 않았다. 상세 evidence는 [Phase 8 review](reviews/2026-09-03-phase-8-extension-platform-code-review.md)에 있다.
