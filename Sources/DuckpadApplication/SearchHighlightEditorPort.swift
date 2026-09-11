import DuckpadDomain

/// Transient search decorations, independent of selections, document edits, and recovery.
@MainActor
public protocol SearchHighlightEditorPort: EditorPort {
    func setSearchHighlights(_ result: SearchResultSet)
    func clearSearchHighlights()
}
