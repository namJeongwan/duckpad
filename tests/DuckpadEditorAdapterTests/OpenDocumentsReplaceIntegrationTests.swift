import AppKit
import DuckpadApplication
import DuckpadDomain
@testable import DuckpadEditorAdapter
import DuckpadInfrastructure
import DuckpadScintillaBridge
import Testing

private actor MaskSwitchSessionStore: SessionStore {
    private var stored: StoredSession?
    private var blocked = false, entered = false, released = false
    func loadSession() async throws(SessionStoreError) -> StoredSession? { stored }
    func commitSession(_ session: ScratchSession, generation: PersistenceGeneration) async throws(SessionStoreError) -> SessionCommitResult {
        if blocked { blocked = false; entered = true; while !released { await Task.yield() } }
        if let stored, generation <= stored.generation { return .superseded(durableGeneration: stored.generation) }
        stored = .init(session: session, generation: generation); return .committed
    }
    func arm() { blocked = true; entered = false; released = false }
    func waitForEntry() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !entered && ContinuousClock.now < deadline { await Task.yield() }
        return entered
    }
    func release() { released = true }
}

@Suite(.serialized) @MainActor
struct OpenDocumentsReplaceIntegrationTests {
    @MainActor private final class Fixture {
        let workspace: ScratchWorkspaceUseCase
        let editor = ScintillaEditorAdapter()
        let binding: EditorBindingUseCase
        let window: NSWindow
        init(store: any SessionStore = InMemorySessionStore()) {
            workspace = ScratchWorkspaceUseCase(store: store)
            _ = NSApplication.shared
            binding = EditorBindingUseCase(workspace: workspace, editor: editor)
            let binding = binding
            workspace.onChange = { binding.render($0) }
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = editor.view
        }
        func start(_ text: String) async throws -> TabSnapshot {
            _ = await workspace.start()
            return try install(text)
        }
        func add(_ text: String) async throws -> TabSnapshot {
            _ = await workspace.addScratch()
            return try install(text)
        }
        func install(_ text: String) throws -> TabSnapshot {
            let tab = try #require(workspace.snapshot().tabs.first { $0.isActive })
            editor.install(.init(bufferID: tab.buffer.bufferID, revision: tab.buffer.revision, text: text))
            editor.display(tab.buffer)
            return tab
        }
        func search(engine: any RegexEnginePort = ICURegexEngine(), limits: SearchLimits = SearchLimits()) -> SearchWorkspaceUseCase {
            SearchWorkspaceUseCase(workspace: workspace, editor: editor, regexEngine: engine, limits: limits)
        }
        func dispose() { workspace.onChange = nil; editor.invalidate(); window.contentView = nil; window.close() }
    }
    private let query = SearchQuery(pattern: "duck", replacement: "오리", options: .init(matchCase: true, scope: .allOpenDocuments))

    @Test(arguments: [false, true]) func fileMaskIsRecheckedAfterPersistenceAndTabSwitch(single: Bool) async throws {
        let store = MaskSwitchSessionStore(), f = Fixture(store: store); defer { f.dispose() }
        _ = try await f.start("")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let swift = root.appendingPathComponent("source.swift"), txt = root.appendingPathComponent("notes.txt")
        for url in [swift, txt] { try Data("duck duck".utf8).write(to: url) }
        let files = FileDocumentUseCase(workspace: f.workspace, editor: f.editor, store: LocalTextFileStore(bookmarkArchiveURL: root.appendingPathComponent(".access.json")))
        _ = await files.open(txt)
        let txtTab = try #require(f.workspace.snapshot().tabs.first { $0.fullPath == txt.path })
        _ = await files.open(swift)
        f.editor.activeScintillaView?.insertCommittedText(" ")
        let search = f.search(), query = SearchQuery(pattern: "duck", replacement: "goose", fileMask: "*.swift")
        var began = false
        let replace = Task { @MainActor in
            began = true
            if single { _ = try await search.replaceCurrentThenFind(query) }
            else { _ = try await search.replaceAll(query) }
        }
        while !began { await Task.yield() }
        for _ in 0..<5 { await Task.yield() }
        await store.arm()
        let activate = Task { @MainActor in await f.workspace.activate(tabID: txtTab.id) }
        let entered = await store.waitForEntry()
        #expect(entered)
        #expect(f.workspace.snapshot().activeBuffer?.bufferID == txtTab.buffer.bufferID)
        f.editor.selectAndReveal(.init(location: 0, length: 4))
        await store.release(); _ = await activate.value
        _ = try? await replace.value
        #expect(f.editor.snapshot(for: txtTab.buffer.bufferID)?.text == "duck duck")
        #expect(f.workspace.snapshot().tabs.first { $0.id == txtTab.id }?.isDirty == false)
        await files.releaseAllSecurityScopedAccess()
    }

    @Test func selectedPreviewRangeReplacesOneRegexCaptureAndPreservesNativeUndo() async throws {
        let f = Fixture(); defer { f.dispose() }
        let tab = try await f.start("duck1 duck2 duck3")
        let query = SearchQuery(pattern: "duck(\\d)", replacement: "goose$1", options: .init(mode: .regularExpression, scope: .allOpenDocuments))
        let search = f.search(), preview = try await search.findAll(query)
        let match = try #require(preview.documents.first?.matches.dropFirst().first)
        let result = try await search.replaceAllOpenDocuments(query, only: [tab.id], expectedRevisions: [tab.buffer.bufferID: tab.buffer.revision], expectedRanges: [tab.buffer.bufferID: [match.range]])
        #expect(result.replacementCount == 1)
        #expect(f.editor.snapshot(for: tab.buffer.bufferID)?.text == "duck1 goose2 duck3")
        f.editor.activeScintillaView?.undo()
        #expect(f.editor.snapshot(for: tab.buffer.bufferID)?.text == "duck1 duck2 duck3")
        f.editor.activeScintillaView?.redo()
        #expect(f.editor.snapshot(for: tab.buffer.bufferID)?.text == "duck1 goose2 duck3")
    }
    @Test func selectedZeroLengthPreviewInsertsOnlyAtItsOwnLocation() async throws {
        let f = Fixture(); defer { f.dispose() }
        let tab = try await f.start("duck duck")
        let query = SearchQuery(pattern: "(?=duck)", replacement: "x", options: .init(mode: .regularExpression, scope: .allOpenDocuments))
        let search = f.search(), preview = try await search.findAll(query)
        let match = try #require(preview.documents.first?.matches.last)
        let result = try await search.replaceAllOpenDocuments(query, only: [tab.id], expectedRevisions: [tab.buffer.bufferID: tab.buffer.revision], expectedRanges: [tab.buffer.bufferID: [match.range]])
        #expect(result.replacementCount == 1)
        #expect(f.editor.snapshot(for: tab.buffer.bufferID)?.text == "duck xduck")
        f.editor.activeScintillaView?.undo()
        #expect(f.editor.snapshot(for: tab.buffer.bufferID)?.text == "duck duck")
    }

    @Test func replacesInactiveAndUnsavedDocumentsWithIndependentUndoAndRecovery() async throws {
        let f = Fixture(); defer { f.dispose() }
        let first = try await f.start("한글 duck 🦆 duck\n")
        f.editor.activeScintillaView?.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 6))
        let second = try await f.add("duck\nplain")
        let third = try await f.add("plain")
        let result = try await f.search().replaceAllOpenDocuments(query)
        #expect(result.replacementCount == 3)
        #expect(result.changedDocumentCount == 2)
        #expect(result.skippedDocumentCount == 0)
        #expect(f.workspace.snapshot().activeBuffer?.bufferID == third.buffer.bufferID)
        #expect(f.editor.snapshot(for: first.buffer.bufferID)?.text == "한글 오리 🦆 오리\n")
        #expect(f.editor.snapshot(for: second.buffer.bufferID)?.text == "오리\nplain")
        #expect(f.workspace.snapshot().tabs.filter(\.isDirty).count == 2)
        #expect(try f.editor.recoveryCapture(for: first.buffer.bufferID)?.materializedSnapshot().utf8 == Data("한글 오리 🦆 오리\n".utf8))
        _ = await f.workspace.activate(tabID: first.id)
        #expect(f.editor.activeSelectionUTF8Range() == .init(location: 0, length: 6))
        f.editor.activeScintillaView?.undo()
        #expect(f.editor.snapshot(for: first.buffer.bufferID)?.text == "한글 duck 🦆 duck\n")
        #expect(f.editor.snapshot(for: second.buffer.bufferID)?.text == "오리\nplain")
        f.editor.activeScintillaView?.redo()
        #expect(f.editor.snapshot(for: first.buffer.bufferID)?.text == "한글 오리 🦆 오리\n")
        _ = await f.workspace.activate(tabID: second.id)
        f.editor.activeScintillaView?.undo()
        #expect(f.editor.snapshot(for: second.buffer.bufferID)?.text == "duck\nplain")
    }

    @Test func namedLegacyDocumentKeepsDiskAndPendingFormatUntilSave() async throws {
        let f = Fixture(); defer { f.dispose() }
        _ = try await f.start("")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cp949.txt")
        let bytes = try TextFileCodec.encode("한글 duck\r\n", encoding: .windows949, byteOrderMark: .absent)
        try bytes.write(to: url)
        let files = FileDocumentUseCase(workspace: f.workspace, editor: f.editor,
            store: LocalTextFileStore(bookmarkArchiveURL: root.appendingPathComponent("access.json")))
        guard case .opened = await files.open(url, assuming: .windows949) else { Issue.record("open failed"); return }
        let context = try #require(f.workspace.activeFileContext())
        let format = TextFileConversion(encoding: .utf8, byteOrderMark: .absent, lineEnding: .lf)
        #expect(await files.changeFormat(format, expectedContext: context) == nil)
        _ = try await f.add("duck")
        let result = try await f.search().replaceAllOpenDocuments(query)
        #expect(result.replacementCount == 2)
        #expect(try Data(contentsOf: url) == bytes)
        let retained = try #require(f.workspace.fileContext(tabID: context.tabID))
        #expect(retained.pendingFileFormat == format)
        #expect(retained.binding?.encoding == .windows949)
        _ = await f.workspace.activate(tabID: context.tabID)
        f.editor.activeScintillaView?.undo()
        #expect(f.editor.snapshot(for: context.buffer.bufferID)?.text == "한글 duck\r\n")
        #expect(f.workspace.activeFileContext()?.pendingFileFormat == format)
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test(arguments: [SearchMode.extended, .regularExpression])
    func extendedNewlinesAndRegexCapturesUseExistingMatcher(mode: SearchMode) async throws {
        let f = Fixture(); defer { f.dispose() }
        let first = try await f.start("duck 12\nduck 34\n")
        let second = try await f.add("duck 56\n")
        let q = SearchQuery(pattern: mode == .extended ? "duck 12\\n" : "duck ([0-9]+)",
                            replacement: mode == .extended ? "오리\\r\\n" : "오리 $1",
                            options: .init(mode: mode, scope: .allOpenDocuments))
        let result = try await f.search().replaceAllOpenDocuments(q)
        #expect(result.replacementCount == (mode == .extended ? 1 : 3))
        #expect(f.editor.snapshot(for: first.buffer.bufferID)?.text == (mode == .extended ? "오리\r\nduck 34\n" : "오리 12\n오리 34\n"))
        #expect(f.editor.snapshot(for: second.buffer.bufferID)?.text == (mode == .extended ? "duck 56\n" : "오리 56\n"))
    }

    @Test func reportsReadOnlyIMEAndOversizedDocumentsWithoutChangingThem() async throws {
        let f = Fixture(); defer { f.dispose() }
        let locked = try await f.start("duck")
        let large = try await f.add("duck duck duck")
        let composing = try await f.add("duck")
        let identity = FileIdentity(canonicalPath: "/tmp/duckpad-readonly-fixture.bin", device: 0, inode: 0,
                                    byteCount: 4, modifiedNanoseconds: 0, contentToken: "fixture")
        _ = await f.workspace.bindSavedFile(tabID: locked.id,
            binding: FileBinding(canonicalPath: identity.canonicalPath, encoding: .utf8, byteOrderMark: .absent,
                                 lineEnding: .none, observedIdentity: identity, binaryByteCount: 4),
            title: "readonly.bin", savedRevision: locked.buffer.revision)
        f.editor.activeScintillaView?.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let result = try await f.search(limits: .init(maximumDocumentBytes: 8)).replaceAllOpenDocuments(query)
        #expect(result.replacementCount == 0)
        #expect(result.skippedDocumentCount == 3)
        #expect(result.documents.first { $0.tabID == locked.id }?.status == .readOnly)
        #expect(result.documents.first { $0.tabID == large.id }?.status == .limitExceeded)
        #expect(f.editor.snapshot(for: locked.buffer.bufferID)?.text == "duck")
        #expect(f.editor.snapshot(for: large.buffer.bufferID)?.text == "duck duck duck")
        #expect(f.editor.activeScintillaView?.hasMarkedText() == true)
        #expect(result.documents.first { $0.tabID == composing.id }?.status == .unavailable)
    }

    @Test func staleAndClosedDocumentsAreReportedWithoutOverwritingNewerEdits() async throws {
        let f = Fixture(); defer { f.dispose() }
        let first = try await f.start("duck")
        let second = try await f.add("duck")
        let engine = SearchScanBarrierRegexEngine(base: ICURegexEngine())
        var q = query; q.options.mode = .regularExpression
        let search = f.search(engine: engine)
        let task = Task { try await search.replaceAllOpenDocuments(q) }
        await engine.waitUntilScanEntered()
        f.editor.activeScintillaView?.insertCommittedText("new ")
        _ = await f.workspace.close(tabID: first.id, decision: .discard)
        engine.releaseScan()
        let result = try await task.value
        #expect(result.replacementCount == 0)
        #expect(result.documents.first { $0.tabID == first.id }?.status == .changed)
        #expect(result.documents.first { $0.tabID == second.id }?.status == .changed)
        #expect(f.editor.snapshot(for: second.buffer.bufferID)?.text == "new duck")
    }

    @Test func cancellationBeforeApplyChangesNothingAndCancellationAfterApplyReportsProgress() async throws {
        let f = Fixture(); defer { f.dispose() }
        let first = try await f.start("duck")
        let second = try await f.add("duck")
        let engine = SearchScanBarrierRegexEngine(base: ICURegexEngine())
        let search = f.search(engine: engine)
        var scanningQuery = query; scanningQuery.options.mode = .regularExpression
        let before = Task { try await search.replaceAllOpenDocuments(scanningQuery) }
        await engine.waitUntilScanEntered()
        before.cancel(); engine.releaseScan()
        do { _ = try await before.value; Issue.record("expected cancellation") }
        catch let failure as SearchFailure { #expect(failure == .cancelled) }
        #expect(f.editor.snapshot(for: first.buffer.bufferID)?.text == "duck")
        #expect(f.editor.snapshot(for: second.buffer.bufferID)?.text == "duck")
        var task: Task<OpenDocumentsReplacementResult, any Error>?
        task = Task {
            try await f.search().replaceAllOpenDocuments(query) { progress in
                if progress.changedDocumentCount == 1 { task?.cancel() }
            }
        }
        let result = try await task!.value
        #expect(result.wasCancelled)
        #expect(result.replacementCount == 1)
        #expect(result.documents.last?.status == .cancelled)
        #expect(f.editor.snapshot(for: first.buffer.bufferID)?.text == "오리")
        #expect(f.editor.snapshot(for: second.buffer.bufferID)?.text == "duck")
    }

    @Test func invalidRegexAndNoOpReplacementLeaveAllUndoHistoriesUntouched() async throws {
        let f = Fixture(); defer { f.dispose() }
        let first = try await f.start("duck")
        let second = try await f.add("duck")
        do {
            _ = try await f.search().replaceAllOpenDocuments(.init(pattern: "(", replacement: "x", options: .init(mode: .regularExpression, scope: .allOpenDocuments)))
            Issue.record("expected invalid regex")
        } catch let failure as SearchFailure { if case .invalidRegularExpression = failure {} else { Issue.record("unexpected failure") } }
        var q = query; q.replacement = "duck"
        let result = try await f.search().replaceAllOpenDocuments(q)
        #expect(result.replacementCount == 0)
        #expect(f.workspace.snapshot().tabs.allSatisfy { !$0.isDirty && $0.buffer.revision == 0 })
        #expect(f.editor.snapshot(for: first.buffer.bufferID)?.text == "duck")
        #expect(f.editor.snapshot(for: second.buffer.bufferID)?.text == "duck")
        #expect(f.editor.activeScintillaView?.canUndo == false)
    }
    @Test func oversizedRegexExpansionSkipsOnlyThatDocument() async throws {
        let f = Fixture(); defer { f.dispose() }
        let large = try await f.start(String(repeating: "x", count: 40))
        let small = try await f.add("x")
        let q = SearchQuery(pattern: "(x+)", replacement: "$1$1", options: .init(mode: .regularExpression, scope: .allOpenDocuments))
        let result = try await f.search(limits: .init(maximumReplacementBytes: 64)).replaceAllOpenDocuments(q)
        #expect(result.documents.first { $0.tabID == large.id }?.status == .limitExceeded)
        #expect(result.replacementCount == 1)
        #expect(f.editor.snapshot(for: large.buffer.bufferID)?.text == String(repeating: "x", count: 40))
        #expect(f.editor.snapshot(for: small.buffer.bufferID)?.text == "xx")
    }

    @Test func replacedInactiveBuffersSurviveFullSessionRecovery() async throws {
        let f = Fixture(); defer { f.dispose() }
        let first = try await f.start("duck 한글")
        let second = try await f.add("duck 🦆")
        _ = try await f.search().replaceAllOpenDocuments(query)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalRecoveryStore(root: root)
        let recovery = SessionRecoveryUseCase(workspace: f.workspace, editor: f.editor, store: store)
        guard case .saved = await recovery.flush() else { Issue.record("recovery flush failed"); return }
        let restored = Fixture(); defer { restored.dispose() }
        let restore = SessionRecoveryUseCase(workspace: restored.workspace, editor: restored.editor, store: store)
        #expect(await restore.start() == .saved)
        await restore.waitForPendingAutosave()
        #expect(restored.workspace.snapshot().tabs.filter(\.isDirty).count == 2)
        #expect(restored.editor.snapshot(for: first.buffer.bufferID)?.text == "오리 한글")
        #expect(restored.editor.snapshot(for: second.buffer.bufferID)?.text == "오리 🦆")
    }

    @Test func sharedSplitDocumentIsReplacedOnceAndKeepsMultipleSelections() async throws {
        let f = Fixture(); defer { f.dispose() }
        let tab = try await f.start("duck duck")
        let primary = try #require(f.editor.activeScintillaView)
        primary.setPrimarySelectionUTF8Range(NSRange(location: 0, length: 0))
        #expect(primary.addSelectionUTF8Range(NSRange(location: 5, length: 0)))
        f.editor.split(orientation: .sideBySide)
        let secondary = try #require(f.editor.secondaryScintillaView)
        let result = try await f.search().replaceAllOpenDocuments(query)
        #expect(result.changedDocumentCount == 1)
        #expect(result.replacementCount == 2)
        #expect(primary.contentUTF8 == Data("오리 오리".utf8))
        #expect(secondary.contentUTF8 == primary.contentUTF8)
        #expect(primary.selectionCount == 2)
        secondary.undo()
        #expect(primary.contentUTF8 == Data("duck duck".utf8))
        #expect(f.editor.recoverySnapshot(for: tab.buffer.bufferID)?.utf8 == primary.contentUTF8)
    }

    @Test func matchLimitNeverAppliesATruncatedPrefixOfADocument() async throws {
        let f = Fixture(); defer { f.dispose() }
        let large = try await f.start("duck duck duck")
        let small = try await f.add("duck")
        let result = try await f.search(limits: .init(maximumMatches: 2)).replaceAllOpenDocuments(query)
        #expect(result.replacementCount == 1)
        #expect(result.documents.first?.status == .limitExceeded)
        #expect(f.editor.snapshot(for: large.buffer.bufferID)?.text == "duck duck duck")
        #expect(f.editor.snapshot(for: small.buffer.bufferID)?.text == "오리")
    }

}
