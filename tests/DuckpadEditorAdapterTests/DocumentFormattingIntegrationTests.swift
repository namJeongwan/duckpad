import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
import DuckpadLocalization
import DuckpadScintillaBridge
@testable import DuckpadPresentation
import Testing

@MainActor
private final class ControlledFormatter: DocumentFormatting {
    var output = "{ \"한글\": 1 }\n"
    var failure: FormattingFailure?
    var requests: [FormattingRequest] = []
    var blocks = false
    var waiting: CheckedContinuation<Void, Never>?
    func format(_ request: FormattingRequest) async throws -> String {
        requests.append(request)
        if blocks { await withCheckedContinuation { waiting = $0 } }
        if let failure { throw failure }
        return output
    }
    func release() { waiting?.resume(); waiting = nil }
}

@Suite(.serialized) @MainActor
struct DocumentFormattingIntegrationTests {
    @MainActor private final class Fixture {
        let root: URL
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
        let engine = ControlledFormatter()
        let formatting: DocumentFormattingUseCase
        let files: FileDocumentUseCase
        let controller: DuckpadWindowController
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-format-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            formatting = DocumentFormattingUseCase(workspace: workspace, editor: editor, formatter: engine)
            files = FileDocumentUseCase(workspace: workspace, editor: editor, store: LocalTextFileStore(bookmarkArchiveURL: root.appendingPathComponent("access.json")))
            files.formattingUseCase = formatting
            controller = DuckpadWindowController(workspace: workspace, previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: TestMarkdownImageAccess(), editorAdapter: editor, editorView: editor.view,
                fileUseCase: files, formattingUseCase: formatting, automaticallyStarts: false)
        }
        func start() async { controller.start(); await controller.waitForStartup() }
        func open(_ text: String, name: String = "input.json") async throws -> FileWorkspaceContext {
            let url = root.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            guard case .opened = await files.open(url) else { throw FormattingFailure.unavailable }
            return try #require(workspace.activeFileContext())
        }
        func dispose() { controller.close(); editor.invalidate(); try? FileManager.default.removeItem(at: root) }
    }

    @Test func markdownSavePreservesIndentationWithoutCallingFormatter() async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        let source = "\'\'\'rust\nfn main() {\n    let n = 1;\n}\n\'\'\'\n"
        let context = try await f.open(source, name: "test.md")
        f.formatting.settings.formatOnSave = true
        #expect(await f.files.saveActive() == .saved(context.tabID))
        #expect(f.engine.requests.isEmpty)
        #expect(try String(contentsOfFile: context.binding!.canonicalPath, encoding: .utf8) == source)
        #expect(f.editor.activeScintillaView?.contentUTF8 == Data(source.utf8))
    }

    @Test func largeFormattedSaveUndoRedoPublishesOncePerAction() async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        let prompt = String(repeating: "한글 🦆 > nested\n", count: 4_000)
        let source = try JSONSerialization.data(withJSONObject: [
            "prompt": prompt,
            "nodes": (0..<800).map { ["id": String($0), "enabled": "true", "label": "한글 🦆"] },
        ])
        let input = String(decoding: source, as: UTF8.self).replacingOccurrences(of: ">", with: "\\u003e")
        f.engine.output = try await BundledPrettierFormatter().format(.init(text: input, parser: "json"))
        let context = try await f.open(input)
        #expect(f.editor.applyLanguage(.init(languageID: .init(rawValue: "json"), lexerName: "json", indentation: .init(), folding: true, braceMatching: true)))
        f.formatting.settings.formatOnSave = true
        #expect(await f.files.saveActive() == .saved(context.tabID))
        let view = try #require(f.editor.activeScintillaView)
        let render = f.workspace.onChange
        var publications = 0
        f.workspace.onChange = { change in
            if case .bufferEdited = change.kind { publications += 1 }
            render?(change)
        }
        let frozenCapture = try #require(f.editor.recoveryCapture(for: context.buffer.bufferID))
        for _ in 0..<3 {
            publications = 0
            view.undo()
            #expect(publications == 1)
            #expect(view.contentUTF8 == Data(input.utf8))
            #expect(f.workspace.snapshot().tabs.first(where: { $0.id == context.tabID })?.isDirty == true)
            #expect(f.workspace.activeFileContext()?.buffer.revision == view.revision)
            #expect(try f.editor.recoveryCapture(for: context.buffer.bufferID)?.materializedSnapshot().utf8 == Data(input.utf8))
            publications = 0
            view.redo()
            #expect(publications == 1)
            #expect(view.contentUTF8 == Data(f.engine.output.utf8))
            #expect(f.workspace.activeFileContext()?.buffer.revision == view.revision)
            #expect(try f.editor.recoveryCapture(for: context.buffer.bufferID)?.materializedSnapshot().utf8 == view.contentUTF8)
            await Task.yield()
        }
        #expect(try frozenCapture.materializedSnapshot().utf8 == Data(f.engine.output.utf8))
        #expect(try String(contentsOfFile: context.binding!.canonicalPath, encoding: .utf8) == f.engine.output)
    }

    @Test func minifiedJSONStylesOnceAndPreservesSelectionRecoveryAndUndo() async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        let payload = String(repeating: "한글 🦆 > nested\n", count: 40)
        let data = try JSONSerialization.data(withJSONObject: ["nodes": (0..<24).map { ["id": String($0), "prompt": payload] }])
        let input = String(decoding: data, as: UTF8.self).replacingOccurrences(of: ">", with: "\\u003e")
        f.engine.output = try await BundledPrettierFormatter().format(.init(text: input, parser: "json"))
        let context = try await f.open(input)
        #expect(f.editor.applyLanguage(.init(languageID: LanguageID(rawValue: "json"), lexerName: "json", indentation: .init(), folding: true, braceMatching: true)))
        let view = try #require(f.editor.activeScintillaView)
        let marker = try #require(input.range(of: "한글"))
        let offset = input[..<marker.lowerBound].utf8.count
        view.setPrimarySelectionUTF8Range(NSRange(location: offset, length: "한글".utf8.count))
        view.resetInstrumentation()
        _ = try await f.formatting.format()
        #expect(view.contentUTF8 == Data(f.engine.output.utf8))
        #expect(view.synchronouslyStyledByteCount > 0)
        #expect(view.synchronouslyStyledByteCount <= view.documentByteLength)
        #expect(view.foldLevel(atLine: 0) & 0x2000 != 0)
        let selected = view.contentUTF8.subdata(in: Int(min(view.anchorUTF8Position, view.caretUTF8Position))..<Int(max(view.anchorUTF8Position, view.caretUTF8Position)))
        #expect(String(decoding: selected, as: UTF8.self) == "한글")
        #expect(try f.editor.recoveryCapture(for: context.buffer.bufferID)?.materializedSnapshot().utf8 == view.contentUTF8)
        var publications = 0
        let render = f.workspace.onChange
        f.workspace.onChange = { change in
            if case .bufferEdited = change.kind { publications += 1 }
            render?(change)
        }
        view.undo()
        #expect(view.contentUTF8 == Data(input.utf8))
        #expect(publications == 1)
        #expect(f.workspace.activeFileContext()?.buffer.revision == view.revision)
        #expect(try f.editor.recoveryCapture(for: context.buffer.bufferID)?.materializedSnapshot().utf8 == Data(input.utf8))
        publications = 0
        view.redo()
        #expect(publications == 1)
        #expect(f.workspace.activeFileContext()?.buffer.revision == view.revision)
        #expect(view.contentUTF8 == Data(f.engine.output.utf8))
    }

    @Test func unchangedFormattingSkipsEngineButEditsAndSettingsInvalidateIt() async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        _ = try await f.open("{\"한글\":1}")
        _ = try await f.formatting.format()
        let count = f.engine.requests.count
        let view = try #require(f.editor.activeScintillaView)
        let reads = view.snapshotReadCount
        _ = try await f.formatting.format()
        #expect(f.engine.requests.count == count)
        #expect(view.snapshotReadCount == reads)
        f.formatting.settings.tabWidth = 4
        _ = try await f.formatting.format()
        #expect(f.engine.requests.count == count + 1)
        view.undo()
        _ = try await f.formatting.format()
        #expect(f.engine.requests.count == count + 2)
        _ = try await f.open("{}", name: "other.json")
        _ = try await f.formatting.format()
        #expect(f.engine.requests.count == count + 3)
    }

    @Test func manualFormatPreservesNativeSelectionsRecoveryAndUndoHistory() async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        let context = try await f.open("{\"한글\":1}")
        let view = try #require(f.editor.activeScintillaView)
        view.setPrimarySelectionUTF8Range(NSRange(location: 2, length: 6))
        #expect(view.addSelectionUTF8Range(NSRange(location: 10, length: 0)))
        let updated = try await f.formatting.format()
        #expect(view.contentUTF8 == Data(f.engine.output.utf8))
        #expect(view.selectionCount == 2)
        #expect(f.workspace.snapshot().tabs.first(where: { $0.id == context.tabID })?.isDirty == true)
        #expect(try f.editor.recoveryCapture(for: context.buffer.bufferID)?.materializedSnapshot().utf8 == Data(f.engine.output.utf8))
        #expect(updated.buffer.revision == view.revision)
        view.undo()
        #expect(view.contentUTF8 == Data("{\"한글\":1}".utf8))
        #expect(!view.canUndo)
        view.redo()
        #expect(view.contentUTF8 == Data(f.engine.output.utf8))
        let revision = view.revision
        _ = try await f.formatting.format()
        #expect(view.revision == revision)
    }

    @Test func saveSettingFormatsCleanAndDirtyDocumentsAndPreservesCRLFEncoding() async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        let context = try await f.open("{\"한글\":1}\r\n")
        let url = URL(fileURLWithPath: context.binding!.canonicalPath)
        #expect(await f.files.saveActive() == .saved(context.tabID))
        #expect(f.engine.requests.isEmpty)
        f.formatting.settings.formatOnSave = true
        #expect(await f.files.saveActive() == .saved(context.tabID))
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ \"한글\": 1 }\r\n")
        #expect(f.workspace.activeFileContext()?.binding?.lineEnding == .crlf)
        #expect(f.workspace.snapshot().tabs.first(where: { $0.id == context.tabID })?.isDirty == false)
        f.editor.activeScintillaView?.undo()
        #expect(f.workspace.snapshot().tabs.first(where: { $0.id == context.tabID })?.isDirty == true)
        #expect(await f.files.saveActive(conversion: .init(encoding: .utf16LittleEndian, byteOrderMark: .present, lineEnding: .crlf)) == .saved(context.tabID))
        #expect(try Data(contentsOf: url).starts(with: [0xff, 0xfe]))
    }

    @Test func saveAsUsesDestinationAndFormattingFailuresSaveOriginalSilently() async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        f.formatting.settings.formatOnSave = true
        let view = try #require(f.editor.activeScintillaView)
        view.insertCommittedText("{\"한글\":1}")
        let id = try #require(f.workspace.activeFileContext()?.tabID)
        let url = f.root.appendingPathComponent("first.json")
        #expect(await f.files.saveAs(url) == .saved(id))
        #expect(f.engine.requests.last?.parser == "json")
        #expect(try String(contentsOf: url, encoding: .utf8) == f.engine.output)
        view.insertCommittedText("broken")
        let raw = view.contentUTF8
        for failure in [FormattingFailure.invalidSyntax("expected a value"), .timedOut, .tooLarge, .unavailable] {
            f.engine.failure = failure
            #expect(await f.files.saveActive() == .saved(id))
            #expect(try Data(contentsOf: url) == raw)
            #expect(view.contentUTF8 == raw)
            #expect(f.controller.window?.attachedSheet == nil)
        }
        await #expect(throws: FormattingFailure.unavailable) { try await f.formatting.format() }
        let unsupported = "fn main() {}\r\n// keep mixed line endings\n"
        let rust = try await f.open(unsupported, name: "main.rs")
        let count = f.engine.requests.count
        _ = await f.files.saveActive()
        #expect(f.engine.requests.count == count)
        #expect(try Data(contentsOf: URL(fileURLWithPath: rust.binding!.canonicalPath)) == Data(unsupported.utf8))
    }

    @Test func editingOrSwitchingTabsDuringFormattingRejectsStaleResult() async throws {
        for switchTab in [false, true] {
            let f = try Fixture(); await f.start(); defer { f.dispose() }
            let context = try await f.open("{\"한글\":1}")
            f.engine.blocks = true
            let task = Task { try await f.formatting.format() }
            while f.engine.waiting == nil { await Task.yield() }
            if switchTab { _ = await f.workspace.addScratch() }
            else { f.editor.activeScintillaView?.insertCommittedText("x") }
            let before = f.editor.snapshot(for: context.buffer.bufferID)?.text
            f.engine.release()
            await #expect(throws: FormattingFailure.staleDocument) { try await task.value }
            #expect(f.editor.snapshot(for: context.buffer.bufferID)?.text == before)
            #expect(try String(contentsOfFile: context.binding!.canonicalPath, encoding: .utf8) == "{\"한글\":1}")
        }
    }

    @Test func editorPaneMustMatchTheWorkspaceBeforeFormatting() async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        let first = try await f.open("{\"first\":1}", name: "one.json")
        let second = try await f.open("{\"second\":2}", name: "two.json")
        _ = await f.workspace.activate(tabID: first.tabID)
        // Simulate a pane being rebound before workspace activation catches up.
        f.editor.display(second.buffer)
        await #expect(throws: FormattingFailure.staleDocument) { try await f.formatting.format() }
        #expect(f.engine.requests.isEmpty)
        #expect(f.editor.snapshot(for: first.buffer.bufferID)?.text == "{\"first\":1}")
        #expect(f.editor.snapshot(for: second.buffer.bufferID)?.text == "{\"second\":2}")
    }

    @Test func saveAllAndCloseSaveUseTheSameFormattingSetting() async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        var settings = AppSettings()
        settings.formatting.formatOnSave = true
        f.controller.applyPreferences(settings)
        let first = try await f.open("{\"한글\":1}", name: "one.json")
        f.editor.activeScintillaView?.insertCommittedText(" ")
        let second = try await f.open("{\"한글\":1}", name: "two.json")
        f.editor.activeScintillaView?.insertCommittedText(" ")
        f.controller.performSaveAll()
        let deadline = ContinuousClock.now + .seconds(5)
        while f.workspace.snapshot().tabs.contains(where: { $0.isDirty }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!f.workspace.snapshot().tabs.contains(where: { $0.isDirty }))
        for context in [first, second] {
            #expect(try String(contentsOfFile: context.binding!.canonicalPath, encoding: .utf8) == f.engine.output)
        }
        f.editor.activeScintillaView?.insertCommittedText(" ")
        await f.controller.performClose(second.tabID, decision: .save).value
        #expect(!f.workspace.snapshot().tabs.contains(where: { $0.id == second.tabID }))
        #expect(try String(contentsOfFile: second.binding!.canonicalPath, encoding: .utf8) == f.engine.output)
    }

    @Test func menuShortcutAndFormattingPreferencesAreVisibleInEnglishAndKorean() async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        _ = try await f.open("{}")
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
        let menu = DuckpadMainMenuFactory.make(target: f.controller)
        let command = try #require(items(menu).first { $0.action == #selector(DuckpadWindowController.performFormatDocument(_:)) })
        #expect(command.keyEquivalent == "f")
        #expect(command.keyEquivalentModifierMask == [.option, .shift])
        #expect(f.controller.validateMenuItem(command))
        let settings = DuckpadSettingsWindowController()
        defer { settings.close() }
        settings.selectCategory("Formatting")
        #expect(settings.selectedCategory == "Formatting")
        var updated = AppSettings()
        var updateTask: Task<Void, Never>?
        settings.configure(settings: updated) { value in updated = value; return .saved(value) }
        settings.onUpdateTaskStarted = { updateTask = $0 }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let root = try #require(settings.window?.contentView)
        for language in [AppLanguage.english, .korean] {
            let catalog = LocalizationCatalog(language: language)
            settings.refreshLocalization(catalog: catalog)
            let toggle = try #require(views(root).compactMap { $0 as? NSButton }.first { $0.title == catalog.text("Format on Save") })
            toggle.state = language == .english ? .on : .off
            toggle.sendAction(toggle.action, to: toggle.target)
            await updateTask?.value
            #expect(updated.formatting.formatOnSave == (language == .english))
            root.layoutSubtreeIfNeeded()
            #expect(toggle.frame.width > 0)
            #expect(toggle.title == catalog.text("Format on Save"))
        }
    }
}
