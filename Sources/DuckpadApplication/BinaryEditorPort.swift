import DuckpadDomain
import Foundation

/// Installs initial read-only bytes, then appends the remainder with progress.
@MainActor
public protocol BinaryEditorPort: EditorPort {
    func prepareBinary(_ data: Data) async throws -> @MainActor (EditorBufferDescriptor) -> Void
    func finishBinaryLoad(for buffer: EditorBufferDescriptor, progress: @escaping @MainActor (Int, Int) -> Void) async throws
    func hasBinaryContent(for bufferID: BufferID) -> Bool
}
