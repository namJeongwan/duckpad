import AppKit

/// Drawing, selection and the field editor use the same vertically centered rect.
/// Each input owns its editor so its Undo/IME state cannot leak into another input.
@MainActor
final class SearchInputCell: NSTextFieldCell {
    private let editor = SearchFieldEditor(frame: .zero)

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        editor.searchField = controlView as? NSTextField
        return editor
    }
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var drawing = super.drawingRect(forBounds: rect)
        let font = font ?? NSFont.systemFont(ofSize: 14)
        let height = min(drawing.height, ceil(font.ascender - font.descender + font.leading))
        drawing.origin.y += floor((drawing.height - height) / 2)
        drawing.size.height = height
        return drawing
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor text: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: drawingRect(forBounds: rect), in: controlView, editor: text, delegate: delegate, start: start, length: length)
    }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor text: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: drawingRect(forBounds: rect), in: controlView, editor: text, delegate: delegate, event: event)
    }
}
