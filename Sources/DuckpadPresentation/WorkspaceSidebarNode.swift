import AppKit
import DuckpadDomain
import DuckpadApplication

@MainActor
final class WorkspaceSidebarNode: NSObject {
    enum Kind { case root, directory, file }

    let rootID: WorkspaceRootID
    let relativePath: String
    let name: String
    let kind: Kind
    let isAvailable: Bool
    weak var parent: WorkspaceSidebarNode?
    var children: [WorkspaceSidebarNode]?
    var isLoading = false
    var failure: WorkspaceBrowserFailure?

    init(root: WorkspaceRoot) {
        rootID = root.id
        relativePath = ""
        name = root.displayName
        kind = .root
        isAvailable = root.isAvailable
        children = root.isAvailable ? nil : []
    }

    init(entry: WorkspaceBrowserEntry, parent: WorkspaceSidebarNode) {
        rootID = entry.rootID
        relativePath = entry.relativePath
        name = entry.name
        kind = entry.kind == .directory ? .directory : .file
        isAvailable = true
        self.parent = parent
        children = kind == .directory ? nil : []
    }

    var isExpandable: Bool { isAvailable && kind != .file }
}
