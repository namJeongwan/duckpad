import AppKit

@MainActor
final class WorkspaceOutlineView: NSOutlineView {
    var onPressReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onPressReturn?()
            return
        }
        super.keyDown(with: event)
    }
}
