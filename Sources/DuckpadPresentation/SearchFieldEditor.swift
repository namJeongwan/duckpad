import AppKit

/// AppKit does not publish every marked-text update as an ordinary edit.
/// Search needs those intermediate queries, while the IME must keep ownership of composition.
@MainActor
final class SearchFieldEditor: NSTextView {
    weak var searchField: NSTextField?

    override init(frame: NSRect, textContainer: NSTextContainer? = nil) {
        let storage = NSTextStorage(), layout = NSLayoutManager()
        let container = textContainer ?? NSTextContainer()
        if textContainer == nil {
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
        }
        super.init(frame: frame, textContainer: container)
        isFieldEditor = true; isRichText = false
        drawsBackground = false; allowsUndo = true
    }
    required init?(coder: NSCoder) { nil }

    override func setMarkedText(_ text: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let previous = string
        super.setMarkedText(text, selectedRange: selectedRange, replacementRange: replacementRange)
        // NSTextView publishes its change, but NSTextField suppresses the control's
        // delegate notification until marked text commits. Refresh only the consumer.
        if string != previous, let searchField {
            searchField.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: searchField))
        }
    }
}
