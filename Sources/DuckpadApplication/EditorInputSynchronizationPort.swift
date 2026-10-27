/// Flushes a web editor's ordered input queue before Save, Close or recovery
/// captures use the synchronous document ports.
@MainActor
public protocol EditorInputSynchronizationPort: EditorPort {
    func synchronizePendingInput() async -> Bool
}
