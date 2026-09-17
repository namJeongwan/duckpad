import AppKit

@MainActor
final class UpdateBadgeButton: NSButton {
    private var pointerTrackingArea: NSTrackingArea?
    private var isPointerInside = false

    override var isEnabled: Bool {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        if let window, !isHiddenOrHasHiddenAncestor {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            isPointerInside = bounds.contains(point) && visibleRect.contains(point)
        } else {
            isPointerInside = false
        }
        var options: NSTrackingArea.Options = [.activeAlways, .inVisibleRect, .mouseEnteredAndExited]
        if isPointerInside { options.insert(.assumeInside) }
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        pointerTrackingArea = area
        addTrackingArea(area)
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        needsDisplay = true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(visibleRect, cursor: .pointingHand) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let base = NSColor.systemBlue
        let background: NSColor
        if !isEnabled {
            background = base.withAlphaComponent(0.45)
        } else if cell?.isHighlighted == true {
            background = base.shadow(withLevel: 0.18) ?? base
        } else if isPointerInside {
            background = base.highlight(withLevel: 0.12) ?? base
        } else {
            background = base
        }
        background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        super.draw(dirtyRect)
    }
}
