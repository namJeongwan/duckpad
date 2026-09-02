# Phase 4 — Loss-averse session and crash recovery

**Status:** Implemented; review pending
**Date:** 2026-09-02

## Product contract

Duckpad는 정상 종료를 기다리지 않고 편집 중인 scratch와 dirty file buffer를 복구한다. untitled 문서는 파일 선택을 요구하지 않으며, file-backed 문서는 마지막으로 관찰한 canonical path, encoding, BOM, EOL과 external-conflict identity/content token을 그대로 유지한다. 복구가 끝나기 전에는 editor와 tab 입력을 허용하지 않는다.

복구 manifest schema v1은 session ID, tab order와 active tab, tab/document/buffer ID, title/pinned state, revision/dirty metadata, `FileBinding`, next untitled number를 저장한다. 각 buffer는 별도의 strict UTF-8 blob이며 selection anchor/caret, first visible line, horizontal scroll offset와 word-wrap 상태를 함께 기록한다.

## Clean Architecture boundary

- Domain의 `ScratchSession`은 exact-ID recovery initializer로 참조 무결성, buffer 단일 소유권, file binding 중복과 active-tab 유효성을 fail closed로 검사한다.
- Application의 `RecoveryStore` port와 `SessionRecoveryUseCase`가 startup restore, coalesced autosave, explicit flush, reset과 close-before-apply durability를 조정한다.
- Infrastructure의 `LocalRecoveryStore`만 JSON, directory layout, permissions와 Darwin durability syscall을 안다. 모든 filesystem I/O는 utility task에서 실행된다.
- `ScintillaEditorAdapter`는 immutable UTF-8 checkpoint와 bounded delta journal만 main actor에서 갱신한다. autosave capture는 journal을 utility task에서 materialize하며 Scintilla 전체 snapshot message를 호출하지 않는다. full editor snapshot은 기존 explicit file save/activation 경계에만 남는다.
- Presentation은 workspace의 기존 단일 `onChange` 소유권을 유지하면서 render 뒤 recovery hook을 호출한다. 별도 callback이 기존 observer를 덮어쓰지 않는다.

## Atomic generation protocol

기본 root는 `Application Support/Duckpad/Recovery`이며 test/smoke는 반드시 injectable temporary root를 사용한다.

```text
Recovery/
  generations/
    00000000000000000041/
      blobs/<buffer-uuid>.utf8
      manifest.json
    00000000000000000042/
      blobs/<buffer-uuid>.utf8
      manifest.json
```

1. root에서 generation/blob directory까지 새 parent를 0700으로 만들고 각 parent directory를 fsync한다.
2. 모든 blob을 0600, `O_EXCL`로 생성하고 `fsync`와 `F_FULLFSYNC`를 확인한 뒤 `blobs/` directory 자체를 sync한다.
3. blob size/SHA-256와 view state를 포함한 sorted-key manifest를 마지막에 쓰고 sync한다.
4. 완성된 temporary generation을 `RENAME_EXCL`로 publish한 뒤 generations directory를 fsync한다.
5. 같은 generation winner가 있으면 전체 archive를 load/validate한다. byte-equivalent archive만 superseded이며 다른 archive는 collision error다.
6. current와 previous known-good generation만 보존한다. newest manifest/blob가 missing, truncated, invalid UTF-8, size/hash mismatch 또는 참조 불일치면 이전 valid generation으로 fallback한다. valid fallback을 확보한 뒤에만 corrupt/new temporary orphan을 제거하고 directory를 다시 sync하여 다음 autosave가 치유할 수 있게 한다.

Manifest가 durable되기 전에는 새 generation을 discoverable로 보지 않는다. publish 뒤 sync 전에 중단된 generation은 restart 시 전체 hash/reference validation을 통과할 때만 사용할 수 있다.

## Lifecycle and loss ordering

- Startup은 recovery load와 모든 editor buffer/view-state install을 마친 다음 workspace를 `.ready`로 publish한다.
- 연속 편집은 250 ms debounce로 합쳐지며 crash safety는 window/app 종료 callback에 의존하지 않는다.
- autosave 중 더 새 edit가 들어오면 captured change serial을 비교해 후속 generation을 예약하므로 새 edit는 dirty로 남고 다음 archive에 포함된다. 모든 recovery commit/reset은 하나의 직렬 operation gate를 통과한다.
- red-close, Cmd-Q와 clean termination도 하나의 shared termination coordinator에서 final recovery flush를 await하고 `.terminateLater`로 reply한다. final flush는 먼저 editor input을 잠그고 앞선 autosave를 기다린 뒤 change serial이 안정될 때까지 capture/commit을 반복한다. window resign도 explicit flush한다.
- explicit discard/close candidate는 recovery manifest commit이 성공한 뒤에만 live workspace에 적용된다. 실패하면 tab/text/dirty를 유지하므로 stale archive resurrection과 accepted-input 삭제를 피한다.
- 모든 generation이 corrupt인 startup은 입력을 disabled로 유지하면서 typed load failure와 retry action을 banner에 표시한다. 사용자가 retry하면 corrupt recovery root를 명시적으로 reset하고 새 scratch startup을 다시 수행한다.
- 내부 `reset()`은 opt-out/reset 경계로 recovery root를 제거하고 parent directory를 sync한다. UI command 노출은 후속 단계다.

## Files

- `Sources/DuckpadApplication/RecoveryPorts.swift`, `SessionRecoveryUseCase.swift`, `ScratchWorkspaceUseCase.swift`, `Ports.swift`
- `Sources/DuckpadDomain/ScratchSession.swift`, `FileBinding.swift`
- `Sources/DuckpadInfrastructure/LocalRecoveryStore.swift`
- `Sources/DuckpadEditorAdapter/ScintillaEditorAdapter.swift`
- `Vendor/Scintilla/5.6.6/bridge/include/DuckpadScintillaBridge.h`, `bridge/DuckpadScintillaBridge.mm`
- `Sources/DuckpadPresentation/DuckpadWindowController.swift`, `ApplicationTerminationCoordinator.swift`
- `Sources/DuckpadApp/DuckpadMain.swift`
- `tests/DuckpadApplicationTests/SessionRecoveryUseCaseTests.swift`
- `tests/DuckpadInfrastructureTests/LocalRecoveryStoreTests.swift`
- `tests/DuckpadEditorAdapterTests/ScintillaEditorAdapterTests.swift`
- `tests/DuckpadPresentationTests/FileCommandRoutingTests.swift`

## Validation contract

```sh
swift build
swift test
swift build -c release
swift test -c release

fresh_dir="$(mktemp -d)"
swift build --scratch-path "$fresh_dir/build"
swift test --scratch-path "$fresh_dir/test"

recovery_root="$(mktemp -d)/recovery"
DUCKPAD_RECOVERY_ROOT="$recovery_root" \
DUCKPAD_RECOVERY_SMOKE_WRITE='crash 한글🙂' swift run DuckpadApp
# expected forced exit: 86
DUCKPAD_RECOVERY_ROOT="$recovery_root" \
DUCKPAD_RECOVERY_SMOKE_VERIFY='crash 한글🙂' swift run DuckpadApp
```

## Remaining scope

현재 slice는 process-wide single-window recovery에 집중한다. iCloud/file coordination, encrypted-at-rest recovery, cross-device sync, user-facing recovery browser, configurable debounce, multi-window manifests와 recovery quota UI는 후속 범위다. `ScratchSession`의 synthesized Codable disk representation은 schema v1 manifest 내부에 version으로 감싸져 있지만, 별도 migration DTO로 분리하는 것은 후속 hardening 대상이다.

## Agent Work Log

### 2026-09-02 — Phase 4 recovery builder

- **Agent/role:** `/root/philosophy_parity`, authenticated product builder; 독립 reviewer 역할을 수행하지 않는다.
- **Input:** Phase 4 loss-averse session/crash-recovery 요구와 current Phase 3 commit. 기존 unstaged `docs/wiki/00-wiki-index.md`, `docs/wiki/04-implementation-foundation.md`, `scripts/vendor_scintilla_5_6_6.sh`를 보존했다.
- **Key decisions:** editor가 live text authority를 유지하고 recovery는 bounded edit로 갱신한 UTF-8 COW snapshot을 받는다. generation directory 자체를 commit 단위로 사용하고 manifest를 마지막에 쓴다. current+previous를 유지하며 fallback이 검증된 뒤에만 corrupt/orphan을 정리한다. close/discard는 recovery durability를 live-session apply보다 앞에 둔다.
- **Implementation:** recovery port/use case, exact session restore, local generation store, native Scintilla view state, startup/autosave/final flush/reset, production Application Support composition과 two-launch forced-exit smoke를 추가했다.
- **Validation evidence:** recovery-focused 19/19 PASS; debug build와 full test 86/86 PASS; release build와 full test 86/86 PASS; 독립 scratch path의 fresh debug build와 full test 86/86 PASS. Fresh build에는 upstream Scintilla Cocoa의 macOS 12 deprecation warning만 있었고 오류는 없었다.
- **Smoke evidence:** `/tmp/duckpad-phase4-smoke.AIZ7p9/recovery`에서 write launch가 autosave 후 graceful delegate를 거치지 않고 exit 86, verify launch가 `crash 한글🙂`와 1 tab을 복구하고 exit 0.
- **Commands:** `swift build`; `swift test`; `swift build -c release`; `swift test -c release`; `swift build --scratch-path /tmp/duckpad-phase4-fresh.moAbd0/build`; `swift test --scratch-path /tmp/duckpad-phase4-fresh.moAbd0/test`; 위 `DUCKPAD_RECOVERY_SMOKE_WRITE`/`DUCKPAD_RECOVERY_SMOKE_VERIFY` 두 launch.
- **Boundaries:** 모든 persistence test는 UUID 기반 `/tmp` root만 사용한다. forbidden-path 검사에서 README path 0건, tracked gitlink 0건, staged path 0건, ignored Notepad++ reference worktree clean을 확인했다. README와 Notepad++ reference를 변경하지 않았고 stage/commit하지 않았다.

### 2026-09-02 — P4-01..P4-06 code-review remediation

- **Agent/role:** `/root/philosophy_parity`, product remediation builder; reviewer verdict를 변경하지 않는다.
- **Input:** independent review `reviews/2026-09-02-phase-4-session-recovery-code-review.md`의 P4-01..P4-06만 수정했다.
- **P4-01:** recovery store operation을 직렬화하고 final termination flush가 input을 잠근 채 기존 blocked autosave 뒤 최신 stable change serial을 durable하게 만들도록 했다. blocked first commit 중 accepted edit가 들어온 adversarial test가 최신 revision/text durability 전에는 종료 승인을 반환하지 않음을 검증한다.
- **P4-02:** 모든 blob file sync 뒤 manifest 작성 전에 `blobs/` directory를 sync한다. injected sync failure는 manifest/final generation을 publish하지 못한다.
- **P4-03:** recovered tab의 document ownership도 one-to-one으로 강제한다. duplicate document manifest load가 fail closed되고 정상 close 뒤 남은 tab/document/buffer가 유효함을 검증한다.
- **P4-04:** decoded view coordinates의 음수, blob 초과, UTF-8 continuation-byte 위치를 거절해 previous generation으로 fallback한다. adapter 직접 설치 경계도 값을 clamp/UTF-8 boundary 정규화하여 `UInt` trap을 제거했다.
- **P4-05:** per-keystroke contiguous `Data.replaceSubrange`를 제거하고 immutable base + bounded delta journal로 교체했다. Application이 utility task에서 materialize하고 durable acknowledgment 뒤 journal prefix를 compact한다. 1/10/50 MiB 중앙 1-byte edit의 journal work가 동일하고 native snapshot read가 0임을 검증한다.
- **P4-06:** corrupt-only load 실패를 controller의 visible persistence error/retry 경계로 전달한다. 실패 중 editor는 disabled이고 explicit reset+retry 뒤 빈 scratch가 ready/editable해진다.
- **Validation:** targeted remediation 9 test functions PASS(`incompleteGenerationNeverReplacesPrevious`의 4 fault arguments 포함); `swift build`와 debug full 94/94 PASS; `swift build -c release`와 release full 94/94 PASS; fresh scratch build와 full 94/94 PASS. Fresh compile warning은 upstream Scintilla Cocoa macOS deprecation뿐이다.
- **Smoke:** `/tmp/duckpad-phase4-remediation-smoke.N4mR2X/recovery`에서 `remediated crash 한글🙂` write process가 autosave 뒤 exit 86, 두 번째 process가 동일 text와 1 tab을 복구하고 exit 0.
- **Safety:** README/Notepad++ reference/reviewer verdict 문서를 수정하지 않았고 stage/commit하지 않았다.
