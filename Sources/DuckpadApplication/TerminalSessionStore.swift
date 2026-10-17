import Foundation

/// In-memory, window-owned session drafts. They are intentionally independent
/// of document recovery and do not imply a connected/running shell.
@MainActor
public final class TerminalSessionStore {
    public struct Session: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let number: Int
        public let configuration: ShellLaunchConfiguration
    }

    public private(set) var sessions: [Session] = []
    public private(set) var selectedID: UUID?
    private var nextNumber = 1

    public init() {}

    public var selectedSession: Session? { sessions.first { $0.id == selectedID } }

    @discardableResult
    public func create(configuration: ShellLaunchConfiguration) -> Session? {
        let session = Session(id: UUID(), number: nextNumber, configuration: configuration)
        nextNumber += 1
        sessions.append(session)
        selectedID = session.id
        return session
    }

    public func select(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    public func remove(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions.remove(at: index)
        if selectedID == id {
            selectedID = sessions.isEmpty ? nil : sessions[min(index, sessions.count - 1)].id
        }
    }

    public func restore(_ sessions: [Session], selectedID: UUID?) {
        guard Set(sessions.map(\.id)).count == sessions.count else { return }
        self.sessions = sessions
        self.selectedID = sessions.contains { $0.id == selectedID } ? selectedID : sessions.first?.id
        nextNumber = max(nextNumber, (sessions.map(\.number).max() ?? 0) + 1)
    }

    public func removeAll() {
        sessions.removeAll()
        selectedID = nil
    }
}
