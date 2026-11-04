import DuckpadDomain

/// Cheap identity used while coalescing native input, before copying document text.
public struct DocumentCompletionInputContext: Equatable, Sendable {
    public let buffer: EditorBufferDescriptor
    public let caretUTF8: Int
    public let contextID: DocumentIntelligenceContextID
    public let languageID: LanguageID

    public init(buffer: EditorBufferDescriptor, caretUTF8: Int,
                contextID: DocumentIntelligenceContextID, languageID: LanguageID) {
        self.buffer = buffer
        self.caretUTF8 = caretUTF8
        self.contextID = contextID
        self.languageID = languageID
    }
}

@MainActor
public protocol AutomaticDocumentCompletionEditorPort: DocumentIntelligenceEditorPort {
    var completionInputContext: DocumentCompletionInputContext? { get }
    /// Committed input or deletion requests a refresh; cancellation invalidates pending work.
    var onCompletionInput: ((DocumentCompletionInput) -> Void)? { get set }
    var onCompletionEdit: ((EditorIncrementalEdit) -> Void)? { get set }
    var onCompletionRetired: ((BufferID) -> Void)? { get set }
}

public enum DocumentCompletionInput: Sendable { case cancel, insertion, deletion }
