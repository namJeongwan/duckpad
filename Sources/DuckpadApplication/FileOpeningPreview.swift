import Foundation

/// A bounded, unverified display sample. Never a document, recovery snapshot,
/// or overwrite identity; the normal complete read still establishes those.
public struct FileOpeningPreview: Sendable {
    public let text: String
    public let totalByteCount: Int

    public init(text: String, totalByteCount: Int) {
        self.text = text
        self.totalByteCount = totalByteCount
    }
}

@MainActor
public protocol FileOpeningPreviewEditorPort: EditorPort {
    func showOpeningPreview(_ preview: FileOpeningPreview, path: String)
    func dismissOpeningPreview()
}
