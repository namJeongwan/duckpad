import AppKit
import DuckpadApplication
import DuckpadDomain
@testable import DuckpadEditorAdapter
import DuckpadInfrastructure
import DuckpadPresentation
import Testing

@Suite(.serialized) @MainActor
struct EditorConventionsIntegrationTests {
    @MainActor private final class Fixture {
        let root: URL
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
        let files: FileDocumentUseCase
        let conventions: DocumentConventionsUseCase
        let binding: EditorBindingUseCase
        let window: NSWindow
        init() throws {
            _ = NSApplication.shared
            root = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-conventions-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            files = FileDocumentUseCase(workspace: workspace, editor: editor, store: LocalTextFileStore(bookmarkArchiveURL: root.appendingPathComponent("access.json")))
            conventions = DocumentConventionsUseCase(reader: LocalEditorConfigReader(), workspace: workspace, editor: editor)
            files.conventionsUseCase = conventions
            binding = EditorBindingUseCase(workspace: workspace, editor: editor)
            let binding = self.binding
            workspace.onChange = { binding.render($0) }
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = editor.view
        }
        func start() async { _ = await workspace.start(); binding.render(workspace.snapshot()) }
        func dispose() { editor.invalidate(); window.contentView = nil; window.close(); try? FileManager.default.removeItem(at: root) }
        func open(_ source: String) async throws -> FileWorkspaceContext {
            let url = root.appendingPathComponent("sample.txt")
            try Data(source.utf8).write(to: url)
            guard case .opened = await files.open(url) else { throw FormattingFailure.unavailable }
            return try #require(workspace.activeFileContext())
        }
    }
    @Test func saveRulesAreUndoableAndSaveAsUsesDestination() async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        let source = "한글  \n  text\t"
        let context = try await f.open(source)
        #expect(await f.files.saveActive() == .saved(context.tabID))
        #expect(f.editor.activeScintillaView?.contentUTF8 == Data(source.utf8))
        let destination = f.root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try "root=true\n[*]\ntrim_trailing_whitespace=true\ninsert_final_newline=true\nend_of_line=crlf\ncharset=utf-8-bom".write(to: destination.appendingPathComponent(".editorconfig"), atomically: true, encoding: .utf8)
        let url = destination.appendingPathComponent("saved.txt")
        #expect(await f.files.saveAs(url) == .saved(context.tabID))
        let bytes = try Data(contentsOf: url)
        #expect(bytes == Data([0xef, 0xbb, 0xbf]) + Data("한글\r\n  text\r\n".utf8))
        let view = try #require(f.editor.activeScintillaView)
        #expect(String(decoding: view.contentUTF8, as: UTF8.self) == "한글\n  text\r\n")
        view.undo()
        #expect(view.contentUTF8 == Data(source.utf8))
        #expect(f.workspace.snapshot().tabs.first(where: { $0.id == context.tabID })?.isDirty == true)
        #expect(try f.editor.recoveryCapture(for: context.buffer.bufferID)?.materializedSnapshot().utf8 == Data(source.utf8))
    }
    @Test func snippetInsertEditNavigateAndUndo() async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        let context = try await f.open("")
        #expect(f.editor.insertSnippet("${1:한글} = ${2:value}$0"))
        let view = try #require(f.editor.activeScintillaView)
        #expect(f.editor.activeSelectionUTF8Range() == .init(location: 0, length: 6))
        view.insertCommittedText("duck")
        #expect(f.editor.moveSnippetField())
        #expect(f.editor.activeSelectionUTF8Range() == .init(location: 7, length: 5))
        view.insertCommittedText("42")
        #expect(f.editor.moveSnippetField())
        #expect(view.contentUTF8 == Data("duck = 42".utf8))
        #expect(f.editor.snippetSession == nil)
        #expect(try f.editor.recoveryCapture(for: context.buffer.bufferID)?.materializedSnapshot().utf8 == view.contentUTF8)
        var states: [String] = []
        for _ in 0..<8 where view.canUndo {
            view.undo(); states.append(String(decoding: view.contentUTF8, as: UTF8.self))
            await Task.yield()
        }
        #expect(view.contentUTF8.isEmpty, "Undo states: \(states)")
    }
    @Test func mirroredFieldsAndReadOnlyAdmission() async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        let context = try await f.open("")
        f.editor.setReadOnly(true, for: context.buffer.bufferID)
        #expect(!f.editor.canInsertSnippet)
        #expect(!f.editor.insertSnippet("bad"))
        f.editor.setReadOnly(false, for: context.buffer.bufferID)
        #expect(f.editor.insertSnippet("${1:name} = $1; $0"))
        let view = try #require(f.editor.activeScintillaView)
        #expect(view.selectionCount == 2)
        view.insertCommittedText("🦆")
        #expect(view.contentUTF8 == Data("🦆 = 🦆; ".utf8))
        #expect(f.editor.moveSnippetField())
        #expect(f.editor.activeSelectionUTF8Range() == .init(location: 13, length: 0))
    }
    @Test func snippetMirrorTypingThroughNativeKeyDown() async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        _ = try await f.open("")
        #expect(f.editor.insertSnippet("${1:first} = ${2:second}; $1$0"))
        let view = try #require(f.editor.activeScintillaView)
        view.focusEditor()
        let responder = try #require(f.window.firstResponder)
        for (character, code) in [("d", 2), ("u", 32), ("c", 8), ("k", 40)] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: f.window.windowNumber,
                context: nil, characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: UInt16(code)))
            responder.keyDown(with: event)
        }
        #expect(view.contentUTF8 == Data("duck = second; duck".utf8))
        #expect(f.editor.moveSnippetField())
        #expect(f.editor.activeSelectionUTF8Range() == .init(location: 7, length: 6))
    }

    @Test func reloadCancelsSnippetAndRestoresSelectionTyping() async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        _ = try await f.open("")
        #expect(f.editor.insertSnippet("${1:name} $1$0"))
        let view = try #require(f.editor.activeScintillaView)
        #expect(view.additionalSelectionTyping)
        let current = try #require(f.workspace.activeFileContext())
        f.editor.reload(.init(bufferID: current.buffer.bufferID, revision: current.buffer.revision, text: "replacement"))
        #expect(f.editor.snippetSession == nil)
        #expect(!view.additionalSelectionTyping)
    }

    @Test func snippetInsertionIsOneUndoAndCompositionIsRejected() async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        _ = try await f.open("before")
        f.editor.selectAndReveal(.init(location: 0, length: 6))
        #expect(f.editor.insertSnippet("${1:after}$0"))
        let view = try #require(f.editor.activeScintillaView)
        f.editor.cancelSnippet()
        view.undo()
        #expect(view.contentUTF8 == Data("before".utf8))
        view.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!f.editor.canInsertSnippet)
        #expect(!f.editor.insertSnippet("do not insert"))
    }

    @Test func editorConfigDecodesUTF16WithoutBOM() async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        try "root=true\n[*]\ncharset=utf-16le".write(to: f.root.appendingPathComponent(".editorconfig"), atomically: true, encoding: .utf8)
        let url = f.root.appendingPathComponent("utf16.txt")
        try TextFileCodec.encode("한글\n", encoding: .utf16LittleEndian, byteOrderMark: .absent).write(to: url)
        guard case .opened = await f.files.open(url) else { Issue.record("open failed"); return }
        #expect(f.editor.activeScintillaView?.contentUTF8 == Data("한글\n".utf8))
    }

    @Test func separateIndentWidthControlsSmartReturn() async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        _ = try await f.open("if True:")
        #expect(f.editor.applyLanguage(.init(languageID: .init(rawValue: "python"), lexerName: "python", indentation: .init(width: 4, useTabs: true), folding: true, braceMatching: true, documentTabWidth: 3)))
        let view = try #require(f.editor.activeScintillaView)
        f.editor.selectAndReveal(.init(location: 8, length: 0))
        view.insertCommittedText("\n")
        #expect(view.contentUTF8 == Data("if True:\n\t ".utf8))
    }

    @Test func actualLanguagePipelineUsesDetectionThenProjectRules() async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        let context = try await f.open("a\n  b\n    c\n  d\n")
        let language = LanguageWorkspaceUseCase(registry: try LanguageManifestLoader().loadBundled(), workspace: f.workspace, editor: f.editor)
        language.conventions = f.conventions
        _ = language.validateAndRefresh()
        #expect(f.editor.activeScintillaView?.configuredTabWidth == 2)
        try "root=true\n[*]\nindent_size=8".write(to: f.root.appendingPathComponent(".editorconfig"), atomically: true, encoding: .utf8)
        _ = await f.conventions.rules(for: URL(fileURLWithPath: context.binding!.canonicalPath))
        _ = language.refreshActive()
        #expect(f.editor.activeScintillaView?.configuredTabWidth == 8)
        var settings = AppSettings(); settings.editorConfigEnabled = false; settings.detectIndentation = false
        settings.overrideLanguageIndentation = true; settings.indentationWidth = 3
        f.conventions.settingsDidChange(settings)
        _ = language.refreshActive()
        #expect(f.editor.activeScintillaView?.configuredTabWidth == 3)
    }

    @Test func documentIndentAndTabWidthOverridePreferences() async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        _ = try await f.open("")
        var preferences = AppSettings(); preferences.overrideLanguageIndentation = true; preferences.indentationWidth = 8
        f.editor.applyPreferences(preferences)
        #expect(f.editor.applyLanguage(.init(languageID: .plainText, lexerName: "null", indentation: .init(width: 2), folding: false, braceMatching: false, documentTabWidth: 3)))
        #expect(f.editor.activeScintillaView?.configuredTabWidth == 3)
        f.editor.applyPreferences(preferences)
        #expect(f.editor.activeScintillaView?.configuredTabWidth == 3)
    }

    @Test func savingScratchWithoutExtensionAppliesConfigToNativeTab() async throws {
        let f = try Fixture(); await f.start()
        defer { f.workspace.onChange = nil; f.dispose() }
        let language = LanguageWorkspaceUseCase(registry: try LanguageManifestLoader().loadBundled(), workspace: f.workspace, editor: f.editor)
        language.conventions = f.conventions
        f.conventions.onRulesChanged = { _ = language.refreshActive() }
        let binding = f.binding
        f.workspace.onChange = { binding.render($0); _ = language.refreshActive() }
        _ = language.validateAndRefresh()
        let context = try #require(f.workspace.activeFileContext())
        #expect(context.binding == nil)
        #expect(f.editor.activeScintillaView?.configuredTabWidth == 4)
        try "root=true\n[*]\nindent_style=space\nindent_size=2\ntab_width=2".write(to: f.root.appendingPathComponent(".editorconfig"), atomically: true, encoding: .utf8)
        #expect(await f.files.saveAs(f.root.appendingPathComponent("new 51")) == .saved(context.tabID))
        let view = try #require(f.editor.activeScintillaView)
        #expect(view.configuredTabWidth == 2)
        view.focusEditor()
        let responder = try #require(f.window.firstResponder)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: f.window.windowNumber,
            context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        responder.keyDown(with: event)
        #expect(view.contentUTF8 == Data("  ".utf8))
    }

    @Test(arguments: [false, true])
    func unchangedSaveAppliesCleanupAndPreservesUndo(projectRules: Bool) async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        let source = "hello 한글  "
        let context = try await f.open(source)
        let url = URL(fileURLWithPath: context.binding!.canonicalPath)
        if projectRules {
            // Rules created after opening must be read before deciding to skip Save.
            try "root=true\n[*]\ntrim_trailing_whitespace=true\ninsert_final_newline=true".write(to: f.root.appendingPathComponent(".editorconfig"), atomically: true, encoding: .utf8)
        } else {
            f.conventions.settings.editorConfigEnabled = false
            f.conventions.settings.trimWhitespaceOnSave = true
            f.conventions.settings.finalNewlineOnSave = true
        }
        #expect(await f.files.saveActive() == .saved(context.tabID))
        #expect(try Data(contentsOf: url) == Data("hello 한글\n".utf8))
        let view = try #require(f.editor.activeScintillaView)
        #expect(view.contentUTF8 == Data("hello 한글\n".utf8))
        let identity = try await LocalTextFileStore().currentIdentity(for: url)
        #expect(await f.files.saveActive() == .saved(context.tabID))
        #expect(try await LocalTextFileStore().currentIdentity(for: url) == identity)
        view.undo()
        #expect(view.contentUTF8 == Data(source.utf8))
        #expect(f.workspace.snapshot().tabs.first(where: { $0.id == context.tabID })?.isDirty == true)
        #expect(try f.editor.recoveryCapture(for: context.buffer.bufferID)?.materializedSnapshot().utf8 == Data(source.utf8))
    }

    @Test(arguments: [TextFileEncoding.utf8, .utf16LittleEndian, .utf16BigEndian])
    func automaticOpenHonorsBOMBeforeProjectCharset(sourceEncoding: TextFileEncoding) async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        let targetEncoding: TextFileEncoding = sourceEncoding == .utf16LittleEndian ? .utf16BigEndian : .utf16LittleEndian
        let charset = targetEncoding == .utf16LittleEndian ? "utf-16le" : "utf-16be"
        try "root=true\n[*]\ncharset=\(charset)".write(to: f.root.appendingPathComponent(".editorconfig"), atomically: true, encoding: .utf8)
        let url = f.root.appendingPathComponent("bom.txt")
        let source = "hello 한글\n"
        try TextFileCodec.encode(source, encoding: sourceEncoding, byteOrderMark: .present).write(to: url)
        guard case .opened = await f.files.open(url) else { Issue.record("open failed"); return }
        let view = try #require(f.editor.activeScintillaView)
        #expect(view.contentUTF8 == Data(source.utf8))
        #expect(f.workspace.activeFileContext()?.binding?.encoding == sourceEncoding)
        view.setPrimarySelectionUTF8Range(NSRange(location: view.contentUTF8.count, length: 0))
        view.insertCommittedText("!")
        let context = try #require(f.workspace.activeFileContext())
        #expect(await f.files.saveActive() == .saved(context.tabID))
        let saved = try TextFileCodec.decode(Data(contentsOf: url))
        #expect(saved.text == source + "!")
        #expect(saved.encoding == targetEncoding)
    }

    @Test func explicitOpenEncodingStillOverridesProjectCharset() async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        try "root=true\n[*]\ncharset=utf-16le".write(to: f.root.appendingPathComponent(".editorconfig"), atomically: true, encoding: .utf8)
        let url = f.root.appendingPathComponent("explicit.txt")
        try TextFileCodec.encode("hello 한글", encoding: .utf16BigEndian, byteOrderMark: .absent).write(to: url)
        guard case .opened = await f.files.open(url, assuming: .utf16BigEndian) else { Issue.record("open failed"); return }
        #expect(f.editor.activeScintillaView?.contentUTF8 == Data("hello 한글".utf8))
    }

    @Test func projectCanDisableCleanupWithoutRewritingCleanFile() async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        f.conventions.settings.trimWhitespaceOnSave = true
        f.conventions.settings.finalNewlineOnSave = true
        try "root=true\n[*]\ntrim_trailing_whitespace=false\ninsert_final_newline=unset".write(to: f.root.appendingPathComponent(".editorconfig"), atomically: true, encoding: .utf8)
        let source = "hello  \r\n"
        let context = try await f.open(source)
        let url = URL(fileURLWithPath: context.binding!.canonicalPath)
        let identity = try await LocalTextFileStore().currentIdentity(for: url)
        #expect(await f.files.saveActive() == .saved(context.tabID))
        #expect(try Data(contentsOf: url) == Data(source.utf8))
        #expect(try await LocalTextFileStore().currentIdentity(for: url) == identity)
    }

    @Test(arguments: [Data([0xff, 0xfe, 0]), Data([0xef, 0xbb, 0xbf, 0xff])])
    func malformedBOMRetainsReadOnlyBinaryFallback(bytes: Data) async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        try "root=true\n[*]\ncharset=utf-16le\ntrim_trailing_whitespace=true".write(to: f.root.appendingPathComponent(".editorconfig"), atomically: true, encoding: .utf8)
        let url = f.root.appendingPathComponent("malformed.txt")
        try bytes.write(to: url)
        guard case .opened = await f.files.open(url) else { Issue.record("open failed"); return }
        #expect(f.workspace.activeFileContext()?.binding?.isReadOnly == true)
        #expect(await f.files.saveActive() == .failed(.readOnly))
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func cleanupOnCleanFileStillChecksExternalConflict() async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        f.conventions.settings.trimWhitespaceOnSave = true
        let context = try await f.open("original  ")
        let url = URL(fileURLWithPath: context.binding!.canonicalPath)
        try Data("external edit".utf8).write(to: url)
        guard case .conflict = await f.files.saveActive() else { Issue.record("missing conflict"); return }
        #expect(try Data(contentsOf: url) == Data("external edit".utf8))
        #expect(f.editor.activeScintillaView?.contentUTF8 == Data("original".utf8))
        #expect(f.workspace.snapshot().tabs.first(where: { $0.id == context.tabID })?.isDirty == true)
        f.editor.activeScintillaView?.undo()
        #expect(f.editor.activeScintillaView?.contentUTF8 == Data("original  ".utf8))
    }

    @Test func unchangedSaveAppliesNewProjectEncodingWithoutLosingText() async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        let context = try await f.open("hello 한글\n")
        try "root=true\n[*]\ncharset=utf-16be".write(to: f.root.appendingPathComponent(".editorconfig"), atomically: true, encoding: .utf8)
        #expect(await f.files.saveActive() == .saved(context.tabID))
        let decoded = try TextFileCodec.decode(Data(contentsOf: URL(fileURLWithPath: context.binding!.canonicalPath)))
        #expect(decoded.text == "hello 한글\n")
        #expect(decoded.encoding == .utf16BigEndian)
    }

    @Test func unchangedSaveHonorsProjectFinalNewlineFalse() async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        f.conventions.settings.finalNewlineOnSave = true
        let context = try await f.open("hello\r\n")
        try "root=true\n[*]\ninsert_final_newline=false".write(to: f.root.appendingPathComponent(".editorconfig"), atomically: true, encoding: .utf8)
        #expect(await f.files.saveActive() == .saved(context.tabID))
        #expect(try Data(contentsOf: URL(fileURLWithPath: context.binding!.canonicalPath)) == Data("hello".utf8))
    }
}
