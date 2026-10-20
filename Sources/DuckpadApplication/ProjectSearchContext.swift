import Foundation

public struct ProjectSearchContext: Sendable {
    public let scope: ProjectSearchScope
    public let roots: [WorkspaceRoot]
    public let folder: URL?
    public init(scope: ProjectSearchScope, roots: [WorkspaceRoot], folder: URL?) { self.scope = scope; self.roots = roots; self.folder = folder }
}
