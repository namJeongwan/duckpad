# Fold State Recovery and Accessible Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve pane-specific Scintilla fold state across recovery and expose lightweight folding through native keyboard, VoiceOver, menu, and Command Palette controls.

**Architecture:** DuckpadApplication owns a bounded `FoldRecoveryState` value and a folding port; the Duckpad-owned Objective-C++ bridge wraps only existing Scintilla/Lexilla fold messages. `ScintillaEditorAdapter` owns pane identity and pending recovery, while Presentation routes native commands and autosave without treating folds as document edits.

**Tech Stack:** Swift 6, AppKit, Swift Testing, Objective-C++17, vendored Scintilla 5.6.6, vendored Lexilla 5.5.3.

**Spec:** `docs/superpowers/specs/2026-09-04-fold-state-recovery-design.md`

## Global Constraints

- Use Scintilla/Lexilla as the only folding engine; add no parser, language server, background worker, or dependency.
- Keep Plain Text and documents above the existing language `maximumStyleBytes` threshold editable with every fold expanded and folding commands disabled.
- Store at most 10,000 sorted, unique, nonnegative contracted header lines per pane.
- Fold operations must not change UTF-8 bytes, document revision, dirty state, selection, Undo, or Redo.
- Preserve existing broad language highlighting and use `SC_AUTOMATICFOLD_CHANGE` so edits cannot strand hidden descendants.
- One source file contains one primary component or value.
- Do not stage or modify the pre-existing user work in `docs/wiki/04-implementation-foundation.md` or `scripts/vendor_scintilla_5_6_6.sh`.
- Do not push until the exact final candidate has passed independent code review with Critical, Important, and Minor findings all at zero.

## File map

- Create `Sources/DuckpadApplication/FoldRecoveryState.swift`: bounded canonical recovery value.
- Create `Sources/DuckpadApplication/FoldingEditorPort.swift`: application-facing fold capability and command contract.
- Modify `Sources/DuckpadApplication/RecoveryPorts.swift`: add one `foldState` to each pane's view state and backward-compatible coding.
- Modify `Vendor/Scintilla/5.6.6/bridge/include/DuckpadScintillaBridge.h`: typed callbacks, queries, commands, and recovery methods.
- Modify `Vendor/Scintilla/5.6.6/bridge/DuckpadScintillaBridge.mm`: Scintilla fold implementation and post-idle recovery signal.
- Modify `Vendor/Scintilla/5.6.6/PROVENANCE.md`: document that the changed bridge remains Duckpad-owned glue, not an upstream patch.
- Modify `Sources/DuckpadEditorAdapter/ScintillaEditorAdapter.swift`: pane-specific capture/restore, pending-state ownership, stable focus routing, and accepted-edit invalidation.
- Modify `Sources/DuckpadPresentation/DuckpadMainMenuFactory.swift`: native View > Folding submenu and accessibility labels.
- Modify `Sources/DuckpadPresentation/DuckpadWindowController.swift`: command routing, validation, recovery callback, and teardown.
- Modify `Sources/DuckpadApp/DuckpadMain.swift`: extend the production language smoke with real folding commands.
- Create `Tests/DuckpadApplicationTests/FoldRecoveryStateTests.swift`: value and archive compatibility tests.
- Create `Tests/DuckpadEditorAdapterTests/FoldingEditorAdapterTests.swift`: bridge and adapter fold/recovery regressions.
- Create `Tests/DuckpadPresentationTests/FoldingPresentationTests.swift`: menu, validation, palette, pane focus, and teardown tests.
- Modify `Benchmarks/DuckpadPerformanceBenchmark/BenchmarkMain.swift`: measured 10,000-fold recovery fixture.
- Modify `Benchmarks/DuckpadPerformanceBenchmark/performance-budgets.v1.json`: frozen sixth metric with a 250 ms maximum.
- Modify `docs/DASHBOARD.md`, `docs/wiki/05-scintilla-integration.md`, and `docs/wiki/10-language-support.md`: delivery and validation evidence.

---

### Task 1: Bounded pane recovery state

**Files:**
- Create: `Sources/DuckpadApplication/FoldRecoveryState.swift`
- Modify: `Sources/DuckpadApplication/RecoveryPorts.swift`
- Create: `Tests/DuckpadApplicationTests/FoldRecoveryStateTests.swift`

**Interfaces:**
- Consumes: existing `EditorViewState` and `SecondaryEditorViewState` Codable archives.
- Produces: `FoldRecoveryState.init(contractedHeaderLines: [Int])`, `FoldRecoveryState.maximumContractedHeaderCount`, and `foldState` on both view-state values.

- [ ] **Step 1: Write failing canonicalization and compatibility tests**

```swift
import DuckpadApplication
import Foundation
import Testing

@Test func foldRecoveryStateCanonicalizesValidLines() {
    #expect(FoldRecoveryState(contractedHeaderLines: [4, 1, 4, -1, 2]).contractedHeaderLines == [1, 2, 4])
}

@Test func legacyEditorViewStateDefaultsBothPanesToNoFolds() throws {
    let data = Data(#"{"anchorUTF8":0,"caretUTF8":0,"firstVisibleLine":0,"horizontalScrollOffset":0,"wordWrapEnabled":true,"splitOrientation":"sideBySide","secondaryViewState":{"anchorUTF8":0,"caretUTF8":0,"firstVisibleLine":0,"horizontalScrollOffset":0,"wordWrapEnabled":true}}"#.utf8)
    let decoded = try JSONDecoder().decode(EditorViewState.self, from: data)
    #expect(decoded.foldState == FoldRecoveryState())
    #expect(decoded.secondaryViewState?.foldState == FoldRecoveryState())
}

@Test func foldRecoveryArchiveRejectsNegativeAndOversizedArrays() {
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(FoldRecoveryState.self, from: Data("[-1]".utf8))
    }
    let oversized = try! JSONEncoder().encode(
        Array(0...FoldRecoveryState.maximumContractedHeaderCount)
    )
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(FoldRecoveryState.self, from: oversized)
    }
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `swift test --filter FoldRecoveryStateTests`

Expected: compilation fails because `FoldRecoveryState` and `foldState` do not exist.

- [ ] **Step 3: Implement the minimal bounded value and Codable wiring**

```swift
public struct FoldRecoveryState: Codable, Equatable, Sendable {
    public static let maximumContractedHeaderCount = 10_000
    public let contractedHeaderLines: [Int]

    public init(contractedHeaderLines: [Int] = []) {
        self.contractedHeaderLines = Array(
            Set(contractedHeaderLines.lazy.filter { $0 >= 0 })
        ).sorted().prefix(Self.maximumContractedHeaderCount).map { $0 }
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.singleValueContainer().decode([Int].self)
        guard values.count <= Self.maximumContractedHeaderCount,
              values.allSatisfy({ $0 >= 0 }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Fold headers must be nonnegative and bounded"))
        }
        contractedHeaderLines = Array(Set(values)).sorted()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(contractedHeaderLines)
    }
}
```

Add `foldState: FoldRecoveryState = .init()` to both initializers, decode with `decodeIfPresent`, and encode it in both view states. Extend the existing adapter `sanitized(_:for:)` path to drop lines outside the recovered line count in Task 3.

Add tests named `initializerTruncatesAtExactlyTenThousand`,
`decoderAcceptsExactlyTenThousand`, and
`decoderCanonicalizesUnsortedDuplicates`. Their hand-derived expectations are
`0..<10_000`, `0..<10_000`, and `[1, 2, 4]` respectively.

- [ ] **Step 4: Run focused and recovery suites and verify GREEN**

Run: `swift test --filter FoldRecoveryStateTests && swift test --filter SessionRecoveryUseCaseTests && swift test --filter LocalRecoveryStoreTests`

Expected: all selected tests pass, including legacy fixtures.

- [ ] **Step 5: Record the task checkpoint without pushing**

Stage only the three Task 1 files, run `git diff --cached --check`, prepare a signed candidate with `chore: add bounded fold recovery state`, obtain independent review receipt, and commit through `scripts/review/local_commit.py`. Do not push.

---

### Task 2: Typed Scintilla folding façade

**Files:**
- Modify: `Vendor/Scintilla/5.6.6/bridge/include/DuckpadScintillaBridge.h`
- Modify: `Vendor/Scintilla/5.6.6/bridge/DuckpadScintillaBridge.mm`
- Modify: `Vendor/Scintilla/5.6.6/PROVENANCE.md`
- Create: `Tests/DuckpadEditorAdapterTests/FoldingEditorAdapterTests.swift`

**Interfaces:**
- Consumes: `SCI_CONTRACTEDFOLDNEXT`, `SCI_GETFOLDLEVEL`, `SCI_GETFOLDEXPANDED`, `SCI_GETFOLDPARENT`, `SCI_FOLDLINE`, `SCI_FOLDALL`, `SCI_GETENDSTYLED`, `SCI_COLOURISE`, and `SCI_SETAUTOMATICFOLD`.
- Produces: `onFoldStateChange`, `onFoldRecoveryProgress`, `contractedFoldHeaderLinesWithMaximumCount:`, `restoreContractedFoldHeaderLines:`, `canCollapseCurrentFold`, `canExpandCurrentFold`, `hasContractedFolds`, and four Boolean command methods.

- [ ] **Step 1: Write failing native behavior tests**

```swift
@MainActor
private func hostedCPPView(
    _ text: String,
    maximumStyleBytes: UInt = 2_000_000
) throws -> (NSWindow, DPScintillaEditorView) {
    _ = NSApplication.shared
    ScintillaEditorAdapter.prepareResources()
    let frame = NSRect(x: 0, y: 0, width: 700, height: 400)
    let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
    let view = DPScintillaEditorView(frame: frame)
    window.contentView = view
    window.makeKeyAndOrderFront(nil)
    try view.loadUTF8(Data(text.utf8), revision: 7)
    #expect(view.applyLexerNamed("cpp", keywords: ["int", "if", "return"], tabWidth: 4, useTabs: false, folding: true, braceMatching: true, maximumStyleBytes: maximumStyleBytes))
    return (window, view)
}

@Test @MainActor func typedFoldCommandsAndCapturePreserveDocumentState() throws {
    let (window, view) = try hostedCPPView("int main() {\n  if (true) {\n    return 0;\n  }\n}\n")
    defer { window.orderOut(nil) }
    view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 0))
    let before = (view.contentUTF8, view.revision, view.caretUTF8Position, view.canUndo)
    #expect(view.canCollapseCurrentFold)
    #expect(view.collapseCurrentFold())
    #expect(view.contractedFoldHeaderLines(maximumCount: 10) == [0])
    #expect(!view.collapseCurrentFold())
    #expect((view.contentUTF8, view.revision, view.caretUTF8Position, view.canUndo) == before)
}

@Test @MainActor func restoreRetriesAfterFinalIdleFoldChunkWithoutPublishingUserChange() async throws {
    let prefix = String(repeating: "// 0123456789abcdef\n", count: 16_384)
    let targetLine = prefix.reduce(into: 0) { if $1 == "\n" { $0 += 1 } }
    let (window, view) = try hostedCPPView(prefix + "int deep() {\n  return 1;\n}\n")
    defer { window.orderOut(nil) }
    var changes = 0
    var pending = view.restoreContractedFoldHeaderLines([NSNumber(value: targetLine)])
    view.onFoldStateChange = { changes += 1 }
    view.onFoldRecoveryProgress = {
        pending = view.restoreContractedFoldHeaderLines(pending)
    }
    let deadline = Date(timeIntervalSinceNow: 2)
    while !pending.isEmpty, Date() < deadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    #expect(pending.isEmpty)
    #expect(view.contractedFoldHeaderLines(maximumCount: 10).map(\.intValue) == [targetLine])
    #expect(changes == 0)
}

@Test @MainActor func automaticFoldChangeRevealsChildrenWhenHeaderIsEditedAway() throws {
    let (window, view) = try hostedCPPView("int main() {\n  return 0;\n}\n")
    defer { window.orderOut(nil) }
    view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 0))
    #expect(view.collapseCurrentFold())
    var foldChanges = 0
    view.onFoldStateChange = { foldChanges += 1 }
    try view.replaceUTF8Range(
        NSRange(location: "int main() ".utf8.count, length: 1),
        withReplacement: Data(" ".utf8),
        expectedRevision: 7,
        resultingRevision: 8
    )
    #expect(view.isLineVisible(at: 1))
    #expect(view.isLineVisible(at: 2))
    #expect(foldChanges == 0)
}
```

Before GREEN, also add these one-break tests:

- `contractedFoldIteratorStopsAtCallerCap`: contract three sibling headers,
  request two, and require `[0, 2]` without a full line scan.
- `currentFoldUsesNearestParentFromChildLine`: place the caret on a return line,
  collapse current, and require its immediate `if` header rather than the outer
  function header.
- `gutterCurrentAndAllCommandsPublishExactlyOneChangeEach`: invoke the shared
  margin-toggle path plus all four commands from fresh fixtures; changed states
  publish one callback and repeated no-ops publish zero.
- `restoreRejectsNegativeOutOfRangeAndNonHeaderLines`: pass `[-1, lineCount,
  childLine]` and require no contractions, no pending entries, and no callback.
- `foldCommandsPreserveFullSelectionDirtyRevisionAndUndoRedo`: select the full
  UTF-8 document before each command and require the literal selection, bytes,
  revision, `canUndo`, and `canRedo` tuple unchanged afterward.
- `plainTextAndLargeFileDisableEveryFoldQueryAndCommand`: apply `null` with
  folding false and apply C++ above its style budget; require all capability
  properties and all Boolean commands false with every line visible.
- `failedLexerApplicationRetainsExistingFoldsAndCapability`: start from a
  contracted C++ document, apply a nonexistent lexer, require `false`, then
  require the same lexer name, contracted list, and capabilities.

- [ ] **Step 2: Run the new test file and verify RED**

Run: `swift test --filter FoldingEditorAdapterTests`

Expected: compilation fails because the typed bridge surface is absent.

- [ ] **Step 3: Implement bounded capture, commands, and exact callbacks**

Add block properties and methods to the public header. Pin Swift imports with
`NS_SWIFT_NAME(contractedFoldHeaderLines(maximumCount:))`,
`NS_SWIFT_NAME(restoreContractedFoldHeaderLines(_:))`, and
`NS_SWIFT_NAME(isLineVisible(at:))`. In Objective-C++:

```objective-c++
- (NSArray<NSNumber *> *)contractedFoldHeaderLinesWithMaximumCount:(NSUInteger)maximumCount {
    NSMutableArray<NSNumber *> *lines = [NSMutableArray array];
    NSInteger line = [_scintilla message:SCI_CONTRACTEDFOLDNEXT wParam:0];
    while (line >= 0 && lines.count < maximumCount) {
        [lines addObject:@(line)];
        line = [_scintilla message:SCI_CONTRACTEDFOLDNEXT wParam:(uptr_t)(line + 1)];
    }
    return lines;
}
```

Resolve the current header from the caret line or `SCI_GETFOLDPARENT`. Return `NO` for unsupported/no-op commands. Use `SC_FOLDACTION_CONTRACT_EVERY_LEVEL` for Collapse All and `SC_FOLDACTION_EXPAND` for Expand All. Publish `onFoldStateChange` once only when the contracted set changes. Set `SC_AUTOMATICFOLD_CHANGE` whenever folding is enabled.

- [ ] **Step 4: Implement post-fold recovery progress without an event-mask fanout**

`restoreContractedFoldHeaderLines:` synchronously colours the bounded prefix, contracts proven headers, and returns unresolved lines whose line end exceeds `SCI_GETENDSTYLED`. While unresolved lines exist, enable a private recovery-progress flag. On `SCN_UPDATEUI`, schedule one coalesced `dispatch_async(dispatch_get_main_queue(), ^{ ... })`; the callback runs after the same `Editor::Idle()` finishes `IdleStyle()` and invokes `onFoldRecoveryProgress`. Clear the flag when Swift reports no pending lines. Do not add `SC_MOD_CHANGEFOLD` to `SCI_SETMODEVENTMASK`.

- [ ] **Step 5: Run bridge tests in Debug and Release and verify GREEN**

Run: `swift test --filter FoldingEditorAdapterTests && swift test -c release --filter FoldingEditorAdapterTests && swift test --filter LanguageEditorAdapterTests`

Expected: all selected tests pass; the final idle chunk restores within two seconds; existing highlighting/folding tests stay green.

- [ ] **Step 6: Record provenance and the reviewed checkpoint without pushing**

Document in `PROVENANCE.md` that only Duckpad-owned `bridge/` code changed and no official Scintilla bytes were modified. Stage the four Task 2 files, run `git diff --cached --check`, prepare `feat: add typed Scintilla folding controls`, obtain independent review receipt, and commit through `local_commit.py`. Do not push.

---

### Task 3: Pane-specific adapter recovery and focus ownership

**Files:**
- Create: `Sources/DuckpadApplication/FoldingEditorPort.swift`
- Modify: `Sources/DuckpadEditorAdapter/ScintillaEditorAdapter.swift`
- Modify: `Tests/DuckpadEditorAdapterTests/FoldingEditorAdapterTests.swift`

**Interfaces:**
- Consumes: Task 1 `FoldRecoveryState` and Task 2 typed bridge methods/callbacks.
- Produces: `FoldingEditorPort` with capability properties, four Boolean commands, and `onFoldStateChange`; adapter-owned primary/secondary pending sets and stable last-focused pane identity.

- [ ] **Step 1: Write failing adapter tests for split recovery and edit authority**

```swift
@Test @MainActor func splitPanesRecoverIndependentContractedHeaders() throws {
    let descriptor = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
    let source = ScintillaEditorAdapter()
    source.install(.init(bufferID: descriptor.bufferID, revision: 0, text: "int outer() {\n  if (true) {\n    return 1;\n  }\n}\n"))
    source.display(descriptor)
    #expect(source.applyLanguage(cppFoldConfiguration))
    let primary = try #require(source.activeScintillaView)
    source.split(orientation: .sideBySide)
    let secondary = try #require(source.secondaryScintillaView)
    #expect(primary !== secondary)
    primary.focusEditor()
    primary.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 0))
    #expect(source.collapseCurrentFold())
    secondary.focusEditor()
    secondary.setPrimarySelectionUTF8Range(NSRange(location: "int outer() {\n  ".utf8.count, length: 0))
    #expect(source.collapseCurrentFold())
    let snapshot = try #require(source.recoverySnapshot(for: descriptor.bufferID))
    #expect(snapshot.viewState.foldState.contractedHeaderLines == [0])
    #expect(snapshot.viewState.secondaryViewState?.foldState.contractedHeaderLines == [1])

    let restored = ScintillaEditorAdapter()
    restored.installRecovery(snapshot)
    restored.display(.init(bufferID: descriptor.bufferID, revision: snapshot.revision))
    #expect(restored.applyLanguage(cppFoldConfiguration))
    #expect(restored.activeScintillaView?.contractedFoldHeaderLines(maximumCount: 10).map(\.intValue) == [0])
    #expect(restored.secondaryScintillaView?.contractedFoldHeaderLines(maximumCount: 10).map(\.intValue) == [1])
}

@Test @MainActor func acceptedMutationsClearPendingForBothPanesButRejectedMutationRetainsIt() async throws {
    let fixture = try makeDeepPendingAdapter()
    fixture.adapter.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }
    fixture.primary.insertCommittedText("x")
    #expect(fixture.adapter.recoverySnapshot(for: fixture.buffer.bufferID)?.viewState.foldState == FoldRecoveryState())
    #expect(fixture.adapter.recoverySnapshot(for: fixture.buffer.bufferID)?.viewState.secondaryViewState?.foldState == FoldRecoveryState())

    let rejected = try makeDeepPendingAdapter()
    rejected.adapter.onEdit = { .rejected(currentRevision: $0.expectedRevision) }
    rejected.primary.insertCommittedText("x")
    await Task.yield()
    let recovery = try #require(rejected.adapter.recoverySnapshot(for: rejected.buffer.bufferID))
    #expect(recovery.viewState.foldState.contractedHeaderLines == [rejected.deepHeaderLine])
    #expect(recovery.viewState.secondaryViewState?.foldState.contractedHeaderLines == [rejected.deepHeaderLine])
}

@Test @MainActor func pendingHeadersSurviveCaptureBetweenIdleChunks() throws {
    let fixture = try makeDeepPendingAdapter()
    let capture = try #require(fixture.adapter.recoveryCapture(for: fixture.buffer.bufferID))
    #expect(capture.viewState.foldState.contractedHeaderLines == [fixture.deepHeaderLine])
    #expect(capture.viewState.secondaryViewState?.foldState.contractedHeaderLines == [fixture.deepHeaderLine])
}
```

In the same test file, define `cppFoldConfiguration` with `.cpp`, lexer `cpp`,
four-space indentation, folding and brace matching enabled, and a 2,000,000-byte
style budget. Define `makeDeepPendingAdapter()` to create a split adapter from a
recovery snapshot whose primary and secondary fold states contain the exact
header line after a 327,680-byte C++ comment prefix; return the adapter, buffer,
both views, and that line. Add table-driven accepted cases for `replaceActive`,
`replaceActiveBatch`, `undo`, and `redo`, in addition to the direct-input case
shown above, and assert both captured pane states are empty after each accepted
revision commit.

Add `bothPanesCompleteDeepRecoveryAfterFinalIdleChunk`: recover the same deep
header into both panes, show the host window, wait no longer than two seconds,
and require each distinct view's contracted list to equal the one literal line.

- [ ] **Step 2: Run adapter tests and verify RED**

Run: `swift test --filter FoldingEditorAdapterTests`

Expected: compilation fails because `FoldingEditorPort` and adapter recovery support are absent.

- [ ] **Step 3: Add the focused application port**

```swift
@MainActor
public protocol FoldingEditorPort: EditorPort {
    var supportsFolding: Bool { get }
    var canCollapseCurrentFold: Bool { get }
    var canExpandCurrentFold: Bool { get }
    var hasCollapsedFolds: Bool { get }
    var onFoldStateChange: (() -> Void)? { get set }
    @discardableResult func collapseCurrentFold() -> Bool
    @discardableResult func expandCurrentFold() -> Bool
    @discardableResult func collapseAllFolds() -> Bool
    @discardableResult func expandAllFolds() -> Bool
}
```

- [ ] **Step 4: Implement per-view pending recovery and stable focus**

Key pending state by `ObjectIdentifier(DPScintillaEditorView)` so primary and secondary lifetimes cannot collide. Capture `native contracted ∪ pending`, bounded through `FoldRecoveryState`. Restore after each successful `applyLanguage`; bridge progress callbacks retry only that view. A focus callback updates `lastFocusedPane`, and `activeScintillaView` resolves the focused view, then the last focused live view, then primary.

Call one `discardPendingFoldRecovery(bufferID:)` helper only after the accepted state updates in `replaceActive`, `replaceActiveBatch`, and `receive`. This covers direct input, programmatic edits, batches, Undo, and Redo. Rejected paths keep pending state so `recoverPendingBufferIfNeeded` reloads and reapplies the authoritative stored folds.

- [ ] **Step 5: Sanitize lifecycle and unsupported-language behavior**

Filter recovered lines against the document line count. On Plain Text and documents over `maximumStyleBytes`, expand native folds, clear pending state, and return `supportsFolding == false`. A failed lexer creation returns `false` without changing the prior language, folding capability, native folds, or pending state. Clear callbacks and pending identity in `invalidate`, split close, retire, and adapter teardown. Current commands retain unrelated pending lines; Expand All clears pending; Collapse All replaces it with native contracted state.

- [ ] **Step 6: Run adapter/recovery tests in both configurations**

Run: `swift test --filter FoldingEditorAdapterTests && swift test --filter ScintillaEditorAdapterTests && swift test -c release --filter FoldingEditorAdapterTests && swift test -c release --filter ScintillaEditorAdapterTests`

Expected: all new tests pass; any pre-existing isolated failure is reproduced against the parent commit before being classified as baseline.

- [ ] **Step 7: Review and record the adapter checkpoint without pushing**

Stage only the three Task 3 files, run `git diff --cached --check`, prepare `feat: recover pane-specific fold state`, obtain an independent review receipt, and commit through `local_commit.py`. Do not push.

---

### Task 4: Native menu, Command Palette, and VoiceOver controls

**Files:**
- Modify: `Sources/DuckpadPresentation/DuckpadMainMenuFactory.swift`
- Modify: `Sources/DuckpadPresentation/DuckpadWindowController.swift`
- Create: `Tests/DuckpadPresentationTests/FoldingPresentationTests.swift`
- Modify: `Tests/DuckpadEditorAdapterTests/FoldingEditorAdapterTests.swift`

**Interfaces:**
- Consumes: Task 3 `FoldingEditorPort` and the existing recursive Command Palette menu index.
- Produces: four Objective-C selectors, View > Folding submenu, validation, autosave routing, and focus restoration.

- [ ] **Step 1: Write failing menu and routing tests**

```swift
@Test @MainActor func foldingSubmenuHasAccessibleConflictFreeCommands() {
    let fixture = makeFoldingPortControllerFixture()
    let menu = DuckpadMainMenuFactory.make(target: fixture.controller)
    let collapse = recursiveMenuItem(titled: "Collapse Current Block", in: menu)
    #expect(collapse?.keyEquivalent == "[")
    #expect(collapse?.keyEquivalentModifierMask == [.command, .option])
    #expect(collapse?.accessibilityLabel() == "Collapse current code block")
    let expand = recursiveMenuItem(titled: "Expand Current Block", in: menu)
    #expect(expand?.keyEquivalent == "]")
    #expect(expand?.keyEquivalentModifierMask == [.command, .option])
    #expect(expand?.accessibilityLabel() == "Expand current code block")
    let paletteTitles = CommandPaletteRegistry.commands(in: menu).map(\.title)
    #expect(paletteTitles.contains("Collapse Current Block"))
    #expect(paletteTitles.contains("Expand Current Block"))
    #expect(paletteTitles.contains("Collapse All"))
    #expect(paletteTitles.contains("Expand All"))
    #expect(recursiveMenuItem(titled: "Collapse All", in: menu)?.accessibilityLabel() == "Collapse all code blocks")
    #expect(recursiveMenuItem(titled: "Expand All", in: menu)?.accessibilityLabel() == "Expand all code blocks")
}

@Test @MainActor func foldChangeSchedulesOneRecoverySaveAndTeardownClearsCallback() async {
    let fixture = await makeFoldingPortControllerFixture(debounce: .zero)
    fixture.adapter.onFoldStateChange?()
    await fixture.recoveryUseCase.waitForPendingAutosave()
    #expect(await fixture.recoveryStore.commitCount == 1)
    fixture.controller.close()
    #expect(fixture.adapter.onFoldStateChange == nil)
}
```

Define `recursiveMenuItem(titled:in:)` as a depth-first traversal of `NSMenu.items`.
Define a focused `FoldingEditorFake` in the Presentation test file that fully
implements `EditorPort` and `FoldingEditorPort`, owns literal capability flags
and invocation counters, and returns a real empty recovery snapshot. It is not
a mock of Scintilla; it isolates controller policy. Define a local actor
`RecordingRecoveryStore` implementing the complete `RecoveryStore` contract
and exposing its committed archive count. `makeFoldingPortControllerFixture`
starts a real workspace, builds a real `SessionRecoveryUseCase` with the fake
editor and recording store, injects both into `DuckpadWindowController`, and
returns all four values.

Add table-driven `allFoldMenuValidationStatesMatchPortCapabilities` covering
all four selectors in enabled and disabled states, plus workspace-not-ready and
Plain Text (`supportsFolding == false`) cases. Assert the controller calls only
the matching Boolean command and refocuses the editor only when it returns
true.

In `FoldingEditorAdapterTests.swift`, exercise the real palette and real
Scintilla adapter:

```swift
@Test @MainActor func paletteRoutesFoldToInitiatingSecondaryPaneAndRestoresFocus() async throws {
    let fixture = try await makeRealFoldingControllerFixture(split: true)
    defer { fixture.controller.close() }
    let secondary = try #require(fixture.adapter.secondaryScintillaView)
    secondary.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 0))
    secondary.focusEditor()
    let menu = DuckpadMainMenuFactory.make(target: fixture.controller)
    NSApplication.shared.mainMenu = menu
    fixture.controller.applicationMainMenuDidChange(menu)
    fixture.controller.performShowCommandPalette(nil)
    #expect(fixture.controller.commandPalettePanel.isPresented)
    fixture.controller.commandPalettePanel.setQuery("Collapse Current Block")
    fixture.controller.commandPalettePanel.activateSelectedResult()
    #expect(secondary.contractedFoldHeaderLines(maximumCount: 10).map(\.intValue) == [0])
    #expect(secondary.hasEditorFocus)
}
```

Define `makeRealFoldingControllerFixture(split:)` in that same test file. It
must start `ScratchWorkspaceUseCase(store: InMemorySessionStore())`, require its
active buffer, create `ScintillaEditorAdapter` and `EditorBindingUseCase`,
install/display the literal `"int main() {\n  return 0;\n}\n"`, apply the same
`cppFoldConfiguration` from Task 3, optionally split, and construct
`DuckpadWindowController(workspace:editorAdapter:editorView:automaticallyStarts:)`
with the adapter and `adapter.view`. Call `controller.showAndFocus()` so the
palette and idle styling have a displayed AppKit host. Return the workspace,
binding, controller, adapter, and window-owning controller as one fixture;
the test's `defer { controller.close() }` is its deterministic cleanup.

- [ ] **Step 2: Run presentation tests and verify RED**

Run these separately and preserve both nonzero exit codes:

```bash
swift test --filter FoldingPresentationTests
swift test --filter paletteRoutesFoldToInitiatingSecondaryPaneAndRestoresFocus
```

Expected: both commands fail because the submenu, selectors, controller routing,
and stable real-adapter palette behavior do not exist.

- [ ] **Step 3: Add the native submenu and explicit accessibility labels**

Create a `Folding` submenu below display options. Add:

```swift
add("Collapse Current Block", #selector(DuckpadWindowController.performCollapseCurrentFold(_:)), "[", target, modifiers: [.command, .option], accessibilityLabel: "Collapse current code block", to: foldingMenu)
add("Expand Current Block", #selector(DuckpadWindowController.performExpandCurrentFold(_:)), "]", target, modifiers: [.command, .option], accessibilityLabel: "Expand current code block", to: foldingMenu)
add("Collapse All", #selector(DuckpadWindowController.performCollapseAllFolds(_:)), "", target, modifiers: [], accessibilityLabel: "Collapse all code blocks", to: foldingMenu)
add("Expand All", #selector(DuckpadWindowController.performExpandAllFolds(_:)), "", target, modifiers: [], accessibilityLabel: "Expand all code blocks", to: foldingMenu)
```

Extend the existing `add` helper with an optional accessibility label and keep recursive shortcut-collision checks unchanged.

- [ ] **Step 4: Route validation, recovery, and focus through the folding port**

Each selector guards the matching capability, invokes the Boolean command, and focuses the same adapter-selected pane after success. `validateMenuItem` uses `supportsFolding`, `canCollapseCurrentFold`, `canExpandCurrentFold`, and `hasCollapsedFolds`; Collapse All is enabled whenever folding is supported. During controller setup, assign `onFoldStateChange = { recoveryUseCase?.editorViewStateDidChange() }`; clear it during teardown.

- [ ] **Step 5: Run menu, palette, and broad presentation regressions**

Run: `swift test --filter FoldingPresentationTests && swift test --filter paletteRoutesFoldToInitiatingSecondaryPaneAndRestoresFocus && swift test --filter CommandPalettePresentationTests && swift test --filter TabFlowLayoutTests && swift test -c release --filter FoldingPresentationTests`

Expected: all selected tests pass; the existing recursive palette discovers every submenu command and secondary-pane routing remains stable after its search field takes focus.

- [ ] **Step 6: Review and record the presentation checkpoint without pushing**

Stage only these four Task 4 files: `Sources/DuckpadPresentation/DuckpadMainMenuFactory.swift`, `Sources/DuckpadPresentation/DuckpadWindowController.swift`, `Tests/DuckpadPresentationTests/FoldingPresentationTests.swift`, and `Tests/DuckpadEditorAdapterTests/FoldingEditorAdapterTests.swift`. Run `git diff --cached --check`, prepare `feat: add accessible folding commands`, obtain an independent review receipt, and commit through `local_commit.py`. Do not push.

---

### Task 5: Frozen performance budget and complete delivery proof

**Files:**
- Modify: `Benchmarks/DuckpadPerformanceBenchmark/BenchmarkMain.swift`
- Modify: `Benchmarks/DuckpadPerformanceBenchmark/performance-budgets.v1.json`
- Modify: `Sources/DuckpadApp/DuckpadMain.swift`
- Modify: `docs/DASHBOARD.md`
- Modify: `docs/wiki/05-scintilla-integration.md`
- Modify: `docs/wiki/10-language-support.md`

**Interfaces:**
- Consumes: delivered fold capture/restore API and existing performance runner/report schema.
- Produces: required `fold_recovery_10000` metric with `maximum: 250.0` milliseconds and final evidence.

- [ ] **Step 1: Make the benchmark inventory test fail closed on the missing metric**

Add `fold_recovery_10000` to `expectedMetricIDs` before adding a budget entry or measured value.

Run: `swift run -c release DuckpadPerformanceBenchmark --warm-launch-ms 1`

Expected: exit 2 with `performance budget schema or metric inventory is invalid`.

- [ ] **Step 2: Implement the exact 10,000-fold fixture and measurement**

Build deterministic nested and sibling C++ headers, apply the C++ language configuration, contract exactly 10,000 headers, capture canonical state, restore it into a second shared-document pane, and assert exact count plus pane independence. Measure the complete contract/capture/restore sequence and add:

```swift
"fold_recovery_10000": try measureFoldRecovery10K()
```

Add the JSON entry:

```json
{
  "id": "fold_recovery_10000",
  "unit": "milliseconds",
  "maximum": 250.0,
  "aggregation": "single_contract_capture_restore_of_10000_headers"
}
```

- [ ] **Step 3: Run the frozen six-budget Release gate**

Run: `scripts/run_performance_benchmarks.sh`

Expected: exit 0, report schema 1, exactly six unique measurements, every `passed` value true, and `fold_recovery_10000.measured <= 250.0`.

- [ ] **Step 4: Run complete functional and production validation**

Run, preserving separate logs and exit codes:

```bash
swift build
swift build -c release
swift test --filter FoldRecoveryStateTests
swift test --filter FoldingEditorAdapterTests
swift test --filter FoldingPresentationTests
swift test --filter LanguageEditorAdapterTests
swift test -c release --filter FoldRecoveryStateTests
swift test -c release --filter FoldingEditorAdapterTests
swift test -c release --filter FoldingPresentationTests
swift test -c release --filter LanguageEditorAdapterTests
swift test
swift test -c release
smoke_root="$(mktemp -d /tmp/duckpad-fold-smoke.XXXXXX)"
DUCKPAD_RECOVERY_ROOT="$smoke_root" DUCKPAD_LANGUAGE_SMOKE=1 .build/release/DuckpadApp
rm -rf "$smoke_root"
git diff --check
```

Expected: focused suites, builds, smoke, and diff check pass. If either monolithic suite reproduces the known AppKit signal 11 or the isolated stale replace-reservation baseline, rerun the exact failing test against the Phase 30 parent and record both outputs; do not call it a Phase 31 pass.

Before this gate, extend the existing `DUCKPAD_LANGUAGE_SMOKE` branch in
`DuckpadMain.swift`: after Swift highlighting succeeds, insert a multiline Swift
function, put the caret on its header, require Collapse Current and Expand
Current both succeed, require fold capture to transition `[header] -> []`, and
require bytes/revision unchanged. Then switch to Python and retain the existing
lexer assertion. The command above is the production smoke; no nonexistent
wrapper script is referenced.

- [ ] **Step 5: Update durable documentation and dashboard evidence**

Document pane-specific recovery, typed Scintilla reuse, native keyboard/VoiceOver commands, Plain Text/large-file behavior, six-budget measurements, focused tests, and any honestly reproduced baseline failures. Mark every Phase 31 dashboard item with evidence and the branch push gate still pending.

- [ ] **Step 6: Perform mandatory final independent code review**

Stage the exact final candidate paths, confirm the two protected user paths remain unstaged, and request review of correctness, recovery authority, async/lifetime safety, UTF-8/revision invariants, highlighting preservation, accessibility, performance, and test honesty. Remediate every Critical, Important, and Minor finding and repeat review until all three counts are zero.

- [ ] **Step 7: Commit, audit, and push the exact reviewed candidate**

Run `git diff --cached --check`; prepare a signed candidate with `chore: validate fold recovery delivery`; obtain a fresh receipt for the exact candidate; commit only through `scripts/review/local_commit.py`; audit the resulting commit; then push `feature/fold-state-recovery` and verify its remote SHA equals local HEAD. Never stage the two protected user paths.

- [ ] **Step 8: Complete the dashboard and goal audit**

Confirm every explicit Phase 31 spec requirement has direct source/test/runtime evidence, update `docs/DASHBOARD.md` to `Delivered`, perform the required final doc-only review and signed commit if that status changed after the reviewed code commit, push again, and keep the broader roadmap goal active unless all remaining dashboard work is also proven complete.

## Requirement-to-test checklist

| Approved requirement | Named proof | Task |
| --- | --- | --- |
| Backward decode, validation, canonicalization, 10,000 bound | `legacyEditorViewStateDefaultsBothPanesToNoFolds`, `foldRecoveryArchiveRejectsNegativeAndOversizedArrays`, `initializerTruncatesAtExactlyTenThousand`, `decoderAcceptsExactlyTenThousand`, `decoderCanonicalizesUnsortedDuplicates` | 1 |
| Contracted iteration and caller cap | `contractedFoldIteratorStopsAtCallerCap` | 2 |
| Header/nearest-parent current commands and no-ops | `typedFoldCommandsAndCapturePreserveDocumentState`, `currentFoldUsesNearestParentFromChildLine` | 2 |
| Gutter/current/all exact callback count | `gutterCurrentAndAllCommandsPublishExactlyOneChangeEach` | 2 |
| Restore ignores invalid/non-header lines and emits no callback | `restoreRejectsNegativeOutOfRangeAndNonHeaderLines`, `restoreRetriesAfterFinalIdleFoldChunkWithoutPublishingUserChange` | 2 |
| Final idle chunk and both deep panes restore within two seconds | `restoreRetriesAfterFinalIdleFoldChunkWithoutPublishingUserChange`, `bothPanesCompleteDeepRecoveryAfterFinalIdleChunk` | 2–3 |
| Automatic fold repair reveals descendants | `automaticFoldChangeRevealsChildrenWhenHeaderIsEditedAway` | 2 |
| Accepted edits clear pending; rejected edit retains/reapplies | `acceptedMutationsClearPendingForBothPanesButRejectedMutationRetainsIt` and its direct/programmatic/batch/Undo/Redo table | 3 |
| Pane states stay independent | `splitPanesRecoverIndependentContractedHeaders` | 3 |
| Fold operations preserve bytes/revision/dirty/selection/Undo/Redo | `foldCommandsPreserveFullSelectionDirtyRevisionAndUndoRedo` | 2–3 |
| Plain Text/large fallback disables commands; lexer failure rolls back | `plainTextAndLargeFileDisableEveryFoldQueryAndCommand`, `failedLexerApplicationRetainsExistingFoldsAndCapability` | 2–3 |
| Native menu, four labels, shortcuts, validation, palette, focus | `foldingSubmenuHasAccessibleConflictFreeCommands`, `allFoldMenuValidationStatesMatchPortCapabilities`, `paletteRoutesFoldToInitiatingSecondaryPaneAndRestoresFocus` | 4 |
| Recovery callback and teardown | `foldChangeSchedulesOneRecoverySaveAndTeardownClearsCallback` | 4 |
| 10,000-fold performance ≤250 ms and independence | `fold_recovery_10000` Release benchmark | 5 |
| Real Lexilla highlighting plus folding smoke | extended `DUCKPAD_LANGUAGE_SMOKE=1` executable path | 5 |
