import DuckpadDomain

@MainActor
public protocol SnippetEditorPort: EditorPort {
    var canInsertSnippet: Bool { get }
    @discardableResult func insertSnippet(_ template: String) -> Bool
    func cancelSnippet()
}
