import AppKit

@MainActor
final class WorkspaceOutlineView: NSOutlineView {
    var onPressReturn: (() -> Void)?
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        if let onCancel { onCancel() }
        else { super.cancelOperation(sender) }
    }

    override func expandItem(_ item: Any?) {
        withoutAnimation { super.expandItem(item) }
    }

    override func expandItem(_ item: Any?, expandChildren: Bool) {
        withoutAnimation { super.expandItem(item, expandChildren: expandChildren) }
    }

    override func collapseItem(_ item: Any?) {
        withoutAnimation { super.collapseItem(item) }
    }

    override func collapseItem(_ item: Any?, collapseChildren: Bool) {
        withoutAnimation { super.collapseItem(item, collapseChildren: collapseChildren) }
    }

    override func reloadItem(_ item: Any?) {
        withoutAnimation { super.reloadItem(item) }
    }

    override func reloadItem(_ item: Any?, reloadChildren: Bool) {
        withoutAnimation { super.reloadItem(item, reloadChildren: reloadChildren) }
    }

    private func withoutAnimation(_ update: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            update()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onPressReturn?()
            return
        }
        super.keyDown(with: event)
    }
}
