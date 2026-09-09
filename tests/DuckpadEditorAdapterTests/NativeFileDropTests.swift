import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
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
