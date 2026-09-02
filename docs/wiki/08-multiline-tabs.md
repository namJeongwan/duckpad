# Phase 5 — Multiline tab workspace

**Status:** Implemented; review pending
**Date:** 2026-09-02

## Product contract

Duckpad의 tab strip은 열린 문서가 많아도 단일 행에서 제목을 숨기지 않는다. 창 너비와 제목 길이에 따라 96–220 pt 범위에서 tab 폭을 정하고, stable document order 그대로 다음 행으로 wrap한다. 최대 4행/작업영역 높이 34%를 넘으면 수직 overflow scroll을 사용하며 active tab은 언제나 visible 영역으로 이동한다.

지원 interaction은 mouse select, close button, middle-click close, `Cmd-W`, 행 사이 drag reorder, pin/unpin, 시각 순서 next/previous, MRU 전환, active tab left/right 이동이다. context menu는 이번 slice의 명시 범위인 Close, Close Others, Close to Right, Pin/Unpin, file-backed tab의 Copy Full Path/Open Containing Folder만 노출한다. dirty indicator, 중앙 생략 path tooltip, stable accessibility ID와 selected/modified/pinned/index/row metadata를 제공한다.

## Architecture and safety

- Domain `ScratchSession`이 order, leading pinned group, activation history를 소유한다. active tab을 닫으면 살아 있는 MRU를 먼저 선택하고, 없을 때만 deterministic neighbor로 fallback한다.
- Application `ScratchWorkspaceUseCase`는 navigate/move/pin을 전체 read→candidate→persist→apply transaction으로 직렬화한다. bulk close target은 coordinator 진입 시 snapshot으로 고정하고 이미 사라진 target은 건너뛴다.
- Application `TabCloseCoordinator` 하나를 click, middle-click, `Cmd-W`, bulk context command와 termination review가 공유한다. 같은 tab의 중복 trigger는 prompt를 한 번만 표시한다. prompt 중 revision이 바뀌면 새 snapshot으로 다시 묻고, discard/save-close는 reviewed revision을 workspace transaction 내부에서 재검증한다.
- 이미 결정되어 durable close된 앞쪽 target은 뒤 target에서 Cancel/save failure가 나도 되돌리지 않는다. Cancel 또는 failure 이후 target은 그대로 남고, stale target은 skip한다.
- Workspace가 이미 actionable retry와 함께 publish한 close persistence failure는 coordinator가 `workspaceFailure`로 구분해 Presentation이 중복 banner로 덮지 않는다.
- File Retry는 시작 operation을 바꾸지 않는다. ordinary/bulk close는 당시 stable TabID target set을 다시 사용하고 failed tab의 최신 revision부터 이어가며, termination은 App delegate를 통해 새 native terminate request와 `terminateLater`/reply cycle을 시작해 남은 dirty review와 final recovery flush를 완료한다.
- Presentation `MultilineTabCollectionLayout`은 한 번의 O(n) generation에서 attributes, item→row table, row→item range spatial index를 cache한다. 개별 item/rowCount 조회는 O(1), visible rect 조회는 O(log rows + intersecting rows/items)이며 bounds width, item width 또는 engine inputs가 바뀔 때만 generation을 다시 만든다.
- AppKit drag의 `.before` index를 source removal 전 insertion으로 해석하고, forward move는 1을 빼 Domain final index로 변환한다. Domain이 pin boundary를 최종 clamp한다.
- Recovery schema v1은 새 `activationHistory`를 저장한다. Phase 4 archive처럼 필드가 없으면 active-only history로 migration하여 기존 recovery를 거부하지 않는다.

## Native commands

| Command | Shortcut | Semantics |
| --- | --- | --- |
| Close Tab | `Cmd-W` | shared loss-safe close coordinator |
| Last Used / Previous in History | `Control-Tab` / `Control-Shift-Tab` | MRU history toggle |
| Next / Previous in Visual Order | `Option-Cmd-Right` / `Option-Cmd-Left` | current wrapped document order |
| Move Tab Left / Right | `Cmd-Shift-[` / `Cmd-Shift-]` | serialized order mutation, pin boundary respected |

## Files

- `Sources/DuckpadDomain/ScratchSession.swift`
- `Sources/DuckpadApplication/ScratchWorkspaceUseCase.swift`, `TabCloseCoordinator.swift`, `SessionRecoveryUseCase.swift`
- `Sources/DuckpadInfrastructure/LocalRecoveryStore.swift`
- `Sources/DuckpadPresentation/TabFlowLayout.swift`, `MultilineTabStripView.swift`, `DuckpadWindowController.swift`, `DuckpadMainMenuFactory.swift`
- `Sources/DuckpadApp/DuckpadMain.swift`
- `tests/DuckpadDomainTests/ScratchSessionTests.swift`
- `tests/DuckpadApplicationTests/ScratchWorkspaceUseCaseTests.swift`, `TabCloseCoordinatorTests.swift`
- `tests/DuckpadPresentationTests/TabFlowLayoutTests.swift`, `FileCommandRoutingTests.swift`

## Acceptance and validation

- 50/500 tabs, narrow resize, row cap/overflow, stable order and selected visibility.
- single-pass cached layout, O(1) item/rowCount lookup, O(log rows + intersecting rows/items) visible query, engine-input invalidation, persistence-only no-op and settled 500-tab edit `fullReload=0/itemReload=1`.
- drag writer→pasteboard→cross-row/end acceptance, forward/backward/end insertion conversion and pin-boundary clamp.
- MRU close, keyboard navigation/move, recovery round-trip and Phase 4 schema-v1 migration.
- single/bulk/termination shared dirty review: duplicate prompt exactly once, mid-batch Cancel, save failure, stale target skip, prompt-time edit와 transaction-time expected-revision race, operation-preserving actionable Retry.
- tab/close accessibility, dirty/pin/index/row value, path tooltip/context commands and menu selector/shortcut wiring.

```sh
swift build
swift test
swift build -c release
swift test -c release

fresh_dir="$(mktemp -d)"
swift build --scratch-path "$fresh_dir/build"
swift test --scratch-path "$fresh_dir/test"

DUCKPAD_TAB_SMOKE=1 DUCKPAD_SMOKE_EXIT=1 swift run DuckpadApp
```

## Deferred parity

Notepad++의 Close All, Close to Left, Close Unchanged, Close Unpinned는 Application scope 모델에는 일부 준비되어 있으나 이번 Phase 5 context-menu/UI acceptance 범위에는 포함하지 않았다. 또한 tab을 다른 view/window로 move/clone, document list popup과 user-configurable tab appearance는 후속 parity slice다. 이 문서는 전체 tab-close workflow가 Full이라고 주장하지 않는다.

## Agent Work Log

### 2026-09-02 — Phase 5 multiline-tab builder

- **Agent/role:** `/root/philosophy_parity`, product builder; 독립 reviewer 또는 commit authorizer 역할을 수행하지 않는다.
- **Input:** multiline tab workspace vertical slice와 current custom `NSCollectionView`; 기존 unstaged `docs/wiki/04-implementation-foundation.md`, `scripts/vendor_scintilla_5_6_6.sh`를 보존했다.
- **Implementation:** Domain order/pin/MRU, Application atomic commands와 shared close gate, cached AppKit layout, drag/middle-click/context/accessibility, native menu shortcuts, recovery migration과 tab smoke를 구현했다.
- **Russell clean_architecture WIP guards:** O(visible×n) layout을 cached O(n)+O(1) lookup으로 교체했다. engine change cache key, resize invalidation reentrancy, duplicate/stale close decision과 transaction TOCTOU, dead MRU/active-close selection, drag event consumption/forward insertion, schema-v1 compatibility, 실제 menu wiring, duplicate failure banner를 각각 targeted regression으로 고정했다.
- **Bulk semantics:** request-start snapshot의 target 순서를 사용한다. 앞에서 승인되어 닫힌 tab은 유지하고 Cancel/save failure에서 즉시 멈추며 이후 tab은 보존한다. prompt 대기 중 이미 닫힌 target은 다시 묻지 않는다.
- **Validation:** targeted Phase 5 tests와 debug/release/fresh 전체 112/112 PASS. 독립 scratch build도 성공했다. injectable temporary recovery root의 실제 AppKit smoke는 300 pt 창에서 50 tabs/17 rows를 렌더링하고 active visibility를 확인한 뒤 exit 0이었다. Fresh build warning은 upstream Scintilla Cocoa의 macOS 12 deprecation뿐이다.
- **Commands:** `swift build`; `swift test`; `swift build -c release`; `swift test -c release`; `swift build --scratch-path "$fresh_dir/build"`; `swift test --scratch-path "$fresh_dir/build"`; `DUCKPAD_RECOVERY_ROOT="$smoke_root" DUCKPAD_TAB_SMOKE=1 DUCKPAD_SMOKE_EXIT=1 swift run DuckpadApp`.
- **Safety:** README/Notepad++ reference를 변경하지 않고 stage/commit하지 않는다.

### 2026-09-02 — P5-01..P5-03 remediation

- **Agent/role:** `/root/philosophy_parity`, focused product builder; 독립 reviewer verdict 문서는 변경하지 않았다.
- **P5-01:** activation persistence failure의 `.persistence` change가 domain의 authoritative active tab으로 collection selection과 accessibility state를 되돌리고 해당 tab을 visible하게 만든다. 동기화 guard로 delegate activation recursion을 막는다. injected failing session store의 실제 controller/AppKit test가 domain/editor/selection 모두 원래 tab에 남고 commit attempt가 하나뿐임을 검증한다.
- **P5-02:** row range/minY/maxY spatial index와 cached row count를 generation에서 한 번 만든다. visible rect는 binary search로 첫 row를 찾고 교차 row/item만 검사한다. 500/5,000-tab deterministic instrumentation test가 두 row 이하, 열 item 이하만 검사하며 engine invalidation test가 cache generation 갱신을 보장한다.
- **P5-03:** close-save resolver는 `saved/cancelled/reviewStale/failed/workspaceFailure/alreadyPresented`를 typed하게 전달한다. file presenter가 Retry action을 소유한 failure는 controller의 generic empty-retry banner로 다시 표시하지 않는다. single close는 실패를 정확히 한 번 표시하고, 실패 뒤 새 edit를 받은 상태에서 retry가 최신 revision/text를 저장한 뒤 닫는 것을 검증한다. termination failure도 file failure 1회, functional retry 1개, generic failure 0개를 검증한다.
- **Validation:** focused command `swift test --filter 'routedCloseSaveFailurePresentsOnceAndRetriesLatestRevision|appTerminationSavesOrCancelsAndSaveFailureStaysOpen|failedActivationRestoresAuthoritativeSelectionWithoutRecursion|visibleAttributeQueriesInspectOnlyIntersectingRowsAtScale'` 4/4 PASS. debug/release/fresh scratch 전체가 각각 115/115 PASS했고 debug/release build도 PASS했다. injectable temporary recovery root의 AppKit smoke는 50 tabs/17 rows와 exit 0을 확인했다. Fresh build warning은 vendored Scintilla Cocoa의 기존 macOS 12 deprecation뿐이다.
- **Scope/safety:** P5-01..P5-03만 수정했다. README/Notepad++ reference, reviewer verdict, stage/commit을 건드리지 않았고 기존 unstaged 문서 04/vendor script를 보존했다.

### 2026-09-02 — P5-03 termination Retry continuation remediation

- **Agent/role:** `/root/philosophy_parity`, focused product builder; remediation re-review verdict 문서는 수정하지 않았다.
- **Operation context:** ordinary와 bulk Retry는 AppKit object/tab snapshot 대신 initiating stable TabID target set을 보존한다. 다시 실행할 때 이미 닫힌 target은 shared coordinator가 건너뛰고, 실패한 tab 하나만 `.save` continuation으로 처리한 뒤 원래 remaining target 순서를 계속 review한다.
- **Termination continuation:** controller는 failed TabID만 기록하고 `ApplicationTerminationCoordinator`의 app-delegate-installed handler로 새 native termination request를 발생시킨다. 새 shared review가 current tab/revision을 다시 읽어 failed save를 재시도하고 남은 dirty tab을 review한 뒤 `flushForTermination()`을 await한다. 이전 request는 false를 한 번만 reply하고 새 request는 별도 `terminateLater`/reply pair를 가진다.
- **Regression evidence:** `terminationFileRetryResumesReviewFlushAndNewTerminateReply`가 첫 reply false 1회, 실제 file Retry invocation, 새 `terminateLater`, 실패 뒤 최신 UTF-8 revision 저장, 남은 dirty tab decision, discard recovery commit과 final flush, 새 reply true를 검증한다. 기존 `routedCloseSaveFailurePresentsOnceAndRetriesLatestRevision`도 ordinary close latest-revision semantics를 유지한다.
- **Deterministic test seam:** newest edit 전에 `workspace.waitForPendingPersistence()`를 await하고 active TabID와 editor text를 확인한다. 그 다음 synchronous edit 직후 revision `+1`과 editor content를 확인하므로 transaction-busy rejection을 사후 polling으로 오인하지 않는다. 새 termination reply도 timing loop 대신 checked continuation으로 await한다.
- **Validation:** isolated termination Retry 10/10, debug full 116/116 3회 연속, release 116/116, fresh scratch 116/116 PASS; debug/release/fresh build PASS. injectable temporary recovery root AppKit smoke는 50 tabs/17 rows와 exit 0을 확인했다. Fresh build warning은 vendored Scintilla Cocoa의 기존 macOS 12 deprecation뿐이다.
- **Scope/safety:** P5-03 continuation만 수정했다. README/Notepad++ reference, reviewer 문서, stage/commit을 건드리지 않았고 기존 unrelated 변경을 보존했다.
