@MainActor
public protocol EditorCopyExportPort: EditorCommandPort {
    var canCopyAsImage: Bool { get }
    func copyAsPlainText()
    /// Returns false when the selection cannot be exported.
    func copyAsImage() -> Bool
}
