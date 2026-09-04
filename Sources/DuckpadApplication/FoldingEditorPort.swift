@MainActor
public protocol FoldingEditorPort: EditorPort {
    var supportsFolding: Bool { get }
    var canCollapseCurrentFold: Bool { get }
    var canExpandCurrentFold: Bool { get }
    var hasCollapsedFolds: Bool { get }
    var onFoldStateChange: (() -> Void)? { get set }

    @discardableResult func collapseCurrentFold() -> Bool
    @discardableResult func expandCurrentFold() -> Bool
    @discardableResult func collapseAllFolds() -> Bool
    @discardableResult func expandAllFolds() -> Bool
    func invalidate()
}
