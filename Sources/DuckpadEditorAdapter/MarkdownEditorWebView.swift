import AppKit
import WebKit

/// File and internal workspace drags belong to their registered ancestor, not WebKit navigation.
final class MarkdownEditorWebView: WKWebView {
    private func destination(_ sender: any NSDraggingInfo) -> NSView? {
        let types = sender.draggingPasteboard.types ?? []
        let internalTypes = types.filter { $0.rawValue == "com.duckpad.editor-group-tab.v1" || $0.rawValue == "com.duckpad.workspace-entry.v1" }
        let forwarded = internalTypes.isEmpty ? types.filter { $0 == .fileURL } : internalTypes
        guard !forwarded.isEmpty else { return nil }
        var view = superview
        while let candidate = view {
            if forwarded.contains(where: candidate.registeredDraggedTypes.contains) { return candidate }
            view = candidate.superview
        }
        return nil
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        destination(sender)?.draggingEntered(sender) ?? super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        destination(sender)?.draggingUpdated(sender) ?? super.draggingUpdated(sender)
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        if let sender, let target = destination(sender) { target.draggingExited(sender) }
        else { super.draggingExited(sender) }
    }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        if let sender, let target = destination(sender) { target.concludeDragOperation(sender) }
        else { super.concludeDragOperation(sender) }
    }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        destination(sender)?.prepareForDragOperation(sender) ?? super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        destination(sender)?.performDragOperation(sender) ?? super.performDragOperation(sender)
    }
}
