import AppKit
import DuckpadApplication
import DuckpadDomain
@testable import DuckpadEditorAdapter
import DuckpadInfrastructure
import DuckpadScintillaBridge
import Foundation
import Testing

private typealias ScintillaMessageInvocation = @convention(c) (
    AnyObject,
    Selector,
    UInt32,
    UInt,
    Int
) -> Int

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

    @MainActor
    private func waitForRevision(
        _ view: DPScintillaEditorView,
        _ expectedRevision: UInt64
    ) async throws {
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(5))
            if view.revision == expectedRevision { return }
        }
    }

    @MainActor
    private func applying(_ edit: EditorIncrementalEdit, to bytes: Data) -> Data? {
        guard edit.range.location >= 0,
              edit.range.length >= 0,
              edit.range.location <= bytes.count,
              edit.range.length <= bytes.count - edit.range.location else {
            return nil
        }
        var result = bytes
        result.replaceSubrange(
            edit.range.location..<(edit.range.location + edit.range.length),
            with: Data(edit.replacement.utf8)
        )
        return result
    }

    @MainActor
    private func sendTestingScintillaMessage(
        _ message: UInt32,
        wParam: UInt = 0,
        lParam: Int = 0,
        to view: DPScintillaEditorView
    ) throws -> Int {
        // `DPScintillaEditorView` deliberately hides Scintilla messages. These
        // test-only values come from the vendored 5.6.6 `Scintilla.h` and let
        // the integration test construct selection states AppKit cannot create.
        let rawView = try #require(view.value(forKey: "scintilla") as? NSObject)
        let selector = NSSelectorFromString("message:wParam:lParam:")
        let implementation = try #require(rawView.method(for: selector))
        let invoke = unsafeBitCast(implementation, to: ScintillaMessageInvocation.self)
        return invoke(rawView, selector, message, wParam, lParam)
    }

    @MainActor
    private func configureTestingSelectionTopology(
        _ view: DPScintillaEditorView,
        shape: DPScintillaSelectionShape,
        caretVirtualSpace: UInt = 0,
        anchorVirtualSpace: UInt = 0
    ) throws {
        // SCI_SETSELECTIONMODE=2422, SCI_SETVIRTUALSPACEOPTIONS=2596,
        // SCI_SETSELECTIONNCARETVIRTUALSPACE=2580, and
        // SCI_SETSELECTIONNANCHORVIRTUALSPACE=2582 in Scintilla 5.6.6.
        _ = try sendTestingScintillaMessage(2422, wParam: UInt(shape.rawValue), to: view)
        _ = try sendTestingScintillaMessage(2596, wParam: 2, to: view) // SCVS_USERACCESSIBLE
        _ = try sendTestingScintillaMessage(2580, lParam: Int(caretVirtualSpace), to: view)
        _ = try sendTestingScintillaMessage(2582, lParam: Int(anchorVirtualSpace), to: view)
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
    func directClosingDelimiterDedentsOneConfiguredLevel() throws {
        let cases: [(prefix: String, closer: String, tabWidth: UInt, useTabs: Bool, expected: String)] = [
            ("  ", "}", 2, false, "}"),
            ("    ", "]", 4, false, "]"),
            ("\t", ")", 4, true, ")"),
        ]

        for fixture in cases {
            let (_, view) = hostedView()
            try view.loadUTF8(Data(fixture.prefix.utf8), revision: 0)
            #expect(view.applyLexerNamed(
                "json",
                keywords: [],
                tabWidth: fixture.tabWidth,
                useTabs: fixture.useTabs,
                folding: true,
                braceMatching: true,
                maximumStyleBytes: 1_000_000
            ))
            view.setPrimarySelectionUTF8Range(NSRange(location: fixture.prefix.utf8.count, length: 0))

            view.insertCommittedText(fixture.closer)

            #expect(view.contentUTF8 == Data(fixture.expected.utf8))
            #expect(view.caretUTF8Position == fixture.expected.utf8.count)
            #expect(view.revision == 2)
        }
    }

    @Test @MainActor
    func mixedIndentationDedentsToExactTabStopColumn() throws {
        let cases: [(prefix: String, useTabs: Bool, expected: String)] = [
            ("\t  ", false, "  }"),
            ("\t  ", true, "\t}"),
            (" \t", false, "}"),
            (" \t", true, "}"),
        ]

        for fixture in cases {
            let (_, view) = hostedView()
            try view.loadUTF8(Data(fixture.prefix.utf8), revision: 0)
            #expect(view.applyLexerNamed(
                "json",
                keywords: [],
                tabWidth: 2,
                useTabs: fixture.useTabs,
                folding: true,
                braceMatching: true,
                maximumStyleBytes: 1_000_000
            ))
            view.setPrimarySelectionUTF8Range(NSRange(location: fixture.prefix.utf8.count, length: 0))

            view.insertCommittedText("}")

            #expect(view.contentUTF8 == Data(fixture.expected.utf8))
            #expect(view.caretUTF8Position == fixture.expected.utf8.count)
            #expect(view.revision == 2)
        }
    }

    @Test @MainActor
    func shortIndentationDedentsToZero() throws {
        let (_, view) = hostedView()
        try view.loadUTF8(Data("  ".utf8), revision: 0)
        #expect(view.applyLexerNamed(
            "json",
            keywords: [],
            tabWidth: 4,
            useTabs: false,
            folding: true,
            braceMatching: true,
            maximumStyleBytes: 1_000_000
        ))
        view.setPrimarySelectionUTF8Range(NSRange(location: 2, length: 0))

        view.insertCommittedText("}")

        #expect(view.contentUTF8 == Data("}".utf8))
        #expect(view.caretUTF8Position == 1)
        #expect(view.revision == 2)
    }

    @Test @MainActor
    func closerDedentPublishesTwoForwardEditsAndOneUndoRestoresBoth() throws {
        let source = "      "
        let adapter = ScintillaEditorAdapter()
        let bufferID = BufferID()
        adapter.install(.init(bufferID: bufferID, revision: 0, text: source))
        adapter.display(.init(bufferID: bufferID, revision: 0))
        #expect(adapter.applyLanguage(.init(
            languageID: .init(rawValue: "json"),
            lexerName: "json",
            indentation: .init(width: 4),
            folding: true,
            braceMatching: true
        )))
        let view = try #require(adapter.activeScintillaView)
        view.setPrimarySelectionUTF8Range(NSRange(location: source.utf8.count, length: 0))
        var edits: [EditorIncrementalEdit] = []
        adapter.onEdit = { edit in
            edits.append(edit)
            return .accepted(newRevision: edit.expectedRevision + 1)
        }
        view.resetInstrumentation()

        view.insertCommittedText("}")

        #expect(edits.count == 2)
        #expect(edits.map(\.expectedRevision) == [0, 1])
        if edits.count == 2 {
            #expect(edits[0].range == .init(location: source.utf8.count, length: 0))
            #expect(edits[0].replacement == "}")
            #expect(edits[1].range == .init(location: 0, length: source.utf8.count))
            #expect(edits[1].replacement == "  ")
        }
        #expect(view.incrementalNotificationCount == 2)
        #expect(view.contentUTF8 == Data("  }".utf8))
        #expect(view.revision == 2)

        view.undo()

        #expect(view.contentUTF8 == Data(source.utf8))
        #expect(adapter.recoverySnapshot(for: bufferID)?.utf8 == Data(source.utf8))
        #expect(view.revision > 2)
        #expect(edits.dropFirst(2).allSatisfy { $0.expectedRevision >= 2 })
    }

    @Test @MainActor
    func repeatedCloserDedentsRetainInitiatingViewTracking() async throws {
        _ = NSApplication.shared
        let source = "    "
        let adapter = ScintillaEditorAdapter()
        let bufferID = BufferID()
        adapter.install(.init(bufferID: bufferID, revision: 0, text: source))
        adapter.display(.init(bufferID: bufferID, revision: 0))
        adapter.split(orientation: .sideBySide)
        #expect(adapter.applyLanguage(.init(
            languageID: .init(rawValue: "json"),
            lexerName: "json",
            indentation: .init(width: 4),
            folding: true,
            braceMatching: true
        )))
        let primary = try #require(adapter.activeScintillaView)
        let secondary = try #require(adapter.secondaryScintillaView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = adapter.view
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        var callbacks = 0
        adapter.onEdit = { edit in
            callbacks += 1
            return .accepted(newRevision: edit.expectedRevision + 1)
        }

        primary.setPrimarySelectionUTF8Range(NSRange(location: source.utf8.count, length: 0))
        primary.focusEditor()
        primary.insertCommittedText("}")
        #expect(primary.contentUTF8 == Data("}".utf8))
        #expect(callbacks == 2)

        adapter.install(.init(bufferID: bufferID, revision: 0, text: source))
        primary.setPrimarySelectionUTF8Range(NSRange(location: source.utf8.count, length: 0))
        primary.focusEditor()
        callbacks = 0
        adapter.onEdit = { .rejected(currentRevision: $0.expectedRevision) }
        primary.insertCommittedText("}")
        try await waitForRevision(primary, 0)
        #expect(primary.contentUTF8 == Data(source.utf8))
        #expect(secondary.contentUTF8 == Data(source.utf8))
        #expect(callbacks == 0)

        adapter.install(.init(bufferID: bufferID, revision: 0, text: source))
        secondary.setPrimarySelectionUTF8Range(NSRange(location: source.utf8.count, length: 0))
        secondary.focusEditor()
        callbacks = 0
        adapter.onEdit = { edit in
            callbacks += 1
            return .accepted(newRevision: edit.expectedRevision + 1)
        }
        secondary.insertCommittedText("}")
        #expect(primary.contentUTF8 == Data("}".utf8))
        #expect(secondary.contentUTF8 == Data("}".utf8))
        #expect(callbacks == 2)

        adapter.install(.init(bufferID: bufferID, revision: 0, text: source))
        secondary.setPrimarySelectionUTF8Range(NSRange(location: source.utf8.count, length: 0))
        secondary.focusEditor()
        callbacks = 0
        adapter.onEdit = { .rejected(currentRevision: $0.expectedRevision) }
        secondary.insertCommittedText("}")
        try await waitForRevision(primary, 0)
        #expect(primary.contentUTF8 == Data(source.utf8))
        #expect(secondary.contentUTF8 == Data(source.utf8))
        #expect(callbacks == 0)
    }

    @Test @MainActor
    func closerDedentRedoRestoresBothAndUsesExistingComponentAuthority() throws {
        let source = "      "
        let adapter = ScintillaEditorAdapter()
        let bufferID = BufferID()
        adapter.install(.init(bufferID: bufferID, revision: 0, text: source))
        adapter.display(.init(bufferID: bufferID, revision: 0))
        #expect(adapter.applyLanguage(.init(
            languageID: .init(rawValue: "json"),
            lexerName: "json",
            indentation: .init(width: 4),
            folding: true,
            braceMatching: true
        )))
        let view = try #require(adapter.activeScintillaView)
        view.setPrimarySelectionUTF8Range(NSRange(location: source.utf8.count, length: 0))
        var edits: [EditorIncrementalEdit] = []
        adapter.onEdit = { edit in
            edits.append(edit)
            return .accepted(newRevision: edit.expectedRevision + 1)
        }

        view.insertCommittedText("}")
        view.undo()
        let revisionAfterUndo = view.revision
        #expect(view.contentUTF8 == Data(source.utf8))

        view.redo()

        #expect(view.contentUTF8 == Data("  }".utf8))
        #expect(adapter.recoverySnapshot(for: bufferID)?.utf8 == Data("  }".utf8))
        #expect(view.revision > revisionAfterUndo)
        #expect(edits.count >= 6)
        #expect(edits.enumerated().allSatisfy { $0.element.expectedRevision == UInt64($0.offset) })
    }

    @Test @MainActor
    func rejectedCloserCancelsPendingIndentationAndRecoversPreInputAuthority() async throws {
        let source = "    "
        let adapter = ScintillaEditorAdapter()
        let bufferID = BufferID()
        adapter.install(.init(bufferID: bufferID, revision: 0, text: source))
        adapter.display(.init(bufferID: bufferID, revision: 0))
        #expect(adapter.applyLanguage(.init(
            languageID: .init(rawValue: "json"),
            lexerName: "json",
            indentation: .init(width: 4),
            folding: true,
            braceMatching: true
        )))
        let view = try #require(adapter.activeScintillaView)
        view.setPrimarySelectionUTF8Range(NSRange(location: source.utf8.count, length: 0))
        var edits: [EditorIncrementalEdit] = []
        adapter.onEdit = { edit in
            edits.append(edit)
            return .rejected(currentRevision: edit.expectedRevision)
        }

        view.insertCommittedText("}")
        try await waitForRevision(view, 0)

        #expect(edits.count == 1)
        #expect(edits.first?.replacement == "}")
        #expect(view.contentUTF8 == Data(source.utf8))
        #expect(adapter.recoverySnapshot(for: bufferID)?.utf8 == Data(source.utf8))
        #expect(!view.canUndo)
    }

    @Test @MainActor
    func rejectedIndentationReplacementKeepsAcceptedCloserAuthority() async throws {
        let source = "    "
        let adapter = ScintillaEditorAdapter()
        let bufferID = BufferID()
        adapter.install(.init(bufferID: bufferID, revision: 0, text: source))
        adapter.display(.init(bufferID: bufferID, revision: 0))
        #expect(adapter.applyLanguage(.init(
            languageID: .init(rawValue: "json"),
            lexerName: "json",
            indentation: .init(width: 4),
            folding: true,
            braceMatching: true
        )))
        let view = try #require(adapter.activeScintillaView)
        view.setPrimarySelectionUTF8Range(NSRange(location: source.utf8.count, length: 0))
        var edits: [EditorIncrementalEdit] = []
        adapter.onEdit = { edit in
            edits.append(edit)
            return edits.count == 1
                ? .accepted(newRevision: edit.expectedRevision + 1)
                : .rejected(currentRevision: edit.expectedRevision)
        }

        view.insertCommittedText("}")
        try await waitForRevision(view, 1)

        #expect(edits.count == 2)
        #expect(edits.map(\.replacement) == ["}", ""])
        #expect(view.contentUTF8 == Data((source + "}").utf8))
        #expect(adapter.recoverySnapshot(for: bufferID)?.utf8 == Data((source + "}").utf8))
        #expect(!view.canUndo)
    }

    @Test @MainActor
    func secondaryCloserDedentUsesPrimaryPublisherAndCancelsTheInitiatorOnRejection() async throws {
        _ = NSApplication.shared
        let source = "      "
        let adapter = ScintillaEditorAdapter()
        let bufferID = BufferID()
        adapter.install(.init(bufferID: bufferID, revision: 0, text: source))
        adapter.display(.init(bufferID: bufferID, revision: 0))
        adapter.split(orientation: .sideBySide)
        #expect(adapter.applyLanguage(.init(
            languageID: .init(rawValue: "json"),
            lexerName: "json",
            indentation: .init(width: 4),
            folding: true,
            braceMatching: true
        )))
        let primary = try #require(adapter.activeScintillaView)
        let secondary = try #require(adapter.secondaryScintillaView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = adapter.view
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        secondary.setPrimarySelectionUTF8Range(NSRange(location: source.utf8.count, length: 0))
        secondary.focusEditor()
        primary.resetInstrumentation()
        secondary.resetInstrumentation()
        var callbacks = 0
        adapter.onEdit = { edit in
            callbacks += 1
            return .accepted(newRevision: edit.expectedRevision + 1)
        }

        secondary.insertCommittedText("}")

        #expect(callbacks == 2)
        #expect(primary.incrementalNotificationCount == 2)
        #expect(secondary.incrementalNotificationCount == 0)
        #expect(primary.revision == 2)
        #expect(secondary.revision == 2)
        #expect(primary.contentUTF8 == Data("  }".utf8))
        #expect(secondary.contentUTF8 == Data("  }".utf8))
        #expect(secondary.caretUTF8Position == 3)

        adapter.install(.init(bufferID: bufferID, revision: 0, text: source))
        secondary.setPrimarySelectionUTF8Range(NSRange(location: source.utf8.count, length: 0))
        secondary.focusEditor()
        primary.resetInstrumentation()
        secondary.resetInstrumentation()
        callbacks = 0
        adapter.onEdit = { edit in
            callbacks += 1
            return .rejected(currentRevision: edit.expectedRevision)
        }

        secondary.insertCommittedText("}")
        try await waitForRevision(primary, 0)

        #expect(callbacks == 1)
        #expect(primary.incrementalNotificationCount == 1)
        #expect(secondary.incrementalNotificationCount == 0)
        #expect(primary.contentUTF8 == Data(source.utf8))
        #expect(secondary.contentUTF8 == Data(source.utf8))
        #expect(primary.revision == 0)
        #expect(secondary.revision == 0)
        #expect(!primary.canUndo)
    }

    @Test @MainActor
    func closerDedentRequiresFiveRevisionBudget() throws {
        let source = "  "
        let acceptedSource = "\t  "
        let acceptedRevision = UInt64.max - 5
        let (_, accepted) = hostedView()
        try accepted.loadUTF8(Data(acceptedSource.utf8), revision: acceptedRevision)
        #expect(accepted.applyLexerNamed(
            "json",
            keywords: [],
            tabWidth: 4,
            useTabs: false,
            folding: true,
            braceMatching: true,
            maximumStyleBytes: 1_000_000
        ))
        accepted.setPrimarySelectionUTF8Range(NSRange(location: acceptedSource.utf8.count, length: 0))
        let originalCaret = accepted.caretUTF8Position
        let originalAnchor = accepted.anchorUTF8Position
        var edits: [DPScintillaEdit] = []
        accepted.onEdit = { edits.append($0) }

        accepted.insertCommittedText("}")

        #expect(accepted.contentUTF8 == Data("  }".utf8))
        #expect(accepted.revision == UInt64.max - 3)
        #expect(accepted.caretUTF8Position == 3)
        #expect(accepted.anchorUTF8Position == 3)
        #expect(accepted.canUndo)
        #expect(edits.count == 2)
        #expect(edits[0].origin == .user)
        #expect(edits[0].range == NSRange(location: acceptedSource.utf8.count, length: 0))
        #expect(edits[0].replacementUTF8 == Data("}".utf8))
        #expect(edits[1].origin == .user)
        #expect(edits[1].range == NSRange(location: 0, length: acceptedSource.utf8.count))
        #expect(edits[1].replacementUTF8 == Data("  ".utf8))
        accepted.undo()
        #expect(accepted.contentUTF8 == Data(acceptedSource.utf8))
        #expect(accepted.caretUTF8Position == originalCaret)
        #expect(accepted.anchorUTF8Position == originalAnchor)
        #expect(accepted.revision == UInt64.max)
        #expect(edits.count == 5)
        #expect(edits.dropFirst(2).allSatisfy { $0.origin == .undo })

        for revision in (UInt64.max - 4)...(UInt64.max - 1) {
            let (_, view) = hostedView()
            try view.loadUTF8(Data(source.utf8), revision: revision)
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

            view.insertCommittedText("}")

            #expect(view.contentUTF8 == Data("  }".utf8))
            #expect(view.revision == revision + 1)
        }

        let (_, exhausted) = hostedView()
        try exhausted.loadUTF8(Data(source.utf8), revision: .max)
        #expect(exhausted.applyLexerNamed(
            "json",
            keywords: [],
            tabWidth: 2,
            useTabs: false,
            folding: true,
            braceMatching: true,
            maximumStyleBytes: 1_000_000
        ))
        exhausted.setPrimarySelectionUTF8Range(NSRange(location: source.utf8.count, length: 0))
        exhausted.insertCommittedText("}")
        #expect(exhausted.contentUTF8 == Data(source.utf8))
        #expect(exhausted.revision == .max)
    }

    @Test @MainActor
    func closerDedentAcceptsExact4096ByteWhitespacePrefix() throws {
        let source = String(repeating: " ", count: 4_096)
        let expected = String(repeating: " ", count: 4_094) + "}"
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
        var edits: [DPScintillaEdit] = []
        view.onEdit = { edits.append($0) }

        view.insertCommittedText("}")

        #expect(view.contentUTF8 == Data(expected.utf8))
        #expect(view.caretUTF8Position == expected.utf8.count)
        #expect(view.anchorUTF8Position == expected.utf8.count)
        #expect(view.revision == 2)
        #expect(view.incrementalNotificationCount == 2)
        #expect(edits.count == 2)
        #expect(edits.map(\.replacementUTF8) == [
            Data("}".utf8),
            Data(String(repeating: " ", count: 4_094).utf8),
        ])

        view.undo()

        #expect(view.contentUTF8 == Data(source.utf8))
        #expect(view.caretUTF8Position == source.utf8.count)
        #expect(view.anchorUTF8Position == source.utf8.count)
    }

    @Test @MainActor
    func undoRedoRejectionRecoversEachAcceptedComponentPrefix() async throws {
        let source = "      "

        @MainActor
        func makeAdapter() throws -> (ScintillaEditorAdapter, BufferID, DPScintillaEditorView) {
            let adapter = ScintillaEditorAdapter()
            let bufferID = BufferID()
            adapter.install(.init(bufferID: bufferID, revision: 0, text: source))
            adapter.display(.init(bufferID: bufferID, revision: 0))
            #expect(adapter.applyLanguage(.init(
                languageID: .init(rawValue: "json"),
                lexerName: "json",
                indentation: .init(width: 4),
                folding: true,
                braceMatching: true
            )))
            let view = try #require(adapter.activeScintillaView)
            view.setPrimarySelectionUTF8Range(NSRange(location: source.utf8.count, length: 0))
            return (adapter, bufferID, view)
        }

        let (baselineAdapter, _, baselineView) = try makeAdapter()
        var baselineEdits: [EditorIncrementalEdit] = []
        baselineAdapter.onEdit = { edit in
            baselineEdits.append(edit)
            return .accepted(newRevision: edit.expectedRevision + 1)
        }
        baselineView.insertCommittedText("}")
        baselineView.undo()
        let undoComponentCount = baselineEdits.count - 2
        #expect(undoComponentCount > 0)
        baselineView.redo()
        let redoComponentCount = baselineEdits.count - 2 - undoComponentCount
        #expect(redoComponentCount > 0)

        for rejectedIndex in 0..<undoComponentCount {
            let (adapter, bufferID, view) = try makeAdapter()
            var accepted: [EditorIncrementalEdit] = []
            var undoStarted = false
            var undoComponent = 0
            adapter.onEdit = { edit in
                if undoStarted {
                    defer { undoComponent += 1 }
                    if undoComponent == rejectedIndex {
                        return .rejected(currentRevision: edit.expectedRevision)
                    }
                }
                accepted.append(edit)
                return .accepted(newRevision: edit.expectedRevision + 1)
            }

            view.insertCommittedText("}")
            undoStarted = true
            view.undo()

            var expected = Data(source.utf8)
            for acceptedEdit in accepted {
                expected = try #require(applying(acceptedEdit, to: expected))
            }
            try await waitForRevision(view, UInt64(accepted.count))
            #expect(view.contentUTF8 == expected)
            #expect(adapter.recoverySnapshot(for: bufferID)?.utf8 == expected)
        }

        for rejectedIndex in 0..<redoComponentCount {
            let (adapter, bufferID, view) = try makeAdapter()
            var accepted: [EditorIncrementalEdit] = []
            var redoStarted = false
            var redoComponent = 0
            adapter.onEdit = { edit in
                if redoStarted {
                    defer { redoComponent += 1 }
                    if redoComponent == rejectedIndex {
                        return .rejected(currentRevision: edit.expectedRevision)
                    }
                }
                accepted.append(edit)
                return .accepted(newRevision: edit.expectedRevision + 1)
            }

            view.insertCommittedText("}")
            view.undo()
            redoStarted = true
            view.redo()

            var expected = Data(source.utf8)
            for acceptedEdit in accepted {
                expected = try #require(applying(acceptedEdit, to: expected))
            }
            try await waitForRevision(view, UInt64(accepted.count))
            #expect(view.contentUTF8 == expected)
            #expect(adapter.recoverySnapshot(for: bufferID)?.utf8 == expected)
        }
    }

    @Test @MainActor
    func closerDedentExcludesPasteIMEProgrammaticMultiCharacterAndNonWhitespaceLines() throws {
        let source = "  "

        @MainActor
        func configuredView(_ text: String = source) throws -> (NSWindow, DPScintillaEditorView) {
            let hosted = hostedView()
            try hosted.1.loadUTF8(Data(text.utf8), revision: 0)
            #expect(hosted.1.applyLexerNamed(
                "json",
                keywords: [],
                tabWidth: 2,
                useTabs: false,
                folding: true,
                braceMatching: true,
                maximumStyleBytes: 1_000_000
            ))
            hosted.1.setPrimarySelectionUTF8Range(NSRange(location: text.utf8.count, length: 0))
            return hosted
        }

        @MainActor
        func assertFollowingEditUndoesWithoutGrouping(
            in view: DPScintillaEditorView,
            preserving literalText: String
        ) {
            view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 0))
            view.insertCommittedText("x")
            #expect(view.contentUTF8 == Data(("x" + literalText).utf8))
            #expect(view.canUndo)
            view.undo()
            #expect(view.contentUTF8 == Data(literalText.utf8))
        }

        let (_, pasted) = try configuredView()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("}", forType: .string)
        pasted.paste()
        #expect(pasted.contentUTF8 == Data("  }".utf8))
        #expect(pasted.revision == 1)
        assertFollowingEditUndoesWithoutGrouping(in: pasted, preserving: "  }")

        let (imeWindow, ime) = try configuredView()
        imeWindow.makeKeyAndOrderFront(nil)
        defer { imeWindow.orderOut(nil) }
        ime.focusEditor()
        ime.setMarkedText(
            "}",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let textInputClient = try #require(imeWindow.firstResponder as? NSTextInputClient)
        textInputClient.insertText("}", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(ime.contentUTF8 == Data("  }".utf8))
        #expect(ime.revision == 3)
        ime.unmarkText()
        assertFollowingEditUndoesWithoutGrouping(in: ime, preserving: "  }")

        let (_, programmatic) = try configuredView()
        try programmatic.replaceUTF8Range(
            NSRange(location: source.utf8.count, length: 0),
            withReplacement: Data("}".utf8),
            expectedRevision: 0,
            resultingRevision: 1
        )
        #expect(programmatic.contentUTF8 == Data("  }".utf8))
        #expect(programmatic.revision == 1)
        assertFollowingEditUndoesWithoutGrouping(in: programmatic, preserving: "  }")

        let (_, multipleCharacters) = try configuredView()
        multipleCharacters.insertCommittedText("}}")
        #expect(multipleCharacters.contentUTF8 == Data("  }}".utf8))
        #expect(multipleCharacters.revision == 2)
        assertFollowingEditUndoesWithoutGrouping(in: multipleCharacters, preserving: "  }}")

        let (_, nonWhitespace) = try configuredView("  value")
        nonWhitespace.insertCommittedText("}")
        #expect(nonWhitespace.contentUTF8 == Data("  value}".utf8))
        #expect(nonWhitespace.revision == 1)
        assertFollowingEditUndoesWithoutGrouping(in: nonWhitespace, preserving: "  value}")

        let (_, zeroIndentation) = try configuredView("")
        zeroIndentation.insertCommittedText("}")
        #expect(zeroIndentation.contentUTF8 == Data("}".utf8))
        #expect(zeroIndentation.revision == 1)
        assertFollowingEditUndoesWithoutGrouping(in: zeroIndentation, preserving: "}")

        let (multipleWindow, multipleSelection) = try configuredView("  \n  ")
        multipleSelection.setPrimarySelectionUTF8Range(NSRange(location: 2, length: 0))
        #expect(multipleSelection.addSelectionUTF8Range(NSRange(location: 5, length: 0)))
        multipleWindow.makeKeyAndOrderFront(nil)
        multipleSelection.focusEditor()
        try sendKeyEvent(
            characters: "}",
            charactersIgnoringModifiers: "]",
            modifierFlags: [.shift],
            keyCode: 30,
            to: multipleWindow
        )
        #expect(multipleSelection.contentUTF8 == Data("  \n  }".utf8))
        #expect(multipleSelection.revision == 1)
        assertFollowingEditUndoesWithoutGrouping(
            in: multipleSelection,
            preserving: "  \n  }"
        )
        multipleWindow.orderOut(nil)

        let (_, rectangularSelection) = try configuredView()
        try configureTestingSelectionTopology(
            rectangularSelection,
            shape: .rectangle
        )
        #expect(try sendTestingScintillaMessage(2423, to: rectangularSelection) == 1)
        rectangularSelection.resetInstrumentation()
        rectangularSelection.insertCommittedText("}")
        #expect(rectangularSelection.contentUTF8 == Data("  }".utf8))
        #expect(rectangularSelection.revision == 1)
        #expect(rectangularSelection.incrementalNotificationCount == 1)
        try configureTestingSelectionTopology(rectangularSelection, shape: .stream)
        assertFollowingEditUndoesWithoutGrouping(
            in: rectangularSelection,
            preserving: "  }"
        )

        let (_, virtualSelection) = try configuredView()
        try configureTestingSelectionTopology(
            virtualSelection,
            shape: .stream,
            caretVirtualSpace: 1,
            anchorVirtualSpace: 1
        )
        #expect(try sendTestingScintillaMessage(2581, to: virtualSelection) == 1)
        #expect(try sendTestingScintillaMessage(2583, to: virtualSelection) == 1)
        virtualSelection.resetInstrumentation()
        virtualSelection.insertCommittedText("}")
        // A rejected preflight preserves Scintilla's normal virtual-space
        // materialization: one space plus the literal closer, never two
        // aggregate smart-dedent edits.
        #expect(virtualSelection.contentUTF8 == Data("   }".utf8))
        #expect(virtualSelection.revision == 3)
        #expect(virtualSelection.incrementalNotificationCount == 3)
        _ = try sendTestingScintillaMessage(2556, wParam: 0, to: virtualSelection)
        #expect(try sendTestingScintillaMessage(2581, to: virtualSelection) == 0)
        #expect(try sendTestingScintillaMessage(2583, to: virtualSelection) == 0)
        assertFollowingEditUndoesWithoutGrouping(
            in: virtualSelection,
            preserving: "   }"
        )

        let longPrefix = String(repeating: " ", count: 4_097)
        let (_, longWhitespace) = try configuredView(longPrefix)
        longWhitespace.resetInstrumentation()
        longWhitespace.insertCommittedText("}")
        #expect(longWhitespace.snapshotReadCount == 0)
        #expect(longWhitespace.contentUTF8 == Data((longPrefix + "}").utf8))
        #expect(longWhitespace.revision == 1)
        #expect(longWhitespace.incrementalNotificationCount == 1)
        assertFollowingEditUndoesWithoutGrouping(
            in: longWhitespace,
            preserving: longPrefix + "}"
        )
    }

    @Test @MainActor
    func explicitIndentUsesTwoAndFourSpaceLanguageWidths() throws {
        for width in [2, 4] {
            let source = "line"
            let adapter = ScintillaEditorAdapter()
            let bufferID = BufferID()
            adapter.install(.init(bufferID: bufferID, revision: 0, text: source))
            adapter.display(.init(bufferID: bufferID, revision: 0))
            #expect(adapter.applyLanguage(.init(
                languageID: .init(rawValue: "json"),
                lexerName: "json",
                indentation: .init(width: width),
                folding: true,
                braceMatching: true
            )))
            let view = try #require(adapter.activeScintillaView)
            view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 0))
            adapter.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }

            adapter.perform(.indent)

            #expect(view.contentUTF8 == Data((String(repeating: " ", count: width) + source).utf8))
            #expect(view.revision == 1)
        }
    }

    @Test @MainActor
    func explicitIndentUsesTabsForMakefileConfiguration() throws {
        let adapter = ScintillaEditorAdapter()
        let bufferID = BufferID()
        adapter.install(.init(bufferID: bufferID, revision: 0, text: "target:"))
        adapter.display(.init(bufferID: bufferID, revision: 0))
        #expect(adapter.applyLanguage(.init(
            languageID: .init(rawValue: "makefile"),
            lexerName: "makefile",
            indentation: .init(width: 4, useTabs: true),
            folding: true,
            braceMatching: true
        )))
        let view = try #require(adapter.activeScintillaView)
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 0))
        adapter.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }

        adapter.perform(.indent)

        #expect(view.contentUTF8 == Data("\ttarget:".utf8))
        #expect(view.revision == 1)
    }

    @Test @MainActor
    func explicitMultilineIndentAndOutdentPreserveSelectionAndGroupUndo() throws {
        let source = "a\nb\nc"
        let adapter = ScintillaEditorAdapter()
        let bufferID = BufferID()
        adapter.install(.init(bufferID: bufferID, revision: 0, text: source))
        adapter.display(.init(bufferID: bufferID, revision: 0))
        #expect(adapter.applyLanguage(.init(
            languageID: .init(rawValue: "json"),
            lexerName: "json",
            indentation: .init(width: 2),
            folding: true,
            braceMatching: true
        )))
        let view = try #require(adapter.activeScintillaView)
        view.restoreCaretUTF8Position(
            0,
            anchorPosition: UInt(source.utf8.count),
            firstVisibleLine: 0,
            horizontalScrollOffset: 0,
            wordWrapEnabled: true
        )
        adapter.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }

        adapter.perform(.indent)

        let indented = "  a\n  b\n  c"
        #expect(view.contentUTF8 == Data(indented.utf8))
        #expect(view.caretUTF8Position == 0)
        #expect(view.anchorUTF8Position == indented.utf8.count)
        let revisionAfterIndent = view.revision
        view.undo()
        #expect(view.contentUTF8 == Data(source.utf8))
        #expect(view.caretUTF8Position == 0)
        #expect(view.anchorUTF8Position == source.utf8.count)

        view.redo()
        #expect(view.contentUTF8 == Data(indented.utf8))
        adapter.perform(.unindent)
        #expect(view.contentUTF8 == Data(source.utf8))
        #expect(view.caretUTF8Position == 0)
        #expect(view.anchorUTF8Position == source.utf8.count)
        #expect(view.revision > revisionAfterIndent)
    }

    @Test @MainActor
    func explicitOutdentHandlesMixedLeadingWhitespace() throws {
        let source = " \tfirst\n\t  second"
        let adapter = ScintillaEditorAdapter()
        let bufferID = BufferID()
        adapter.install(.init(bufferID: bufferID, revision: 0, text: source))
        adapter.display(.init(bufferID: bufferID, revision: 0))
        #expect(adapter.applyLanguage(.init(
            languageID: .init(rawValue: "json"),
            lexerName: "json",
            indentation: .init(width: 4),
            folding: true,
            braceMatching: true
        )))
        let view = try #require(adapter.activeScintillaView)
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: source.utf8.count))
        adapter.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }

        adapter.perform(.unindent)

        #expect(view.contentUTF8 == Data("first\n  second".utf8))
        #expect(view.revision == 3)
    }

    @Test @MainActor
    func explicitIndentAdvancesDirtyAndRecoveryForEveryNativeEdit() async throws {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        #expect(await workspace.start() == .saved)
        let adapter = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: adapter)
        let buffer = try #require(workspace.snapshot().activeBuffer)
        let source = "one\ntwo"
        adapter.install(.init(bufferID: buffer.bufferID, revision: 0, text: source))
        adapter.display(.init(bufferID: buffer.bufferID, revision: 0))
        #expect(adapter.applyLanguage(.init(
            languageID: .init(rawValue: "json"),
            lexerName: "json",
            indentation: .init(width: 2),
            folding: true,
            braceMatching: true
        )))
        let view = try #require(adapter.activeScintillaView)
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: source.utf8.count))
        let appendCount = adapter.recoveryJournalAppendCount

        adapter.perform(.indent)

        let expected = "  one\n  two"
        #expect(view.contentUTF8 == Data(expected.utf8))
        #expect(workspace.snapshot().activeBuffer?.revision == 2)
        #expect(workspace.snapshot().tabs.first?.isDirty == true)
        #expect(adapter.recoveryJournalAppendCount == appendCount + 2)
        #expect(adapter.recoverySnapshot(for: buffer.bufferID)?.utf8 == Data(expected.utf8))
        _ = binding
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
    func blockCommentWrapAndUnwrapPreserveUTF8CRLFAndSelectionDirection() throws {
        let (_, view) = hostedView()
        let prefix = "앞\r\n"
        let payload = "한글🦆"
        let source = prefix + payload + "\r\n뒤"
        let payloadStart = prefix.utf8.count
        let payloadEnd = payloadStart + payload.utf8.count
        try view.loadUTF8(Data(source.utf8), revision: 4)
        view.restoreCaretUTF8Position(
            UInt(payloadStart),
            anchorPosition: UInt(payloadEnd),
            firstVisibleLine: 0,
            horizontalScrollOffset: 0,
            wordWrapEnabled: true
        )

        #expect(view.toggleBlockComments(
            withStartUTF8: Data("/*".utf8),
            endUTF8: Data("*/".utf8),
            selectionOwner: view
        ))

        let wrapped = prefix + "/*" + payload + "*/\r\n뒤"
        #expect(view.contentUTF8 == Data(wrapped.utf8))
        #expect(view.caretUTF8Position == payloadStart)
        #expect(view.anchorUTF8Position == payloadEnd + 4)
        #expect(view.revision == 5)

        #expect(view.toggleBlockComments(
            withStartUTF8: Data("/*".utf8),
            endUTF8: Data("*/".utf8),
            selectionOwner: view
        ))

        #expect(view.contentUTF8 == Data(source.utf8))
        #expect(view.caretUTF8Position == payloadStart)
        #expect(view.anchorUTF8Position == payloadEnd)
        #expect(view.revision == 6)
    }

    @Test @MainActor
    func emptyCaretInsertsAndRemovesAdjacentPairAtExactBytePosition() throws {
        let (_, view) = hostedView()
        let source = "한글🦆x"
        let caret = "한글🦆".utf8.count
        try view.loadUTF8(Data(source.utf8), revision: 7)
        view.setPrimarySelectionUTF8Range(NSRange(location: caret, length: 0))

        #expect(view.toggleBlockComments(
            withStartUTF8: Data("<!--".utf8),
            endUTF8: Data("-->".utf8),
            selectionOwner: view
        ))
        #expect(view.contentUTF8 == Data("한글🦆<!---->x".utf8))
        #expect(view.caretUTF8Position == caret + 4)
        #expect(view.anchorUTF8Position == caret + 4)
        #expect(view.revision == 8)

        #expect(view.toggleBlockComments(
            withStartUTF8: Data("<!--".utf8),
            endUTF8: Data("-->".utf8),
            selectionOwner: view
        ))
        #expect(view.contentUTF8 == Data(source.utf8))
        #expect(view.caretUTF8Position == caret)
        #expect(view.anchorUTF8Position == caret)
        #expect(view.revision == 9)
    }

    @Test @MainActor
    func identicalDelimitersRequireTwoDisjointEdgesBeforeUnwrap() throws {
        let (_, view) = hostedView()
        try view.loadUTF8(Data("x|y".utf8), revision: 0)
        view.setPrimarySelectionUTF8Range(NSRange(location: 1, length: 1))

        #expect(view.toggleBlockComments(
            withStartUTF8: Data("|".utf8),
            endUTF8: Data("|".utf8),
            selectionOwner: view
        ))
        #expect(view.contentUTF8 == Data("x|||y".utf8))
        #expect(view.anchorUTF8Position == 1)
        #expect(view.caretUTF8Position == 4)

        try view.loadUTF8(Data("x||y".utf8), revision: 4)
        view.setPrimarySelectionUTF8Range(NSRange(location: 1, length: 2))
        #expect(view.toggleBlockComments(
            withStartUTF8: Data("|".utf8),
            endUTF8: Data("|".utf8),
            selectionOwner: view
        ))
        #expect(view.contentUTF8 == Data("xy".utf8))
        #expect(view.caretUTF8Position == 1)
        #expect(view.anchorUTF8Position == 1)
    }

    @Test @MainActor
    func nestedDelimiterTextIsHandledLiterally() throws {
        let (_, view) = hostedView()
        let source = "/* outer /* inner */ outer */"
        try view.loadUTF8(Data(source.utf8), revision: 0)
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: source.utf8.count))

        #expect(view.toggleBlockComments(
            withStartUTF8: Data("/*".utf8),
            endUTF8: Data("*/".utf8),
            selectionOwner: view
        ))
        let expected = " outer /* inner */ outer "
        #expect(view.contentUTF8 == Data(expected.utf8))
        #expect(view.anchorUTF8Position == 0)
        #expect(view.caretUTF8Position == expected.utf8.count)
    }

    @Test @MainActor
    func blockCommentRejectsInvalidDelimiterDataWithoutMutation() throws {
        let (_, view) = hostedView()
        let source = "한글"
        try view.loadUTF8(Data(source.utf8), revision: 11)
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: source.utf8.count))
        var callbacks = 0
        view.onEdit = { _ in callbacks += 1 }
        let originalCaret = view.caretUTF8Position
        let originalAnchor = view.anchorUTF8Position

        for (start, end) in [
            (Data(), Data("*/".utf8)),
            (Data("/*".utf8), Data()),
            (Data([0xFF]), Data("*/".utf8)),
            (Data(String(repeating: "a", count: 65).utf8), Data("*/".utf8)),
            (Data("/*".utf8), Data(String(repeating: "b", count: 65).utf8)),
        ] {
            #expect(!view.toggleBlockComments(
                withStartUTF8: start,
                endUTF8: end,
                selectionOwner: view
            ))
            #expect(view.contentUTF8 == Data(source.utf8))
            #expect(view.revision == 11)
            #expect(view.caretUTF8Position == originalCaret)
            #expect(view.anchorUTF8Position == originalAnchor)
            #expect(callbacks == 0)
        }
    }

    @Test @MainActor
    func blockCommentRejectsMultiRectangularLineThinAndVirtualSelections() throws {
        let topologyCases: [(DPScintillaSelectionShape, UInt, UInt, UInt, Bool)] = [
            (.stream, 1, 0, 0, true),
            (.stream, 2, 0, 0, false),
            (.rectangle, 1, 0, 0, false),
            (.lines, 1, 0, 0, false),
            (.thin, 1, 0, 0, false),
            (.stream, 1, 1, 0, false),
            (.stream, 1, 0, 1, false),
        ]
        for topology in topologyCases {
            #expect(DPScintillaEditorView.blockCommentSupportsSelectionShape(
                topology.0,
                count: topology.1,
                caretVirtualSpace: topology.2,
                anchorVirtualSpace: topology.3
            ) == topology.4)
        }

        let (window, view) = hostedView()
        let source = "one two"
        try view.loadUTF8(Data(source.utf8), revision: 3)
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 3))
        #expect(view.addSelectionUTF8Range(NSRange(location: 4, length: 3)))
        var callbacks = 0
        view.onEdit = { _ in callbacks += 1 }
        window.makeKeyAndOrderFront(nil)
        view.focusEditor()
        let focusedBefore = view.hasEditorFocus

        #expect(!view.toggleBlockComments(
            withStartUTF8: Data("/*".utf8),
            endUTF8: Data("*/".utf8),
            selectionOwner: view
        ))
        #expect(view.contentUTF8 == Data(source.utf8))
        #expect(view.selectionCount == 2)
        #expect(view.revision == 3)
        #expect(!view.canUndo)
        #expect(callbacks == 0)
        #expect(view.hasEditorFocus == focusedBefore)
        window.orderOut(nil)
    }

    @Test @MainActor
    func blockCommentUndoRedoRestoresExactBytesSelectionAndRevision() throws {
        let (_, view) = hostedView()
        let prefix = "앞\r\n"
        let payload = "한글"
        let source = prefix + payload + "\r\n뒤"
        let payloadStart = prefix.utf8.count
        let payloadEnd = payloadStart + payload.utf8.count
        try view.loadUTF8(Data(source.utf8), revision: 10)
        view.restoreCaretUTF8Position(
            UInt(payloadStart),
            anchorPosition: UInt(payloadEnd),
            firstVisibleLine: 0,
            horizontalScrollOffset: 0,
            wordWrapEnabled: true
        )
        var edits: [DPScintillaEdit] = []
        view.onEdit = { edits.append($0) }

        #expect(view.toggleBlockComments(
            withStartUTF8: Data("<!--".utf8),
            endUTF8: Data("-->".utf8),
            selectionOwner: view
        ))
        let wrapped = prefix + "<!--" + payload + "-->\r\n뒤"
        #expect(view.contentUTF8 == Data(wrapped.utf8))
        #expect(view.revision == 11)
        #expect(edits.count == 1)
        #expect(edits[0].origin == .user)

        view.undo()
        #expect(view.contentUTF8 == Data(source.utf8))
        #expect(view.caretUTF8Position == payloadStart)
        #expect(view.anchorUTF8Position == payloadEnd)
        #expect(view.revision == 13)
        #expect(edits.count == 3)
        #expect(edits.dropFirst().allSatisfy { $0.origin == .undo })

        view.redo()
        #expect(view.contentUTF8 == Data(wrapped.utf8))
        #expect(view.revision == 15)
        #expect(edits.count == 5)
        #expect(edits.suffix(2).allSatisfy { $0.origin == .redo })
    }

    @Test @MainActor
    func blockCommentReservesUndoRevisionBudget() throws {
        let source = "payload"
        let configuration = EditorLanguageConfiguration(
            languageID: .init(rawValue: "cpp"),
            lexerName: "cpp",
            comments: .init(blockStart: "/*", blockEnd: "*/"),
            indentation: .init(width: 4),
            folding: true,
            braceMatching: true
        )

        let rejectedAdapter = ScintillaEditorAdapter()
        let rejectedBufferID = BufferID()
        let rejectedRevision = UInt64.max - 2
        rejectedAdapter.install(.init(
            bufferID: rejectedBufferID,
            revision: rejectedRevision,
            text: source
        ))
        rejectedAdapter.display(.init(bufferID: rejectedBufferID, revision: rejectedRevision))
        #expect(rejectedAdapter.applyLanguage(configuration))
        let rejectedView = try #require(rejectedAdapter.activeScintillaView)
        rejectedView.setPrimarySelectionUTF8Range(NSRange(location: 0, length: source.utf8.count))
        var rejectedEdits: [EditorIncrementalEdit] = []
        rejectedAdapter.onEdit = { edit in
            rejectedEdits.append(edit)
            return .accepted(newRevision: edit.expectedRevision + 1)
        }

        #expect(!rejectedAdapter.canToggleBlockComment)
        #expect(rejectedAdapter.toggleBlockComment() == .rejected(currentRevision: rejectedRevision))
        #expect(rejectedView.contentUTF8 == Data(source.utf8))
        #expect(rejectedView.revision == rejectedRevision)
        #expect(!rejectedView.canUndo)
        #expect(rejectedEdits.isEmpty)

        let acceptedAdapter = ScintillaEditorAdapter()
        let acceptedBufferID = BufferID()
        let acceptedRevision = UInt64.max - 3
        acceptedAdapter.install(.init(
            bufferID: acceptedBufferID,
            revision: acceptedRevision,
            text: source
        ))
        acceptedAdapter.display(.init(bufferID: acceptedBufferID, revision: acceptedRevision))
        #expect(acceptedAdapter.applyLanguage(configuration))
        let acceptedView = try #require(acceptedAdapter.activeScintillaView)
        acceptedView.setPrimarySelectionUTF8Range(NSRange(location: 0, length: source.utf8.count))
        var acceptedEdits: [EditorIncrementalEdit] = []
        acceptedAdapter.onEdit = { edit in
            acceptedEdits.append(edit)
            return .accepted(newRevision: edit.expectedRevision + 1)
        }

        #expect(acceptedAdapter.canToggleBlockComment)
        #expect(acceptedAdapter.toggleBlockComment() == .accepted(newRevision: UInt64.max - 2))
        #expect(acceptedView.contentUTF8 == Data("/*payload*/".utf8))
        #expect(acceptedView.revision == UInt64.max - 2)

        acceptedView.undo()
        #expect(acceptedView.contentUTF8 == Data(source.utf8))
        #expect(acceptedView.revision == UInt64.max)
        #expect(acceptedAdapter.activeDocumentIntelligenceBuffer?.revision == UInt64.max)
        #expect(acceptedAdapter.recoverySnapshot(for: acceptedBufferID)?.utf8 == Data(source.utf8))
        #expect(acceptedEdits.map(\.expectedRevision) == [
            UInt64.max - 3,
            UInt64.max - 2,
            UInt64.max - 1,
        ])
    }

    @Test @MainActor
    func largeBlockCommentPublishesOneAggregateEditWithinExplicitCommandBudget() throws {
        let (_, view) = hostedView()
        let payload = Data(repeating: 0x61, count: 1 * 1_024 * 1_024)
        try view.loadUTF8(payload, revision: 0)
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: payload.count))
        var edits: [DPScintillaEdit] = []
        view.onEdit = { edits.append($0) }
        view.resetInstrumentation()
        let clock = ContinuousClock()
        let start = clock.now

        #expect(view.toggleBlockComments(
            withStartUTF8: Data("/*".utf8),
            endUTF8: Data("*/".utf8),
            selectionOwner: view
        ))
        let duration = start.duration(to: clock.now)

        #expect(view.revision == 1)
        #expect(view.documentByteLength == payload.count + 4)
        #expect(view.snapshotReadCount == 0)
        #expect(view.incrementalNotificationCount == 1)
        #expect(view.incrementalPayloadByteCount == (2 * payload.count) + 4)
        #expect(edits.count == 1)
        #expect(edits[0].range == NSRange(location: 0, length: payload.count))
        #expect(edits[0].deletedUTF8.count == payload.count)
        #expect(edits[0].replacementUTF8.count == payload.count + 4)
        #if !DEBUG
        #expect(duration < .milliseconds(250))
        #endif
    }

    @Test @MainActor
    func adapterUsesOnlyLastSuccessfullyAppliedBlockPair() throws {
        let adapter = ScintillaEditorAdapter()
        let bufferID = BufferID()
        adapter.install(.init(bufferID: bufferID, revision: 0, text: "payload"))
        adapter.display(.init(bufferID: bufferID, revision: 0))
        adapter.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }
        let original = EditorLanguageConfiguration(
            languageID: .init(rawValue: "cpp"),
            lexerName: "cpp",
            comments: .init(blockStart: "/*", blockEnd: "*/"),
            indentation: .init(width: 4),
            folding: true,
            braceMatching: true
        )
        let failedReplacement = EditorLanguageConfiguration(
            languageID: .init(rawValue: "html"),
            lexerName: "not-a-real-lexer",
            comments: .init(blockStart: "<!--", blockEnd: "-->"),
            indentation: .init(width: 2),
            folding: true,
            braceMatching: true
        )

        #expect(adapter.applyLanguage(original))
        #expect(adapter.canToggleBlockComment)
        #expect(!adapter.applyLanguage(failedReplacement))
        #expect(adapter.canToggleBlockComment)
        adapter.activeScintillaView?.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 7))

        #expect(adapter.toggleBlockComment() == .accepted(newRevision: 1))
        #expect(adapter.recoverySnapshot(for: bufferID)?.utf8 == Data("/*payload*/".utf8))
    }

    @Test @MainActor
    func blockCommentAcceptanceAdvancesDirtyRecoveryExactlyOnce() async throws {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        #expect(await workspace.start() == .saved)
        let adapter = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: adapter)
        let buffer = try #require(workspace.snapshot().activeBuffer)
        adapter.install(.init(bufferID: buffer.bufferID, revision: 0, text: "payload"))
        adapter.display(.init(bufferID: buffer.bufferID, revision: 0))
        #expect(adapter.applyLanguage(.init(
            languageID: .init(rawValue: "cpp"),
            lexerName: "cpp",
            comments: .init(blockStart: "/*", blockEnd: "*/"),
            indentation: .init(width: 4),
            folding: true,
            braceMatching: true
        )))
        adapter.activeScintillaView?.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 7))
        let appendCount = adapter.recoveryJournalAppendCount

        #expect(adapter.toggleBlockComment() == .accepted(newRevision: 1))
        let workspaceSnapshot = workspace.snapshot()
        #expect(workspaceSnapshot.activeBuffer?.revision == 1)
        #expect(workspaceSnapshot.tabs.first?.isDirty == true)
        #expect(adapter.recoveryJournalAppendCount == appendCount + 1)
        let recovery = try #require(adapter.recoverySnapshot(for: buffer.bufferID))
        #expect(recovery.revision == 1)
        #expect(recovery.utf8 == Data("/*payload*/".utf8))
        _ = binding
    }

    @Test @MainActor
    func rejectedBlockCommentReloadsUnchangedAuthorityWithoutPartialDelimiter() async throws {
        let adapter = ScintillaEditorAdapter()
        let bufferID = BufferID()
        let source = "한글 payload"
        adapter.install(.init(bufferID: bufferID, revision: 3, text: source))
        adapter.display(.init(bufferID: bufferID, revision: 3))
        #expect(adapter.applyLanguage(.init(
            languageID: .init(rawValue: "cpp"),
            lexerName: "cpp",
            comments: .init(blockStart: "/*", blockEnd: "*/"),
            indentation: .init(width: 4),
            folding: true,
            braceMatching: true
        )))
        let view = try #require(adapter.activeScintillaView)
        let selection = NSRange(location: "한글 ".utf8.count, length: 7)
        view.setPrimarySelectionUTF8Range(selection)
        let recoveryAppends = adapter.recoveryJournalAppendCount
        adapter.onEdit = { .rejected(currentRevision: $0.expectedRevision) }

        #expect(adapter.toggleBlockComment() == .rejected(currentRevision: 3))
        for _ in 0..<100 where view.revision != 3 {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(view.contentUTF8 == Data(source.utf8))
        #expect(view.revision == 3)
        #expect(view.anchorUTF8Position == selection.location)
        #expect(view.caretUTF8Position == selection.location + selection.length)
        #expect(adapter.recoveryJournalAppendCount == recoveryAppends)
        #expect(adapter.recoverySnapshot(for: bufferID)?.utf8 == Data(source.utf8))
    }

    @Test @MainActor
    func splitBlockCommentTargetsFocusedPaneAndSharesAcceptedText() throws {
        _ = NSApplication.shared
        let adapter = ScintillaEditorAdapter()
        let bufferID = BufferID()
        adapter.install(.init(bufferID: bufferID, revision: 0, text: "left right"))
        adapter.display(.init(bufferID: bufferID, revision: 0))
        adapter.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }
        adapter.split(orientation: .sideBySide)
        #expect(adapter.applyLanguage(.init(
            languageID: .init(rawValue: "cpp"),
            lexerName: "cpp",
            comments: .init(blockStart: "/*", blockEnd: "*/"),
            indentation: .init(width: 4),
            folding: true,
            braceMatching: true
        )))
        let primary = try #require(adapter.activeScintillaView)
        let secondary = try #require(adapter.secondaryScintillaView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = adapter.view
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        primary.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 4))
        secondary.setPrimarySelectionUTF8Range(NSRange(location: 5, length: 5))
        secondary.focusEditor()
        #expect(adapter.activeScintillaView === secondary)

        #expect(adapter.toggleBlockComment() == .accepted(newRevision: 1))
        #expect(primary.contentUTF8 == Data("left /*right*/".utf8))
        #expect(secondary.contentUTF8 == Data("left /*right*/".utf8))
        #expect(primary.caretUTF8Position == 4)
        #expect(primary.anchorUTF8Position == 0)
        #expect(secondary.anchorUTF8Position == 5)
        #expect(secondary.caretUTF8Position == 14)
    }

    @Test @MainActor
    func secondaryBlockCommentUsesPrimaryAggregatePublisherWhenAcceptedOrRejected() async throws {
        _ = NSApplication.shared
        let adapter = ScintillaEditorAdapter()
        let bufferID = BufferID()
        let source = "left right"
        adapter.install(.init(bufferID: bufferID, revision: 0, text: source))
        adapter.display(.init(bufferID: bufferID, revision: 0))
        adapter.split(orientation: .sideBySide)
        #expect(adapter.applyLanguage(.init(
            languageID: .init(rawValue: "cpp"),
            lexerName: "cpp",
            comments: .init(blockStart: "/*", blockEnd: "*/"),
            indentation: .init(width: 4),
            folding: true,
            braceMatching: true
        )))
        let primary = try #require(adapter.activeScintillaView)
        let secondary = try #require(adapter.secondaryScintillaView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = adapter.view
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        secondary.setPrimarySelectionUTF8Range(NSRange(location: 5, length: 5))
        secondary.focusEditor()
        primary.resetInstrumentation()
        secondary.resetInstrumentation()
        var callbacks = 0
        adapter.onEdit = { edit in
            callbacks += 1
            return .accepted(newRevision: edit.expectedRevision + 1)
        }

        #expect(adapter.toggleBlockComment() == .accepted(newRevision: 1))
        #expect(callbacks == 1)
        #expect(primary.incrementalNotificationCount == 1)
        #expect(secondary.incrementalNotificationCount == 0)
        #expect(primary.revision == 1)
        #expect(secondary.revision == 1)
        #expect(primary.contentUTF8 == Data("left /*right*/".utf8))
        #expect(secondary.contentUTF8 == Data("left /*right*/".utf8))
        #expect(secondary.anchorUTF8Position == 5)
        #expect(secondary.caretUTF8Position == 14)

        adapter.install(.init(bufferID: bufferID, revision: 0, text: source))
        secondary.setPrimarySelectionUTF8Range(NSRange(location: 5, length: 5))
        secondary.focusEditor()
        primary.resetInstrumentation()
        secondary.resetInstrumentation()
        let recoveryAppends = adapter.recoveryJournalAppendCount
        callbacks = 0
        adapter.onEdit = { edit in
            callbacks += 1
            return .rejected(currentRevision: edit.expectedRevision)
        }

        #expect(adapter.toggleBlockComment() == .rejected(currentRevision: 0))
        for _ in 0..<100 where primary.revision != 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(callbacks == 1)
        #expect(primary.incrementalNotificationCount == 1)
        #expect(secondary.incrementalNotificationCount == 0)
        #expect(primary.revision == 0)
        #expect(secondary.revision == 0)
        #expect(primary.contentUTF8 == Data(source.utf8))
        #expect(secondary.contentUTF8 == Data(source.utf8))
        #expect(secondary.anchorUTF8Position == 5)
        #expect(secondary.caretUTF8Position == 10)
        #expect(adapter.recoveryJournalAppendCount == recoveryAppends)
    }

    @Test @MainActor
    func largeStyleFallbackRetainsLiteralBlockCommentCapability() throws {
        let adapter = ScintillaEditorAdapter()
        let bufferID = BufferID()
        let payload = String(repeating: "a", count: 2_048)
        adapter.install(.init(bufferID: bufferID, revision: 0, text: payload))
        adapter.display(.init(bufferID: bufferID, revision: 0))
        adapter.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }
        #expect(adapter.applyLanguage(.init(
            languageID: .init(rawValue: "html"),
            lexerName: "hypertext",
            comments: .init(blockStart: "<!--", blockEnd: "-->"),
            indentation: .init(width: 2),
            folding: true,
            braceMatching: true,
            maximumStyleBytes: 1_024
        )))
        let view = try #require(adapter.activeScintillaView)
        #expect(view.languageStylingFallback)
        #expect(adapter.canToggleBlockComment)
        view.setPrimarySelectionUTF8Range(NSRange(location: 0, length: payload.utf8.count))

        #expect(adapter.toggleBlockComment() == .accepted(newRevision: 1))
        #expect(view.contentUTF8 == Data(("<!--" + payload + "-->").utf8))
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
