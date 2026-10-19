import AppKit

@MainActor
final class ShortcutTableView: NSTableView {
    var onShortcutKey: ((NSEvent) -> Bool)?
    var onFocusLeft: (() -> Void)?

    // Cells are display-only. Let the table own clicks even over their label stacks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }
    override func mouseDown(with event: NSEvent) {
        if row(at: convert(event.locationInWindow, from: nil)) >= 0 {
            window?.makeFirstResponder(self)
        }
        super.mouseDown(with: event)
    }
    func routeShortcutKey(_ event: NSEvent) -> Bool {
        guard isEnabled, window?.firstResponder === self, selectedRow >= 0 else { return false }
        return onShortcutKey?(event) ?? false
    }
    override func keyDown(with event: NSEvent) {
        if !routeShortcutKey(event) { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if routeShortcutKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusLeft?() }
        return resigned
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(visibleRect, cursor: .arrow)
    }
}
