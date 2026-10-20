import AppKit

/// Explicit toggle semantics for mouse, keyboard and accessibility activation.
@MainActor
final class SearchOptionButton: NSButton {
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var pressed = false
    var isOn = false { didSet { needsDisplay = true } }
    var onToggle: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // AppKit's momentary cell never changes state behind the action handler.
        setButtonType(.momentaryChange)
        isBordered = false; imagePosition = .noImage; focusRingType = .none
        font = .systemFont(ofSize: 14)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityRole(.checkBox)
        target = self; action = #selector(activateToggle)
    }
    required init?(coder: NSCoder) { nil }
    override var isEnabled: Bool { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    override var intrinsicContentSize: NSSize { .init(width: max(32, super.intrinsicContentSize.width + 12), height: 28) }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func performClick(_ sender: Any?) { activateToggle() }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        activateToggle(); return true
    }
    override func accessibilityValue() -> Any? { NSNumber(value: isOn) }
    @objc private func activateToggle() {
        guard isEnabled else { return }
        isOn.toggle(); onToggle?(isOn)
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty && [36, 49, 76].contains(event.keyCode) { performClick(nil) }
        else { super.keyDown(with: event) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func highlight(_ flag: Bool) { pressed = flag; needsDisplay = true }
    override func resetCursorRects() { super.resetCursorRects(); if isEnabled { addCursorRect(visibleRect, cursor: .pointingHand) } }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let background: NSColor
        if isOn { background = NSColor.controlAccentColor.withAlphaComponent(isEnabled ? 0.65 : 0.2) }
        else if isEnabled && pressed { background = NSColor.controlAccentColor.withAlphaComponent(0.3) }
        else if isEnabled && hovered { background = NSColor.labelColor.withAlphaComponent(0.1) }
        else { background = .clear }
        background.setFill(); NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        let foreground: NSColor = !isEnabled ? .disabledControlTextColor : isOn ? .white : .labelColor
        let text = NSAttributedString(string: title, attributes: [.font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: foreground])
        let size = text.size()
        text.draw(at: .init(x: floor(bounds.midX - size.width / 2), y: floor(bounds.midY - size.height / 2)))
        if window?.firstResponder === self {
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5); outline.lineWidth = 1; outline.stroke()
        }
    }
}
