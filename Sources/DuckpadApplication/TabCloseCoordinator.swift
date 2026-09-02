import DuckpadDomain
import Foundation

public enum TabCloseBatchOutcome: Equatable, Sendable {
    case completed
    case cancelled
    case failed(PersistenceFailure)
    /// The workspace already emitted this failure with its exact retry token.
    /// Presentation must not replace that actionable event with a duplicate.
    case workspaceFailure(PersistenceFailure)
    /// A file workflow already owns the visible failure and functional retry.
    case alreadyPresented
}

public enum TabCloseSaveOutcome: Equatable, Sendable {
    case saved
    case cancelled
    case reviewStale(currentRevision: UInt64)
    case failed(PersistenceFailure)
    case workspaceFailure(PersistenceFailure)
    case alreadyPresented
}

/// Serializes single, bulk, and termination dirty-tab review. Concurrent
/// requests capture a per-TabID review version, so a click queued behind an
/// already visible prompt never presents a second prompt for the same state.
@MainActor
public final class TabCloseCoordinator {
    public typealias DecisionProvider = @MainActor (TabSnapshot, Bool) async -> CloseDecision
    public typealias SaveHandler = @MainActor (TabID, UInt64) async -> TabCloseSaveOutcome

    private let workspace: ScratchWorkspaceUseCase
    private var reviewBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var reviewVersions: [TabID: UInt64] = [:]

    public init(workspace: ScratchWorkspaceUseCase) {
        self.workspace = workspace
    }

    public func close(
        tabIDs: [TabID],
        saveAvailable: Bool,
        decision: @escaping DecisionProvider,
        save: @escaping SaveHandler
    ) async -> TabCloseBatchOutcome {
        let requested = tabIDs.map { ($0, reviewVersions[$0, default: 0]) }
        await acquireReview()
        defer { releaseReview() }
        for (tabID, requestedVersion) in requested {
            guard let tab = workspace.snapshot().tabs.first(where: { $0.id == tabID }) else { continue }
            guard reviewVersions[tabID, default: 0] == requestedVersion else { continue }
            let result = await closeOne(
                tab: tab,
                saveAvailable: saveAvailable,
                decision: decision,
                save: save
            )
            reviewVersions[tabID, default: 0] &+= 1
            switch result {
            case .completed:
                continue
            case .cancelled, .failed, .workspaceFailure, .alreadyPresented:
                return result
            }
        }
        return .completed
    }

    /// Uses the same review gate as click/Cmd-W/bulk closes. Dirty tabs saved
    /// for termination remain open; discarded tabs use the ordinary durable
    /// close transaction.
    public func reviewDirtyForTermination(
        saveAvailable: Bool,
        decision: @escaping DecisionProvider,
        save: @escaping SaveHandler
    ) async -> TabCloseBatchOutcome {
        let requestedVersions = Dictionary(uniqueKeysWithValues: workspace.snapshot().tabs.map {
            ($0.id, reviewVersions[$0.id, default: 0])
        })
        await acquireReview()
        defer { releaseReview() }
        for tab in workspace.snapshot().tabs where tab.isDirty {
            if let requestedVersion = requestedVersions[tab.id],
               reviewVersions[tab.id, default: 0] != requestedVersion {
                return .cancelled
            }
        }
        while let tab = workspace.snapshot().tabs.first(where: \.isDirty) {
            let choice = await decision(tab, saveAvailable)
            guard let current = workspace.snapshot().tabs.first(where: { $0.id == tab.id }) else {
                continue
            }
            guard current.buffer.revision == tab.buffer.revision,
                  current.isDirty == tab.isDirty else {
                continue
            }
            reviewVersions[tab.id, default: 0] &+= 1
            switch choice {
            case .cancel:
                return .cancelled
            case .save:
                guard saveAvailable else {
                    return .failed(PersistenceFailure(
                        operation: .save,
                        cause: .unavailable("tab save unavailable during termination review")
                    ))
                }
                switch await save(tab.id, tab.buffer.revision) {
                case .saved:
                    break
                case .cancelled:
                    return .cancelled
                case .reviewStale:
                    continue
                case .failed(let failure):
                    return .failed(failure)
                case .workspaceFailure(let failure):
                    return .workspaceFailure(failure)
                case .alreadyPresented:
                    return .alreadyPresented
                }
            case .discard:
                switch await workspace.close(
                    tabID: tab.id,
                    decision: .discard,
                    expectedRevision: tab.buffer.revision
                ) {
                case .closed:
                    break
                case .reviewStale:
                    continue
                case .persistenceFailed(let failure):
                    return .workspaceFailure(failure)
                default:
                    return .failed(PersistenceFailure(
                        operation: .save,
                        cause: .corrupt("dirty tab discard was not applied")
                    ))
                }
            }
        }
        return .completed
    }

    private func closeOne(
        tab: TabSnapshot,
        saveAvailable: Bool,
        decision: DecisionProvider,
        save: SaveHandler
    ) async -> TabCloseBatchOutcome {
        var reviewedTab = tab
        while true {
            switch await workspace.close(tabID: reviewedTab.id) {
            case .closed:
                return .completed
            case .requiresDecision:
                let choice = await decision(reviewedTab, saveAvailable)
                guard let current = workspace.snapshot().tabs.first(where: { $0.id == reviewedTab.id }) else {
                    return .completed
                }
                // A decision applies only to the exact revision shown. Editing
                // while a sheet is open causes a new review, never stale discard.
                guard current.buffer.revision == reviewedTab.buffer.revision,
                      current.isDirty == reviewedTab.isDirty else {
                    reviewedTab = current
                    continue
                }
                switch choice {
                case .cancel:
                    return .cancelled
                case .discard:
                    let close = await workspace.close(
                        tabID: reviewedTab.id,
                        decision: .discard,
                        expectedRevision: reviewedTab.buffer.revision
                    )
                    if case .reviewStale = close {
                        if let newest = workspace.snapshot().tabs.first(where: { $0.id == reviewedTab.id }) {
                            reviewedTab = newest
                            continue
                        }
                    }
                    return outcome(close)
                case .save:
                    guard saveAvailable else {
                        return .failed(PersistenceFailure(
                            operation: .save,
                            cause: .unavailable("tab save unavailable")
                        ))
                    }
                    switch await save(reviewedTab.id, reviewedTab.buffer.revision) {
                    case .saved:
                        break
                    case .cancelled:
                        return .cancelled
                    case .reviewStale:
                        guard let newest = workspace.snapshot().tabs.first(where: { $0.id == reviewedTab.id }) else {
                            return .completed
                        }
                        reviewedTab = newest
                        continue
                    case .failed(let failure):
                        return .failed(failure)
                    case .workspaceFailure(let failure):
                        return .workspaceFailure(failure)
                    case .alreadyPresented:
                        return .alreadyPresented
                    }
                    guard let afterSave = workspace.snapshot().tabs.first(where: { $0.id == reviewedTab.id }) else {
                        return .completed
                    }
                    if afterSave.isDirty {
                        reviewedTab = afterSave
                        continue
                    }
                    return outcome(await workspace.close(
                        tabID: reviewedTab.id,
                        expectedRevision: afterSave.buffer.revision
                    ))
                }
            case .reviewStale(let revision):
                guard let newest = workspace.snapshot().tabs.first(where: { $0.id == reviewedTab.id }) else {
                    return .completed
                }
                guard newest.buffer.revision == revision else { continue }
                reviewedTab = newest
            case .cancelled:
                return .cancelled
        case .persistenceFailed(let failure):
            return .workspaceFailure(failure)
            case .saveUnavailable:
                return .failed(PersistenceFailure(operation: .save, cause: .unavailable("tab save unavailable")))
            case .rejected(.unknownTab):
                return .completed
            case .rejected(let error):
                return .failed(PersistenceFailure(operation: .save, cause: .corrupt("tab close rejected: \(error)")))
            }
        }
    }

    private func outcome(_ outcome: CloseOutcome) -> TabCloseBatchOutcome {
        switch outcome {
        case .closed: return .completed
        case .cancelled: return .cancelled
        case .persistenceFailed(let failure): return .workspaceFailure(failure)
        case .rejected(.unknownTab): return .completed
        case .requiresDecision, .saveUnavailable, .reviewStale, .rejected:
            return .failed(PersistenceFailure(operation: .save, cause: .corrupt("tab close was not applied")))
        }
    }

    private func acquireReview() async {
        if !reviewBusy {
            reviewBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func releaseReview() {
        if waiters.isEmpty {
            reviewBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
