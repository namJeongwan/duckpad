import AppKit

@MainActor
final class TabPinButton: NSButton {
    var isPinned = false {
        didSet { if isPinned != oldValue { updateAppearance() } }
    }
    private(set) var isPointerInside = false
    private var pointerTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setButtonType(.momentaryChange)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    override var isEnabled: Bool {
        didSet { if isEnabled != oldValue { updateAppearance() } }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, let action else { return false }
        return NSApplication.shared.sendAction(action, to: target, from: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        var inside = false
        if let window, !isHiddenOrHasHiddenAncestor {
            let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            inside = bounds.contains(location) && visibleRect.contains(location)
        }
        var options: NSTrackingArea.Options = [.activeAlways, .inVisibleRect, .mouseEnteredAndExited]
        if inside { options.insert(.assumeInside) }
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTrackingArea = area
        setPointerInside(inside)
    }

    override func mouseEntered(with event: NSEvent) { setPointerInside(true) }
    override func mouseExited(with event: NSEvent) { setPointerInside(false) }

    func resetPointerState() { setPointerInside(false) }

    override func draw(_ dirtyRect: NSRect) {
        if isEnabled, isPointerInside || cell?.isHighlighted == true {
            NSColor.controlAccentColor.withAlphaComponent(cell?.isHighlighted == true ? 0.30 : 0.16).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
        super.draw(dirtyRect)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func setPointerInside(_ inside: Bool) {
        guard isPointerInside != inside else { return }
        isPointerInside = inside
        updateAppearance()
    }

    private func updateAppearance() {
        let name = isPinned ? (isPointerInside && isEnabled ? "pin.slash" : "pin.fill") : "pin"
        image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        contentTintColor = !isEnabled ? .disabledControlTextColor
            : (isPinned || isPointerInside ? .controlAccentColor : .secondaryLabelColor)
        needsDisplay = true
    }
}
