import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadScintillaBridge
import Testing

@Suite(.serialized) @MainActor
struct AutomaticDocumentCompletionTests {
    @MainActor private final class Fixture {
        let editor = ScintillaEditorAdapter()
        let intelligence: DocumentIntelligenceUseCase
        let window: NSWindow
        let native: DPScintillaEditorView

        init(_ text: String = "alpha alphabet Alpine\n") throws {
            _ = NSApplication.shared
            let buffer = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
            editor.install(.init(bufferID: buffer.bufferID, revision: 0, text: text))
            editor.display(buffer)
            editor.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }
            native = try #require(editor.activeScintillaView)
            intelligence = DocumentIntelligenceUseCase(editor: editor)
            intelligence.enableAutomaticCompletion { ["allocate align"] }
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = editor.view
            window.makeKeyAndOrderFront(nil)
            native.focusEditor()
            native.setPrimarySelectionUTF8Range(.init(location: text.utf8.count, length: 0))
            native.resetInstrumentation()
        }

        func dispose() {
            intelligence.cancel()
            editor.invalidate()
            window.contentView = nil
            window.close()
        }

        func key(_ characters: String, code: UInt16) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code))
            try #require(window.firstResponder).keyDown(with: event)
        }

        func type(_ text: String) throws {
            let client = try #require(window.firstResponder as? any NSTextInputClient)
            client.insertText(text, replacementRange: .init(location: NSNotFound, length: 0))
        }

        func settle() async throws { try await Task.sleep(for: .milliseconds(350)) }
    }

    @Test func typingShowsCandidatesWithoutInvokingTheCompletionCommand() async throws {
        let f = try Fixture(); defer { f.dispose() }
        try f.type("a")
        try await f.settle()
        #expect(f.native.isCompletionActive)
        // Restart so the snapshot assertion still covers coalesced initial input.
        f.intelligence.cancel()
        f.native.resetInstrumentation()
        try f.type("l")
        try f.type("p")
        #expect(f.native.snapshotReadCount == 0)
        try await f.settle()
        #expect(f.native.isCompletionActive)
        #expect(f.native.completionItemCount == 3)
        #expect(f.native.snapshotReadCount == 1)
        #expect(f.native.revision == 3)
        #expect(f.native.contentUTF8 == Data("alpha alphabet Alpine\nalp".utf8))
        try f.key("\t", code: 48)
        #expect(!f.native.isCompletionActive)
        #expect(f.native.contentUTF8 == Data("alpha alphabet Alpine\nalpha".utf8))
        f.native.undo()
        #expect(f.native.contentUTF8 == Data("alpha alphabet Alpine\nalp".utf8))
    }

    @Test func languageKeywordsParticipateInAutomaticSuggestions() async throws {
        let f = try Fixture("\n"); defer { f.dispose() }
        try f.type("al")
        try await f.settle()
        #expect(f.native.isCompletionActive)
        #expect(f.native.completionItemCount == 2)
    }

    @Test func visibleSuggestionsKeepNativeFilteringWithoutAnotherSnapshot() async throws {
        let f = try Fixture(); defer { f.dispose() }
        try f.type("al")
        try await f.settle()
        #expect(f.native.isCompletionActive)
        f.native.resetInstrumentation()
        try f.type("p")
        try await f.settle()
        #expect(f.native.isCompletionActive)
        #expect(f.native.snapshotReadCount == 0)
        try f.key("\r", code: 36)
        #expect(f.native.contentUTF8 == Data("alpha alphabet Alpine\nalpha".utf8))
        #expect(!f.native.isCompletionActive)
    }

    @Test func initialDiacriticMatchesRemainAvailable() async throws {
        let f = try Fixture("résumé\n"); defer { f.dispose() }
        try f.type("re")
        try await f.settle()
        #expect(f.native.isCompletionActive)
        #expect(f.native.completionItemCount == 1)
        try f.key("\t", code: 48)
        #expect(f.native.contentUTF8 == Data("résumé\nrésumé".utf8))
    }

    @Test func whitespaceUndoAndReadOnlyChangesDoNotShowPendingSuggestions() async throws {
        let f = try Fixture(); defer { f.dispose() }
        try f.type("alp ")
        try await f.settle()
        #expect(!f.native.isCompletionActive)
        try f.type("alp")
        f.native.undo()
        try await f.settle()
        #expect(!f.native.isCompletionActive)
        try f.type("alp")
        f.editor.setReadOnly(true, for: try #require(f.editor.activeDocumentIntelligenceBuffer).bufferID)
        try await f.settle()
        #expect(!f.native.isCompletionActive)
    }

    @Test func escapeCancelsThePendingSuggestionBeforeAnySnapshot() async throws {
        let f = try Fixture(); defer { f.dispose() }
        try f.type("alp")
        try f.key("\u{1b}", code: 53)
        try await f.settle()
        #expect(!f.native.isCompletionActive)
        #expect(f.native.snapshotReadCount == 0)
        #expect(f.native.contentUTF8 == Data("alpha alphabet Alpine\nalp".utf8))
    }

    @Test func focusAndCaretChangesRejectPendingSuggestions() async throws {
        let f = try Fixture(); defer { f.dispose() }
        try f.type("alp")
        f.native.setPrimarySelectionUTF8Range(.init(location: 0, length: 0))
        try await f.settle()
        #expect(!f.native.isCompletionActive)
        #expect(f.native.snapshotReadCount == 0)
        f.native.setPrimarySelectionUTF8Range(.init(location: Int(f.native.documentByteLength), length: 0))
        try f.type("h")
        f.window.makeFirstResponder(nil)
        try await f.settle()
        #expect(!f.native.isCompletionActive)
    }

    @Test func compositionWaitsForCommitAndKeepsKoreanText() async throws {
        let f = try Fixture("한글단어 한글함수\n"); defer { f.dispose() }
        f.native.setMarkedText("한글", selectedRange: .init(location: 2, length: 0),
                               replacementRange: .init(location: NSNotFound, length: 0))
        try await f.settle()
        #expect(f.native.hasMarkedText())
        #expect(!f.native.isCompletionActive)
        #expect(f.native.snapshotReadCount == 0)
        let client = try #require(f.window.firstResponder as? any NSTextInputClient)
        client.insertText("한글", replacementRange: .init(location: NSNotFound, length: 0))
        try await f.settle()
        #expect(!f.native.hasMarkedText())
        #expect(f.native.isCompletionActive)
        #expect(f.native.completionItemCount == 2)
        #expect(f.native.contentUTF8 == Data("한글단어 한글함수\n한글".utf8))
    }

    @Test func multipleCaretsAndOversizedDocumentsNeverTriggerSnapshots() async throws {
        let f = try Fixture(); defer { f.dispose() }
        #expect(f.native.addSelectionUTF8Range(.init(location: 0, length: 0)))
        try f.type("alp")
        try await f.settle()
        #expect(!f.native.isCompletionActive)
        #expect(f.native.snapshotReadCount == 0)

        let large = try Fixture(String(repeating: "alpha ", count: 700_000) + "\n")
        defer { large.dispose() }
        try large.type("alp")
        try await large.settle()
        #expect(!large.native.isCompletionActive)
        #expect(large.native.snapshotReadCount == 0)
    }

    @Test func movingToAnotherPaneDoesNotPublishThePreviousPanesRequest() async throws {
        let f = try Fixture(); defer { f.dispose() }
        f.editor.split(orientation: .sideBySide)
        f.native.focusEditor()
        try f.type("alp")
        let secondary = try #require(f.editor.secondaryScintillaView)
        secondary.setPrimarySelectionUTF8Range(.init(location: Int(f.native.documentByteLength), length: 0))
        secondary.focusEditor()
        try await f.settle()
        #expect(!f.native.isCompletionActive)
        #expect(!secondary.isCompletionActive)
        #expect(f.native.snapshotReadCount == 0)
    }
}
