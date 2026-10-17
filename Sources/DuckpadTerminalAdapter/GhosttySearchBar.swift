import AppKit
import DuckpadLocalization

@MainActor
final class GhosttySearchBar: NSView, NSSearchFieldDelegate {
    let field = NSSearchField()
    let count = NSTextField(labelWithString: "")
    var onQuery: ((String) -> Void)?
    var onNavigate: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        field.placeholderString = L10n.text("Search")
        field.setAccessibilityLabel(L10n.text("Terminal Search"))
        field.sendsSearchStringImmediately = true
        field.delegate = self
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let previous = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: nil)!, target: self, action: #selector(previousMatch))
        let next = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)!, target: self, action: #selector(nextMatch))
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)!, target: self, action: #selector(closeSearch))
        for (button, key) in [(previous, "Find Previous"), (next, "Find Next"), (close, "Close Find Panel")] {
            button.isBordered = false
            button.setAccessibilityLabel(L10n.text(key))
            button.toolTip = L10n.text(key)
            button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        }
        let stack = NSStackView(views: [field, count, previous, next, close])
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { nil }
    func controlTextDidChange(_ notification: Notification) { onQuery?(field.stringValue) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { onClose?(); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            onNavigate?(NSApp.currentEvent?.modifierFlags.contains(.shift) == true); return true
        }
        return false
    }
    @objc private func previousMatch() { onNavigate?(true) }
    @objc private func nextMatch() { onNavigate?(false) }
    @objc private func closeSearch() { onClose?() }
}
