import AppKit

/// Keeps the existing workspace above a lazily attached bottom panel. Resizing
/// the window gives extra height to the editor; dragging changes panel height.
@MainActor
final class TerminalWorkspaceSplitView: NSSplitView, NSSplitViewDelegate {
    private var preferredPanelHeight: CGFloat = 220
    private var arranging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isVertical = false
        dividerStyle = .thin
        delegate = self
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("duckpad.workspace.bottom-split")
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

    func show(_ panel: NSView) {
        guard panel.superview !== self else { return }
        addArrangedSubview(panel)
        arrange()
    }

    func hide(_ panel: NSView) {
        guard panel.superview === self else { return }
        preferredPanelHeight = panel.frame.height
        removeArrangedSubview(panel)
        panel.removeFromSuperview()
        arrange()
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) { arrange() }

    private func arrange() {
        guard !arranging, let workspace = arrangedSubviews.first else { return }
        arranging = true
        defer { arranging = false }
        guard arrangedSubviews.count == 2 else { workspace.frame = bounds; return }
        let available = max(0, bounds.height - dividerThickness)
        let panelHeight = min(max(100, preferredPanelHeight), max(0, available - minimumEditorHeight))
        workspace.frame = NSRect(x: 0, y: 0, width: bounds.width, height: available - panelHeight)
        arrangedSubviews[1].frame = NSRect(x: 0, y: available - panelHeight + dividerThickness,
                                         width: bounds.width, height: panelHeight)
    }

    private var minimumEditorHeight: CGFloat { min(140, max(0, (bounds.height - dividerThickness) * 0.5)) }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat { minimumEditorHeight }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(minimumEditorHeight, bounds.height - dividerThickness - 100)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !arranging, arrangedSubviews.count == 2 else { return }
        preferredPanelHeight = arrangedSubviews[1].frame.height
    }

    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                   forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        proposedEffectiveRect.insetBy(dx: 0, dy: -3)
    }
}
