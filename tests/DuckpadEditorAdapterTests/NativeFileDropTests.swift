import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
@testable import DuckpadInfrastructure
@testable import DuckpadPresentation
import Testing

@Suite(.serialized)
struct NativeFileDropTests {
    @Test @MainActor func nativeEditorForwardsFinderFilesToWorkspaceWithoutInsertingPaths() throws {
        _ = NSApplication.shared
        let editor = ScintillaEditorAdapter()
        let buffer = EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        editor.install(.init(bufferID: buffer.bufferID, revision: 0, text: "keep this text"))
        editor.display(buffer)
        let root = FileDropView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        editor.view.frame = root.bounds
        root.addSubview(editor.view)
        let window = NSWindow(contentRect: root.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer {
            editor.invalidate()
            window.contentView = nil
            window.close()
        }
        let native = try #require(findNativeContent(in: editor.view))
        let urls = [URL(fileURLWithPath: "/tmp/drop.bin"), URL(fileURLWithPath: "/tmp/drop.unknown")]
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects(urls as [NSURL])
        // Finder/other sources can also advertise a string representation.
        pasteboard.setString(urls[0].path, forType: .string)
        var received: [[URL]] = []
        root.onFiles = { received.append($0) }
        let info = FileDraggingInfo(window: window, pasteboard: pasteboard, operation: .copy)

        #expect(native.draggingEntered(info) == .copy)
        #expect(native.draggingUpdated(info) == .copy)
        #expect(native.prepareForDragOperation(info))
        #expect(native.performDragOperation(info))
        native.concludeDragOperation(info)
        #expect(received == [urls])
        #expect(editor.activeScintillaView?.contentUTF8 == Data("keep this text".utf8))
        #expect(editor.activeScintillaView?.revision == 0)

        let moveOnly = FileDraggingInfo(window: window, pasteboard: pasteboard, operation: .move)
        #expect(native.draggingEntered(moveOnly).isEmpty)
        #expect(!native.prepareForDragOperation(moveOnly))
        #expect(!native.performDragOperation(moveOnly))
        #expect(received.count == 1)
    }

    @Test @MainActor func droppedImplicitGrantOpensAndSavesWithoutAFilePanel() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("dropped.md")
        try Data("dropped 한글".utf8).write(to: file)
        let scoped = try #require(URL(string: file.absoluteString + "?scope"))
        let store = LocalTextFileStore(bookmarkArchiveURL: folder.appendingPathComponent("grants.json"),
            testingSecurityScopedAccessRequired: true,
            testingStartSecurityScopedAccess: { $0 == scoped }, testingStopSecurityScopedAccess: { _ in },
            testingCreateSecurityScopedBookmark: { _ in Data("drop-grant".utf8) },
            testingResolveSecurityScopedBookmark: { _ in (scoped, false) })
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
        let files = FileDocumentUseCase(workspace: workspace, editor: editor, store: store)
        let controller = DuckpadWindowController(workspace: workspace, previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: TestMarkdownImageAccess(), editorAdapter: editor,
            editorView: editor.view, fileUseCase: files, automaticallyStarts: false)
        defer { controller.close(); editor.invalidate() }
        controller.start(); await controller.waitForStartup()
        let window = try #require(controller.window)
        let native = try #require(findNativeContent(in: editor.view))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.writeObjects([file as NSURL])
        let info = FileDraggingInfo(window: window, pasteboard: board, operation: .copy)
        #expect(native.performDragOperation(info))
        native.concludeDragOperation(info)
        let deadline = ContinuousClock.now + .seconds(3)
        while workspace.activeFileContext()?.binding?.canonicalPath != file.path, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let context = try #require(workspace.activeFileContext())
        #expect(context.binding?.canonicalPath == file.path)
        #expect(context.binding?.securityScopedBookmark != nil)
        #expect(editor.activeScintillaView?.contentUTF8 == Data("dropped 한글".utf8))
        editor.activeScintillaView?.selectAll()
        editor.activeScintillaView?.insertCommittedText("saved after drop")
        #expect(await files.saveActive() == .saved(context.tabID))
        #expect(try String(contentsOf: file, encoding: .utf8) == "saved after drop")
    }

    @Test @MainActor func markdownImageDropRemembersChoiceAndUndoesAsOneEdit() async throws {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
        let controller = DuckpadWindowController(workspace: workspace, previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: TestMarkdownImageAccess(), editorAdapter: editor, editorView: editor.view, automaticallyStarts: false)
        controller.start(); await controller.waitForStartup()
        defer { controller.close(); editor.invalidate() }
        let context = try #require(workspace.activeFileContext())
        _ = await workspace.setLanguageOverride(.manual(.init(rawValue: "markdown")), for: context.tabID)
        let native = try #require(findNativeContent(in: editor.view))
        let view = try #require(editor.activeScintillaView)
        view.insertCommittedText("# Document\n")
        let before = view.contentUTF8
        var asks = 0
        var remembered: [Int] = []
        controller.markdownImageDropDecision = { _ in asks += 1; return .init(action: .insert, remember: true) }
        controller.onMarkdownImageDropPreferenceChanged = { action in
            remembered.append(action)
            controller.applyPreferences(.init(markdownImageDropAction: action))
            return true
        }
        let urls = [URL(fileURLWithPath: "/tmp/duck image.png"), URL(fileURLWithPath: "/tmp/duck[2].svg")]
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.writeObjects(urls as [NSURL])
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let point = native.convert(NSPoint(x: native.bounds.midX, y: native.bounds.midY), to: nil)
        let info = FileDraggingInfo(window: controller.window!, pasteboard: board, operation: .copy, location: point)
        #expect(native.performDragOperation(info))
        for _ in 0..<100 {
            if remembered == [1] { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(asks == 1)
        #expect(remembered == [1])
        #expect(String(decoding: view.contentUTF8, as: UTF8.self).contains("![duck image](<file:///tmp/duck%20image.png>)"))
        #expect(workspace.snapshot().tabs.count == 1)
        view.undo()
        #expect(view.contentUTF8 == before)
        await controller.handleMarkdownImageDrop(urls)
        #expect(asks == 1)
        #expect(view.contentUTF8 != before)
        view.undo()
        #expect(view.contentUTF8 == before)
    }

    @Test @MainActor func cancelledAndStaleImageDropDoNotInsertOrRemember() async throws {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
        let controller = DuckpadWindowController(workspace: workspace, previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: TestMarkdownImageAccess(), editorAdapter: editor, editorView: editor.view, automaticallyStarts: false)
        controller.start(); await controller.waitForStartup()
        defer { controller.close(); editor.invalidate() }
        let context = try #require(workspace.activeFileContext())
        _ = await workspace.setLanguageOverride(.manual(.init(rawValue: "markdown")), for: context.tabID)
        let view = try #require(editor.activeScintillaView)
        var saves = 0
        controller.onMarkdownImageDropPreferenceChanged = { _ in saves += 1; return true }
        controller.markdownImageDropDecision = { _ in nil }
        await controller.handleMarkdownImageDrop([URL(fileURLWithPath: "/tmp/a.png")])
        #expect(view.contentUTF8.isEmpty)
        controller.markdownImageDropDecision = { _ in
            view.insertCommittedText("changed while choosing")
            return .init(action: .insert, remember: true)
        }
        await controller.handleMarkdownImageDrop([URL(fileURLWithPath: "/tmp/a.png")])
        #expect(view.contentUTF8 == Data("changed while choosing".utf8))
        #expect(saves == 0)
    }

    @Test @MainActor func rememberedOpenAndTabBarDropsUseNormalFileOpening() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
        let files = FileDocumentUseCase(workspace: workspace, editor: editor, store: LocalTextFileStore(bookmarkArchiveURL: root.appendingPathComponent("access.json")))
        let controller = DuckpadWindowController(workspace: workspace, previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: TestMarkdownImageAccess(), editorAdapter: editor, editorView: editor.view, fileUseCase: files, automaticallyStarts: false)
        controller.start(); await controller.waitForStartup()
        defer { controller.close(); editor.invalidate() }
        let context = try #require(workspace.activeFileContext())
        _ = await workspace.setLanguageOverride(.manual(.init(rawValue: "markdown")), for: context.tabID)
        var asks = 0
        controller.markdownImageDropDecision = { _ in asks += 1; return nil }
        controller.applyPreferences(.init(markdownImageDropAction: 2))
        let image = root.appendingPathComponent("open.svg")
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8).write(to: image)
        await controller.handleMarkdownImageDrop([image])
        for _ in 0..<100 {
            if workspace.activeFileContext()?.binding?.canonicalPath == image.resolvingSymlinksInPath().path { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(workspace.activeFileContext()?.binding?.canonicalPath == image.resolvingSymlinksInPath().path)
        #expect(asks == 0)
        _ = await workspace.activate(tabID: context.tabID)
        controller.applyPreferences(.init(markdownImageDropAction: 0))
        let second = root.appendingPathComponent("tab.svg")
        try Data("<svg/>".utf8).write(to: second)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.writeObjects([second as NSURL])
        let strip = controller.editorGroupWorkspace.primaryPane.tabStrip
        let point = strip.convert(NSPoint(x: strip.bounds.midX, y: strip.bounds.midY), to: nil)
        let drop = try #require(controller.window?.contentView as? FileDropView)
        #expect(drop.performDragOperation(FileDraggingInfo(window: controller.window!, pasteboard: board, operation: .copy, location: point)))
        for _ in 0..<100 {
            if workspace.activeFileContext()?.binding?.canonicalPath == second.resolvingSymlinksInPath().path { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(workspace.activeFileContext()?.binding?.canonicalPath == second.resolvingSymlinksInPath().path)
        #expect(asks == 0)
    }

    @Test @MainActor func previewForwardsImageDropsToWorkspaceWithLocation() throws {
        let root = FileDropView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let panel = MarkdownPreviewPanel(frame: root.bounds, resourceReader: LocalPreviewResourceReader(), imageAccess: TestMarkdownImageAccess())
        root.addSubview(panel)
        let window = NSWindow(contentRect: root.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { panel.invalidate(); window.contentView = nil; window.close() }
        let web = try #require(panel.subviews.compactMap { $0 as? MarkdownPreviewWebView }.first)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let url = URL(fileURLWithPath: "/tmp/test.svg")
        board.writeObjects([url as NSURL])
        var received: [URL] = []
        root.onFilesAtLocation = { urls, point in received = urls; #expect(point == NSPoint(x: 20, y: 20)) }
        let info = FileDraggingInfo(window: window, pasteboard: board, operation: .copy)
        #expect(web.draggingEntered(info) == .copy)
        #expect(web.performDragOperation(info))
        #expect(received == [url])
    }

    @MainActor private func findNativeContent(in view: NSView) -> NSView? {
        if view.registeredDraggedTypes.contains(.fileURL) { return view }
        return view.subviews.lazy.compactMap { findNativeContent(in: $0) }.first
    }
}

@MainActor
private final class FileDraggingInfo: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingSourceOperationMask: NSDragOperation
    let draggingLocation: NSPoint
    let draggingPasteboard: NSPasteboard
    let draggedImageLocation: NSPoint = .zero
    let draggedImage: NSImage? = nil
    let draggingSource: Any? = nil
    let draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 2
    let springLoadingHighlight: NSSpringLoadingHighlight = .none

    init(window: NSWindow, pasteboard: NSPasteboard, operation: NSDragOperation, location: NSPoint = NSPoint(x: 20, y: 20)) {
        draggingLocation = location
        draggingDestinationWindow = window
        draggingPasteboard = pasteboard
        draggingSourceOperationMask = operation
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func resetSpringLoading() {}
}
