import Foundation

public protocol DuckpadIdentifier: Codable, Hashable, Sendable {
    var rawValue: UUID { get }
    init(rawValue: UUID)
}

public extension DuckpadIdentifier {
    init() { self.init(rawValue: UUID()) }
}

public struct DocumentID: DuckpadIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public struct BufferID: DuckpadIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public struct TabID: DuckpadIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public struct SessionID: DuckpadIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}
