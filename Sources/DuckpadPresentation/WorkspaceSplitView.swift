import AppKit

/// A quiet vertical workspace divider with a forgiving drag target.
@MainActor
final class WorkspaceSplitView: NSSplitView, NSSplitViewDelegate {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var dividerColor: NSColor {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? super.dividerColor : WorkspaceColors.border
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                   forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        proposedEffectiveRect.insetBy(dx: -3, dy: 0)
    }
}
