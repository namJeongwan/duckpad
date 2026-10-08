import Foundation

public struct PlantUMLFailure: Error, Sendable {
    public let code: String
    public let detail: String
    public init(_ code: String, _ detail: String = "") { self.code = code; self.detail = detail }
}
