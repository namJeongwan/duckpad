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
        let controller = DuckpadWindowController(workspace: workspace, editorAdapter: editor,
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

    @MainActor private func findNativeContent(in view: NSView) -> NSView? {
        if view.registeredDraggedTypes.contains(.fileURL) { return view }
        return view.subviews.lazy.compactMap { findNativeContent(in: $0) }.first
    }
}

@MainActor
private final class FileDraggingInfo: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingSourceOperationMask: NSDragOperation
    let draggingLocation = NSPoint(x: 20, y: 20)
    let draggingPasteboard: NSPasteboard
    let draggedImageLocation: NSPoint = .zero
    let draggedImage: NSImage? = nil
    let draggingSource: Any? = nil
    let draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 2
    let springLoadingHighlight: NSSpringLoadingHighlight = .none

    init(window: NSWindow, pasteboard: NSPasteboard, operation: NSDragOperation) {
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
