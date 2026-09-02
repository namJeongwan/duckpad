import AppKit
import DuckpadApplication
import DuckpadDomain
@testable import DuckpadEditorAdapter
import DuckpadInfrastructure
import DuckpadPresentation
import DuckpadScintillaBridge
import Testing

@Suite(.serialized)
struct ScintillaBridgeTests {
    @Test @MainActor
    func realViewUsesUTF8ByteRangesAndRejectsStaleRevision() throws {
        let view = makeHostedView()
        try view.loadUTF8(Data("Duckpad 한글 🦆".utf8), revision: 4)
        #expect(text(view) == "Duckpad 한글 🦆")
        #expect(view.revision == 4)
        #expect(view.cursorResourcesAvailable)
        #expect(view.accessibilityIdentifier() == "duckpad.editor.scintilla")

        try view.replaceUTF8Range(
            NSRange(location: 8, length: 6),
            withReplacement: Data("오리".utf8),
            expectedRevision: 4,
            resultingRevision: 5
        )
        #expect(text(view) == "Duckpad 오리 🦆")
        #expect(view.revision == 5)

        var rejected = false
        do {
            try view.replaceUTF8Range(
                NSRange(location: 0, length: 0),
                withReplacement: Data("x".utf8),
                expectedRevision: 4,
                resultingRevision: 5
            )
        } catch { rejected = true }
        #expect(rejected)
        #expect(text(view) == "Duckpad 오리 🦆")

        try view.loadUTF8(Data("x".utf8), revision: .max)
        do {
            try view.replaceUTF8Range(
                NSRange(location: 1, length: 0),
                withReplacement: Data("y".utf8),
                expectedRevision: .max,
                resultingRevision: .max
            )
            Issue.record("revision overflow must fail closed")
        } catch {
            #expect(view.revision == .max)
            #expect(text(view) == "x")
        }
    }

    @Test @MainActor
    func splitUTF8CodePointBoundariesFailWithoutMutation() throws {
        for sample in ["é", "한", "🦆", "e\u{301}"] {
            let view = makeHostedView()
            let original = Data(sample.utf8)
            try view.loadUTF8(original, revision: 9)
            let continuationOffsets = original.indices.filter {
                (original[$0] & 0xC0) == 0x80
            }
            for offset in continuationOffsets {
                for range in [
                    NSRange(location: offset, length: 0),
                    NSRange(location: 0, length: offset),
                ] {
                    do {
                        try view.replaceUTF8Range(
                            range,
                            withReplacement: Data("x".utf8),
                            expectedRevision: 9,
                            resultingRevision: 10
                        )
                        Issue.record("split UTF-8 boundary \(range) must be rejected")
                    } catch {
                        #expect(view.revision == 9)
                        #expect(view.contentUTF8 == original)
                    }
                }
            }
        }

        let combining = makeHostedView()
        try combining.loadUTF8(Data("e\u{301}".utf8), revision: 1)
        try combining.replaceUTF8Range(
            NSRange(location: 1, length: 2),
            withReplacement: Data("".utf8),
            expectedRevision: 1,
            resultingRevision: 2
        )
        #expect(text(combining) == "e")
    }

    @Test @MainActor
    func revisionExhaustionIsReadOnlyBeforeUserMutation() throws {
        let view = makeHostedView()
        var edits = 0
        var errors: [any Error] = []
        view.onEdit = { _ in edits += 1 }
        view.onError = { errors.append($0) }
        try view.loadUTF8(Data("base".utf8), revision: .max - 1)
        view.setPrimarySelectionUTF8Range(NSRange(location: 4, length: 0))
        view.insertCommittedText("!")
        #expect(view.revision == .max)
        #expect(edits == 1)
        let accepted = view.contentUTF8

        view.resetInstrumentation()
        edits = 0
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("paste", forType: .string)
        view.insertCommittedText("x")
        view.paste()
        view.undo()
        view.redo()
        view.setMarkedText(
            "한",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        #expect(!view.isInputEnabled)
        #expect(view.contentUTF8 == accepted)
        #expect(view.revision == .max)
        #expect(edits == 0)
        #expect(view.incrementalNotificationCount == 0)
        #expect(!errors.isEmpty)
        #expect((view.lastMutationError as? NSError)?.code == 4)
        #expect(!view.hasMarkedText())

        do {
            try view.replaceUTF8Range(
                NSRange(location: 0, length: 0),
                withReplacement: Data("external".utf8),
                expectedRevision: .max,
                resultingRevision: .max
            )
            Issue.record("external apply at max revision must fail")
        } catch {
            #expect(view.contentUTF8 == accepted)
            #expect(view.revision == .max)
        }
    }

    @Test @MainActor
    func acceptedEditWorkIsBoundedAcrossOneTenAndFiftyMegabytes() throws {
        let clock = ContinuousClock()
        var durations: [Duration] = []
        for size in [1_000_000, 10_000_000, 50_000_000] {
            let adapter = ScintillaEditorAdapter()
            let bufferID = BufferID()
            adapter.display(EditorBufferDescriptor(bufferID: bufferID, revision: 0))
            adapter.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }
            let view = try #require(adapter.activeScintillaView)
            var document = Data(repeating: 0x61, count: size)
            for newline in stride(from: 79, to: size, by: 80) { document[newline] = 0x0A }
            try view.loadUTF8(document, revision: 0)
            view.isWordWrapEnabled = false
            view.setPrimarySelectionUTF8Range(NSRange(location: size, length: 0))
            view.resetInstrumentation()
            let start = clock.now
            view.insertCommittedText("x")
            durations.append(start.duration(to: clock.now))

            #expect(view.documentByteLength == size + 1)
            #expect(view.snapshotReadCount == 0)
            #expect(view.incrementalNotificationCount == 1)
            #expect(view.incrementalPayloadByteCount == 1)
        }
        #expect(durations.allSatisfy { $0 < .milliseconds(250) })
        #expect((durations.max() ?? .zero) - (durations.min() ?? .zero) < .milliseconds(100))
    }

    @Test @MainActor
    func typingUndoRedoAndMultiselectionEmitOwnedEdits() throws {
        let view = makeHostedView()
        try view.loadUTF8(Data("alpha beta".utf8), revision: 0)
        var edits: [DPScintillaEdit] = []
        view.onEdit = { edits.append($0) }
        view.setPrimarySelectionUTF8Range(NSRange(location: 5, length: 0))
        view.insertCommittedText(" 한글")
        #expect(text(view) == "alpha 한글 beta")
        #expect(edits.first?.range == NSRange(location: 5, length: 0))
        #expect(edits.first?.replacementUTF8 == Data(" ".utf8))
        #expect(edits.first?.baseRevision == 0)
        #expect(edits.last?.resultingRevision == UInt64(edits.count))
        #expect(edits.enumerated().allSatisfy { offset, edit in
            edit.baseRevision == UInt64(offset)
                && edit.resultingRevision == UInt64(offset + 1)
        })
        #expect(edits.allSatisfy { !$0.insertedUTF8.isEmpty && $0.deletedUTF8.isEmpty })
        #expect(view.canUndo)

        let insertedEventCount = edits.count
        view.undo()
        #expect(text(view) == "alpha beta")
        #expect(edits.last?.origin == .undo)
        let undoEvents = edits.dropFirst(insertedEventCount)
        #expect(undoEvents.allSatisfy { $0.insertedUTF8.isEmpty && !$0.deletedUTF8.isEmpty })
        #expect(undoEvents.reduce(0) { $0 + $1.deletedUTF8.count } == Data(" 한글".utf8).count)
        view.redo()
        #expect(text(view) == "alpha 한글 beta")
        #expect(edits.last?.origin == .redo)

        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 5))
        #expect(view.addSelectionUTF8Range(NSRange(location: 13, length: 4)))
        #expect(view.selectionCount == 2)
        view.isWordWrapEnabled = false
        #expect(!view.isWordWrapEnabled)
        view.isWordWrapEnabled = true
        #expect(view.isWordWrapEnabled)
    }

    @Test @MainActor
    func koreanMarkedTextCopyPasteAndLargeUTF8RemainValid() throws {
        let view = makeHostedView()
        try view.loadUTF8(Data(), revision: 0)
        view.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())
        view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.unmarkText()
        #expect(!view.hasMarkedText())
        #expect(text(view) == "한")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(" 붙여넣기", forType: .string)
        view.setPrimarySelectionUTF8Range(NSRange(location: 3, length: 0))
        view.paste()
        #expect(text(view) == "한 붙여넣기")
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 3))
        view.copySelection()
        #expect(NSPasteboard.general.string(forType: .string) == "한")

        let large = String(repeating: "Duckpad-한글-🦆\n", count: 40_000)
        try view.loadUTF8(Data(large.utf8), revision: 100)
        #expect(view.contentUTF8.count == large.utf8.count)
        #expect(text(view) == large)
    }

    @Test @MainActor
    func swiftAdapterPublishesRevisionCheckedIncrementalEdit() {
        let adapter = ScintillaEditorAdapter()
        let bufferID = BufferID()
        adapter.display(EditorBufferDescriptor(bufferID: bufferID, revision: 0))
        var received: EditorIncrementalEdit?
        adapter.onEdit = {
            received = $0
            return .accepted(newRevision: $0.expectedRevision + 1)
        }
        adapter.activeScintillaView?.insertCommittedText("🦆")
        #expect(received?.range == TextEditRange(location: 0, length: 0))
        #expect(received?.replacement == "🦆")
        #expect(adapter.snapshot(for: bufferID)?.text == "🦆")
        #expect(adapter.snapshot(for: bufferID)?.revision == 1)
    }

    @Test @MainActor
    func rejectedEditReplaysAcceptedDeltaJournalWithoutHotPathSnapshot() async {
        let adapter = ScintillaEditorAdapter()
        let bufferID = BufferID()
        adapter.display(EditorBufferDescriptor(bufferID: bufferID, revision: 0))
        adapter.onEdit = {
            $0.replacement == "A"
                ? .accepted(newRevision: $0.expectedRevision + 1)
                : .rejected(currentRevision: $0.expectedRevision)
        }
        let view = adapter.activeScintillaView!
        view.resetInstrumentation()
        view.insertCommittedText("A")
        #expect(view.snapshotReadCount == 0)
        view.insertCommittedText("B")
        for _ in 0..<200 where view.revision != 1 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(view.snapshotReadCount == 0)
        #expect(view.revision == 1)
        #expect(adapter.snapshot(for: bufferID)?.text == "A")
    }

    @Test @MainActor
    func eachBufferKeepsItsOwnScintillaUndoState() {
        let adapter = ScintillaEditorAdapter()
        let first = BufferID()
        let second = BufferID()
        adapter.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }
        adapter.display(EditorBufferDescriptor(bufferID: first, revision: 0))
        adapter.activeScintillaView?.insertCommittedText("A")
        adapter.display(EditorBufferDescriptor(bufferID: second, revision: 0))
        adapter.activeScintillaView?.insertCommittedText("B")
        adapter.retire(bufferID: second)
        adapter.display(EditorBufferDescriptor(bufferID: first, revision: 1))

        #expect(adapter.activeScintillaView?.canUndo == true)
        adapter.activeScintillaView?.undo()
        #expect(adapter.snapshot(for: first)?.text == "")
        #expect(adapter.snapshot(for: second) == nil)
    }

    @Test @MainActor
    func productionWindowBoundaryHostsAndFocusesScintilla() {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let adapter = ScintillaEditorAdapter()
        let controller = DuckpadWindowController(
            workspace: workspace,
            editorAdapter: adapter,
            editorView: adapter.view,
            automaticallyStarts: false
        )
        controller.showAndFocus()
        #expect(adapter.view.window === controller.window)
        #expect(adapter.view.isDescendant(of: controller.window!.contentView!))
        adapter.focus()
        #expect(adapter.activeScintillaView?.hasEditorFocus == true)
        controller.close()
    }

    @Test
    func publicFacadeDoesNotExposeRawScintillaSurface() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let header = try String(contentsOf: root.appendingPathComponent(
            "Vendor/Scintilla/5.6.6/bridge/include/DuckpadScintillaBridge.h"
        ))
        for forbidden in ["SCI_", "SCNotification", "ScintillaView", "sptr_t", "void *", "ILexer"] {
            #expect(!header.contains(forbidden))
        }
    }

    @MainActor
    private func makeHostedView() -> DPScintillaEditorView {
        _ = NSApplication.shared
        ScintillaEditorAdapter.prepareResources()
        let view = DPScintillaEditorView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.orderOut(nil)
        return view
    }

    @MainActor
    private func text(_ view: DPScintillaEditorView) -> String? {
        String(data: view.contentUTF8, encoding: .utf8)
    }
}
