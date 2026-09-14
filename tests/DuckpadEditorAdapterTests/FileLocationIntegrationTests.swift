import AppKit
import PDFKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
@testable import DuckpadPresentation
import Testing

@MainActor private final class LocationPanels: FilePanelPresenting {
    var destination: URL?
    var confirmed = false
    var confirmedURL: URL?
    var warnedAboutUnsavedChanges: Bool?
    var duringPanel: (@MainActor () async -> Void)?
    func chooseOpenURL(attachedTo window: NSWindow?) async -> URL? { nil }
    func chooseSaveURL(suggestedName: String, attachedTo window: NSWindow?) async -> URL? { nil }
    func chooseFileLocation(for url: URL, renaming: Bool, attachedTo window: NSWindow?) async -> URL? {
        await duringPanel?(); return destination
    }
    func confirmTrash(of url: URL, hasUnsavedChanges: Bool, attachedTo window: NSWindow?) async -> Bool {
        confirmedURL = url
        warnedAboutUnsavedChanges = hasUnsavedChanges
        await duringPanel?(); return confirmed
    }
}

// Keep integration artifacts in the fixture; the infrastructure suite tests native Trash.
private struct LocationTestFileStore: TextFileStore {
    let base: LocalTextFileStore
    let trashURL: URL
    func canonicalURL(for url: URL) async throws(TextFileStoreError) -> URL { try await base.canonicalURL(for: url) }
    func read(from url: URL) async throws(TextFileStoreError) -> FileReadResult { try await base.read(from: url) }
    func readForDisplay(from url: URL, assuming encoding: TextFileEncoding?) async throws(TextFileStoreError) -> FileReadResult {
        try await base.readForDisplay(from: url, assuming: encoding)
    }
    func currentIdentity(for url: URL) async throws(TextFileStoreError) -> FileIdentity? { try await base.currentIdentity(for: url) }
    func writeAtomically(_ data: Data, to url: URL, expectedIdentity: FileIdentity?, overwrite: Bool) async throws(TextFileStoreError) -> FileWriteReceipt {
        try await base.writeAtomically(data, to: url, expectedIdentity: expectedIdentity, overwrite: overwrite)
    }
    func changeLocation(of binding: FileBinding, operation: FileLocationOperation) async throws(TextFileStoreError) -> FileLocationReceipt {
        if case .trash = operation { return try await base.changeLocation(of: binding, operation: .move(trashURL)) }
        return try await base.changeLocation(of: binding, operation: operation)
    }
}

private actor LocationSessionStore: SessionStore {
    let memory = InMemorySessionStore()
    var fails = false
    func setFails(_ value: Bool) { fails = value }
    func loadSession() async throws(SessionStoreError) -> StoredSession? { try await memory.loadSession() }
    func storedSession() async -> ScratchSession? { await memory.storedSession() }
    func commitSession(_ session: ScratchSession, generation: PersistenceGeneration) async throws(SessionStoreError) -> SessionCommitResult {
        if fails { throw .unavailable("injected") }
        return try await memory.commitSession(session, generation: generation)
    }
}

@Suite(.serialized) @MainActor
struct FileLocationIntegrationTests {
    @MainActor private final class Fixture {
        let root: URL
        let store = LocationSessionStore()
        let workspace: ScratchWorkspaceUseCase
        let editor = ScintillaEditorAdapter()
        let files: FileDocumentUseCase
        let controller: DuckpadWindowController
        let panels = LocationPanels()
        init(simulatedTrash: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-location-\(UUID())").resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            workspace = ScratchWorkspaceUseCase(store: store)
            let base = LocalTextFileStore(bookmarkArchiveURL: root.appendingPathComponent("access.json"))
            let fileStore: any TextFileStore = simulatedTrash
                ? LocationTestFileStore(base: base, trashURL: root.appendingPathComponent("trashed.txt")) : base
            files = FileDocumentUseCase(workspace: workspace, editor: editor, store: fileStore)
            controller = DuckpadWindowController(workspace: workspace, editorAdapter: editor, editorView: editor.view,
                secondaryEditorView: editor.secondaryGroupView, additionalEditorViews: editor.additionalEditorGroupViews,
                editorGroupRouter: editor, fileUseCase: files, filePanels: panels, automaticallyStarts: false)
        }
        func start() async { controller.start(); await controller.waitForStartup() }
        func open(_ text: String = "한글 🦆\r\n", name: String = "original.txt") async throws -> FileWorkspaceContext {
            let url = root.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            guard case .opened = await files.open(url) else { throw FormattingFailure.unavailable }
            return try #require(workspace.activeFileContext())
        }
        func dispose() { controller.close(); editor.invalidate(); try? FileManager.default.removeItem(at: root) }
    }

    @Test func renameAndMovePreserveDirtyTextUndoEncodingAndSaveDestination() async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        let original = try await f.open()
        let view = try #require(f.editor.activeScintillaView)
        view.insertCommittedText("edited")
        let edited = view.contentUTF8
        #expect(edited != Data("한글 🦆\r\n".utf8))
        let context = try #require(f.workspace.activeFileContext())
        let destination = f.root.appendingPathComponent("renamed.json")
        #expect(await f.files.changeLocation(.move(destination), expectedContext: context) == .saved(context.tabID))
        #expect(!FileManager.default.fileExists(atPath: original.binding!.canonicalPath))
        #expect(try Data(contentsOf: destination) == Data("한글 🦆\r\n".utf8))
        #expect(view.contentUTF8 == edited)
        #expect(f.workspace.activeFileContext()?.buffer == context.buffer)
        #expect(f.workspace.activeFileContext()?.title == "renamed.json")
        #expect(f.workspace.activeFileContext()?.binding?.lineEnding == .crlf)
        #expect(f.workspace.snapshot().tabs.first(where: { $0.id == context.tabID })?.isDirty == true)
        view.undo()
        #expect(view.contentUTF8 == Data("한글 🦆\r\n".utf8))
        view.redo()
        #expect(view.contentUTF8 == edited)
        #expect(await f.files.saveActive() == .saved(context.tabID))
        #expect(try Data(contentsOf: destination) == edited)
        let folder = f.root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let moved = folder.appendingPathComponent("renamed.json")
        #expect(await f.files.changeLocation(.move(moved), expectedContext: f.workspace.activeFileContext()!) == .saved(context.tabID))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try Data(contentsOf: moved) == edited)
        #expect(try await f.store.storedSession()?.fileBinding(for: context.tabID)?.canonicalPath == moved.path)
    }

    @Test func caseOnlyRenamePreservesRequestedSpelling() async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        let context = try await f.open("case", name: "Original.txt")
        let destination = f.root.appendingPathComponent("original.txt")
        #expect(await f.files.changeLocation(.move(destination), expectedContext: context) == .saved(context.tabID))
        #expect(f.workspace.activeFileContext()?.binding?.canonicalPath == destination.path)
        #expect(f.workspace.activeFileContext()?.title == "original.txt")
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.root.path).contains("original.txt"))
    }

    @Test func occupiedDestinationAndExternalChangeLeaveBothFilesUntouched() async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        let context = try await f.open("original")
        let target = f.root.appendingPathComponent("occupied.txt")
        try Data("other".utf8).write(to: target)
        #expect(await f.files.changeLocation(.move(target), expectedContext: context) == .failed(.store(.destinationExists(target.path))))
        #expect(try String(contentsOf: target, encoding: .utf8) == "other")
        let source = URL(fileURLWithPath: context.binding!.canonicalPath)
        try Data("external".utf8).write(to: source)
        let result = await f.files.changeLocation(.trash, expectedContext: context)
        guard case .failed(.store(.conflict)) = result else { Issue.record("Expected stale file conflict"); return }
        #expect(try String(contentsOf: source, encoding: .utf8) == "external")
        #expect(f.workspace.activeFileContext() == context)
    }

    @Test func trashClosesDirtyTabAndPersistsRemoval() async throws {
        let f = try Fixture(simulatedTrash: true); await f.start(); defer { f.dispose() }
        _ = try await f.open("disk bytes")
        let view = try #require(f.editor.activeScintillaView)
        view.insertCommittedText("unsaved")
        let context = try #require(f.workspace.activeFileContext())
        f.panels.confirmed = true
        await f.controller.routeFileLocationChange(renaming: nil, expectedContext: context)
        #expect(f.panels.warnedAboutUnsavedChanges == true)
        #expect(f.workspace.fileContext(tabID: context.tabID) == nil)
        #expect(f.workspace.activeFileContext()?.tabID != context.tabID)
        #expect(!FileManager.default.fileExists(atPath: context.binding!.canonicalPath))
        #expect(try String(contentsOf: f.root.appendingPathComponent("trashed.txt"), encoding: .utf8) == "disk bytes")
        #expect(await f.store.storedSession()?.tabs.contains(where: { $0.id == context.tabID }) == false)
    }

    @Test func tabContextMenuOffersFileLocationCommands() async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        let context = try await f.open()
        let menu = try #require(f.controller.tabStrip.contextMenu(for: context.tabID))
        for name in ["renameFile", "moveFile", "trashFile"] {
            #expect(menu.items.contains { $0.action == NSSelectorFromString(name) && $0.isEnabled })
        }
    }

    @Test(arguments: ["renameFile", "moveFile", "trashFile"], [false, true])
    func tabContextCommandsTargetClickedInactiveTab(command: String, split: Bool) async throws {
        let f = try Fixture(simulatedTrash: true); await f.start(); defer { f.dispose() }
        let clicked = try await f.open("clicked", name: "clicked.txt")
        let other = try await f.open("other", name: "other.txt")
        if split {
            f.controller.editorGroupWorkspace.onAction?(.splitAdjacent(clicked.tabID, .primary, .primary, .right, .move))
            for _ in 0..<100 { await Task.yield() }
            f.controller.performActivate(other.tabID)
            for _ in 0..<100 { await Task.yield() }
        }
        #expect(f.workspace.activeFileContext()?.tabID == other.tabID)
        f.panels.destination = f.root.appendingPathComponent("destination.txt")
        f.panels.confirmed = true
        let pane = try #require(f.controller.editorGroupWorkspace.pane(for: split ? .secondary : .primary))
        let menu = try #require(pane.tabStrip.contextMenu(for: clicked.tabID))
        let index = try #require(menu.items.firstIndex { $0.action == NSSelectorFromString(command) })
        #expect(menu.items[index].isEnabled)
        menu.performActionForItem(at: index)
        for _ in 0..<300 {
            if !f.controller.requiresTerminationReview { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!f.controller.requiresTerminationReview)
        #expect(f.workspace.fileContext(tabID: other.tabID) == other)
        #expect(try String(contentsOf: URL(fileURLWithPath: other.binding!.canonicalPath), encoding: .utf8) == "other")
        if command == "trashFile" {
            #expect(f.panels.confirmedURL?.path == clicked.binding?.canonicalPath)
            #expect(f.panels.warnedAboutUnsavedChanges == false)
            #expect(f.workspace.fileContext(tabID: clicked.tabID) == nil)
            #expect(!f.controller.editorGroupLayoutSnapshot.primaryTabIDs.contains(clicked.tabID))
            #expect(!f.controller.editorGroupLayoutSnapshot.secondaryTabIDs.contains(clicked.tabID))
        } else {
            #expect(f.workspace.fileContext(tabID: clicked.tabID)?.binding?.canonicalPath == f.panels.destination?.path)
            #expect(try String(contentsOf: f.panels.destination!, encoding: .utf8) == "clicked")
        }
    }

    @Test func trashClosesAllClonedViewsOfTheFile() async throws {
        let f = try Fixture(simulatedTrash: true); await f.start(); defer { f.dispose() }
        let context = try await f.open("cloned")
        f.controller.editorGroupWorkspace.onAction?(.splitAdjacent(context.tabID, .primary, .primary, .right, .copy))
        for _ in 0..<100 { await Task.yield() }
        #expect(f.controller.editorGroupLayoutSnapshot.primaryTabIDs.contains(context.tabID))
        #expect(f.controller.editorGroupLayoutSnapshot.secondaryTabIDs.contains(context.tabID))
        #expect(await f.files.changeLocation(.trash, expectedContext: context) == .saved(context.tabID))
        #expect(f.workspace.fileContext(tabID: context.tabID) == nil)
        #expect(!f.controller.editorGroupLayoutSnapshot.primaryTabIDs.contains(context.tabID))
        #expect(!f.controller.editorGroupLayoutSnapshot.secondaryTabIDs.contains(context.tabID))
    }

    @Test func trashClosesReadOnlyBinaryTab() async throws {
        let f = try Fixture(simulatedTrash: true); await f.start(); defer { f.dispose() }
        let context = try await f.open("\0\0binary", name: "binary.bin")
        #expect(context.binding?.isReadOnly == true)
        #expect(await f.files.changeLocation(.trash, expectedContext: context) == .saved(context.tabID))
        #expect(f.workspace.fileContext(tabID: context.tabID) == nil)
        #expect(try Data(contentsOf: f.root.appendingPathComponent("trashed.txt")) == Data("\0\0binary".utf8))
    }

    @Test func trashCloseFailureRetainsUnsavedBufferWithoutOriginalFileBinding() async throws {
        let f = try Fixture(simulatedTrash: true); await f.start(); defer { f.dispose() }
        _ = try await f.open("disk")
        let view = try #require(f.editor.activeScintillaView)
        view.insertCommittedText("unsaved")
        let bytes = view.contentUTF8
        let context = try #require(f.workspace.activeFileContext())
        f.workspace.installCloseRecoveryCommitter { _ in .failed(.unavailable("injected close failure")) }
        guard case .failed(.workspace) = await f.files.changeLocation(.trash, expectedContext: context) else {
            Issue.record("Expected close persistence failure"); return
        }
        #expect(f.workspace.fileContext(tabID: context.tabID)?.binding == nil)
        #expect(f.workspace.fileContext(tabID: context.tabID)?.buffer == context.buffer)
        #expect(f.editor.activeScintillaView?.contentUTF8 == bytes)
        #expect(!FileManager.default.fileExists(atPath: context.binding!.canonicalPath))
    }

    @Test func cancelledAndStalePanelsCannotRenameOrTrashAnotherDocument() async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        let original = try await f.open("original")
        await f.controller.routeFileLocationChange(renaming: nil, expectedContext: original)
        #expect(FileManager.default.fileExists(atPath: original.binding!.canonicalPath))
        f.panels.destination = f.root.appendingPathComponent("new.txt")
        f.panels.duringPanel = { _ = await f.workspace.addScratch() }
        await f.controller.routeFileLocationChange(renaming: true, expectedContext: original)
        #expect(FileManager.default.fileExists(atPath: original.binding!.canonicalPath))
        #expect(!FileManager.default.fileExists(atPath: f.panels.destination!.path))
        #expect(f.workspace.fileContext(tabID: original.tabID) == original)
    }

    @Test func completedMoveKeepsNewBindingWhenSessionPersistenceFails() async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        let context = try await f.open("retained")
        let target = f.root.appendingPathComponent("moved.txt")
        await f.store.setFails(true)
        let result = await f.files.changeLocation(.move(target), expectedContext: context)
        guard case .failed(.workspace) = result else { Issue.record("Expected persistence failure"); return }
        #expect(f.workspace.activeFileContext()?.binding?.canonicalPath == target.path)
        #expect(!FileManager.default.fileExists(atPath: context.binding!.canonicalPath))
        #expect(try Data(contentsOf: target) == Data("retained".utf8))
        #expect(f.editor.snapshot(for: context.buffer.bufferID)?.text == "retained")
        await f.store.setFails(false)
        _ = await f.workspace.retry(.saveCurrent)
        #expect(try await f.store.storedSession()?.fileBinding(for: context.tabID)?.canonicalPath == target.path)
    }

    @Test func structuralChangesWaitForFileLocationCommit() async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        let context = try await f.open()
        var entered = false
        var release: CheckedContinuation<Void, Never>?
        let mutation = Task {
            await f.workspace.changeFileLocation(expected: context, destinationPath: nil) {
                entered = true
                await withCheckedContinuation { release = $0 }
                return nil
            }
        }
        while !entered { await Task.yield() }
        var changed = false
        let newTab = Task { _ = await f.workspace.addScratch(); changed = true }
        await Task.yield()
        #expect(!changed)
        #expect(f.workspace.activeFileContext() == context)
        release?.resume()
        #expect(await mutation.value == .saved(context.tabID))
        await newTab.value
        #expect(f.workspace.fileContext(tabID: context.tabID)?.binding == nil)
        #expect(f.editor.snapshot(for: context.buffer.bufferID)?.text == "한글 🦆\r\n")
    }

    @Test func fileMenusExposeCommandsAndDisableFileActionsForScratch() async throws {
        let f = try Fixture(); await f.start(); defer { f.dispose() }
        func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
        let menu = items(DuckpadMainMenuFactory.make(target: f.controller))
        for selector in [#selector(DuckpadWindowController.performRenameFile(_:)),
                         #selector(DuckpadWindowController.performMoveFile(_:)),
                         #selector(DuckpadWindowController.performTrashFile(_:))] {
            let item = try #require(menu.first { $0.action == selector })
            #expect(!f.controller.validateMenuItem(item))
        }
        let printItem = try #require(menu.first { $0.action == #selector(DuckpadWindowController.performPrintDocument(_:)) })
        #expect(printItem.keyEquivalent == "p")
        #expect(printItem.keyEquivalentModifierMask == [.command])
        #expect(f.controller.validateMenuItem(printItem))
        _ = try await f.open()
        let rename = try #require(menu.first { $0.action == #selector(DuckpadWindowController.performRenameFile(_:)) })
        #expect(f.controller.validateMenuItem(rename))
    }

    // NSPrintOperation runs a nested AppKit loop; isolate it from suites that
    // intentionally switch windows or prepare application termination.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DUCKPAD_PRINT_PDF_TEST"] == "1"))
    func printOperationProducesMultiplePDFPagesWithoutChangingText() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("printed.pdf")
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        let text = (0..<250).map { "Line \($0): 한글 text" }.joined(separator: "\n")
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = DocumentPrintController.makeView(text: text, width: width)
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        #expect(operation.run())
        let pdf = try #require(PDFDocument(url: url))
        #expect(pdf.pageCount > 1)
        #expect(pdf.string?.contains("Line 249") == true)
        #expect(view.string == text)
    }

    @Test func printSnapshotWrapsLongLinesAndContainsAllUnsavedUnicodeText() throws {
        let text = String(repeating: "한글 🦆 abcdefghijklmnopqrstuvwxyz ", count: 500) + "\nlast page"
        let view = DocumentPrintController.makeView(text: text, width: 400)
        #expect(view.string == text)
        #expect(view.frame.width == 400)
        #expect(view.frame.height > 1000)
        #expect(view.textColor == NSColor.black)
        #expect(!view.isEditable)
    }
}
