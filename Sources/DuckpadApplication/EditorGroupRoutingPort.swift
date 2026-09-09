import DuckpadDomain

/// Routes the existing editor and its capabilities between at most four
/// window-local groups without exposing presentation or AppKit types.
@MainActor
public protocol EditorGroupRoutingPort: EditorPort {
    var activeEditorGroup: EditorGroupID { get }
    var editorGroupOrientation: EditorGroupSplitOrientation? { get }
    var hasVisibleGroups: Bool { get }
    var suspendedInternalSplitOrientation: EditorSplitOrientation? { get }
    var onEditorGroupFocus: ((EditorGroupID) -> Void)? { get set }

    func setEditorGroupOrientation(_ orientation: EditorGroupSplitOrientation?)
    func retainEditorGroups(_ groups: Set<EditorGroupID>)
    func activateEditorGroup(_ group: EditorGroupID)
    func display(_ buffer: EditorBufferDescriptor, in group: EditorGroupID)
    func assign(
        _ buffer: EditorBufferDescriptor,
        from source: EditorGroupID?,
        to destination: EditorGroupID,
        cloning: Bool
    )
}

public extension EditorGroupRoutingPort {
    func retainEditorGroups(_ groups: Set<EditorGroupID>) {}
}
