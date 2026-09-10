import Foundation
import DuckpadDomain

@MainActor
public protocol FileChangeMonitoring: AnyObject {
    var onChange: ((Set<String>) -> Void)? { get set }
    func watch(paths: Set<String>)
    func stop()
}

public enum LiveFileChange: Equatable, Sendable {
    case conflict
    case unavailable
}
