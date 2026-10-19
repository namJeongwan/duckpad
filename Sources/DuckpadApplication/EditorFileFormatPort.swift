import DuckpadDomain

@MainActor
public protocol EditorFileFormatPort: EditorPort {
    var onFileFormatSavePointReached: ((EditorBufferDescriptor) -> Void)? { get set }
    func reloadFile(_ snapshot: EditorTextSnapshot, from: DocumentFileFormat, to: DocumentFileFormat)
    func changeFileFormat(from: DocumentFileFormat, to: DocumentFileFormat,
                          buffer: EditorBufferDescriptor, wasDirty: Bool) -> Bool
}
