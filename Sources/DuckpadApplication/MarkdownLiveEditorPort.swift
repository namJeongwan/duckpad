import Foundation

/// Markdown presentation is view metadata. Source bytes and the native undo
/// history remain owned by the editor when switching modes.
@MainActor
public protocol MarkdownLiveEditorPort: EditorPort {
    var onOpenMarkdownLink: ((URL) -> Void)? { get set }
    var canUseMarkdownLiveEditing: Bool { get }
    var isMarkdownLiveEditingEnabled: Bool { get }
    func setMarkdownLiveEditingEnabled(_ enabled: Bool)
    func setMarkdownDocumentURL(_ url: URL?)
    func refreshMarkdownImageAccess()
}
