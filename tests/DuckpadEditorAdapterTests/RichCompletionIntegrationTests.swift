import AppKit
import Testing
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import DuckpadScintillaBridge
@testable import DuckpadEditorAdapter

@Suite(.serialized) @MainActor struct RichCompletionIntegrationTests {
    @MainActor private final class Provider: DocumentCompletionProviding {
        var items: [DocumentCompletionSuggestion] = []
        var delay: Duration = .zero
        var requests = 0
        var ignoresCancellation = false
        func completions(in capture: DocumentIntelligenceCapture, prefixRange: SearchUTF8Range) async throws -> [DocumentCompletionSuggestion] {
            requests += 1
            if delay > .zero {
                do { try await Task.sleep(for: delay) }
                catch { if !ignoresCancellation { throw error } }
            }
            return items
        }
        func shutdown() {}
    }
    @MainActor private final class Fixture {
        let editor = ScintillaEditorAdapter()
        let intelligence: DocumentIntelligenceUseCase
        let window: NSWindow
        let native: DPScintillaEditorView
        init(_ text: String, lexer: String? = nil) throws {
            _ = NSApplication.shared
            let buffer = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
            editor.install(.init(bufferID: buffer.bufferID, revision: 0, text: text)); editor.display(buffer)
            editor.onEdit = { .accepted(newRevision: $0.expectedRevision + 1) }
            native = try #require(editor.activeScintillaView)
            if let lexer {
                #expect(editor.applyLanguage(.init(languageID: .init(rawValue: lexer), lexerName: lexer,
                    indentation: .init(), folding: false, braceMatching: false)))
            }
            intelligence = DocumentIntelligenceUseCase(editor: editor)
            intelligence.completionMatcher = CodeMirrorCompletionMatcher()
            intelligence.enableAutomaticCompletion()
            window = NSWindow(contentRect: NSRect(x: 50, y: 100, width: 800, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = editor.view
            window.makeKeyAndOrderFront(nil); native.focusEditor()
            native.setPrimarySelectionUTF8Range(.init(location: text.utf8.count, length: 0))
        }
        func type(_ text: String) throws {
            let client = try #require(window.firstResponder as? any NSTextInputClient)
            client.insertText(text, replacementRange: .init(location: NSNotFound, length: 0))
        }
        func key(_ code: UInt16, characters: String = "\u{7f}") throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code))
            try #require(window.firstResponder).keyDown(with: event)
        }
        func settle() async throws { try await Task.sleep(for: .milliseconds(400)) }
        func awaitSuggestions(_ count: Int, timeout: Duration = .seconds(2)) async throws {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while editor.completionSuggestionCount != count || editor.isCompletionSuggestionVisible != (count > 0) {
                guard ContinuousClock.now < deadline else { return }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        func dispose() { intelligence.cancel(); editor.invalidate(); window.contentView = nil; window.close() }
    }

    @Test func automaticSuggestionsUseCodeEditPanelAndCodeMirrorAbbreviationMatching() async throws {
        let f = try Fixture("user_name user_email updateName\n"); defer { f.dispose() }
        try f.type("un")
        try await f.settle()
        #expect(f.editor.isCompletionSuggestionVisible)
        #expect(!f.native.isCompletionActive)
        #expect(f.editor.completionSuggestionCount == 2)
        #expect(try #require(f.editor.completionPanel.window).frame.width >= 280)
        #expect(f.editor.completionPanel.onAccept?(0, false) == true)
        f.editor.completionPanel.close()
        try await f.settle()
        #expect(f.native.contentUTF8 == Data("user_name user_email updateName\nuser_name".utf8))
        f.native.undo()
        #expect(f.native.contentUTF8 == Data("user_name user_email updateName\nun".utf8))
    }

    @Test func firstCharacterAndBackspaceRefreshUntilThePrefixIsEmpty() async throws {
        let f = try Fixture("user_name user_email updateName other\n"); defer { f.dispose() }
        try f.type("u")
        try await f.awaitSuggestions(3)
        #expect(f.editor.isCompletionSuggestionVisible)
        #expect(f.editor.completionSuggestionCount == 3)
        try f.type("s")
        try await f.awaitSuggestions(2)
        #expect(f.editor.completionSuggestionCount == 2)
        try f.type("z")
        try await f.awaitSuggestions(0)
        #expect(!f.editor.isCompletionSuggestionVisible)
        for count in [2, 3, 0] {
            try f.key(51)
            try await f.awaitSuggestions(count)
            #expect(f.editor.isCompletionSuggestionVisible == (count > 0))
            #expect(f.editor.completionSuggestionCount == count)
        }
        #expect(f.native.contentUTF8 == Data("user_name user_email updateName other\n".utf8))
        try f.type(" ")
        try await f.awaitSuggestions(0)
        #expect(!f.editor.isCompletionSuggestionVisible)
    }

    @Test func deletingSelectedPrefixAndForwardDeleteAlsoRefreshSuggestions() async throws {
        let f = try Fixture("user_name user_email updateName other\nuZ"); defer { f.dispose() }
        let start = Int(f.native.documentByteLength) - 2
        f.native.setPrimarySelectionUTF8Range(.init(location: start + 1, length: 0))
        try f.key(117, characters: "\u{f728}")
        try await f.awaitSuggestions(3)
        #expect(f.editor.completionSuggestionCount == 3)
        f.native.setPrimarySelectionUTF8Range(.init(location: start, length: 1))
        try f.key(51)
        try await f.awaitSuggestions(0)
        #expect(!f.editor.isCompletionSuggestionVisible)
        #expect(f.editor.completionSuggestionCount == 0)
    }

    @Test func deletingEntireDocumentClosesAutomaticSuggestionsButManualCompletionStillWorks() async throws {
        let f = try Fixture("user_name\nu"); defer { f.dispose() }
        f.intelligence.enableAutomaticCompletion { ["unless until"] }
        f.native.setPrimarySelectionUTF8Range(.init(location: 0, length: Int(f.native.documentByteLength)))
        try f.key(51)
        try await f.settle()
        #expect(f.native.contentUTF8.isEmpty)
        #expect(!f.editor.isCompletionSuggestionVisible)
        #expect(await f.intelligence.complete(supplementalTerms: ["unless until"]) == .presented(count: 2))
        #expect(f.editor.isCompletionSuggestionVisible)
        #expect(f.editor.completionSuggestionCount == 2)
    }

    @Test(arguments: ["\n ", "\n\t", "\n\n", "\n    u", "headers = {}\n\nu"])
    func blankLineDeletionNeverRequestsLocalOrServerCandidates(ending: String) async throws {
        let f = try Fixture("user_name user_email\n" + ending, lexer: "python"); defer { f.dispose() }
        let provider = Provider(); f.intelligence.completionProvider = provider
        try f.key(51)
        try await f.settle()
        #expect(!f.editor.isCompletionSuggestionVisible)
        #expect(f.editor.completionSuggestionCount == 0)
        #expect(provider.requests == 0)
    }

    @Test func emptyPrefixDoesNotReappearAfterDelayedServerResultsOrCaretMovement() async throws {
        let text = "user_name user_email\n"
        let f = try Fixture(text, lexer: "python"); defer { f.dispose() }
        let provider = Provider(); provider.delay = .milliseconds(300); provider.ignoresCancellation = true
        provider.items = [.init(label: "user_server", source: .languageServer,
            insertRange: .init(location: text.utf8.count, length: 1))]
        f.intelligence.completionProvider = provider
        try f.type("u")
        try await f.awaitSuggestions(2)
        try await Task.sleep(for: .milliseconds(100))
        #expect(provider.requests == 1)
        try f.key(51)
        try await f.settle()
        #expect(!f.editor.isCompletionSuggestionVisible)
        #expect(provider.requests == 1)
        f.native.setPrimarySelectionUTF8Range(.init(location: 0, length: 0))
        f.native.setPrimarySelectionUTF8Range(.init(location: text.utf8.count, length: 0))
        try await f.settle()
        #expect(!f.editor.isCompletionSuggestionVisible)
        #expect(provider.requests == 1)
        try f.type("u")
        try await f.awaitSuggestions(2)
        #expect(f.editor.isCompletionSuggestionVisible)
        try f.key(53, characters: "\u{1b}")
        try f.key(36, characters: "\r")
        try await f.settle()
        #expect(f.native.contentUTF8.suffix(3) == Data("\nu\n".utf8))
        #expect(!f.editor.isCompletionSuggestionVisible)
    }

    @Test func memberAccessStillOpensAutomaticSemanticCompletionWithoutAWordPrefix() async throws {
        let f = try Fixture("object", lexer: "python"); defer { f.dispose() }
        let provider = Provider()
        provider.items = [.init(label: "member", source: .languageServer, insertRange: .init(location: 7, length: 0))]
        f.intelligence.completionProvider = provider
        try f.type(".")
        try await f.awaitSuggestions(1)
        #expect(provider.requests == 1)
        #expect(f.editor.isCompletionSuggestionVisible)
        #expect(f.editor.completionSuggestionCount == 1)
    }

    @Test(arguments: ["python|class ", "ruby|class ", "ruby|module ", "rust|struct ", "rust|pub struct ", "rust|trait ", "cpp|class "])
    func declarationNamesDoNotTriggerAutomaticSuggestions(context: String) async throws {
        let parts = context.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let f = try Fixture("Person PersonRecord Product\n" + parts[1], lexer: String(parts[0])); defer { f.dispose() }
        let provider = Provider(); f.intelligence.completionProvider = provider
        try f.type("P")
        try await f.settle()
        #expect(!f.editor.isCompletionSuggestionVisible, "\(context)")
        #expect(provider.requests == 0, "\(context)")
        try f.type("erson")
        try await f.settle()
        #expect(!f.editor.isCompletionSuggestionVisible, "\(context)")
        #expect(provider.requests == 0, "\(context)")
    }

    @Test func pythonMethodNamesUseSemanticCandidatesWithoutDocumentWordNoise() async throws {
        let head = "__document_word __repr__ renderWord\nclass Person:\n    def "
        let f = try Fixture(head, lexer: "python"); defer { f.dispose() }
        let provider = Provider()
        provider.items = ["__init__", "__repr__", "unrelated"].map {
            .init(label: $0, kind: 2, source: .languageServer, insertRange: .init(location: head.utf8.count, length: 2))
        }
        f.intelligence.completionProvider = provider
        try f.type("__")
        try await f.awaitSuggestions(2)
        #expect(provider.requests == 1)
        #expect(f.editor.isCompletionSuggestionVisible)
        #expect(f.editor.completionSuggestionCount == 2)
        // Deleting the method prefix closes the popup, preserving the empty-prefix rule.
        try f.key(51); try f.key(51)
        try await f.settle()
        #expect(!f.editor.isCompletionSuggestionVisible)
        #expect(provider.requests == 1)
    }

    @Test func pythonOverrideNameDoesNotMixInGlobalsOrFuzzyDunderNames() async throws {
        let head = "renderLocal reprLocal\nclass Person(Parent):\n    def "
        let f = try Fixture(head, lexer: "python"); defer { f.dispose() }
        let provider = Provider()
        provider.items = ["render", "__repr__"].map {
            .init(label: $0, kind: 2, source: .languageServer, insertRange: .init(location: head.utf8.count, length: 2))
        }
        f.intelligence.completionProvider = provider
        try f.type("re")
        try await f.awaitSuggestions(1)
        #expect(provider.requests == 1)
        #expect(f.editor.completionSuggestionCount == 1)
    }

    @Test(arguments: [("ruby", "class Person\n  def ", "pa", "paddle"), ("rust", "impl Person {\n    fn ", "re", "render")])
    func otherFunctionNameSlotsAlsoUseOnlyLanguageServerCandidates(lexer: String, head: String, typed: String, name: String) async throws {
        let text = name + "_document_word\n" + head
        let f = try Fixture(text, lexer: lexer); defer { f.dispose() }
        let provider = Provider()
        provider.items = [.init(label: name, kind: 2, source: .languageServer,
            insertRange: .init(location: text.utf8.count, length: typed.utf8.count))]
        f.intelligence.completionProvider = provider
        try f.type(typed)
        try await f.awaitSuggestions(1)
        #expect(provider.requests == 1)
        #expect(f.editor.completionSuggestionCount == 1)
    }

    @Test(arguments: ["lf", "crlf", "tabs", "nested", "mixed"])
    func methodStubInsertionPreservesIndentationLineEndingsAndOneUndo(style: String) async throws {
        let newline = style == "crlf" || style == "mixed" ? "\r\n" : "\n"
        let indent = style == "tabs" ? "\t" : (style == "nested" ? "        " : "    ")
        let prefix = style == "nested" ? "class Outer:\n    class Person:\n" : (style == "mixed" ? "# header\nclass Person:\r\n" : "class Person:" + newline)
        let head = prefix + indent + "def "
        let f = try Fixture(head, lexer: "python"); defer { f.dispose() }
        let provider = Provider()
        let item = DocumentCompletionSuggestion(label: "__init__", kind: 2, source: .languageServer,
            insertText: "__init__(self) -> None:\n    pass", insertRange: .init(location: head.utf8.count, length: 2))
        provider.items = [item]; f.intelligence.completionProvider = provider
        // Resolution returns fresh server text; the host's relative-indentation flag must survive it.
        f.editor.onCompletionResolve = { _, _ in item }
        try f.type("__")
        try await f.awaitSuggestions(1)
        #expect(f.editor.completionSuggestionCount == 1)
        #expect(f.editor.completionPanel.onAccept?(0, true) == true)
        f.editor.completionPanel.close()
        try await f.settle()
        let expected = head + "__init__(self) -> None:" + newline + indent + "    pass"
        #expect(f.native.contentUTF8 == Data(expected.utf8))
        #expect(f.native.caretUTF8Position == UInt(expected.utf8.count))
        f.native.undo()
        #expect(f.native.contentUTF8 == Data((head + "__").utf8))
    }

    @Test func methodStubAndResolvedImportRemainOneUndoBatch() async throws {
        let head = "class Person:\n    def "
        let f = try Fixture(head, lexer: "python"); defer { f.dispose() }
        let provider = Provider()
        let item = DocumentCompletionSuggestion(label: "__new__", kind: 2, source: .languageServer,
            insertText: "__new__(cls) -> Any:\n    return super().__new__(cls)",
            insertRange: .init(location: head.utf8.count, length: 4), additionalEdits: [
                .init(range: .init(location: 0, length: 0), replacementUTF8: Data("from typing import Any\n".utf8))])
        provider.items = [item]; f.intelligence.completionProvider = provider
        f.editor.onCompletionResolve = { _, _ in item }
        try f.type("__ne")
        try await f.awaitSuggestions(1)
        #expect(f.editor.completionPanel.onAccept?(0, true) == true)
        f.editor.completionPanel.close()
        try await f.settle()
        let expected = "from typing import Any\n" + head + "__new__(cls) -> Any:\n        return super().__new__(cls)"
        #expect(f.native.contentUTF8 == Data(expected.utf8))
        #expect(f.native.caretUTF8Position == UInt(expected.utf8.count))
        f.native.undo()
        #expect(f.native.contentUTF8 == Data((head + "__ne").utf8))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DUCKPAD_PYTHON_SERVERS_TEST_DIRECTORY"] != nil), arguments: ["basedpyright", "pyright"])
    func realPythonServersCompleteAndInsertMagicMethods(server: String) async throws {
        let tools = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["DUCKPAD_PYTHON_SERVERS_TEST_DIRECTORY"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-methods-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("pyproject.toml"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".venv"), withDestinationURL: tools.deletingLastPathComponent())
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let loader = LocalExtensionPackageLoader(root: root.appendingPathComponent("unused-packages"))
        let (package, files) = try await loader.readPackage(at: packageRoot.appendingPathComponent("LanguagePlugins/com.duckpad.python.duckpad-plugin"))
        let registration = LanguageServerRegistration(extensionID: package.manifest.id, packageDigest: package.packageDigest,
            service: try #require(package.manifest.contributes.languageServices.first), packageFiles: files)
        let url = root.appendingPathComponent("person.py"), head = "class Person:\n    def "
        try head.write(to: url, atomically: true, encoding: .utf8)
        let f = try Fixture(head, lexer: "python"); defer { f.dispose() }
        let provider = LanguageServerCompletionProvider(registry: .init(registrations: [registration]),
            settings: [registration.settingsKey: .init(serverID: server)]) { _ in url }
        defer { provider.shutdown() }
        f.intelligence.completionProvider = provider
        f.editor.onCompletionResolve = { item, capture in await provider.resolve(item, capture: capture) }
        try f.type("__")
        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        while !f.editor.isCompletionSuggestionVisible, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(f.editor.isCompletionSuggestionVisible)
        #expect(provider.context(for: url)?.serverID == server)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let content = try #require(f.editor.completionPanel.window?.contentView)
        let table = try #require(descendants(content).compactMap { $0 as? NSTableView }.first)
        var labels: [String: Int] = [:]
        for row in 0..<table.numberOfRows {
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true),
               let label = descendants(cell).compactMap({ $0 as? NSTextField }).first?.stringValue { labels[label] = row }
        }
        #expect(labels["__repr__"] != nil)
        let index = try #require(labels["__init__"])
        #expect(f.editor.completionPanel.onAccept?(index, true) == true)
        f.editor.completionPanel.close()
        let expected = head + "__init__(self) -> None:\n        pass"
        for _ in 0..<200 where f.native.contentUTF8 != Data(expected.utf8) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(f.native.contentUTF8 == Data(expected.utf8))
        f.native.undo()
        #expect(f.native.contentUTF8 == Data((head + "__").utf8))
    }

    @Test(arguments: ["class Person", "if ready", "value", "mapping = {key"])
    func pythonBlockAndAnnotationColonsDoNotActAsMemberAccess(before: String) async throws {
        let f = try Fixture(before, lexer: "python"); defer { f.dispose() }
        let provider = Provider()
        provider.items = [.init(label: "False", source: .languageServer, insertRange: .init(location: before.utf8.count + 1, length: 0))]
        f.intelligence.completionProvider = provider
        try f.type(":")
        try await f.settle()
        #expect(!f.editor.isCompletionSuggestionVisible)
        #expect(provider.requests == 0)
    }

    @Test(arguments: ["class New(", "def new(value:", "value:", "return "])
    func pythonTypeReferencesAndExpressionsStillComplete(before: String) async throws {
        let f = try Fixture("Person PersonRecord\n" + before, lexer: "python"); defer { f.dispose() }
        try f.type("P")
        try await f.awaitSuggestions(2)
        #expect(f.editor.isCompletionSuggestionVisible, "\(before)")
        #expect(f.editor.completionSuggestionCount == 2, "\(before)")
    }

    @Test func rustNamespaceAccessStillCompletes() async throws {
        let f = try Fixture("Person", lexer: "rust"); defer { f.dispose() }
        let provider = Provider()
        provider.items = [.init(label: "new", source: .languageServer, insertRange: .init(location: 8, length: 0))]
        f.intelligence.completionProvider = provider
        try f.type("::")
        try await f.awaitSuggestions(1)
        #expect(provider.requests == 1)
        #expect(f.editor.isCompletionSuggestionVisible)
    }

    @Test func zoomedEditorCompletionRemainsCompactAndInsideItsWindow() async throws {
        let f = try Fixture((0..<20).map { "user_\($0)" }.joined(separator: " ") + "\n"); defer { f.dispose() }
        f.window.setContentSize(NSSize(width: 420, height: 180))
        f.editor.applyPreferences(AppSettings(editorFontSize: 28))
        try f.type("u")
        try await f.settle()
        let panel = try #require(f.editor.completionPanel.window)
        #expect(panel.isVisible)
        #expect(f.window.convertToScreen(f.window.contentLayoutRect).contains(panel.frame))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let content = try #require(panel.contentView)
        let table = try #require(descendants(content).compactMap { $0 as? NSTableView }.first)
        #expect(table.rowHeight <= 24)
    }

    @Test func slowServerCannotLeaveUnmatchedCandidatesVisible() async throws {
        let f = try Fixture("user_name user_email\n"); defer { f.dispose() }
        let provider = Provider(); provider.delay = .seconds(1)
        f.intelligence.completionProvider = provider
        try f.type("u")
        try await f.awaitSuggestions(2)
        #expect(f.editor.completionSuggestionCount == 2)
        try f.type("sz")
        try await f.awaitSuggestions(0, timeout: .milliseconds(500))
        #expect(!f.editor.isCompletionSuggestionVisible)
        try f.key(51)
        try await f.awaitSuggestions(2)
        #expect(f.editor.isCompletionSuggestionVisible)
        #expect(f.editor.completionSuggestionCount == 2)
    }

    @Test(arguments: ["python", "ruby", "rust", "cpp", "null"])
    func quotedTextSuppressesTypingAndDeletionButCodeOutsideQuotesCompletes(lexer: String) async throws {
        let f = try Fixture("user_name user_email\n\"\"", lexer: lexer); defer { f.dispose() }
        f.native.setPrimarySelectionUTF8Range(.init(location: Int(f.native.documentByteLength) - 1, length: 0))
        f.native.resetInstrumentation()
        try f.type("u")
        try await Task.sleep(for: .milliseconds(80))
        #expect(!f.editor.isCompletionSuggestionVisible)
        #expect(f.native.snapshotReadCount == 0)
        try f.key(51)
        try await Task.sleep(for: .milliseconds(80))
        #expect(!f.editor.isCompletionSuggestionVisible)
        f.native.setPrimarySelectionUTF8Range(.init(location: Int(f.native.documentByteLength), length: 0))
        try f.type(" + u")
        try await f.awaitSuggestions(2)
        #expect(f.editor.isCompletionSuggestionVisible,
            "\(lexer): style=\(f.native.style(atUTF8Position: f.native.caretUTF8Position - 1)), allowed=\(f.native.allowsCodeCompletion), text=\(String(decoding: f.native.contentUTF8, as: UTF8.self))")
        #expect(f.editor.completionSuggestionCount == 2)
    }

    @Test(arguments: ["python", "ruby", "rust", "cpp"])
    func commentsAndUnterminatedStringsDoNotRequestServerCompletions(lexer: String) async throws {
        // Rust's unclosed 'u is a valid lifetime, rather than a character string.
        let openings = ["\"", (lexer == "python" || lexer == "ruby") ? "# " : "// "] + (lexer == "rust" ? [] : ["'"])
        for opening in openings {
            let f = try Fixture("user_name user_email\n", lexer: lexer); defer { f.dispose() }
            let provider = Provider(); f.intelligence.completionProvider = provider
            try f.type(opening + "u")
            try await Task.sleep(for: .milliseconds(80))
            #expect(!f.editor.isCompletionSuggestionVisible)
            #expect(provider.requests == 0)
            _ = await f.intelligence.complete()
            #expect(provider.requests == 0)
            if opening.hasPrefix("#") || opening.hasPrefix("//") {
                try f.type("\nu")
                try await f.awaitSuggestions(2)
                #expect(f.editor.isCompletionSuggestionVisible)
            }
        }
    }

    @Test func openingQuoteClosesVisibleCandidatesImmediately() async throws {
        let f = try Fixture("user_name user_email\n", lexer: "python"); defer { f.dispose() }
        try f.type("u")
        try await f.awaitSuggestions(2)
        #expect(f.editor.isCompletionSuggestionVisible)
        try f.type("\"")
        try await Task.sleep(for: .milliseconds(80))
        #expect(!f.editor.isCompletionSuggestionVisible)
        try f.type("u")
        try await Task.sleep(for: .milliseconds(80))
        #expect(!f.editor.isCompletionSuggestionVisible)
    }

    @Test(arguments: ["python", "ruby"])
    func interpolationExpressionsRemainCode(lexer: String) async throws {
        let expressions = lexer == "python" ? ["f\"{u}\"", "f'prefix {u}'"] : ["\"#{u}\"", "%Q{prefix #{u}}"]
        for text in expressions {
            let f = try Fixture("user_name user_email\n" + text, lexer: lexer); defer { f.dispose() }
            let offset = try #require(text.firstIndex(of: "u"))
            f.native.setPrimarySelectionUTF8Range(.init(location: "user_name user_email\n".utf8.count + text[..<offset].utf8.count, length: 0))
            try f.type("u")
            try await f.awaitSuggestions(2)
            #expect(f.editor.isCompletionSuggestionVisible)
        }
    }

    @Test func multilineRawEscapedAndCharacterLiteralsStayQuiet() async throws {
        let cases = [
            ("python", "value = '''\n", "\n'''"),
            ("python", "value = r\"", "\""),
            ("python", #"value = "escaped \" "#, "\""),
            ("ruby", "value = %q{", "}"),
            ("ruby", "value = <<~TEXT\n", "\nTEXT"),
            ("rust", "let value = r#\"", "\"#;"),
            ("rust", "let value = '", "';"),
            ("rust", "/* nested /* comment */ ", "*/"),
            ("cpp", "R\"tag(", ")tag\";"),
            ("cpp", "/* multiline\n", "*/")
        ]
        for (lexer, prefix, suffix) in cases {
            let text = "user_name user_email\n" + prefix
            let f = try Fixture(text + suffix, lexer: lexer); defer { f.dispose() }
            f.native.setPrimarySelectionUTF8Range(.init(location: text.utf8.count, length: 0))
            try f.type("u")
            try await Task.sleep(for: .milliseconds(80))
            #expect(!f.editor.isCompletionSuggestionVisible, "\(lexer): \(prefix)")
        }
    }

    @Test func contractionsInUntypedTextStillAllowWordCompletion() async throws {
        let f = try Fixture("user_name user_email\ndon't "); defer { f.dispose() }
        try f.type("u")
        try await f.awaitSuggestions(2)
        #expect(f.editor.isCompletionSuggestionVisible)
        #expect(f.editor.completionSuggestionCount == 2)
    }

    @Test func semanticReplacementAndAdditionalImportAreOneUndoStep() async throws {
        let f = try Fixture("# sample\nna"); defer { f.dispose() }
        let provider = Provider()
        provider.items = [.init(label: "name", detail: "str", documentation: "A user's name", kind: 6,
            source: .languageServer, insertRange: .init(location: 9, length: 2), additionalEdits: [
                .init(range: .init(location: 0, length: 0), replacementUTF8: Data("import example\n".utf8))])]
        f.intelligence.completionProvider = provider
        #expect(await f.intelligence.complete() == .presented(count: 1))
        #expect(f.editor.completionPanel.onAccept?(0, true) == true)
        f.editor.completionPanel.close()
        try await f.settle()
        #expect(f.native.contentUTF8 == Data("import example\n# sample\nname".utf8))
        #expect(f.native.caretUTF8Position == UInt("import example\n# sample\nname".utf8.count))
        f.native.undo()
        #expect(f.native.contentUTF8 == Data("# sample\nna".utf8))
    }

    @Test func longCompletionDocumentationCanScrollWithoutOverlappingCandidates() async throws {
        let f = try Fixture("ag"); defer { f.dispose() }
        let provider = Provider()
        let documentation = String(repeating: "A long paragraph should wrap within the documentation pane. ", count: 12)
            + "\n" + (0..<50).map { "parameter_\($0): Callable | str | list[str]" }.joined(separator: "\n")
        provider.items = [.init(label: "aggregate", kind: 2, source: .languageServer,
            insertRange: .init(location: 0, length: 2))]
        f.intelligence.completionProvider = provider
        _ = await f.intelligence.complete()
        let window = try #require(f.editor.completionPanel.window)
        f.editor.completionPanel.updateInfo(at: 0, detail: "", documentation: documentation)
        try await Task.sleep(for: .milliseconds(80))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let views = descendants(try #require(window.contentView))
        let scroll = try #require(views.compactMap { $0 as? NSScrollView }.first { $0.documentView is NSTextView })
        let text = try #require(scroll.documentView as? NSTextView)
        #expect(text.string == documentation)
        #expect(scroll.hasVerticalScroller)
        #expect(text.frame.height > scroll.contentSize.height)
        let container = try #require(text.textContainer)
        #expect(text.frame.width <= scroll.contentSize.width,
            "document width=\(text.frame.width), viewport=\(scroll.contentSize.width)")
        #expect(container.containerSize.width <= scroll.contentSize.width - 24 + 1)
        let used = try #require(text.layoutManager).usedRect(for: container)
        #expect(used.width <= scroll.contentSize.width - 24 + 1,
            "used=\(used.width), container=\(container.containerSize.width), viewport=\(scroll.contentSize.width)")
        let list = try #require(views.compactMap { $0 as? NSScrollView }.first { $0.documentView is NSTableView })
        #expect(scroll.frame.maxY < list.frame.minY)
        let screen = try #require(window.screen)
        #expect(window.frame.height <= screen.visibleFrame.height - 16)
        #expect(f.window.firstResponder is any NSTextInputClient)
        f.editor.completionPanel.updateInfo(at: 0, detail: "", documentation: "Short description")
        #expect(text.string == "Short description")
        #expect(scroll.contentView.bounds.minY == 0)
        f.editor.completionPanel.updateInfo(at: 0, detail: "", documentation: "")
        #expect(scroll.isHidden)
    }

    @Test func enterKeepsSuffixAndTabReplacesSuffix() async throws {
        for replace in [false, true] {
            let f = try Fixture("alpha\nalZZ"); defer { f.dispose() }
            f.native.setPrimarySelectionUTF8Range(.init(location: 8, length: 0))
            _ = await f.intelligence.complete()
            #expect(f.editor.completionPanel.onAccept?(0, replace) == true)
            f.editor.completionPanel.close()
            try await f.settle()
            #expect(f.native.contentUTF8 == Data((replace ? "alpha\nalpha" : "alpha\nalphaZZ").utf8))
        }
    }

    @Test func stalePaneAndCaretCannotAcceptSemanticCompletion() async throws {
        let f = try Fixture("alpha\nal"); defer { f.dispose() }
        _ = await f.intelligence.complete()
        let accept = f.editor.completionPanel.onAccept
        f.native.setPrimarySelectionUTF8Range(.init(location: 0, length: 0))
        #expect(accept?(0, true) == false)
        #expect(f.native.contentUTF8 == Data("alpha\nal".utf8))
        f.intelligence.cancel()
        #expect(!f.editor.isCompletionSuggestionVisible)
    }

    @Test func compositionAndMultipleCaretsDoNotOpenRichPopup() async throws {
        let f = try Fixture("한글이름 한글단어\n"); defer { f.dispose() }
        f.native.setMarkedText("한글", selectedRange: .init(location: 2, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        try await f.settle()
        #expect(!f.editor.isCompletionSuggestionVisible)
        let client = try #require(f.window.firstResponder as? any NSTextInputClient)
        client.insertText("한글", replacementRange: .init(location: NSNotFound, length: 0))
        try await f.settle()
        #expect(f.editor.completionSuggestionCount == 2)
        f.intelligence.cancel()
        #expect(f.native.addSelectionUTF8Range(.init(location: 0, length: 0)))
        try f.type("한")
        try await f.settle()
        #expect(!f.editor.isCompletionSuggestionVisible)
    }
}
