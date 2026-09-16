import AppKit
import WebKit

/// Finder file drops belong to the workspace, not WebKit navigation.
final class MarkdownPreviewWebView: WKWebView {
    private func destination(_ sender: any NSDraggingInfo) -> NSView? {
        guard sender.draggingPasteboard.types?.contains(.fileURL) == true else { return nil }
        var view = superview
        while let candidate = view {
            if candidate.registeredDraggedTypes.contains(.fileURL) { return candidate }
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
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        destination(sender)?.prepareForDragOperation(sender) ?? super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        destination(sender)?.performDragOperation(sender) ?? super.performDragOperation(sender)
    }
}
