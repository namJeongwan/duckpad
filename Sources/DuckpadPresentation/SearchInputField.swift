import AppKit

/// Search inputs share typography, centered text/editor geometry and flat focus chrome.
@MainActor
final class SearchInputField: NSTextField {
    static let preferredHeight: CGFloat = 28
    private let showsUnderline: Bool
    private var hoverTrackingArea: NSTrackingArea?
    private var hovered = false
    var showsInteractionChrome = true { didSet { needsDisplay = true } }

    init(fontSize: CGFloat = 14, showsUnderline: Bool = false) {
        self.showsUnderline = showsUnderline
        super.init(frame: .zero)
        cell = SearchInputCell(textCell: "")
        font = .systemFont(ofSize: fontSize)
        isEditable = true; isSelectable = true; usesSingleLineMode = true
        // usesSingleLineMode only affects cell drawing. Scrolling also tells
        // AppKit's field editor to grow horizontally instead of wrapping.
        cell?.wraps = false; cell?.isScrollable = true; lineBreakMode = .byClipping
        isBordered = false; isBezeled = false; drawsBackground = false; focusRingType = .none
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        if !isBezeled { size.height = Self.preferredHeight }
        return size
    }
    override var isEnabled: Bool { didSet { synchronizeHover() } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
        synchronizeHover()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); synchronizeHover() }
    override func mouseEntered(with event: NSEvent) { hovered = isEnabled; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    private func synchronizeHover() {
        if isEnabled, let window, !isHiddenOrHasHiddenAncestor {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            hovered = bounds.contains(point) && visibleRect.contains(point)
        } else { hovered = false }
        needsDisplay = true
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func textDidBeginEditing(_ notification: Notification) { super.textDidBeginEditing(notification); needsDisplay = true }
    override func textDidEndEditing(_ notification: Notification) { super.textDidEndEditing(notification); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let focused = isEnabled && currentEditor() != nil && window?.isKeyWindow == true
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        if showsInteractionChrome && isEnabled && hovered {
            NSColor.labelColor.withAlphaComponent(0.045).setFill(); outline.fill()
        }
        super.draw(dirtyRect)
        if showsInteractionChrome && isEnabled && (hovered || focused) {
            NSColor.labelColor.withAlphaComponent(focused ? 0.28 : 0.16).setStroke()
            outline.lineWidth = 1
            outline.stroke()
        }
        guard showsUnderline else { return }
        (focused ? NSColor.labelColor.withAlphaComponent(0.28) : NSColor.separatorColor).setFill()
        NSRect(x: 0, y: isFlipped ? bounds.height - 1 : 0, width: bounds.width, height: 1).fill()
    }
}
