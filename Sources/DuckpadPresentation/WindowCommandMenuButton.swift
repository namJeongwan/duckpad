import AppKit

@MainActor
final class WindowCommandMenuButton: NSPopUpButton {
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
