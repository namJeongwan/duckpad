import AppKit

/// Retains the classic Find field's native search chrome and live IME queries.
@MainActor
final class SearchFindCell: NSSearchFieldCell {
    private let editor = SearchFieldEditor(frame: .zero)
    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        editor.searchField = controlView as? NSTextField
        return editor
    }
}
