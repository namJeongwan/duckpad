import DuckpadDomain
import Foundation

public protocol EditorConfigReading: Sendable {
    func conventions(for file: URL) async -> EditorConventions
}
