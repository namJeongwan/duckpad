import Foundation

struct DiagramFailure: Error, Sendable {
    let code: String
    let detail: String
    init(_ code: String, _ detail: String = "") { self.code = code; self.detail = String(detail.prefix(65_536)) }
}
