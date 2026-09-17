import DuckpadDomain
import Foundation

/// Publishes an initial text preview, then loads bounded chunks with progress.
/// The complete source remains available for recovery; input stays disabled
/// for this buffer until its native document is complete.
@MainActor
public protocol ProgressiveTextEditorPort: EditorPort {
    func prepareText(_ text: String) async throws -> @MainActor (EditorBufferDescriptor) -> Void
    func hasPendingTextLoad(for bufferID: BufferID) -> Bool
    func finishTextLoad(for buffer: EditorBufferDescriptor,
                        progress: @escaping @MainActor (Int, Int) -> Void) async throws
}
