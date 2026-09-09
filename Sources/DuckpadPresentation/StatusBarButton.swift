import AppKit

@MainActor
final class StatusBarButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovered = false
    private var isPressed = false

    override var isEnabled: Bool {
        didSet {
            updateBackground()
            window?.invalidateCursorRects(for: self)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
        synchronizeHover()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateBackground()
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        isPressed = flag
        updateBackground()
    }

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        // Native popups run synchronously; keep the source visibly engaged
        // until they close, then refresh hover from the actual pointer.
        isPressed = true
        updateBackground()
        defer { isPressed = false; synchronizeHover() }
        return super.sendAction(action, to: target)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(visibleRect, cursor: .pointingHand) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func synchronizeHover() {
        if let window, !isHiddenOrHasHiddenAncestor {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            isHovered = bounds.contains(point) && visibleRect.contains(point)
        } else {
            isHovered = false
        }
        updateBackground()
    }

    private func updateBackground() {
        wantsLayer = true
        layer?.cornerRadius = 3
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color: NSColor
            if isEnabled && isPressed {
                color = NSColor.controlAccentColor.withAlphaComponent(0.20)
            } else if isEnabled && isHovered {
                color = NSColor.labelColor.withAlphaComponent(0.10)
            } else {
                color = .clear
            }
            layer?.backgroundColor = color.cgColor
        }
    }
}
