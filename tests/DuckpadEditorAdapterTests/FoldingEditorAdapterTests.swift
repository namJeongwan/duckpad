import AppKit
@testable import DuckpadEditorAdapter
import DuckpadScintillaBridge
import Foundation
import Testing

@Suite(.serialized)
struct FoldingEditorAdapterTests {
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
}
