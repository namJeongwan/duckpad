import AppKit
import DuckpadApplication
import DuckpadDomain
@testable import DuckpadEditorAdapter
import DuckpadScintillaBridge
import Foundation
import Testing

@Suite(.serialized)
struct FoldingEditorAdapterTests {
    private let cppFoldConfiguration = EditorLanguageConfiguration(
        languageID: .init(rawValue: "cpp"),
        lexerName: "cpp",
        keywords: ["int if return"],
        indentation: .init(width: 4, useTabs: false),
        folding: true,
        braceMatching: true,
        maximumStyleBytes: 2_000_000
    )

    @MainActor
    private func hostedCPPView(
        _ text: String,
        maximumStyleBytes: UInt = 2_000_000
    ) throws -> (NSWindow, DPScintillaEditorView) {
        _ = NSApplication.shared
        ScintillaEditorAdapter.prepareResources()
        let frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let view = DPScintillaEditorView(frame: frame)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        try view.loadUTF8(Data(text.utf8), revision: 7)
        #expect(view.applyLexerNamed(
            "cpp",
            keywords: ["int", "if", "return"],
            tabWidth: 4,
            useTabs: false,
            folding: true,
            braceMatching: true,
            maximumStyleBytes: maximumStyleBytes
        ))
        return (window, view)
    }

    @MainActor
    private func cleanUp(_ window: NSWindow, _ view: DPScintillaEditorView) {
        window.orderOut(nil)
        view.onFoldStateChange = nil
        view.onFoldRecoveryProgress = nil
    }

    @Test @MainActor
    func typedFoldCommandsAndCapturePreserveDocumentState() throws {
        let (window, view) = try hostedCPPView("int main() {\n  if (true) {\n    return 0;\n  }\n}\n")
        defer { cleanUp(window, view) }
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 0))
        let before = (view.contentUTF8, view.revision, view.caretUTF8Position, view.canUndo)
        #expect(view.canCollapseCurrentFold)
        #expect(view.collapseCurrentFold())
        #expect(view.contractedFoldHeaderLines(maximumCount: 10) == [0])
        #expect(!view.collapseCurrentFold())
        #expect((view.contentUTF8, view.revision, view.caretUTF8Position, view.canUndo) == before)
    }

    @Test @MainActor
    func restoreRetriesAfterFinalIdleFoldChunkWithoutPublishingUserChange() async throws {
        let prefix = String(repeating: "// 0123456789abcdef\n", count: 16_384)
        let targetLine = prefix.reduce(into: 0) { if $1 == "\n" { $0 += 1 } }
        let (window, view) = try hostedCPPView(prefix + "int deep() {\n  return 1;\n}\n")
        defer { cleanUp(window, view) }
        var changes = 0
        var pending = view.restoreContractedFoldHeaderLines([NSNumber(value: targetLine)])
        view.onFoldStateChange = { changes += 1 }
        view.onFoldRecoveryProgress = {
            pending = view.restoreContractedFoldHeaderLines(pending)
        }
        let deadline = Date(timeIntervalSinceNow: 2)
        while !pending.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(pending.isEmpty)
        #expect(view.contractedFoldHeaderLines(maximumCount: 10).map(\.intValue) == [targetLine])
        #expect(changes == 0)
    }

    @Test @MainActor
    func automaticFoldChangeRevealsChildrenWhenHeaderIsEditedAway() throws {
        let (window, view) = try hostedCPPView("int main() {\n  return 0;\n}\n")
        defer { cleanUp(window, view) }
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

    @Test @MainActor
    func contractedFoldIteratorStopsAtCallerCap() throws {
        let source = "void one() {\n}\nvoid two() {\n}\nvoid three() {\n}\n"
        let (window, view) = try hostedCPPView(source)
        defer { cleanUp(window, view) }
        for line in [0, 2, 4] {
            view.toggleFold(atLine: UInt(line))
        }
        #expect(view.contractedFoldHeaderLines(maximumCount: 2).map(\.intValue) == [0, 2])
    }

    @Test @MainActor
    func currentFoldUsesNearestParentFromChildLine() throws {
        let source = "int main() {\n  if (true) {\n    return 0;\n  }\n}\n"
        let (window, view) = try hostedCPPView(source)
        defer { cleanUp(window, view) }
        let returnOffset = try #require(source.range(of: "return")).lowerBound
        let caret = source.utf8.distance(from: source.utf8.startIndex, to: returnOffset)
        view.setPrimarySelectionUTF8Range(NSRange(location: caret, length: 0))
        #expect(view.collapseCurrentFold())
        #expect(view.contractedFoldHeaderLines(maximumCount: 10).map(\.intValue) == [1])
    }

    @Test @MainActor
    func gutterCurrentAndAllCommandsPublishExactlyOneChangeEach() throws {
        let source = "int main() {\n  if (true) {\n    return 0;\n  }\n}\n"

        do {
            let (window, view) = try hostedCPPView(source)
            defer { cleanUp(window, view) }
            var changes = 0
            view.onFoldStateChange = { changes += 1 }
            view.toggleFold(atLine: 0)
            #expect(changes == 1)
        }

        do {
            let (window, view) = try hostedCPPView(source)
            defer { cleanUp(window, view) }
            var changes = 0
            view.onFoldStateChange = { changes += 1 }
            view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 0))
            #expect(view.collapseCurrentFold())
            #expect(changes == 1)
            changes = 0
            #expect(!view.collapseCurrentFold())
            #expect(changes == 0)
        }

        do {
            let (window, view) = try hostedCPPView(source)
            defer { cleanUp(window, view) }
            view.toggleFold(atLine: 0)
            var changes = 0
            view.onFoldStateChange = { changes += 1 }
            view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 0))
            #expect(view.expandCurrentFold())
            #expect(changes == 1)
            changes = 0
            #expect(!view.expandCurrentFold())
            #expect(changes == 0)
        }

        do {
            let (window, view) = try hostedCPPView(source)
            defer { cleanUp(window, view) }
            var changes = 0
            view.onFoldStateChange = { changes += 1 }
            #expect(view.collapseAllFolds())
            #expect(changes == 1)
            changes = 0
            #expect(!view.collapseAllFolds())
            #expect(changes == 0)
        }

        do {
            let (window, view) = try hostedCPPView(source)
            defer { cleanUp(window, view) }
            #expect(view.collapseAllFolds())
            var changes = 0
            view.onFoldStateChange = { changes += 1 }
            #expect(view.expandAllFolds())
            #expect(changes == 1)
            changes = 0
            #expect(!view.expandAllFolds())
            #expect(changes == 0)
        }
    }

    @Test @MainActor
    func restoreRejectsNegativeOutOfRangeAndNonHeaderLines() throws {
        let (window, view) = try hostedCPPView("int main() {\n  return 0;\n}\n")
        defer { cleanUp(window, view) }
        var changes = 0
        view.onFoldStateChange = { changes += 1 }
        let pending = view.restoreContractedFoldHeaderLines([
            NSNumber(value: -1),
            NSNumber(value: view.lineCount),
            NSNumber(value: 1),
        ])
        #expect(pending.isEmpty)
        #expect(view.contractedFoldHeaderLines(maximumCount: 10).isEmpty)
        #expect(changes == 0)
    }

    @Test @MainActor
    func restoreRejectsOversizedInputBeforeApplyingAnyFold() throws {
        let (window, view) = try hostedCPPView("int main() {\n  return 0;\n}\n")
        defer { cleanUp(window, view) }
        var changes = 0
        view.onFoldStateChange = { changes += 1 }
        let oversized = Array(repeating: NSNumber(value: 0), count: 10_001)

        let pending = view.restoreContractedFoldHeaderLines(oversized)

        #expect(pending.isEmpty)
        #expect(view.contractedFoldHeaderLines(maximumCount: 10).isEmpty)
        #expect(changes == 0)
    }

    @Test @MainActor
    func restoreRejectsFractionalNonFiniteAndOverflowingNumbers() throws {
        let invalidValues: [(String, NSNumber)] = [
            ("fractional", NSNumber(value: 0.5)),
            ("NaN", NSNumber(value: Double.nan)),
            ("positive infinity", NSNumber(value: Double.infinity)),
            ("negative infinity", NSNumber(value: -Double.infinity)),
            ("positive NSInteger overflow", NSDecimalNumber(string: "18446744073709551616")),
            ("negative NSInteger overflow", NSDecimalNumber(string: "-18446744073709551616")),
        ]

        for (label, number) in invalidValues {
            let (window, view) = try hostedCPPView("int main() {\n  return 0;\n}\n")
            defer { cleanUp(window, view) }
            var changes = 0
            view.onFoldStateChange = { changes += 1 }

            let pending = view.restoreContractedFoldHeaderLines([number])

            #expect(pending.isEmpty, "\(label) remained pending")
            #expect(
                view.contractedFoldHeaderLines(maximumCount: 10).isEmpty,
                "\(label) was converted to a valid fold header"
            )
            #expect(changes == 0, "\(label) published a fold-state change")
        }
    }

    @Test @MainActor
    func foldCommandsPreserveFullSelectionDirtyRevisionAndUndoRedo() throws {
        let source = "int main() {\n  if (true) {\n    return 1;\n  }\n}"
        for command in 0..<4 {
            let (window, view) = try hostedCPPView(source)
            defer { cleanUp(window, view) }
            let valueOffset = try #require(source.range(of: "1")).lowerBound
            let byteOffset = source.utf8.distance(from: source.utf8.startIndex, to: valueOffset)
            try view.replaceUTF8Range(
                NSRange(location: byteOffset, length: 1),
                withReplacement: Data("2".utf8),
                expectedRevision: 7,
                resultingRevision: 8
            )
            try view.replaceUTF8Range(
                NSRange(location: byteOffset, length: 1),
                withReplacement: Data("3".utf8),
                expectedRevision: 8,
                resultingRevision: 9
            )
            view.undo()
            #expect(view.canUndo)
            #expect(view.canRedo)
            if command == 1 || command == 3 {
                view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 0))
                #expect(command == 1 ? view.collapseCurrentFold() : view.collapseAllFolds())
            }
            view.restoreCaretUTF8Position(
                0,
                anchorPosition: view.documentByteLength,
                firstVisibleLine: 0,
                horizontalScrollOffset: 0,
                wordWrapEnabled: view.isWordWrapEnabled
            )
            let beforeContent = view.contentUTF8
            let beforeRevision = view.revision
            let beforeCaret = view.caretUTF8Position
            let beforeAnchor = view.anchorUTF8Position
            let beforeCanUndo = view.canUndo
            let beforeCanRedo = view.canRedo

            let changed: Bool
            switch command {
            case 0: changed = view.collapseCurrentFold()
            case 1: changed = view.expandCurrentFold()
            case 2: changed = view.collapseAllFolds()
            default: changed = view.expandAllFolds()
            }

            #expect(changed, "fold command index \(command) was a no-op")
            #expect(view.contentUTF8 == beforeContent)
            #expect(view.revision == beforeRevision)
            #expect(view.caretUTF8Position == beforeCaret)
            #expect(view.anchorUTF8Position == beforeAnchor)
            #expect(view.canUndo == beforeCanUndo)
            #expect(view.canRedo == beforeCanRedo)
        }
    }

    @Test @MainActor
    func plainTextAndLargeFileDisableEveryFoldQueryAndCommand() throws {
        for (maximumStyleBytes, lexer, folding) in [
            (UInt(2_000_000), "null", false),
            (UInt(4), "cpp", true),
        ] {
            let (window, view) = try hostedCPPView("int main() {\n  return 0;\n}\n")
            defer { cleanUp(window, view) }
            #expect(view.applyLexerNamed(
                lexer,
                keywords: lexer == "cpp" ? ["int", "return"] : [],
                tabWidth: 4,
                useTabs: false,
                folding: folding,
                braceMatching: folding,
                maximumStyleBytes: maximumStyleBytes
            ))
            #expect(!view.canCollapseCurrentFold)
            #expect(!view.canExpandCurrentFold)
            #expect(!view.hasContractedFolds)
            #expect(!view.collapseCurrentFold())
            #expect(!view.expandCurrentFold())
            #expect(!view.collapseAllFolds())
            #expect(!view.expandAllFolds())
            for line in 0..<view.lineCount {
                #expect(view.isLineVisible(at: line))
            }
        }
    }

    @Test @MainActor
    func failedLexerApplicationRetainsExistingFoldsAndCapability() throws {
        let source = "int main() {\n  return 0;\n}\n"
        let (window, view) = try hostedCPPView(source)
        defer { cleanUp(window, view) }
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 0))
        #expect(view.collapseCurrentFold())
        let lexerName = view.lexerName
        let folds = view.contractedFoldHeaderLines(maximumCount: 10)
        let capabilities = (
            view.canCollapseCurrentFold,
            view.canExpandCurrentFold,
            view.hasContractedFolds
        )

        #expect(!view.applyLexerNamed(
            "not-a-real-lexer",
            keywords: [],
            tabWidth: 8,
            useTabs: true,
            folding: false,
            braceMatching: false,
            maximumStyleBytes: 2_000_000
        ))

        #expect(view.lexerName == lexerName)
        #expect(view.contractedFoldHeaderLines(maximumCount: 10) == folds)
        #expect(view.canCollapseCurrentFold == capabilities.0)
        #expect(view.canExpandCurrentFold == capabilities.1)
        #expect(view.hasContractedFolds == capabilities.2)
    }

    @MainActor
    private func makeDeepPendingAdapter(
        prefix: String = String(repeating: "// 0123456789abcdef\n", count: 16_384),
        leadingText: String = "",
        leadingLineCount: Int = 0,
        foldLines: [Int]? = nil,
        split: Bool = true
    ) throws -> (
        adapter: ScintillaEditorAdapter,
        buffer: EditorBufferDescriptor,
        primary: DPScintillaEditorView,
        secondary: DPScintillaEditorView?,
        deepHeaderLine: Int
    ) {
        let deepHeaderLine = leadingLineCount + prefix.reduce(into: 0) {
            if $1 == "\n" { $0 += 1 }
        }
        let text = leadingText + prefix + "int deep() {\n  return 1;\n}\n"
        let buffer = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        let secondaryState = split ? SecondaryEditorViewState(
            foldState: FoldRecoveryState(contractedHeaderLines: foldLines ?? [deepHeaderLine])
        ) : nil
        let viewState = EditorViewState(
            foldState: FoldRecoveryState(contractedHeaderLines: foldLines ?? [deepHeaderLine]),
            splitOrientation: split ? .sideBySide : nil,
            secondaryViewState: secondaryState
        )
        let adapter = ScintillaEditorAdapter()
        adapter.installRecovery(EditorRecoverySnapshot(
            bufferID: buffer.bufferID,
            revision: buffer.revision,
            utf8: Data(text.utf8),
            viewState: viewState
        ))
        adapter.display(buffer)
        #expect(adapter.applyLanguage(cppFoldConfiguration))
        let primary = try #require(adapter.activeScintillaView)
        let secondary: DPScintillaEditorView?
        if split {
            secondary = adapter.secondaryScintillaView
        } else {
            secondary = nil
        }
        return (adapter, buffer, primary, secondary, deepHeaderLine)
    }

    @MainActor
    private func expectNoCapturedFolds(
        _ adapter: ScintillaEditorAdapter,
        bufferID: BufferID,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let capture = try #require(adapter.recoveryCapture(for: bufferID), sourceLocation: sourceLocation)
        #expect(capture.viewState.foldState == FoldRecoveryState(), sourceLocation: sourceLocation)
        #expect(
            capture.viewState.secondaryViewState?.foldState == FoldRecoveryState(),
            sourceLocation: sourceLocation
        )
    }

    @MainActor
    private func makeReentrantInvalidationFixture() throws -> (
        adapter: ScintillaEditorAdapter,
        buffer: EditorBufferDescriptor,
        primary: DPScintillaEditorView,
        secondary: DPScintillaEditorView
    ) {
        let adapter = ScintillaEditorAdapter()
        let buffer = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        adapter.install(.init(bufferID: buffer.bufferID, revision: 0, text: "int main() {\n}\n"))
        adapter.display(buffer)
        let primary = try #require(adapter.activeScintillaView)
        adapter.split(orientation: .sideBySide)
        let secondary = try #require(adapter.secondaryScintillaView)
        return (adapter, buffer, primary, secondary)
    }

    @MainActor
    private func expectTerminalInvalidation(
        _ adapter: ScintillaEditorAdapter,
        bufferID: BufferID,
        retainedViews: [DPScintillaEditorView],
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        await Task.yield()
        await Task.yield()

        #expect(adapter.activeScintillaView == nil, sourceLocation: sourceLocation)
        #expect(adapter.secondaryScintillaView == nil, sourceLocation: sourceLocation)
        #expect(adapter.activeDocumentIntelligenceBuffer == nil, sourceLocation: sourceLocation)
        #expect(adapter.snapshot(for: bufferID) == nil, sourceLocation: sourceLocation)
        #expect(adapter.recoveryCapture(for: bufferID) == nil, sourceLocation: sourceLocation)
        #expect(
            adapter.replaceActive(
                range: .init(location: 0, length: 0),
                with: Data("ignored".utf8),
                expectedRevision: 41
            ) == .rejected(currentRevision: 41),
            sourceLocation: sourceLocation
        )
        for retainedView in retainedViews {
            #expect(retainedView.superview == nil, sourceLocation: sourceLocation)
            #expect(retainedView.onEdit == nil, sourceLocation: sourceLocation)
            #expect(retainedView.onError == nil, sourceLocation: sourceLocation)
            #expect(retainedView.onFocus == nil, sourceLocation: sourceLocation)
            #expect(retainedView.onFoldStateChange == nil, sourceLocation: sourceLocation)
            #expect(retainedView.onFoldRecoveryProgress == nil, sourceLocation: sourceLocation)
        }

        adapter.invalidate()
        adapter.install(.init(bufferID: bufferID, revision: 9, text: "must stay retired"))
        adapter.display(.init(bufferID: bufferID, revision: 9))
        #expect(adapter.activeScintillaView == nil, sourceLocation: sourceLocation)
        #expect(adapter.activeDocumentIntelligenceBuffer == nil, sourceLocation: sourceLocation)
        #expect(adapter.snapshot(for: bufferID) == nil, sourceLocation: sourceLocation)
        adapter.invalidate()
        #expect(adapter.activeScintillaView == nil, sourceLocation: sourceLocation)
        #expect(adapter.activeDocumentIntelligenceBuffer == nil, sourceLocation: sourceLocation)
    }

    @Test @MainActor
    func splitPanesRecoverIndependentContractedHeaders() throws {
        _ = NSApplication.shared
        let descriptor = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        let source = ScintillaEditorAdapter()
        source.install(.init(
            bufferID: descriptor.bufferID,
            revision: 0,
            text: "int outer() {\n  if (true) {\n    return 1;\n  }\n}\n"
        ))
        source.display(descriptor)
        #expect(source.applyLanguage(cppFoldConfiguration))
        let primary = try #require(source.activeScintillaView)
        source.split(orientation: .sideBySide)
        let secondary = try #require(source.secondaryScintillaView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = source.view
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        primary.focusEditor()
        primary.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 0))
        #expect(source.collapseCurrentFold())
        secondary.focusEditor()
        secondary.setPrimarySelectionUTF8Range(NSRange(
            location: "int outer() {\n  ".utf8.count,
            length: 0
        ))
        #expect(source.collapseCurrentFold())
        let snapshot = try #require(source.recoverySnapshot(for: descriptor.bufferID))
        #expect(snapshot.viewState.foldState.contractedHeaderLines == [0])
        #expect(snapshot.viewState.secondaryViewState?.foldState.contractedHeaderLines == [1])

        let restored = ScintillaEditorAdapter()
        restored.installRecovery(snapshot)
        restored.display(.init(bufferID: descriptor.bufferID, revision: snapshot.revision))
        #expect(restored.applyLanguage(cppFoldConfiguration))
        #expect(
            restored.activeScintillaView?.contractedFoldHeaderLines(maximumCount: 10).map(\.intValue)
                == [0]
        )
        #expect(
            restored.secondaryScintillaView?.contractedFoldHeaderLines(maximumCount: 10).map(\.intValue)
                == [1]
        )
    }

    @Test @MainActor
    func pendingHeadersSurviveCaptureBetweenIdleChunks() throws {
        let fixture = try makeDeepPendingAdapter()
        let capture = try #require(fixture.adapter.recoveryCapture(for: fixture.buffer.bufferID))
        #expect(capture.viewState.foldState.contractedHeaderLines == [fixture.deepHeaderLine])
        #expect(
            capture.viewState.secondaryViewState?.foldState.contractedHeaderLines
                == [fixture.deepHeaderLine]
        )
    }

    @Test @MainActor
    func acceptedDirectProgrammaticAndBatchMutationsClearBothPanePendingStates() throws {
        do {
            let fixture = try makeDeepPendingAdapter()
            fixture.adapter.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }
            fixture.primary.insertCommittedText("x")
            try expectNoCapturedFolds(fixture.adapter, bufferID: fixture.buffer.bufferID)
        }

        do {
            let fixture = try makeDeepPendingAdapter()
            fixture.adapter.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }
            #expect(fixture.adapter.replaceActive(
                range: .init(location: 0, length: 0),
                with: Data("x".utf8),
                expectedRevision: 0
            ) == .accepted(newRevision: 1))
            try expectNoCapturedFolds(fixture.adapter, bufferID: fixture.buffer.bufferID)
        }

        do {
            let fixture = try makeDeepPendingAdapter()
            let result = fixture.adapter.replaceActiveBatch(
                [.init(range: .init(location: 0, length: 0), replacementUTF8: Data("x".utf8))],
                expectedRevision: 0,
                accept: { .accepted(newRevision: $0.count == 1 ? 1 : 0) }
            )
            #expect(result == .accepted(newRevision: 1))
            try expectNoCapturedFolds(fixture.adapter, bufferID: fixture.buffer.bufferID)
        }
    }

    @Test @MainActor
    func acceptedUndoAndRedoEachClearIndependentlySeededPendingState() throws {
        do {
            let undo = try makeDeepPendingAdapter()
            try undo.primary.replaceUTF8Range(
                NSRange(location: 0, length: 0),
                withReplacement: Data("x".utf8),
                expectedRevision: 0,
                resultingRevision: 1
            )
            undo.primary.synchronizeRevision(0)
            undo.adapter.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }

            undo.primary.undo()

            try expectNoCapturedFolds(undo.adapter, bufferID: undo.buffer.bufferID)
        }

        do {
            let redo = try makeDeepPendingAdapter()
            let adapterEditHandler = redo.primary.onEdit
            redo.primary.onEdit = nil
            try redo.primary.replaceUTF8Range(
                NSRange(location: 0, length: 0),
                withReplacement: Data("x".utf8),
                expectedRevision: 0,
                resultingRevision: 1
            )
            redo.primary.undo()
            redo.primary.synchronizeRevision(0)
            redo.primary.onEdit = adapterEditHandler
            redo.adapter.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }

            redo.primary.redo()

            try expectNoCapturedFolds(redo.adapter, bufferID: redo.buffer.bufferID)
        }
    }

    @Test @MainActor
    func rejectedMutationRetainsAndReloadsAuthoritativeFoldsForBothPanes() async throws {
        let fixture = try makeDeepPendingAdapter()
        fixture.adapter.onEdit = { .rejected(currentRevision: $0.expectedRevision) }
        fixture.primary.insertCommittedText("x")
        await Task.yield()

        let recovery = try #require(fixture.adapter.recoverySnapshot(for: fixture.buffer.bufferID))
        #expect(recovery.viewState.foldState.contractedHeaderLines == [fixture.deepHeaderLine])
        #expect(
            recovery.viewState.secondaryViewState?.foldState.contractedHeaderLines
                == [fixture.deepHeaderLine]
        )
    }

    @Test @MainActor
    func bothPanesCompleteDeepRecoveryAfterFinalIdleChunk() async throws {
        _ = NSApplication.shared
        let fixture = try makeDeepPendingAdapter()
        let secondary = try #require(fixture.secondary)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = fixture.adapter.view
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        let expected = [fixture.deepHeaderLine]
        let deadline = Date(timeIntervalSinceNow: 2)
        while Date() < deadline {
            let primaryFolds = fixture.primary
                .contractedFoldHeaderLines(maximumCount: 10).map(\.intValue)
            let secondaryFolds = secondary
                .contractedFoldHeaderLines(maximumCount: 10).map(\.intValue)
            if primaryFolds == expected, secondaryFolds == expected { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.primary !== secondary)
        #expect(fixture.primary.contractedFoldHeaderLines(maximumCount: 10).map(\.intValue) == expected)
        #expect(secondary.contractedFoldHeaderLines(maximumCount: 10).map(\.intValue) == expected)
    }

    @Test @MainActor
    func directNativeFocusUpdatesLastFocusedPaneBeforeExternalResponderTransfer() throws {
        _ = NSApplication.shared
        let adapter = ScintillaEditorAdapter()
        let bufferID = BufferID()
        adapter.install(.init(bufferID: bufferID, revision: 0, text: "int main() {\n}\n"))
        adapter.display(.init(bufferID: bufferID, revision: 0))
        let primary = try #require(adapter.activeScintillaView)
        adapter.split(orientation: .sideBySide)
        let secondary = try #require(adapter.secondaryScintillaView)
        let field = NSTextField(frame: .zero)
        let host = NSStackView(views: [adapter.view, field])
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        secondary.focusEditor()
        #expect(adapter.activeScintillaView === secondary)
        var primaryFocusEvents = 0
        let adapterFocusHandler = primary.onFocus
        primary.onFocus = {
            primaryFocusEvents += 1
            adapterFocusHandler?()
        }
        primary.focusEditor()
        #expect(primary.hasEditorFocus)
        #expect(primaryFocusEvents == 1)
        window.makeFirstResponder(field)
        #expect(adapter.activeScintillaView === primary)

        adapter.closeSplit()
        #expect(adapter.activeScintillaView === primary)
    }

    @Test @MainActor
    func recoveredFoldLinesAreSanitizedToDocumentLineCount() throws {
        let adapter = ScintillaEditorAdapter()
        let bufferID = BufferID()
        adapter.installRecovery(.init(
            bufferID: bufferID,
            revision: 0,
            utf8: Data("int main() {\n}\n".utf8),
            viewState: .init(
                foldState: .init(contractedHeaderLines: [0, 2, 99]),
                splitOrientation: .sideBySide,
                secondaryViewState: .init(foldState: .init(contractedHeaderLines: [0, 3, 100]))
            )
        ))
        adapter.display(.init(bufferID: bufferID, revision: 0))
        let capture = try #require(adapter.recoveryCapture(for: bufferID))
        #expect(capture.viewState.foldState.contractedHeaderLines == [0, 2])
        #expect(capture.viewState.secondaryViewState?.foldState.contractedHeaderLines == [0])
    }

    @Test @MainActor
    func plainTextAndOverBudgetLanguageClearPendingAndDisableAdapterCommands() throws {
        for configuration in [
            EditorLanguageConfiguration(
                languageID: .plainText,
                lexerName: "null",
                indentation: .init(width: 4, useTabs: false),
                folding: false,
                braceMatching: false,
                maximumStyleBytes: 2_000_000
            ),
            EditorLanguageConfiguration(
                languageID: .init(rawValue: "cpp"),
                lexerName: "cpp",
                indentation: .init(width: 4, useTabs: false),
                folding: true,
                braceMatching: true,
                maximumStyleBytes: 1_024
            ),
        ] {
            let fixture = try makeDeepPendingAdapter()
            #expect(fixture.adapter.applyLanguage(configuration))
            #expect(!fixture.adapter.supportsFolding)
            #expect(!fixture.adapter.canCollapseCurrentFold)
            #expect(!fixture.adapter.canExpandCurrentFold)
            #expect(!fixture.adapter.hasCollapsedFolds)
            #expect(!fixture.adapter.collapseCurrentFold())
            #expect(!fixture.adapter.expandCurrentFold())
            #expect(!fixture.adapter.collapseAllFolds())
            #expect(!fixture.adapter.expandAllFolds())
            try expectNoCapturedFolds(fixture.adapter, bufferID: fixture.buffer.bufferID)
        }
    }

    @Test @MainActor
    func failedAdapterLexerApplicationPreservesCapabilityAndPendingState() throws {
        let fixture = try makeDeepPendingAdapter()
        let before = try #require(fixture.adapter.recoveryCapture(for: fixture.buffer.bufferID))
        let capabilities = (
            fixture.adapter.supportsFolding,
            fixture.adapter.canCollapseCurrentFold,
            fixture.adapter.canExpandCurrentFold,
            fixture.adapter.hasCollapsedFolds
        )
        let invalid = EditorLanguageConfiguration(
            languageID: .init(rawValue: "invalid"),
            lexerName: "not-a-real-lexer",
            indentation: .init(width: 8, useTabs: true),
            folding: false,
            braceMatching: false,
            maximumStyleBytes: 2_000_000
        )

        #expect(!fixture.adapter.applyLanguage(invalid))
        #expect(fixture.adapter.supportsFolding == capabilities.0)
        #expect(fixture.adapter.canCollapseCurrentFold == capabilities.1)
        #expect(fixture.adapter.canExpandCurrentFold == capabilities.2)
        #expect(fixture.adapter.hasCollapsedFolds == capabilities.3)
        #expect(fixture.adapter.recoveryCapture(for: fixture.buffer.bufferID)?.viewState == before.viewState)
    }

    @Test @MainActor
    func currentAndAllCommandsApplySpecifiedPendingRecoveryOwnership() throws {
        let leading = "int shallow() {\n}\n"
        let fixture = try makeDeepPendingAdapter(
            leadingText: leading,
            leadingLineCount: 2,
            foldLines: [0, 16_386],
            split: false
        )
        #expect(fixture.deepHeaderLine == 16_386)
        fixture.primary.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 0))
        #expect(fixture.adapter.expandCurrentFold())
        #expect(
            fixture.adapter.recoveryCapture(for: fixture.buffer.bufferID)?
                .viewState.foldState.contractedHeaderLines == [fixture.deepHeaderLine]
        )
        #expect(fixture.adapter.collapseCurrentFold())
        #expect(
            fixture.adapter.recoveryCapture(for: fixture.buffer.bufferID)?
                .viewState.foldState.contractedHeaderLines == [0, fixture.deepHeaderLine]
        )
        #expect(fixture.adapter.expandAllFolds())
        #expect(
            fixture.adapter.recoveryCapture(for: fixture.buffer.bufferID)?
                .viewState.foldState == FoldRecoveryState()
        )

        let collapseAll = try makeDeepPendingAdapter(
            leadingText: leading,
            leadingLineCount: 2,
            foldLines: [16_386],
            split: false
        )
        #expect(collapseAll.adapter.collapseAllFolds())
        let collapsed = try #require(
            collapseAll.adapter.recoveryCapture(for: collapseAll.buffer.bufferID)
        )
        let native = collapseAll.primary
            .contractedFoldHeaderLines(maximumCount: 10_000).map(\.intValue)
        #expect(collapsed.viewState.foldState.contractedHeaderLines == native)
        #expect(collapseAll.primary.expandAllFolds())
        #expect(
            collapseAll.adapter.recoveryCapture(for: collapseAll.buffer.bufferID)?
                .viewState.foldState == FoldRecoveryState()
        )
    }

    @Test @MainActor
    func adapterFoldCallbackForwardsChangesAndRetirementClearsNativeCallbacks() throws {
        let adapter = ScintillaEditorAdapter()
        let bufferID = BufferID()
        adapter.install(.init(bufferID: bufferID, revision: 0, text: "int main() {\n}\n"))
        adapter.display(.init(bufferID: bufferID, revision: 0))
        #expect(adapter.applyLanguage(cppFoldConfiguration))
        let view = try #require(adapter.activeScintillaView)
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 0))
        var changes = 0
        let port: any FoldingEditorPort = adapter
        adapter.onFoldStateChange = { changes += 1 }

        #expect(port.collapseCurrentFold())
        #expect(changes == 1)
        adapter.retire(bufferID: bufferID)
        #expect(view.onFoldStateChange == nil)
        #expect(view.onFoldRecoveryProgress == nil)
    }

    @Test @MainActor
    func adapterInvalidationDisconnectsEveryRetainedNativeView() throws {
        let adapter = ScintillaEditorAdapter()
        let firstBufferID = BufferID()
        adapter.install(.init(bufferID: firstBufferID, revision: 0, text: "int one() {\n}\n"))
        adapter.display(.init(bufferID: firstBufferID, revision: 0))
        let firstPrimary = try #require(adapter.activeScintillaView)

        let secondBufferID = BufferID()
        adapter.install(.init(bufferID: secondBufferID, revision: 0, text: "int two() {\n}\n"))
        adapter.display(.init(bufferID: secondBufferID, revision: 0))
        adapter.split(orientation: .sideBySide)
        let secondPrimary = try #require(adapter.activeScintillaView)
        let secondSecondary = try #require(adapter.secondaryScintillaView)
        adapter.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }
        adapter.onFoldStateChange = {}
        let lifecyclePort: any FoldingEditorPort = adapter

        lifecyclePort.invalidate()

        #expect(adapter.activeScintillaView == nil)
        #expect(adapter.secondaryScintillaView == nil)
        #expect(adapter.splitOrientation == nil)
        #expect(adapter.onEdit == nil)
        #expect(adapter.onFoldStateChange == nil)
        for retainedView in [firstPrimary, secondPrimary, secondSecondary] {
            #expect(retainedView.superview == nil)
            #expect(retainedView.onEdit == nil)
            #expect(retainedView.onError == nil)
            #expect(retainedView.onFocus == nil)
            #expect(retainedView.onFoldStateChange == nil)
            #expect(retainedView.onFoldRecoveryProgress == nil)
        }
    }

    @Test @MainActor
    func directNativeEditCannotRepopulateAfterCallbackInvalidatesAdapter() async throws {
        let fixture = try makeReentrantInvalidationFixture()
        var callbackOutcome: EditorEditOutcome?
        fixture.adapter.onEdit = { edit in
            fixture.adapter.invalidate()
            let outcome = EditorEditOutcome.accepted(newRevision: edit.expectedRevision + 1)
            callbackOutcome = outcome
            return outcome
        }

        fixture.primary.insertCommittedText("x")

        #expect(callbackOutcome == .accepted(newRevision: 1))
        await expectTerminalInvalidation(
            fixture.adapter,
            bufferID: fixture.buffer.bufferID,
            retainedViews: [fixture.primary, fixture.secondary]
        )
    }

    @Test @MainActor
    func replaceActiveReturnsAcceptedOutcomeWithoutRepopulatingAfterCallbackInvalidation() async throws {
        let fixture = try makeReentrantInvalidationFixture()
        fixture.adapter.onEdit = { edit in
            fixture.adapter.invalidate()
            return .accepted(newRevision: edit.expectedRevision + 1)
        }

        let outcome = fixture.adapter.replaceActive(
            range: .init(location: 0, length: 0),
            with: Data("x".utf8),
            expectedRevision: 0
        )

        #expect(outcome == .accepted(newRevision: 1))
        await expectTerminalInvalidation(
            fixture.adapter,
            bufferID: fixture.buffer.bufferID,
            retainedViews: [fixture.primary, fixture.secondary]
        )
    }

    @Test @MainActor
    func replaceActiveBatchReturnsAcceptedOutcomeWithoutRepopulatingAfterCallbackInvalidation() async throws {
        let fixture = try makeReentrantInvalidationFixture()

        let outcome = fixture.adapter.replaceActiveBatch(
            [.init(range: .init(location: 0, length: 0), replacementUTF8: Data("x".utf8))],
            expectedRevision: 0,
            accept: { edits in
                fixture.adapter.invalidate()
                return .accepted(newRevision: edits.count == 1 ? 1 : 0)
            }
        )

        #expect(outcome == .accepted(newRevision: 1))
        await expectTerminalInvalidation(
            fixture.adapter,
            bufferID: fixture.buffer.bufferID,
            retainedViews: [fixture.primary, fixture.secondary]
        )
    }
}
