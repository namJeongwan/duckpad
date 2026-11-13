import DuckpadApplication
import DuckpadDomain
import Foundation

/// Holds one directory response after reading it, even when its caller is cancelled.
actor RefreshGatedRootStore: WorkspaceRootStore {
    let base: any WorkspaceRootStore
    private var armed = false
    private var fails = false
    private var pending: CheckedContinuation<Void, Never>?
    var hasPendingRead: Bool { pending != nil }

    init(base: any WorkspaceRootStore, holdFirstRead: Bool = false) { self.base = base; armed = holdFirstRead }
    func arm(fails: Bool) { armed = true; self.fails = fails }
    func release() { pending?.resume(); pending = nil }

    func loadRoots() async throws(WorkspaceBrowserFailure) -> [WorkspaceRoot] { try await base.loadRoots() }
    func addRoot(_ url: URL) async throws(WorkspaceBrowserFailure) -> WorkspaceRoot { try await base.addRoot(url) }
    func removeRoot(_ id: WorkspaceRootID) async throws(WorkspaceBrowserFailure) { try await base.removeRoot(id) }
    func readFile(_ entry: WorkspaceBrowserEntry) async throws(WorkspaceBrowserFailure) -> WorkspaceFileRead { try await base.readFile(entry) }
    func updateNavigation(rootID: WorkspaceRootID, expandedRelativePaths: [String], selectedRelativePath: String?) async throws(WorkspaceBrowserFailure) -> WorkspaceRoot {
        try await base.updateNavigation(rootID: rootID, expandedRelativePaths: expandedRelativePaths, selectedRelativePath: selectedRelativePath)
    }
    func children(rootID: WorkspaceRootID, relativeDirectory: String) async throws(WorkspaceBrowserFailure) -> [WorkspaceBrowserEntry] {
        try await children(rootID: rootID, relativeDirectory: relativeDirectory, includeHiddenFiles: false)
    }
    func children(rootID: WorkspaceRootID, relativeDirectory: String, includeHiddenFiles: Bool) async throws(WorkspaceBrowserFailure) -> [WorkspaceBrowserEntry] {
        let hold = armed
        let shouldFail = fails
        if hold { armed = false }
        let entries = try await base.children(rootID: rootID, relativeDirectory: relativeDirectory, includeHiddenFiles: includeHiddenFiles)
        if hold {
            await withCheckedContinuation { pending = $0 }
            if shouldFail { throw .io("delayed directory failure") }
        }
        return entries
    }
}
