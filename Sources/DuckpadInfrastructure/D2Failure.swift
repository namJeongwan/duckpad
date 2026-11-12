import Foundation

public struct D2Failure: Error, Sendable {
    public let code: String
    public let detail: String
    public init(_ code: String, _ detail: String = "") { self.code = code; self.detail = String(detail.prefix(65_536)) }
}
