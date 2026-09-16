import DuckpadDomain

/// Records a successful disk save without changing text or undo history.
@MainActor
public protocol EditorSavePointPort: EditorPort {
    /// A newer edit must never be marked saved by an older asynchronous write.
    func recordSavePoint(for bufferID: BufferID, revision: UInt64)
}
