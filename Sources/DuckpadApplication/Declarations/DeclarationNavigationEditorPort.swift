import Foundation
import DuckpadDomain

@MainActor
public protocol DeclarationNavigationEditorPort: DocumentIntelligenceEditorPort {
    /// The clicked byte offset, without changing the selection before recording history.
    var onDeclarationRequested: ((Int) -> Void)? { get set }
    var onDeclarationHoverRequested: ((DocumentIntelligenceCapture, Int, DeclarationIndex) async -> Bool)? { get set }
    func clearDeclarationHover()
    func declarationLanguage(for buffer: EditorBufferDescriptor) -> String?
    func declarationContent(for buffer: EditorBufferDescriptor, maximumBytes: Int) -> Data?
    func declarationContextIsCurrent(_ capture: DocumentIntelligenceCapture) -> Bool
    /// Place the target near 20% of the active pane's visible text height.
    func revealDeclaration(_ range: SearchUTF8Range)
}
