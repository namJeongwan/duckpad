import AppKit

@MainActor
final class WindowCommandMenuButton: NSPopUpButton {
    private var titleAttributes: [NSAttributedString.Key: Any] {
        [.font: font ?? NSFont.menuBarFont(ofSize: 13),
         .foregroundColor: isEnabled ? (contentTintColor ?? NSColor.labelColor) : NSColor.disabledControlTextColor]
    }

    override var intrinsicContentSize: NSSize {
        // The arrowless native cell had 6 pt of total title padding.
        NSSize(width: ceil((title as NSString).size(withAttributes: titleAttributes).width) + 6 * 1.3,
               height: 23)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Avoid the popup cell's asymmetric arrow/title insets while retaining
        // its native menu, keyboard, and accessibility behavior.
        let size = (title as NSString).size(withAttributes: titleAttributes)
        let rect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                          width: size.width, height: size.height)
        (title as NSString).draw(in: rect, withAttributes: titleAttributes)
    }

    override func mouseDown(with event: NSEvent) {
        if !presentMenu() { super.mouseDown(with: event) }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 49, modifiers.isEmpty, presentMenu() {
            return
        }
        super.keyDown(with: event)
    }

    override func performClick(_ sender: Any?) {
        if !presentMenu() { super.performClick(sender) }
    }

    override func accessibilityPerformPress() -> Bool {
        presentMenu() || super.accessibilityPerformPress()
    }

    override func accessibilityPerformShowMenu() -> Bool {
        presentMenu() || super.accessibilityPerformShowMenu()
    }

    private func presentMenu() -> Bool {
        guard isEnabled, let action else { return false }
        return NSApplication.shared.sendAction(action, to: target, from: self)
    }
}
