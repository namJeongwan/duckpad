# Phase 1 구현 Foundation

> **상태:** 실행 가능한 builder 결과. 제품 패리티 승인이나 commit authorization을 뜻하지 않는다.

## 결과

Duckpad는 Swift 6과 AppKit으로 빌드되는 최소 애플리케이션이 되었다. 앱을 시작하면 파일 선택 없이 빈 `new 1` scratch tab을 즉시 표시하되, session restore가 성공할 때까지 editor와 tab action을 비활성화한다. load 실패 상태도 입력을 승인하지 않고 recovery retry가 끝난 뒤에만 편집을 허용하므로 accepted fallback text가 restore에 덮이는 상태를 만들지 않는다. 탭은 창 너비가 줄어들면 다음 행으로 흐르며, 활성/수정 상태와 닫기/추가 동작을 지원한다.

이 단계의 목적은 Scintilla와 파일 기능을 서둘러 결합하는 것이 아니라, 이후 편집 엔진을 교체해도 제품 상태와 use case가 흔들리지 않는 실행 경계를 만드는 것이다.

## 빌드 선택

현재 저장소는 `Package.swift`를 기준으로 한다.

- Xcode 프로젝트 생성 없이 Command Line Tools의 `swift build`, `swift test`, `swift run`으로 재현할 수 있다.
- deployment target은 macOS 13이다.
- 테스트는 source-built 공식 `swift-testing` 6.2.4를 exact pin한다. transitive `swift-syntax` 602.0.0까지 `Package.resolved`에 잠긴다.
- 절대 toolchain path, unsafe linker flag, host SDK의 `_TestingInterop` dylib를 사용하지 않는다. macOS 13 deployment baseline에서 fresh scratch-path build/test를 검증한다.

실행 명령:

```sh
swift build
swift test
swift run DuckpadApp
```

비대화형 window smoke:

```sh
DUCKPAD_SMOKE_EXIT=1 swift run DuckpadApp
```

## Clean Architecture 경계

의존성은 바깥 계층에서 안쪽으로만 향한다.

```text
DuckpadApp ───────────────┬──> DuckpadPresentation ──> DuckpadApplication ──> DuckpadDomain
                         └──> DuckpadInfrastructure ─> DuckpadApplication ──> DuckpadDomain
```

| Target | 책임 | 직접 의존성 |
| --- | --- | --- |
| `DuckpadDomain` | typed ID, buffer/document/tab/session aggregate와 불변식 | 없음 |
| `DuckpadApplication` | scratch workspace use case, snapshot, `SessionStore`/`EditorPort` | Domain |
| `DuckpadInfrastructure` | 현재 process lifetime용 in-memory session adapter | Application, Domain |
| `DuckpadPresentation` | AppKit window, editor adapter, multiline tab strip/layout | Application, Domain |
| `DuckpadApp` | NSApplication 시작과 composition root | 네 제품 모듈 |

Domain/Application은 AppKit을 import하지 않는다. Presentation은 저장 구현을 알지 못하고, Infrastructure는 UI를 알지 못한다.

## 모델과 동작

### Typed identity와 aggregate

`DocumentID`, `BufferID`, `TabID`, `SessionID`는 모두 UUID를 감싸지만 서로 대입할 수 없는 별도 타입이다. `ScratchSession`은 다음 관계를 소유한다.

- 하나의 tab은 하나의 document를 참조한다.
- 하나의 document는 하나의 buffer identity를 참조한다.
- Domain의 `BufferMetadata`는 `BufferID`, dirty flag와 monotonic revision만 가진다. full text는 소유하지 않는다.
- 새 scratch는 `new N`으로 이름 붙고 즉시 active가 된다.
- active tab을 닫으면 같은 위치의 오른쪽 tab, 없으면 왼쪽 tab을 선택한다.
- revision이 stale이면 incremental edit를 거부하고, `UInt64.max`에서는 wrap하지 않고 `revisionExhausted`로 fail-closed한다.
- aggregate는 동일한 `BufferID`의 중복 소유를 `duplicateBufferID`로 거부해 close 이후 dangling document/tab 참조를 만들지 않는다.

Application의 `ScratchWorkspaceUseCase`는 add/activate/close/edit를 단일 변경 지점으로 만든다. startup은 `.restoring`, `.ready`, `.failed`의 typed state machine이며 `.ready`에서만 edit revision을 승인한다. MainActor reentrancy를 허용하더라도 FIFO transaction gate가 async mutation의 read → candidate → save → apply 전체를 직렬화한다. 동기 editor callback이 transaction 도중 들어오면 승인하지 않고 adapter가 이전 snapshot으로 복구하므로 accepted state가 사라지지 않는다. `SessionStore`는 `Sendable`, typed `async throws`와 monotonic `PersistenceGeneration` atomic commit 계약을 가진다. store는 generation 비교와 durable state 교체를 하나의 actor isolation boundary에서 처리하며, `OrderedSessionWriter`가 cancellation 여부와 무관하게 모든 side effect를 순차화한다. `flushPersistence()`는 앞선 write가 끝난 뒤 최신 generation이 durable해질 때만 반환한다.

UI 발행은 MainActor의 typed `WorkspaceChange`로 이루어진다. reset/insert/active/update/remove/persistence를 구분하며, 실패 event는 UUID와 retry intent를 함께 제공한다. 저장 실패는 `PersistenceFailure`/`PersistenceOutcome`/`PersistenceState`에 operation과 typed cause를 보존한다. 빠른 incremental edit 저장은 token 기반 debounce/coalesce하되 Task cancellation을 durable ordering 근거로 사용하지 않는다.

마지막 clean tab close는 Domain의 정상적인 optional active-tab 반환을 성공 여부로 해석하지 않는다. close → replacement scratch 생성 → 저장 1회 → snapshot 발행 1회 순서를 보장한다. dirty tab은 삭제 전에 반드시 application close policy를 거친다. Phase 1에는 file save가 없으므로 지원 outcome은 `discard`, `cancel`, 명시적인 `saveUnavailable`이다. cancel/saveUnavailable/persistence failure는 기존 tab과 live text를 유지한다.

### Multiline tab strip

`MultilineTabStripView`는 내부 `NSScrollView`가 실제 `NSCollectionView`/`MultilineTabCollectionLayout`을 host한다. 순수 계산기 `TabFlowLayoutEngine`이 제목 기반 폭을 min/max 범위로 제한하고, 사용 가능한 너비를 넘는 항목을 다음 행으로 이동한다. bounds width 변경 시 layout을 invalidate하되 viewport는 기본 4행과 workspace 높이 34% 중 작은 cap을 넘지 않는다. overflow row는 내부에서 세로 scroll되고 active tab은 매 snapshot/resize 뒤 visible rect로 이동한다.

각 tab item은 다음 상태와 동작을 제공한다. editor의 한 글자 변경은 `.tabUpdated(index:)`로 해당 collection item 하나만 reload하고 이후 `.persistence` change는 tab strip no-op이다. 500-tab 실제 controller 경계에서 debounce 저장이 settle된 뒤에도 full reload 0회/item reload 1회와 250ms 미만 budget을 검증한다.

- 활성 tab 배경과 selection
- 수정된 buffer의 dirty dot
- tab별 close button
- `+` scratch 추가 button
- tab 선택으로 활성 전환
- stable `TabID` 기반 accessibility identifier
- selected/modified/pinned/index/row metadata와 tab press action
- 제목을 포함하는 close label/identifier/action

### 현재 editor adapter

`TextViewEditorAdapter`는 `NSTextView`를 `NSScrollView` 안에 구성하고 Application의 `EditorPort`를 구현한다. adapter가 buffer별 live text snapshot과 `UndoManager`의 authority이며 Domain에는 text를 복제하지 않는다. buffer 전환 시 해당 buffer의 undo manager를 함께 전환하므로 B를 retire해도 A의 undo history가 유지된다. `NSTextStorage` character edit를 UTF-16 range/replacement/expected revision으로 전달하고 Application이 새 revision을 승인해야 snapshot을 확정한다. stale/rejected edit는 직전 adapter snapshot으로 복구한다. `setInputEnabled`가 restore gate를 실제 AppKit control에 적용한다. persisted close 성공 change를 받은 뒤에만 `retire(bufferID:)`가 닫힌 buffer의 text/undo만 제거하며, inactive open buffer와 failed-close buffer는 그대로 보존한다.

`DuckpadWindowController`는 모든 workspace change와 failure event를 구독한다. load/edit-background/add/activate/discard-close 저장 실패를 event ID별 한 번만 nonmodal error banner에 표시하며, typed retry intent를 같은 UI에서 다시 실행한다. modal UI는 dirty-discard 선택에만 사용한다. controller close는 collection delegate/layout/document 연결과 window/controller 연결을 해제하며 전역 test window 보존 없이 deallocation된다.

### App icon resource 경계

사용자가 제공한 `/Users/namjeongwan/Downloads/Duckpad_macOS_icon_set` PNG는 읽기 전용으로 검사했다. 기존 16/32/128/256/512 point 및 대응 2x 파일이 정확한 정사각 pixel 크기와 alpha를 이미 갖고 있어 resize나 디자인 변경 없이 표준 `AppIcon.iconset` 이름으로 복사했다. `iconutil -c icns`로 `Duckpad.icns`를 생성했고 source attribution을 resource 옆에 보존한다.

SwiftPM executable은 세 resource를 명시적으로 copy하며 `Bundle.module`의 ICNS를 개발 실행 시 `NSApplication.applicationIconImage`에 설정한다. SwiftPM CLI executable은 배포용 `.app` bundle/Info.plist 생성기가 아니므로, 향후 Xcode/archive 또는 별도 bundler 단계는 같은 `Duckpad.icns`를 `Contents/Resources`에 넣고 `CFBundleIconFile = Duckpad`로 연결하거나 동일 iconset을 AppIcon asset catalog에 연결해야 한다. 현재 단계에서 임의 Info.plist를 만들어 CLI와 배포 bundle 책임을 섞지 않는다.

## 파일 지도

| 경로 | 내용 |
| --- | --- |
| `Package.swift`, `Package.resolved` | 모듈 graph와 exact test dependency lock |
| `Sources/DuckpadDomain/Identifiers.swift` | 네 typed ID |
| `Sources/DuckpadDomain/ScratchSession.swift` | text-free buffer metadata, document/tab/session 모델, revision guard |
| `Sources/DuckpadApplication/Ports.swift` | generation-aware atomic store와 incremental editor/snapshot/lifecycle port |
| `Sources/DuckpadApplication/ScratchWorkspaceUseCase.swift` | ordered writer, startup state, typed workspace diff/failure/retry와 use case |
| `Sources/DuckpadInfrastructure/InMemorySessionStore.swift` | off-main actor in-memory adapter |
| `Sources/DuckpadPresentation/TabFlowLayout.swift` | 순수 wrap/row/cap 계산과 custom collection layout |
| `Sources/DuckpadPresentation/MultilineTabStripView.swift` | scroll-hosted capped tab UI, visibility/accessibility/action |
| `Sources/DuckpadPresentation/TextViewEditorAdapter.swift` | live-text NSTextView incremental editor adapter |
| `Sources/DuckpadPresentation/DuckpadWindowController.swift` | 실제 window와 view composition |
| `Sources/DuckpadApp/DuckpadMain.swift` | executable entry point, bundled 개발 Dock icon과 smoke exit |
| `Sources/DuckpadApp/Resources/` | 사용자 제공 표준 iconset, 생성 ICNS와 source attribution |
| `Tests/DuckpadDomainTests/` | scratch/typed graph, duplicate ID, revision conflict/overflow, close invariant |
| `Tests/DuckpadApplicationTests/` | delayed restore, adversarial ordered persistence, retirement, final/dirty close와 failure |
| `Tests/DuckpadPresentationTests/` | 50/500 geometry, targeted reload, real controller failure/restore 및 AppKit lifecycle |

## 검증 근거

2026-09-02, Apple Swift 6.3.1 (`arm64-apple-macosx26.0`) 환경에서 실행했다.

| 검증 | 결과 |
| --- | --- |
| `swift build` | PASS, `DuckpadApp` executable과 모든 library target 생성 |
| `swift test` | PASS, Domain 7 + Application 13 + Presentation 15 = 35 tests |
| `swift build -c release` | PASS, warning 없이 production configuration build |
| `swift test -c release` | PASS, 35/35 |
| `DUCKPAD_SMOKE_EXIT=1 swift run DuckpadApp` | PASS, 실제 AppKit application/window 생성 후 `Duckpad smoke window ready`, exit 0 |
| `swift package describe --type json` | PASS, 위 표와 동일한 inward dependency graph 확인 |
| fresh `swift build --scratch-path /tmp/duckpad-phase1-final.190XrZ` | PASS, dependency resolve와 app resources 포함 macOS 13 product build |
| fresh `swift test --scratch-path /tmp/duckpad-phase1-final.190XrZ` | PASS, 35/35, host-specific linker path/dylib warning 없음 |

이전 Swift Testing 6.3.1 workaround의 절대 CLT path와 macOS 14 `_TestingInterop` 경고는 제거됐다. source-compatible 6.2.4 package를 빌드하므로 선언한 macOS 13 baseline과 test runtime이 충돌하지 않는다.

## Scintilla bridge gap

현재 편집 가능한 foundation은 완성됐지만 Notepad++ 수준의 editor engine은 아직 아니다. 다음 구현 단계에서 `EditorPort` 뒤의 `TextViewEditorAdapter`를 Scintilla Cocoa bridge로 교체해야 한다.

남은 주요 gap:

- Scintilla native view lifecycle과 Swift memory/notification bridge
- UTF-8 byte offset과 Swift `String`/selection offset 변환
- lexer/style, marker, indicator, folding, multi-selection 및 rectangular selection
- Scintilla undo buffer와 Domain revision/dirty 동기화
- incremental edit range를 Scintilla byte offset과 UTF-8/UTF-16 사이에서 검증하는 bridge
- file open/save, encoding/EOL, external-change detection, crash recovery용 text snapshot persistence

교체 시 Domain에 AppKit/Scintilla 타입을 넣지 않는다. 현재 revision-checked incremental edit/snapshot 계약을 유지하면서 selection, commands, viewport state를 확장하고 Scintilla 구현과 fake adapter를 같은 contract test로 검증한다.

## 완료 조건

이 foundation의 완료 조건은 다음과 같으며 현재 모두 충족한다.

- Swift 6에서 제품 module과 executable이 빌드된다.
- dependency graph가 inward-only다.
- typed ID를 가진 untitled scratch aggregate와 최소 use case가 검증된다.
- 실제 AppKit window에 custom multiline `NSCollectionView` tab strip과 편집기가 조립된다.
- 시작 즉시 active 빈 scratch가 보이되 restore 완료 전 입력은 비활성화되고 이후 안전하게 편집할 수 있다.
- add/activate/dirty close policy/final close와 resize wrap/cap/visibility의 핵심 규칙이 자동 테스트된다.
- live text는 editor adapter에만 있고 revision-checked incremental edit가 Domain metadata를 갱신한다.
- ordered, generation-aware actor persistence의 success/failure/coalescing/flush ordering이 adversarial store로 테스트된다.
- 앱 window smoke가 자동 종료 모드로 성공한다.

이 완료는 Phase 1 foundation 범위에 한정되며 Notepad++ 패리티 feature를 `Full`로 표기하는 근거가 아니다.

## Agent Work Log

### 2026-09-02 — Phase 1 executable foundation

- **Agent/role:** `/root/philosophy_parity`, product implementation builder로 전환.
- **Scope:** SwiftPM foundation, Clean Architecture targets, scratch domain/use cases, AppKit multiline tabs/editor/window, unit tests, smoke 및 본 문서.
- **Skill used:** `source-command-sc-implement`. 요구사항을 domain/application/adapters/composition으로 분리하고 구현 후 build/test/smoke 순서로 검증하는 데 사용했다.
- **Key decisions:** 로컬에서 즉시 재현 가능한 SwiftPM을 채택했다. editor engine은 `EditorPort` 뒤로 격리했다. tab wrap geometry는 AppKit layout과 분리한 순수 계산기로 만들어 headless test가 가능하게 했다. startup/last-close 모두 최소 한 개 scratch invariant를 Application에서 보장한다.
- **Files changed:** `Package.swift`, `Package.resolved`, `Sources/DuckpadDomain/`, `Sources/DuckpadApplication/`, `Sources/DuckpadInfrastructure/`, `Sources/DuckpadPresentation/`, `Sources/DuckpadApp/`, `Tests/DuckpadDomainTests/`, `Tests/DuckpadApplicationTests/`, `Tests/DuckpadPresentationTests/`, 이 문서와 wiki index.
- **Commands/evidence:** `swift --version`; `swift package resolve`; `swift build`; `swift test`; `DUCKPAD_SMOKE_EXIT=1 swift run DuckpadApp`; `swift package describe --type json`.
- **Historical correction (superseded):** 최초 builder는 Swift Testing 6.3.1과 테스트 전용 `_TestingInterop` linker/rpath를 사용했다. 아래 independent-review remediation에서 이 host-specific workaround를 완전히 제거했다.
- **Historical validation:** 당시 build PASS, 8/8 tests PASS, AppKit smoke PASS, dependency graph inspection PASS. 현재 기준은 아래 20-test fresh validation이다.
- **Out of scope:** Scintilla bridge, disk persistence, file open/save, lexer/plugin/parity feature 구현, staging/commit.
- **Commit:** 없음. 요청에 따라 stage/commit하지 않았다.

### 2026-09-02 — Phase 1 independent code-review remediation

- **Agent/role:** `/root/philosophy_parity`, Phase 1 implementation builder. 독립 review 문서의 verdict를 스스로 변경하지 않으며 수정 결과는 exact bytes에 대한 후속 독립 re-review 전까지 승인 근거가 아니다.
- **Review input:** `docs/wiki/reviews/2026-09-02-phase-1-code-review.md`의 B-01, M-01~M-05, m-01~m-03.
- **B-01:** Application close는 Domain의 optional active ID를 성공 flag로 사용하지 않는다. 마지막 tab close 뒤 replacement를 만든 candidate 전체를 정확히 한 번 저장하고 성공 후 한 번 publish한다. 회귀 test가 새 active ID, stored session, save delta 1, publish count 1을 함께 검증한다.
- **M-01:** dirty close는 `requiresDecision(saveAvailable: false)`에서 멈춘다. `cancel`과 현재 미지원 `save`는 tab/live content를 유지하며 explicit `discard`만 삭제를 허용한다. UI alert도 Discard/Cancel만 제공하고 file save 미지원임을 설명한다.
- **M-02:** Domain의 full `String`을 제거했다. `BufferMetadata`는 ID/revision/dirty만 소유하고 `EditorPort`/`TextViewEditorAdapter`가 incremental UTF-16 edit와 buffer별 live text snapshot을 담당한다. stale revision은 reject/restore된다.
- **M-03:** `SessionStore`는 `Sendable` typed `async throws(SessionStoreError)`가 됐고 `InMemorySessionStore`는 actor다. MainActor use case가 typed persistence state/outcome을 publish하며 rapid editor saves를 debounce/coalesce한다. failure 시 durable mutation은 rollback하고 live dirty content는 유지한다.
- **M-04:** collection을 vertical `NSScrollView` 안에 넣고 기본 최대 4행/workspace 34% cap을 적용했다. selected tab을 visible rect로 이동하며 pure 50/500/narrow test와 실제 500-tab AppKit resize test를 추가했다.
- **M-05:** 절대 CLT linker path와 host dylib를 제거했다. macOS 13을 유지하면서 source-built `swift-testing` 6.2.4와 `swift-syntax` 602.0.0을 exact lock했다.
- **m-01:** 실제 `NSWindow`가 collection/scroll host를 layout하는 serialized AppKit suite를 추가했다. resize, selection, scroll visibility, accessibility press/close와 NSTextStorage edit를 검증한다. test window는 process lifetime까지 유지해 AppKit delayed layout teardown의 use-after-free를 방지한다.
- **m-02:** `UInt64.max` revision은 `revisionExhausted`로 실패하고 값이 wrap되지 않는 public-boundary test를 추가했다. Domain close 자체도 dirty buffer를 explicit `discardingDirty` 없이 삭제할 수 없다.
- **m-03:** tab/close/add에 stable accessibility identifier를 부여했다. tab value는 selected/modified/pinned/index/row를 포함하고 tab press 및 close button action을 실제 AppKit item에서 실행한다. resize 뒤 visible item의 row metadata도 refresh한다.
- **Files changed:** `Package.swift`, `Package.resolved`, Domain/Application/Infrastructure/Presentation Swift files, 세 Swift test target, 본 문서.
- **Validation commands:** `swift build`; `swift test`; `DUCKPAD_SMOKE_EXIT=1 swift run DuckpadApp`; fresh `swift build --scratch-path /tmp/duckpad-phase1-release.3AqN7p`; fresh `swift test --scratch-path /tmp/duckpad-phase1-release.3AqN7p`; package/import/absolute-path/whitespace scans.
- **Validation result:** normal build PASS with no warnings, 20/20 tests PASS, AppKit smoke PASS. Fresh dependency resolution/build PASS with no warnings and final fresh 20/20 tests PASS. swift-testing output confirms version 6.2.4; unsafe/absolute linker configuration is absent.
- **Remaining Scintilla gap:** Cocoa bridge, byte-offset conversion, lexer/style/selection/viewport commands and recoverable text persistence remain. 이미 확정한 incremental revision/snapshot port 뒤에서 구현한다.
- **Commit:** 없음. stage/commit하지 않았다.

### 2026-09-02 — Phase 1 independent code re-review remediation

- **Agent/role:** `/root/philosophy_parity`, Phase 1 implementation builder. 재리뷰 verdict는 수정하지 않았고 이 기록은 후속 독립 검토를 대체하지 않는다.
- **Review input:** `docs/wiki/reviews/2026-09-02-phase-1-code-rereview.md`의 F-01~F-04와 m-01~m-03.
- **Skill used:** `source-command-sc-implement`. async correctness를 store atomic boundary, application writer/state machine, editor lifecycle, presentation subscriber로 나누고 adversarial/real-AppKit test를 함께 구현했다.
- **F-01:** startup을 `.restoring/.ready/.failed`로 만들고 restoring 중 Application edit 승인을 거부했다. Controller는 editor의 editable/selectable과 tab action을 실제로 비활성화한다. delayed actor load의 fake binding test와 실제 controller/NSTextView test가 restore 전 입력 거부와 restore 후 입력 허용을 검증한다.
- **F-02:** 취소되는 debounce Task를 write correctness 근거에서 제거했다. `StoredSession`이 durable generation을 복원하고 `SessionStore.commitSession`은 generation compare+replace atomicity를 요구한다. detached tail 기반 `OrderedSessionWriter`가 side effect를 직렬화한다. cancellation을 무시하고 actor reentrancy를 허용하는 adversarial store에서 concurrent commit 최대 1, flush 후 durable revision 2를 검증했다.
- **F-03:** `EditorPort`에 input과 `retire(bufferID:)` lifecycle을 추가했다. 성공적으로 persist된 `.tabRemoved` change에서만 binding이 adapter text/undo를 폐기한다. inactive open buffer 및 failed-close text 보존, successful discard 뒤 snapshot/undo 제거를 fake와 실제 NSTextView 양쪽에서 검증했다.
- **F-04:** 모든 persistence failure change는 unique event ID와 typed retry intent를 가진다. Controller는 load, add, activate, background edit save, discard-close save failure를 한 번씩 nonmodal presenter에 전달하며 Retry가 실패한 close를 실제 완료하는 boundary test를 추가했다.
- **m-01:** public seeded buffer 추가는 기존 `BufferID`를 `duplicateBufferID`로 거부하고 aggregate를 변경하지 않는다.
- **m-02:** `WorkspaceChangeKind.tabUpdated(index:)`를 tab strip이 item reload 한 번으로 처리한다. 수동 diff와 실제 controller 양쪽의 500-tab typing test가 full reload 0, item reload 1, 250ms 미만을 검증했다.
- **m-03:** `AppKitTestLifetime.windows` 전역 보존을 제거했다. test window는 `isReleasedWhenClosed = false`로 ARC 소유권을 명확히 하고, delegate/layout/document/controller 연결을 teardown한 뒤 autorelease pool 경계에서 controller와 window가 모두 deallocate됨을 검증했다.
- **Files changed:** `Sources/DuckpadDomain/ScratchSession.swift`, `Sources/DuckpadApplication/Ports.swift`, `Sources/DuckpadApplication/ScratchWorkspaceUseCase.swift`, `Sources/DuckpadInfrastructure/InMemorySessionStore.swift`, `Sources/DuckpadPresentation/TextViewEditorAdapter.swift`, `Sources/DuckpadPresentation/MultilineTabStripView.swift`, `Sources/DuckpadPresentation/DuckpadWindowController.swift`, 세 Swift test file, 본 문서.
- **Validation commands/results:** `swift build` PASS; `swift build -c release` PASS; `swift test` 30/30 PASS; `DUCKPAD_SMOKE_EXIT=1 swift run DuckpadApp` PASS; fresh `/tmp/duckpad-phase1-remediation.hDXeH4`에서 dependency resolve 포함 build PASS와 test 30/30 PASS. 경고 없음.
- **Constraints:** root/docs wiki README를 만들지 않았고 `notepad-plus-plus/`를 수정하지 않았다. stage/commit하지 않았다.
- **Remaining Scintilla gap:** Scintilla Cocoa bridge, UTF-8 byte offset conversion, engine undo lifecycle 구현은 여전히 다음 phase 범위다. 새 `EditorPort` input/retire 및 incremental revision 계약 뒤에서 구현한다.

### 2026-09-02 — Phase 1 final remediation and supplied app icon

- **Agent/role:** `/root/philosophy_parity`, final Phase 1 implementation builder. 독립 second re-review의 status/verdict는 수정하지 않았다.
- **Review input:** `docs/wiki/reviews/2026-09-02-phase-1-code-second-rereview.md`의 F2-01, F2-02, F2-03, f-04 및 사용자 제공 app icon 추가 요구.
- **Skill decision:** code remediation에는 `source-command-sc-implement`를 사용했다. 아이콘은 디자인 변경/생성이 금지된 기존 artwork이므로 `imagegen`은 사용하지 않고 Apple의 deterministic resource 도구만 사용했다.
- **F2-01:** FIFO MainActor transaction gate가 start/add/activate/close/save-current의 read→candidate→save→apply 전체를 직렬화한다. gate가 점유된 동안 synchronous editor edit는 fail-closed되고 adapter snapshot으로 돌아간다. blocking/reentrant store에서 concurrent add 두 건이 모두 반영되어 workspace/durable tab 3개가 되며 close→queued add→edit 경로도 tab/revision 손실이 없음을 검증했다.
- **F2-02:** `.failed` startup에서도 editor/tab action을 계속 비활성화하는 정책을 확정했다. failure→입력 시도 거부→store recovery→`.start` retry→ready→입력 승인 순서를 fake와 real controller 경계가 검증한다.
- **F2-03:** `BufferTextView`가 active buffer에 맞는 전용 `UndoManager`를 제공하고 adapter가 buffer별 manager를 소유한다. B retirement는 B text/undo만 제거하며 실제 AppKit A edit→B edit→B retire→A display→A undo가 통과한다.
- **f-04:** `.persistence` change를 tab strip no-op으로 처리했다. 실제 500-tab controller test가 debounce write settle 뒤에도 full reload delta 0, item reload delta 1을 확인한다.
- **App icon:** Downloads의 13 PNG를 검사해 필요한 10개 표준 size/2x pair가 정확한 dimensions/alpha임을 확인했다. 원본 변경·resize·crop·색상/디자인 변경 없이 `Sources/DuckpadApp/Resources/AppIcon.iconset`에 복사하고 `iconutil`로 `Duckpad.icns`를 생성했다. `AppIcon-SOURCE.md`에 사용자 제공 attribution과 변환 내역을 기록했다. SwiftPM resource 및 `Bundle.module` 개발 Dock icon을 연결하고 PNG pixel/alpha와 ICNS header/16~1024 representation test를 추가했다.
- **Validation:** debug build PASS, debug tests 35/35 PASS, release build PASS, release tests 35/35 PASS, ICNS→iconset round-trip PASS, `DUCKPAD_SMOKE_EXIT=1 swift run DuckpadApp` PASS. fresh `/tmp/duckpad-phase1-final.190XrZ`에서 dependency resolve/resource copy 포함 build PASS와 tests 35/35 PASS.
- **Files changed:** Application use case, editor adapter, tab strip, app entry rename 및 resources, `Package.swift`, Application/Presentation tests, 본 문서.
- **Constraints:** Downloads 원본, `notepad-plus-plus/`, README를 수정/생성하지 않았다. stage/commit하지 않았다.
