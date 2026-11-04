// Adapted from CodeEditSourceEditor/CodeSuggestion/TableView/CodeSuggestionRowView.swift.
// Copyright (c) 2022 CodeEdit. MIT license; see LICENSE.md.
import AppKit

final class CodeSuggestionRowView: NSTableRowView {
    var selectionColor: NSColor = .selectedTextBackgroundColor
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        // Use the full row bounds: dirtyRect clips selection during arrow-key scrolling.
        let selectionRect = bounds.insetBy(dx: 3, dy: 0)
        let path = NSBezierPath(roundedRect: selectionRect, xRadius: 3, yRadius: 3)
        context.setFillColor(selectionColor.cgColor)
        path.fill()
    }
}
