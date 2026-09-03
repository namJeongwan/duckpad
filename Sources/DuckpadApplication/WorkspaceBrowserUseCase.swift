import DuckpadDomain
import Foundation

public enum WorkspaceEntryKind: String, Codable, Equatable, Sendable {
    case directory
    case file
}

public struct WorkspaceBrowserEntry: Codable, Equatable, Hashable, Sendable {
    public let rootID: WorkspaceRootID
    public let relativePath: String
    public let name: String
    public let kind: WorkspaceEntryKind

    public init(rootID: WorkspaceRootID, relativePath: String, name: String, kind: WorkspaceEntryKind) {
        self.rootID = rootID
        self.relativePath = relativePath
        self.name = name
        self.kind = kind
    }
}

public struct WorkspaceFileRead: Equatable, Sendable {
    public let url: URL
    public let result: FileReadResult

    public init(url: URL, result: FileReadResult) {
        self.url = url
        self.result = result
    }
}

public struct WorkspaceRoot: Codable, Equatable, Sendable, Identifiable {
    public static let maximumRootCount = 32
    public static let maximumExpandedPathCount = 1_000

    public let id: WorkspaceRootID
    public let canonicalPath: String
    public let displayName: String
    public let isAvailable: Bool
    public let expandedRelativePaths: [String]
    public let selectedRelativePath: String?

    public init(
        id: WorkspaceRootID = WorkspaceRootID(),
        canonicalPath: String,
        displayName: String,
        isAvailable: Bool = true,
        expandedRelativePaths: [String] = [],
        selectedRelativePath: String? = nil
    ) {
        self.id = id
        self.canonicalPath = canonicalPath
        self.displayName = displayName
        self.isAvailable = isAvailable
        self.expandedRelativePaths = Array(Set(expandedRelativePaths)).sorted()
        self.selectedRelativePath = selectedRelativePath
    }
}

public enum WorkspaceBrowserFailure: Error, Equatable, Sendable, LocalizedError {
    case invalidPath(String)
    case unavailableRoot(WorkspaceRootID)
    case unknownRoot(WorkspaceRootID)
    case duplicateRoot(String)
    case rootLimitExceeded(Int)
    case entryLimitExceeded(Int)
    case permissionDenied(String)
    case fileTooLarge(actual: UInt64, limit: UInt64)
    case cancelled
    case corruptStore(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let path): "Invalid workspace path: \(path)"
        case .unavailableRoot: "This workspace folder is unavailable. Add it again to restore access."
        case .unknownRoot: "The workspace folder is no longer registered."
        case .duplicateRoot(let path): "This folder is already in the workspace: \(path)"
        case .rootLimitExceeded(let limit): "A workspace can contain up to \(limit) folders."
        case .entryLimitExceeded(let limit): "This folder contains more than \(limit) immediate items."
        case .permissionDenied(let path): "Duckpad does not have permission to access: \(path)"
        case .fileTooLarge(let actual, let limit): "The file is too large to open (\(actual) bytes; limit \(limit))."
        case .cancelled: "The workspace operation was cancelled."
        case .corruptStore: "The saved workspace list is damaged and could not be loaded."
        case .io(let message): "Workspace I/O failed: \(message)"
        }
    }
}

public protocol WorkspaceRootStore: Sendable {
    func loadRoots() async throws(WorkspaceBrowserFailure) -> [WorkspaceRoot]
    func addRoot(_ url: URL) async throws(WorkspaceBrowserFailure) -> WorkspaceRoot
    func removeRoot(_ id: WorkspaceRootID) async throws(WorkspaceBrowserFailure)
    func children(rootID: WorkspaceRootID, relativeDirectory: String) async throws(WorkspaceBrowserFailure) -> [WorkspaceBrowserEntry]
    func readFile(_ entry: WorkspaceBrowserEntry) async throws(WorkspaceBrowserFailure) -> WorkspaceFileRead
    func updateNavigation(
        rootID: WorkspaceRootID,
        expandedRelativePaths: [String],
        selectedRelativePath: String?
    ) async throws(WorkspaceBrowserFailure) -> WorkspaceRoot
}

public enum WorkspaceBrowserState: Equatable, Sendable {
    case idle
    case loading
    case ready([WorkspaceRoot])
    case failed(WorkspaceBrowserFailure)
}

@MainActor
public final class WorkspaceBrowserUseCase {
    private let store: any WorkspaceRootStore
    private var currentRoots: [WorkspaceRoot] = []
    private var mutationBusy = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var commandEpoch: UInt64 = 0
    private var commandsSuspended = false
    private var reconciliationNeeded = false
    public private(set) var state: WorkspaceBrowserState = .idle
    public private(set) var acceptsCommands = false
    public var onStateChange: ((WorkspaceBrowserState) -> Void)?

    public init(store: any WorkspaceRootStore) {
        self.store = store
    }

    @discardableResult
    public func start() async -> WorkspaceBrowserState {
        await acquireMutation()
        defer { releaseMutation() }
        let epoch = commandEpoch
        guard commandIsAuthorized(epoch) else { return state }
        publish(.loading)
        do {
            let roots = try await store.loadRoots()
            guard commandIsAuthorized(epoch) else {
                await handleInvalidatedMutation()
                return state
            }
            if roots.count > WorkspaceRoot.maximumRootCount {
                acceptsCommands = false
                publish(.failed(.rootLimitExceeded(WorkspaceRoot.maximumRootCount)))
            } else {
                currentRoots = roots
                acceptsCommands = true
                publish(.ready(roots))
            }
        } catch let failure {
            guard commandIsAuthorized(epoch) else {
                await handleInvalidatedMutation()
                return state
            }
            acceptsCommands = false
            publish(.failed(failure))
        }
        return state
    }

    @discardableResult
    public func addRoot(_ url: URL) async -> WorkspaceBrowserState {
        await acquireMutation()
        defer { releaseMutation() }
        guard !Task.isCancelled else { return state }
        guard acceptsCommands else { return state }
        let epoch = commandEpoch
        let current = currentRoots
        guard current.count < WorkspaceRoot.maximumRootCount else {
            publish(.failed(.rootLimitExceeded(WorkspaceRoot.maximumRootCount)))
            return state
        }
        do {
            let added = try await store.addRoot(url)
            guard commandIsAuthorized(epoch) else {
                await handleInvalidatedMutation()
                return state
            }
            var roots = current.filter { $0.id != added.id }
            roots.append(added)
            roots.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            currentRoots = roots
            publish(.ready(roots))
        } catch let failure {
            guard commandIsAuthorized(epoch) else {
                await handleInvalidatedMutation()
                return state
            }
            publish(.failed(failure))
        }
        return state
    }

    @discardableResult
    public func removeRoot(_ id: WorkspaceRootID) async -> WorkspaceBrowserState {
        await acquireMutation()
        defer { releaseMutation() }
        guard !Task.isCancelled else { return state }
        guard acceptsCommands else { return state }
        let epoch = commandEpoch
        let current = currentRoots
        do {
            try await store.removeRoot(id)
            guard commandIsAuthorized(epoch) else {
                await handleInvalidatedMutation()
                return state
            }
            currentRoots = current.filter { $0.id != id }
            publish(.ready(currentRoots))
        } catch let failure {
            guard commandIsAuthorized(epoch) else {
                await handleInvalidatedMutation()
                return state
            }
            publish(.failed(failure))
        }
        return state
    }

    public func children(rootID: WorkspaceRootID, relativeDirectory: String) async throws(WorkspaceBrowserFailure) -> [WorkspaceBrowserEntry] {
        guard roots.contains(where: { $0.id == rootID }) else { throw .unknownRoot(rootID) }
        return try await store.children(rootID: rootID, relativeDirectory: relativeDirectory)
    }

    public func readFile(_ entry: WorkspaceBrowserEntry) async throws(WorkspaceBrowserFailure) -> WorkspaceFileRead {
        guard entry.kind == .file, roots.contains(where: { $0.id == entry.rootID }) else {
            throw .invalidPath(entry.relativePath)
        }
        return try await store.readFile(entry)
    }

    public func updateNavigation(
        rootID: WorkspaceRootID,
        expandedRelativePaths: [String],
        selectedRelativePath: String?
    ) async {
        await acquireMutation()
        defer { releaseMutation() }
        guard !Task.isCancelled else { return }
        guard expandedRelativePaths.count <= WorkspaceRoot.maximumExpandedPathCount else { return }
        let epoch = commandEpoch
        do {
            let updated = try await store.updateNavigation(
                rootID: rootID,
                expandedRelativePaths: expandedRelativePaths,
                selectedRelativePath: selectedRelativePath
            )
            guard commandIsAuthorized(epoch) else {
                await handleInvalidatedMutation()
                return
            }
            var roots = currentRoots
            guard let index = roots.firstIndex(where: { $0.id == rootID }) else { return }
            roots[index] = updated
            currentRoots = roots
            publish(.ready(roots))
        } catch let failure {
            guard commandIsAuthorized(epoch) else {
                await handleInvalidatedMutation()
                return
            }
            publish(.failed(failure))
        }
    }

    public var roots: [WorkspaceRoot] {
        currentRoots
    }

    public func suspendCommands() {
        if !commandsSuspended {
            commandEpoch &+= 1
            reconciliationNeeded = true
        }
        commandsSuspended = true
        acceptsCommands = false
    }

    public func resumeCommandsAndReconcile() async {
        guard commandsSuspended else { return }
        commandsSuspended = false
        await acquireMutation()
        defer { releaseMutation() }
        await reconcileLocked(epoch: commandEpoch)
    }

    private func publish(_ state: WorkspaceBrowserState) {
        self.state = state
        onStateChange?(state)
    }

    private func commandIsAuthorized(_ epoch: UInt64) -> Bool {
        !Task.isCancelled && !commandsSuspended && epoch == commandEpoch
    }

    private func handleInvalidatedMutation() async {
        reconciliationNeeded = true
        if !commandsSuspended {
            Task { @MainActor [weak self] in
                await self?.reconcileIfNeeded()
            }
        }
    }

    private func reconcileIfNeeded() async {
        await acquireMutation()
        defer { releaseMutation() }
        guard reconciliationNeeded, !commandsSuspended else { return }
        await reconcileLocked(epoch: commandEpoch)
    }

    private func reconcileLocked(epoch: UInt64) async {
        do {
            let roots = try await store.loadRoots()
            guard !commandsSuspended, epoch == commandEpoch else {
                reconciliationNeeded = true
                return
            }
            guard roots.count <= WorkspaceRoot.maximumRootCount else {
                acceptsCommands = false
                publish(.failed(.rootLimitExceeded(WorkspaceRoot.maximumRootCount)))
                return
            }
            currentRoots = roots
            reconciliationNeeded = false
            acceptsCommands = true
            publish(.ready(roots))
        } catch let failure {
            guard !commandsSuspended, epoch == commandEpoch else {
                reconciliationNeeded = true
                return
            }
            acceptsCommands = false
            publish(.failed(failure))
        }
    }

    private func acquireMutation() async {
        if !mutationBusy {
            mutationBusy = true
            return
        }
        await withCheckedContinuation { mutationWaiters.append($0) }
    }

    private func releaseMutation() {
        if mutationWaiters.isEmpty {
            mutationBusy = false
        } else {
            mutationWaiters.removeFirst().resume()
        }
    }
}
