import AppKit

@MainActor
final class CommandPaletteRowView: NSTableRowView {
    private var hoverTrackingArea: NSTrackingArea?
    private var hovered = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
        synchronizeHover()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); synchronizeHover() }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    private func synchronizeHover() {
        if let window, !isHiddenOrHasHiddenAncestor {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            hovered = bounds.contains(point) && visibleRect.contains(point)
        } else { hovered = false }
        needsDisplay = true
    }
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if hovered && !isSelected {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 0), xRadius: 6, yRadius: 6).fill()
        }
    }
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.24).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 0), xRadius: 6, yRadius: 6).fill()
    }
}
