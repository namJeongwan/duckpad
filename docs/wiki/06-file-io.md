# Phase 3 — File Open/Save vertical slice

**Status:** Implemented; review pending
**Date:** 2026-09-02
**Scope:** local text-file open, save, save as, encoding/EOL preservation, external-change conflict handling and native macOS command routing

## Product behavior

Duckpad의 scratch-first 흐름은 유지한다. 시작 시 `new 1`은 경로 없는 editable buffer이고, 처음 `Save`를 누르면 native Save panel로 이어진다. 파일을 열면 scratch tab을 없애지 않고 새 tab을 만들며, 이미 열린 canonical path는 중복 buffer를 만들지 않고 기존 tab을 활성화한다. tab과 window title은 파일 이름을 표시하고 editor revision이 저장된 revision보다 새로우면 AppKit document-edited 상태와 dirty tab 표시가 유지된다.

macOS File menu는 `Open…` (`⌘O`), `Save` (`⌘S`), `Save As…` (`⇧⌘S`)를 제공한다. `NSOpenPanel`/`NSSavePanel`은 Presentation adapter에만 있고 Application use case에는 AppKit type이 없다. Finder file URL drag/drop도 같은 open use case를 통과한다.

red-window close와 Cmd-Q는 같은 serialized dirty-document review를 사용한다. 각 dirty tab은 Save/Discard/Cancel 중 하나가 확정될 때까지 종료되지 않는다. Save/Save As 또는 persistence가 실패하면 window/application은 열린 채로 남고, Cancel은 live buffer를 유지한다. Cmd-Q의 비동기 panel/save 동안 App delegate는 `.terminateLater`를 반환하고 최종 결정을 `reply(toApplicationShouldTerminate:)`로 전달한다.

Notepad++ 대응 근거는 `notepad-plus-plus/PowerEditor/src/menuCmdID.h:25-31`, `Notepad_plus.rc:448`, `NppCommands.cpp:222`, `NppCommands.cpp:441-450`의 Open/Save/Save As command surface다. encoding과 EOL을 buffer metadata로 기억하는 동작은 `ScintillaComponent/Buffer.h:219-222`, `ScintillaComponent/Buffer.cpp:69-84`, `Buffer.cpp:2083-2096`에 대응한다. Duckpad는 Windows dialog/API를 복사하지 않고 native panel, canonical POSIX path와 atomic sibling replacement로 변환한다. 참고 tree의 어떤 파일도 제품 source로 복사하거나 version 관리하지 않는다.

## Architecture and authority

의존성은 기존 inward rule을 유지한다.

- `DuckpadDomain`: `FileBinding`은 `ScratchDocument`와 `BufferMetadata` 밖에서 canonical path, encoding, BOM, EOL, last-observed `FileIdentity`를 보관한다. Save As는 DocumentID/BufferID를 유지한 채 binding만 교체한다.
- `DuckpadApplication`: `TextFileStore` port, strict `TextFileCodec`, `FileDocumentUseCase`가 open/save/conflict transaction을 직렬화한다. live text는 계속 EditorPort adapter가 소유하며 save에서만 explicit snapshot을 요구한다. open/reload는 explicit `install` boundary를 사용한다.
- `DuckpadInfrastructure`: `LocalTextFileStore`가 blocking syscall을 utility detached task에서 실행한다.
- `DuckpadPresentation`: native panels, external-change alert, menu action routing, title/dirty 표시와 file drop을 담당한다.
- `DuckpadApp`: production `ScintillaEditorAdapter`, local store, file use case와 native panels를 조립한다.

`WorkspaceChange.tabUpdated`와 persistence-only event는 editor content를 다시 display하지 않는다. 따라서 일반 keystroke가 full snapshot/reload를 유발하지 않으며, Scintilla의 bounded incremental notification 경계를 보존한다.

## Encoding and line endings

읽기는 다음 순서로 fail-closed 감지한다.

1. `EF BB BF`: UTF-8 BOM
2. `FF FE`: UTF-16 little-endian BOM
3. `FE FF`: UTF-16 big-endian BOM
4. BOM 없음: strict UTF-8

잘못된 UTF-8, 홀수 byte UTF-16, 단독 high/low surrogate는 replacement character로 조용히 바꾸지 않고 typed codec error다. 빈 파일은 UTF-8/no-BOM/EOL-none으로 연다. LF, CRLF, CR 및 mixed 상태를 감지하며 normal save는 원문 text와 encoding/BOM을 그대로 encode한다. `TextFileConversion`을 넘긴 explicit save만 선택한 encoding/BOM/EOL로 변환한다. Korean, emoji와 combining scalar는 byte-exact codec round-trip test 대상이다.

auto detection에서 BOM 없는 bytes는 계속 strict UTF-8로만 해석한다. 사용자가 encoding을 명시한 `decode(_:assuming:)` 및 file-open API만 BOM 없는 UTF-16LE/BE를 허용하며, endian별 surrogate validation은 동일하게 적용한다. explicit EOL/encoding conversion으로 갱신된 `FileBinding`은 이후 ordinary save에서도 선택한 EOL로 normalize하고 같은 encoding/BOM으로 encode하므로 한 번 선택한 durable format이 되돌아가지 않는다.

## Atomic save and conflicts

저장은 대상과 같은 directory에 예측 불가능한 sibling temp를 `O_EXCL`로 만들고 전체 bytes를 쓴 뒤 temp `fsync`와 Darwin `F_FULLFSYNC`를 모두 확인한다. 새 대상은 `renameatx_np(..., RENAME_EXCL)`로만 publish하므로 temp sync 뒤 다른 process가 파일을 만들어도 덮어쓰지 않는다. 기존 대상은 `RENAME_SWAP`으로 후보와 현재 경로를 원자 교환하고, 밀려난 실제 inode/mtime/hash가 expected identity와 정확히 같을 때만 commit한다. 다르면 즉시 swap-back, candidate unlink, directory sync 후 conflict를 반환한다.

swap 뒤에는 displaced original을 삭제하기 전에 parent directory open/fsync/close를 모두 검사한다. 첫 directory durability 단계가 실패하면 retained original로 swap-back하고 다시 sync한다. 성공 결과는 `FileWriteReceipt(.durable)`뿐이다. 실패는 original-restored, replacement-visible/durability-uncertain, filesystem-state-uncertain으로 구분하며 복구 파일이 남으면 typed `recoveryPath`를 제공한다. 어떤 uncertain 결과도 binding을 갱신하거나 dirty를 지우지 않는다.

binding의 identity는 canonical path, device/inode, byte count, nanosecond mtime와 SHA-256 content token을 포함한다. normal save 직전에 현재 identity가 마지막 open/save identity와 다르면 overwrite하지 않고 `.conflict`를 반환한다. UI는 다음 명시적 선택만 허용한다.

- **Overwrite:** 현재 live snapshot을 의도적으로 대상에 쓴다.
- **Reload:** 외부 bytes를 strict decode하고 같은 document/buffer의 revision을 올린 뒤 editor에 install한다.
- **Cancel:** live text와 dirty state를 유지한다.

save I/O 중 추가 edit가 들어와도 저장한 snapshot revision과 현재 revision이 같을 때만 clean 처리한다. 더 새 revision은 binding의 새 disk identity를 받되 dirty로 남아 accepted input을 잃지 않는다.

## Files

- `Sources/DuckpadDomain/FileBinding.swift`, `ScratchSession.swift`
- `Sources/DuckpadApplication/FilePorts.swift`, `FileDocumentUseCase.swift`, `ScratchWorkspaceUseCase.swift`
- `Sources/DuckpadInfrastructure/LocalTextFileStore.swift`
- `Sources/DuckpadPresentation/FilePanels.swift`, `ApplicationTerminationCoordinator.swift`, `DuckpadWindowController.swift`
- `Sources/DuckpadApp/DuckpadMain.swift`
- `Tests/DuckpadApplicationTests/TextFileCodecTests.swift`, `FileDocumentUseCaseTests.swift`
- `Tests/DuckpadInfrastructureTests/LocalTextFileStoreTests.swift`
- `Tests/DuckpadPresentationTests/FileCommandRoutingTests.swift`

## Validation contract

```sh
swift build
swift test
swift build -c release
swift test -c release

fresh_dir="$(mktemp -d)"
swift build --scratch-path "$fresh_dir/build"
swift test --scratch-path "$fresh_dir/test"

smoke_file="$(mktemp)"
printf '한글🙂\r\n' > "$smoke_file"
DUCKPAD_SMOKE_FILE="$smoke_file" DUCKPAD_SMOKE_EXIT=1 swift run DuckpadApp
```

Acceptance requires strict codec round trips for every supported encoding/BOM/EOL combination, empty and malformed input tests, atomic rollback, stale external modification protection, duplicate open, save-as binding, native panel routing, all prior Phase 1/2 tests, release and clean scratch builds, and a noninteractive file round-trip smoke.

## Remaining scope

Phase 3 does not yet implement legacy 8-bit code pages, encoding heuristics without BOM, file coordination/iCloud, filesystem watching, recent files, save-all, permissions/xattrs preservation, directory/workspace open, or recovery across process restarts. These are later parity slices rather than silent fallbacks in this one.

## Agent Work Log

### 2026-09-02 — Phase 3 builder

- **Agent/role:** `/root/philosophy_parity`, authenticated product builder.
- **Input:** parent Phase 3 file vertical-slice requirements and current Phase 2 clean HEAD. Existing unstaged `00-wiki-index.md`, `04-implementation-foundation.md`, and `scripts/vendor_scintilla_5_6_6.sh` were preserved.
- **Decisions:** keep stable file metadata separate from Document/Buffer; retain Scintilla as live-text authority; use strict Unicode decoding; serialize file operations; compare content token as well as stat metadata; require explicit overwrite/reload/cancel; keep dirty when a newer edit races a completed save.
- **Implementation:** added clean architecture ports/use cases, codec, atomic adapter, native command/panel/drop routing, title/dirty state, close-save path and environment-driven smoke.
- **Notepad++ boundary:** source paths were read only as behavior evidence. No reference-tree file was changed, copied, staged or committed.
- **Validation:** targeted Domain tests passed 7/7; initial file/codec/infrastructure tests passed 8/8; AppKit command-routing test passed after eliminating a reentrant editor display on `tabUpdated`; the final save-race regression increases the complete suite to 56 tests.
- **Final results:** `swift build` PASS; debug `swift test` 56/56 PASS; `swift build -c release` PASS; release `swift test -c release` 56/56 PASS. Fresh scratch build at `/tmp/duckpad-phase3-build.q9dpgh` PASS and fresh scratch test at `/tmp/duckpad-phase3-test.ZkSBOH` 56/56 PASS. `DUCKPAD_SMOKE_FILE=/tmp/duckpad-phase3-smoke.g37dZC DUCKPAD_SMOKE_EXIT=1 swift run DuckpadApp` opened the real production Scintilla window, completed noninteractive open/save, printed the success receipt and exited 0; file SHA-256 stayed `510b7be31dbc89eb0b7293f192c946e0538d2675ea31e3936d18eb257dd15849` before/after.
- **Git:** no stage or commit in this task.

### 2026-09-02 — P3-01..P3-05 review remediation

- **Agent/role:** `/root/philosophy_parity`, focused Phase 3 remediation builder; the independent review verdict is not changed by this work log.
- **Review input:** `reviews/2026-09-02-phase-3-file-io-code-review.md` P3-01 through P3-05.
- **P3-01 evidence:** replaced check-then-rename with Darwin `RENAME_EXCL` for absent targets and `RENAME_SWAP` plus displaced-file identity validation for existing targets. Real-store fault injection changes/creates the destination after temp full-sync and before commit; both existing and absent race tests preserve the external bytes and return conflict.
- **P3-02 evidence:** `NSWindowDelegate.windowShouldClose` and App delegate termination share the same async multi-tab dirty review. App termination uses `.terminateLater`; Save, Discard, Cancel, failed save and two-dirty-tab ordering have AppKit boundary tests.
- **P3-03 evidence:** auto decode remains BOM/strict while caller-selected UTF-16LE/BE accepts no-BOM bytes. Matching endian, Korean, emoji, combining scalar, CRLF and malformed-data contracts are tested.
- **P3-04 evidence:** file `fsync`/`F_FULLFSYNC` and directory open/fsync/close are checked. Injected failures prove original restoration; injected rollback failure reports filesystem uncertainty plus a live recovery path. Application failure tests prove no new binding and dirty/live editor preservation.
- **P3-05 evidence:** binding-selected EOL is applied on every subsequent save; conversion-to-UTF-16LE/no-BOM/CRLF followed by another edit and ordinary save remains UTF-16LE/no-BOM/CRLF.
- **Validation:** targeted atomic/durability suite PASS; targeted lifecycle 3/3 PASS; targeted encoding/conversion/application durability 3/3 PASS; debug full suite 67/67 PASS; release full suite 67/67 PASS. A clean scratch build completed and the current test tree then passed 67/67 from `/tmp/duckpad-phase3-remediation.G5dqUx`; validation exposed fixed 20 ms assumptions in asynchronous Scintilla recovery and red-close approval tests, which were replaced with condition-based bounded polling (up to 1 second). `DUCKPAD_SMOKE_FILE=/tmp/duckpad-phase3-smoke.g37dZC DUCKPAD_SMOKE_EXIT=1 swift run DuckpadApp` exited 0 with the production Scintilla composition, and the file SHA-256 remained `510b7be31dbc89eb0b7293f192c946e0538d2675ea31e3936d18eb257dd15849` before and after the round trip.
- **Git:** README and Notepad++ reference modifications remain forbidden; no stage or commit.

### 2026-09-02 — P3-02 shared termination review remediation

- **Agent/role:** `/root/philosophy_parity`, final focused Phase 3 builder; the independent final-review verdict is not modified here.
- **Review input:** `reviews/2026-09-02-phase-3-file-io-final-review.md` P3-02 residual only.
- **Ownership decision:** composition creates one `ApplicationTerminationCoordinator`, injects it into `DuckpadWindowController`, and retains that same instance in `DuckpadAppDelegate`. The controller and coordinator no longer carry separate in-flight review gates.
- **Behavior:** red-close and Cmd-Q register replies against one in-flight dirty-document task. Repeated red-close events coalesce to one window-close reply; every pending application-termination caller receives the same result. A mid-review caller joins even when an earlier discard/save has already changed dirty state. Cancel or save failure returns `false` to all callers and leaves the dirty document and window available.
- **Evidence:** deterministic presenter gating covers red-close first then repeated Cmd-Q with Cancel, and repeated Cmd-Q first then red-close with an injected save failure. Each ordering observes exactly one presenter decision, one save attempt at most, consistent application replies, and no approved window close on failure.
- **Validation:** focused lifecycle suite 5/5 PASS; full debug 69/69 PASS; full release 69/69 PASS. `DUCKPAD_SMOKE_FILE=/tmp/duckpad-phase3-smoke.g37dZC DUCKPAD_SMOKE_EXIT=1 swift run DuckpadApp` exited 0, and the file SHA-256 remained `510b7be31dbc89eb0b7293f192c946e0538d2675ea31e3936d18eb257dd15849` before and after the production Scintilla round trip. Fresh dependency validation was intentionally not repeated because this focused change adds no dependency or package-graph change.
- **Git:** no README or Notepad++ reference change; no stage or commit.
