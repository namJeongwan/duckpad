import Foundation
import DuckpadApplication

/// Targets are resolved from the clicked tab, not the currently selected tab.
enum TerminalSessionCloseScope: String, CaseIterable {
    case current, left, right, others, all

    var titleKey: String {
        switch self {
        case .current: "Close Terminal Session"
        case .left: "Close Tabs to Left"
        case .right: "Close Tabs to Right"
        case .others: "Close Other Tabs"
        case .all: "Close All Tabs"
        }
    }

    @MainActor func targets(in sessions: [TerminalSessionStore.Session], relativeTo id: UUID?) -> [UUID] {
        if self == .all { return sessions.map(\.id) }
        guard let id, let index = sessions.firstIndex(where: { $0.id == id }) else { return [] }
        switch self {
        case .current: return [id]
        case .left: return sessions.prefix(index).map(\.id)
        case .right: return sessions.dropFirst(index + 1).map(\.id)
        case .others: return sessions.filter { $0.id != id }.map(\.id)
        case .all: return sessions.map(\.id)
        }
    }
}
