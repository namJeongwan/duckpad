import AppKit

/// Search inputs share typography, centered text/editor geometry and flat focus chrome.
@MainActor
final class SearchInputField: NSTextField {
    static let preferredHeight: CGFloat = 28
    private let showsUnderline: Bool

    init(fontSize: CGFloat = 14, showsUnderline: Bool = false) {
        self.showsUnderline = showsUnderline
        super.init(frame: .zero)
        cell = SearchInputCell(textCell: "")
        font = .systemFont(ofSize: fontSize)
        isEditable = true; isSelectable = true; usesSingleLineMode = true
        isBordered = false; isBezeled = false; drawsBackground = false; focusRingType = .none
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize; size.height = Self.preferredHeight; return size
    }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func textDidBeginEditing(_ notification: Notification) { super.textDidBeginEditing(notification); needsDisplay = true }
    override func textDidEndEditing(_ notification: Notification) { super.textDidEndEditing(notification); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsUnderline else { return }
        let focused = isEnabled && currentEditor() != nil && window?.isKeyWindow == true
        (focused ? NSColor.controlAccentColor.withAlphaComponent(0.7) : NSColor.separatorColor).setFill()
        NSRect(x: 0, y: isFlipped ? bounds.height - 1 : 0, width: bounds.width, height: 1).fill()
    }
}
