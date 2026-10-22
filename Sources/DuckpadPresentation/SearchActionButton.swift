import AppKit

@MainActor
final class SearchActionButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?
    private var hovered = false
    var isPrimary = false { didSet { refresh() } }
    override var isEnabled: Bool { didSet { synchronizeHover(); refresh(); window?.invalidateCursorRects(for: self) } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false; imagePosition = .noImage; font = .systemFont(ofSize: 13)
        setButtonType(.momentaryPushIn); wantsLayer = true
        layer?.cornerRadius = 5; layer?.borderWidth = 1
        setContentCompressionResistancePriority(.required, for: .horizontal)
        refresh()
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { .init(width: super.intrinsicContentSize.width + (controlSize == .small ? 16 : 24), height: controlSize == .small ? 24 : 32) }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
        synchronizeHover()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); synchronizeHover() }
    override func mouseEntered(with event: NSEvent) { hovered = isEnabled; refreshChrome() }
    override func mouseExited(with event: NSEvent) { hovered = false; refreshChrome() }
    override func resetCursorRects() { super.resetCursorRects(); if isEnabled { addCursorRect(visibleRect, cursor: .pointingHand) } }
    override func draw(_ dirtyRect: NSRect) {
        // AppKit's cell owns mouse/keyboard tracking and pressed state.
        refreshChrome()
        super.draw(dirtyRect)
    }
    private func synchronizeHover() {
        if isEnabled, let window, !isHiddenOrHasHiddenAncestor {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            hovered = bounds.contains(point) && visibleRect.contains(point)
        } else { hovered = false }
        refreshChrome()
    }
    private func refresh() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let foreground: NSColor = isEnabled ? (isPrimary ? .white : .labelColor) : .disabledControlTextColor
            attributedTitle = NSAttributedString(string: title, attributes: [.font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: foreground])
        }
        refreshChrome()
    }
    private func refreshChrome() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let pressed = cell?.isHighlighted == true
            let background: NSColor
            if isPrimary && isEnabled {
                let accent = NSColor.controlAccentColor
                background = pressed ? (accent.blended(withFraction: 0.18, of: .black) ?? accent)
                    : hovered ? (accent.blended(withFraction: 0.12, of: .white) ?? accent) : accent
            } else if isEnabled && (pressed || hovered) {
                background = NSColor.labelColor.withAlphaComponent(pressed ? 0.16 : 0.08)
            } else { background = .clear }
            layer?.backgroundColor = background.cgColor
            layer?.borderColor = (isPrimary && isEnabled ? NSColor.controlAccentColor
                : isEnabled && hovered ? NSColor.labelColor.withAlphaComponent(0.24) : NSColor.separatorColor).cgColor
        }
    }
    override var title: String { didSet { refresh() } }
}
