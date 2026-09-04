import AppKit
import DuckpadApplication
import DuckpadDomain
@testable import DuckpadEditorAdapter
import DuckpadInfrastructure
import DuckpadScintillaBridge
import Foundation
import Testing

@Suite(.serialized)
struct LanguageEditorAdapterTests {
    @MainActor
    private func hostedView() -> (NSWindow, DPScintillaEditorView) {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let view = DPScintillaEditorView(frame: window.contentView!.bounds)
        window.contentView?.addSubview(view)
        return (window, view)
    }

    @MainActor
    private func sendKeyEvent(
        characters: String,
        charactersIgnoringModifiers: String,
        modifierFlags: NSEvent.ModifierFlags = [],
        keyCode: UInt16,
        to window: NSWindow
    ) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        ))
        NSApplication.shared.postEvent(event, atStart: true)
        let queuedEvent = try #require(NSApplication.shared.nextEvent(
            matching: .keyDown,
            until: Date(timeIntervalSinceNow: 0.1),
            inMode: .default,
            dequeue: true
        ))
        NSApplication.shared.sendEvent(queuedEvent)
    }

    @Test @MainActor
    func everyBundledLexerResolvesInVendoredLexilla() throws {
        let registry = try LanguageManifestLoader().loadBundled()
        let unresolved = Set(registry.definitions.map(\.lexerName)).filter {
            !DPScintillaEditorView.supportsLexerNamed($0)
        }
        #expect(unresolved.isEmpty)
    }

    @Test @MainActor
    func representativeLexersStyleKeywordsStringsCommentsAndUTF8() throws {
        for fixture in [
            ("cpp", ["int return"], "int main() { const char *s = \"🦆\"; return 1; } // 한글", 5, 4, 6, 2),
            ("python", ["def return"], "def duck():\n    value = 1\n    return \"🦆\" # 한글", 5, 2, 3, 1),
            ("rust", ["fn let"], "fn main() { let n = 1; let duck = \"🦆\"; } // 한글", 6, 5, 13, 2),
        ] {
            let (_, view) = hostedView()
            try view.loadUTF8(Data(fixture.2.utf8), revision: 7)
            #expect(view.applyLexerNamed(fixture.0, keywords: fixture.1, tabWidth: 4, useTabs: false, folding: true, braceMatching: true, maximumStyleBytes: 1_000_000))
            func offset(_ token: String) -> UInt {
                let bytes = Array(fixture.2.utf8)
                let needle = Array(token.utf8)
                for index in bytes.indices where index + needle.count <= bytes.count {
                    if Array(bytes[index..<(index + needle.count)]) == needle { return UInt(index) }
                }
                Issue.record("missing fixture token \(token)")
                return 0
            }
            #expect(view.style(atUTF8Position: 0) == fixture.3)
            #expect(view.style(atUTF8Position: offset("1")) == fixture.4)
            #expect(view.style(atUTF8Position: offset("\"")) == fixture.5)
            #expect(view.style(atUTF8Position: offset(fixture.0 == "python" ? "#" : "//")) == fixture.6)
            let emojiOffset = fixture.2.utf8.distance(from: fixture.2.utf8.startIndex, to: fixture.2.utf8.firstIndex(of: 0xF0)!)
            #expect(view.style(atUTF8Position: UInt(emojiOffset)) >= 0)
        }
    }

    @Test @MainActor
    func foldBraceAndIndentCapabilitiesAreAppliedAndCanBeDisabled() throws {
        let hosted = hostedView()
        let view = hosted.1
        let source = "한글🦆 int main() {\n  if (true) {\n    return 1;\n  }\n}\n"
        try view.loadUTF8(Data(source.utf8), revision: 1)
        #expect(view.applyLexerNamed("cpp", keywords: ["int if return true"], tabWidth: 8, useTabs: true, folding: true, braceMatching: true, maximumStyleBytes: 1_000_000))
        #expect(view.configuredTabWidth == 8)
        #expect(view.configuredUseTabs)
        #expect(view.configuredFoldingEnabled)
        #expect(view.configuredBraceMatchingEnabled)
        #expect((view.foldLevel(atLine: 0) & 0x2000) != 0)
        let expanded = view.isFoldExpanded(atLine: 0)
        view.toggleFold(atLine: 0)
        #expect(view.isFoldExpanded(atLine: 0) != expanded)
        let brace = Array(source.utf8).firstIndex(of: Character("{").asciiValue!)!
        view.setPrimarySelectionUTF8Range(NSRange(location: brace + 1, length: 0))
        view.updateBraceHighlight()
        #expect(view.highlightedBraceUTF8Position == brace)
        #expect(view.matchingBraceUTF8Position > view.highlightedBraceUTF8Position)
        #expect(view.foregroundColor(forStyle: 34) != view.foregroundColor(forStyle: 35))

        let (_, badBraceView) = hostedView()
        let unmatched = "한글🦆 {"
        try badBraceView.loadUTF8(Data(unmatched.utf8), revision: 2)
        #expect(badBraceView.applyLexerNamed("cpp", keywords: ["int"], tabWidth: 4, useTabs: false, folding: true, braceMatching: true, maximumStyleBytes: 1_000_000))
        let unmatchedBrace = Array(unmatched.utf8).firstIndex(of: Character("{").asciiValue!)!
        badBraceView.setPrimarySelectionUTF8Range(NSRange(location: unmatchedBrace + 1, length: 0))
        badBraceView.updateBraceHighlight()
        #expect(badBraceView.badBraceUTF8Position == unmatchedBrace)

        #expect(view.applyLexerNamed("null", keywords: [], tabWidth: 4, useTabs: false, folding: false, braceMatching: false, maximumStyleBytes: 1_000_000))
        #expect(!view.configuredFoldingEnabled)
        #expect(!view.configuredBraceMatchingEnabled)
        view.updateBraceHighlight()
        #expect(view.highlightedBraceUTF8Position == -1)
        #expect(view.matchingBraceUTF8Position == -1)
    }

    @Test @MainActor
    func typingOpeningBraceInJSONAutoClosesAndUndoRemovesThePair() throws {
        let (_, view) = hostedView()
        try view.loadUTF8(Data(), revision: 0)
        #expect(view.applyLexerNamed(
            "json",
            keywords: [],
            tabWidth: 2,
            useTabs: false,
            folding: true,
            braceMatching: true,
            maximumStyleBytes: 1_000_000
        ))

        view.insertCommittedText("{")

        #expect(String(decoding: view.contentUTF8, as: UTF8.self) == "{}")
        #expect(view.caretUTF8Position == 1)
        view.undo()
        #expect(view.contentUTF8.isEmpty)
    }

    @Test @MainActor
    func plainTextAndPasteDoNotTriggerSmartPairing() throws {
        let (_, plainTextView) = hostedView()
        try plainTextView.loadUTF8(Data(), revision: 0)
        #expect(plainTextView.applyLexerNamed(
            "null",
            keywords: [],
            tabWidth: 4,
            useTabs: false,
            folding: false,
            braceMatching: false,
            maximumStyleBytes: 1_000_000
        ))
        plainTextView.insertCommittedText("{")
        #expect(String(decoding: plainTextView.contentUTF8, as: UTF8.self) == "{")

        let (_, jsonView) = hostedView()
        try jsonView.loadUTF8(Data(), revision: 0)
        #expect(jsonView.applyLexerNamed(
            "json",
            keywords: [],
            tabWidth: 2,
            useTabs: false,
            folding: true,
            braceMatching: true,
            maximumStyleBytes: 1_000_000
        ))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("{", forType: .string)
        jsonView.paste()
        #expect(String(decoding: jsonView.contentUTF8, as: UTF8.self) == "{")

        try jsonView.loadUTF8(Data(), revision: 1)
        let largePaste = String(repeating: "{", count: 4 * 1_024 * 1_024)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(largePaste, forType: .string)
        jsonView.paste()
        #expect(jsonView.documentByteLength == largePaste.utf8.count)
        #expect(jsonView.contentPrefixUTF8(withMaximumLength: 4) == Data("{{{{".utf8))
    }

    @Test @MainActor
    func smartEditingPreservesCRLFAndCRLineEndings() throws {
        for (source, expected, caret) in [
            ("{\r\n}", "{\r\n  \r\n}", 5),
            ("{\r}", "{\r  \r}", 4),
        ] {
            let (window, view) = hostedView()
            try view.loadUTF8(Data(source.utf8), revision: 0)
            #expect(view.applyLexerNamed(
                "json",
                keywords: [],
                tabWidth: 2,
                useTabs: false,
                folding: true,
                braceMatching: true,
                maximumStyleBytes: 1_000_000
            ))
            view.setPrimarySelectionUTF8Range(NSRange(location: 1, length: 0))
            window.makeKeyAndOrderFront(nil)
            view.focusEditor()

            try sendKeyEvent(
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                keyCode: 36,
                to: window
            )

            #expect(String(decoding: view.contentUTF8, as: UTF8.self) == expected)
            #expect(view.caretUTF8Position == caret)
            window.orderOut(nil)
        }
    }

    @Test @MainActor
    func IMECompositionDoesNotTriggerSmartPairing() throws {
        let (window, view) = hostedView()
        try view.loadUTF8(Data(), revision: 0)
        #expect(view.applyLexerNamed(
            "json",
            keywords: [],
            tabWidth: 2,
            useTabs: false,
            folding: true,
            braceMatching: true,
            maximumStyleBytes: 1_000_000
        ))
        window.makeKeyAndOrderFront(nil)
        view.focusEditor()
        try sendKeyEvent(
            characters: "{",
            charactersIgnoringModifiers: "[",
            modifierFlags: [.shift],
            keyCode: 33,
            to: window
        )
        try view.loadUTF8(Data(), revision: 1)

        view.setMarkedText(
            "{",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(String(decoding: view.contentUTF8, as: UTF8.self) == "{")
        #expect(view.hasMarkedText())
        view.setMarkedText(
            "[",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(String(decoding: view.contentUTF8, as: UTF8.self) == "[")

        let textInputClient = try #require(window.firstResponder as? NSTextInputClient)
        textInputClient.insertText(
            "{",
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        #expect(String(decoding: view.contentUTF8, as: UTF8.self) == "{")
        #expect(!view.hasMarkedText())
    }

    @Test @MainActor
    func failedLexerChangePreservesThePreviousSmartEditingConfiguration() throws {
        let (_, view) = hostedView()
        try view.loadUTF8(Data(), revision: 0)
        #expect(view.applyLexerNamed(
            "json",
            keywords: [],
            tabWidth: 2,
            useTabs: false,
            folding: true,
            braceMatching: true,
            maximumStyleBytes: 1_000_000
        ))

        #expect(!view.applyLexerNamed(
            "not-a-real-lexer",
            keywords: [],
            tabWidth: 8,
            useTabs: true,
            folding: false,
            braceMatching: false,
            maximumStyleBytes: 1_000_000
        ))
        #expect(view.configuredBraceMatchingEnabled)
        view.insertCommittedText("{")
        #expect(String(decoding: view.contentUTF8, as: UTF8.self) == "{}")
    }

    @Test @MainActor
    func pressingReturnBetweenJSONBracesCreatesAnIndentedLineAndAlignsTheCloser() throws {
        let (_, view) = hostedView()
        try view.loadUTF8(Data(), revision: 0)
        #expect(view.applyLexerNamed(
            "json",
            keywords: [],
            tabWidth: 2,
            useTabs: false,
            folding: true,
            braceMatching: true,
            maximumStyleBytes: 1_000_000
        ))
        view.insertCommittedText("{")

        view.insertCommittedText("\n")

        #expect(String(decoding: view.contentUTF8, as: UTF8.self) == "{\n  \n}")
        #expect(view.caretUTF8Position == 4)
        view.undo()
        #expect(String(decoding: view.contentUTF8, as: UTF8.self) == "{}")
    }

    @Test @MainActor
    func pressingReturnAfterJSONMemberKeepsSiblingIndentAndDedentsTheCloser() throws {
        let (_, view) = hostedView()
        let source = "{\n  \"a\": \"b\",}"
        try view.loadUTF8(Data(source.utf8), revision: 4)
        #expect(view.applyLexerNamed(
            "json",
            keywords: [],
            tabWidth: 2,
            useTabs: false,
            folding: true,
            braceMatching: true,
            maximumStyleBytes: 1_000_000
        ))
        view.setPrimarySelectionUTF8Range(NSRange(location: source.utf8.count - 1, length: 0))

        view.insertCommittedText("\n")

        #expect(String(decoding: view.contentUTF8, as: UTF8.self) == "{\n  \"a\": \"b\",\n  \n}")
        #expect(view.caretUTF8Position == source.utf8.count + 2)
    }

    @Test @MainActor
    func pressingReturnAfterPythonColonUsesTheConfiguredIndentWidth() throws {
        let (_, view) = hostedView()
        let source = "def duck():"
        try view.loadUTF8(Data(source.utf8), revision: 2)
        #expect(view.applyLexerNamed(
            "python",
            keywords: ["def"],
            tabWidth: 4,
            useTabs: false,
            folding: true,
            braceMatching: true,
            maximumStyleBytes: 1_000_000
        ))
        view.setPrimarySelectionUTF8Range(NSRange(location: source.utf8.count, length: 0))

        view.insertCommittedText("\n")

        #expect(String(decoding: view.contentUTF8, as: UTF8.self) == "def duck():\n    ")
        #expect(view.caretUTF8Position == source.utf8.count + 5)
        view.undo()
        #expect(String(decoding: view.contentUTF8, as: UTF8.self) == source)
    }

    @Test @MainActor
    func smartIndentBoundsOnlyWhitespaceInspectionOnLongLines() throws {
        let longMinifiedSource = String(repeating: "x", count: 4_097) + "{"
        let (_, longMinifiedView) = hostedView()
        try longMinifiedView.loadUTF8(Data(longMinifiedSource.utf8), revision: 0)
        #expect(longMinifiedView.applyLexerNamed(
            "json",
            keywords: [],
            tabWidth: 2,
            useTabs: false,
            folding: true,
            braceMatching: true,
            maximumStyleBytes: 1_000_000
        ))
        longMinifiedView.setPrimarySelectionUTF8Range(NSRange(
            location: longMinifiedSource.utf8.count,
            length: 0
        ))
        longMinifiedView.insertCommittedText("\n")
        #expect(String(decoding: longMinifiedView.contentUTF8, as: UTF8.self).hasSuffix("{\n  "))

        for (whitespaceCount, expectedSuffix) in [
            (4_096, " \n  "),
            (4_097, " \n"),
        ] {
            let source = "{" + String(repeating: " ", count: whitespaceCount)
            let (_, view) = hostedView()
            try view.loadUTF8(Data(source.utf8), revision: 0)
            #expect(view.applyLexerNamed(
                "json",
                keywords: [],
                tabWidth: 2,
                useTabs: false,
                folding: true,
                braceMatching: true,
                maximumStyleBytes: 1_000_000
            ))
            view.setPrimarySelectionUTF8Range(NSRange(location: source.utf8.count, length: 0))

            view.insertCommittedText("\n")

            #expect(String(decoding: view.contentUTF8, as: UTF8.self).hasSuffix(expectedSuffix))
        }
    }

    @Test @MainActor
    func autoClosedPairAdvancesWorkspaceRecoveryAsOneNativeEdit() throws {
        let adapter = ScintillaEditorAdapter()
        let bufferID = BufferID()
        adapter.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }
        adapter.display(EditorBufferDescriptor(bufferID: bufferID, revision: 0))
        #expect(adapter.applyLanguage(EditorLanguageConfiguration(
            languageID: LanguageID(rawValue: "json"),
            lexerName: "json",
            indentation: .init(width: 2),
            folding: true,
            braceMatching: true
        )))
        let view = try #require(adapter.activeScintillaView)

        view.insertCommittedText("{")

        let paired = try #require(adapter.recoverySnapshot(for: bufferID))
        #expect(String(decoding: paired.utf8, as: UTF8.self) == "{}")
        #expect(paired.revision == 1)
        view.undo()
        let undone = try #require(adapter.recoverySnapshot(for: bufferID))
        #expect(undone.utf8.isEmpty)
        #expect(undone.revision == 2)
    }

    @Test @MainActor
    func appKitKeyEventUsesSmartEditingThroughTheScintillaFirstResponder() throws {
        let (window, view) = hostedView()
        try view.loadUTF8(Data(), revision: 0)
        #expect(view.applyLexerNamed(
            "json",
            keywords: [],
            tabWidth: 2,
            useTabs: false,
            folding: true,
            braceMatching: true,
            maximumStyleBytes: 1_000_000
        ))
        window.makeKeyAndOrderFront(nil)
        view.focusEditor()
        try sendKeyEvent(
            characters: "{",
            charactersIgnoringModifiers: "[",
            modifierFlags: [.shift],
            keyCode: 33,
            to: window
        )

        #expect(String(decoding: view.contentUTF8, as: UTF8.self) == "{}")
        #expect(view.caretUTF8Position == 1)

        try sendKeyEvent(
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            keyCode: 36,
            to: window
        )
        #expect(String(decoding: view.contentUTF8, as: UTF8.self) == "{\n  \n}")
        #expect(view.caretUTF8Position == 4)

        try view.loadUTF8(Data("{".utf8), revision: 7)
        #expect(String(decoding: view.contentUTF8, as: UTF8.self) == "{")
    }

    @Test @MainActor
    func themeAndLanguageChangesDoNotMutateTextRevisionOrUndo() throws {
        let (_, view) = hostedView()
        try view.loadUTF8(Data("int duck = 1;".utf8), revision: 4)
        view.resetInstrumentation()
        #expect(view.applyLexerNamed("cpp", keywords: ["int"], tabWidth: 4, useTabs: false, folding: true, braceMatching: true, maximumStyleBytes: 1_000_000))
        let before = view.contentUTF8
        let revision = view.revision
        let canUndo = view.canUndo
        let snapshotReads = view.snapshotReadCount
        view.apply(.dark)
        #expect(view.foregroundColor(forStyle: 33) != view.foregroundColor(forStyle: 0))
        view.apply(.highContrastLight)
        #expect(view.revision == revision)
        #expect(view.canUndo == canUndo)
        #expect(view.snapshotReadCount == snapshotReads)
        #expect(view.contentUTF8 == before)
    }

    @Test @MainActor
    func largeDocumentFallsBackWithoutSnapshotRead() throws {
        let (_, view) = hostedView()
        let bytes = Data(repeating: 0x61, count: 50 * 1_024 * 1_024)
        try view.loadUTF8(bytes, revision: 2)
        view.resetInstrumentation()
        #expect(view.applyLexerNamed("cpp", keywords: ["int"], tabWidth: 4, useTabs: false, folding: true, braceMatching: true, maximumStyleBytes: 16 * 1_024 * 1_024))
        #expect(view.languageStylingFallback)
        #expect(view.lexerName == "null")
        #expect(view.snapshotReadCount == 0)
        #expect(view.synchronouslyStyledByteCount == 0)
        #expect(!view.configuredFoldingEnabled)
        #expect(!view.configuredBraceMatchingEnabled)
        #expect(view.revision == 2)
    }

    @Test @MainActor
    func multilineCommentToggleIsBoundedAndOneUndoRestoresExactText() throws {
        let (_, view) = hostedView()
        let original = "  first\r\n\r\n\t한글\r\nlast"
        try view.loadUTF8(Data(original.utf8), revision: 0)
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: original.utf8.count))
        #expect(view.toggleLineComments(withPrefixUTF8: Data("//".utf8)))
        let changed = String(data: view.contentUTF8, encoding: .utf8)!
        #expect(changed == "  //first\r\n\r\n\t//한글\r\n//last")
        #expect(view.commentCommandInspectedByteCount < 64)
        view.undo()
        #expect(String(data: view.contentUTF8, encoding: .utf8) == original)
    }

    @Test @MainActor
    func commentToggleAdvancesWorkspaceRecoveryAndGroupedUndoRestoresIt() async throws {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        #expect(await workspace.start() == .saved)
        let adapter = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: adapter)
        let buffer = try #require(workspace.snapshot().activeBuffer)
        adapter.display(buffer)
        let original = "one\n  two\n한글"
        adapter.install(EditorTextSnapshot(bufferID: buffer.bufferID, revision: 0, text: original))
        adapter.activeScintillaView?.setPrimarySelectionUTF8Range(NSRange(location: 0, length: original.utf8.count))
        let commented = adapter.toggleLineComment(prefix: "//")
        guard case .accepted(let commentedRevision) = commented else {
            Issue.record("comment command rejected")
            return
        }
        #expect(commentedRevision == 3)
        #expect(String(data: adapter.recoverySnapshot(for: buffer.bufferID)!.utf8, encoding: .utf8) == "//one\n  //two\n//한글")
        adapter.activeScintillaView?.undo()
        let restored = try #require(adapter.recoverySnapshot(for: buffer.bufferID))
        #expect(String(data: restored.utf8, encoding: .utf8) == original)
        #expect(restored.revision > commentedRevision)
        _ = binding
    }

    @Test @MainActor
    func nativeCompletionListIsNonMutatingAndCancellable() throws {
        let (_, view) = hostedView()
        let text = "alpha alp"
        try view.loadUTF8(Data(text.utf8), revision: 9)
        view.setPrimarySelectionUTF8Range(NSRange(location: text.utf8.count, length: 0))
        let before = view.contentUTF8

        #expect(view.showCompletionItems(["alpha", "alphabet"], replacingPrefixByteCount: 3))
        #expect(view.isCompletionActive)
        #expect(view.completionItemCount == 2)
        #expect(view.revision == 9)
        #expect(view.contentUTF8 == before)

        view.cancelCompletion()
        #expect(!view.isCompletionActive)
        #expect(view.completionItemCount == 0)
    }

    @Test @MainActor
    func intelligenceCaptureChecksBudgetBeforeSnapshotAndBindsCaretRevision() async throws {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        #expect(await workspace.start() == .saved)
        let adapter = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: adapter)
        let buffer = try #require(workspace.snapshot().activeBuffer)
        adapter.display(buffer)
        let text = String(repeating: "alpha ", count: 400) + "alp"
        adapter.install(EditorTextSnapshot(bufferID: buffer.bufferID, revision: 0, text: text))
        adapter.activeScintillaView?.setPrimarySelectionUTF8Range(
            NSRange(location: text.utf8.count, length: 0)
        )
        adapter.activeScintillaView?.resetInstrumentation()

        #expect(adapter.captureDocumentIntelligence(maximumBytes: 1_024) == nil)
        #expect(adapter.activeScintillaView?.snapshotReadCount == 0)
        let capture = try #require(adapter.captureDocumentIntelligence(maximumBytes: 4_096))
        #expect(capture.buffer == buffer)
        #expect(capture.caretUTF8 == text.utf8.count)
        #expect(adapter.activeScintillaView?.snapshotReadCount == 1)
        #expect(adapter.presentCompletionItems(
            ["alpha"], replacingPrefixByteCount: 3,
            expectedBuffer: capture.buffer, expectedCaretUTF8: capture.caretUTF8,
            expectedContextID: capture.contextID
        ))
        #expect(adapter.activeScintillaView?.isCompletionActive == true)
        _ = binding
    }

    @Test @MainActor
    func completionCaptureCannotPublishAcrossSplitPaneFocus() async throws {
        _ = NSApplication.shared
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        #expect(await workspace.start() == .saved)
        let adapter = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: adapter)
        let buffer = try #require(workspace.snapshot().activeBuffer)
        let text = "alpha alp"
        adapter.install(.init(bufferID: buffer.bufferID, revision: 0, text: text))
        adapter.display(buffer)
        adapter.split(orientation: .sideBySide)
        let primary = try #require(adapter.activeScintillaView)
        let secondary = try #require(adapter.secondaryScintillaView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = adapter.view
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        primary.setPrimarySelectionUTF8Range(NSRange(location: text.utf8.count, length: 0))
        secondary.setPrimarySelectionUTF8Range(NSRange(location: text.utf8.count, length: 0))
        primary.focusEditor()
        let capture = try #require(adapter.captureDocumentIntelligence(maximumBytes: 1_024))

        secondary.focusEditor()
        #expect(!adapter.presentCompletionItems(
            ["alpha"], replacingPrefixByteCount: 3,
            expectedBuffer: capture.buffer, expectedCaretUTF8: capture.caretUTF8,
            expectedContextID: capture.contextID
        ))
        #expect(!primary.isCompletionActive)
        #expect(!secondary.isCompletionActive)
        _ = binding
    }
}
