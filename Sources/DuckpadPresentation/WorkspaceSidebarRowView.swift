import AppKit

@MainActor
final class WorkspaceSidebarRowView: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? super.interiorBackgroundStyle : .normal
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            super.drawSelection(in: dirtyRect)
            return
        }
        WorkspaceColors.selection.withAlphaComponent(isEmphasized ? 1 : 0.6).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 4, yRadius: 4).fill()
    }
}
