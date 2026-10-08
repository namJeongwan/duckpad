import Foundation

/// The XPC reply block is invoked exactly once, off the listener thread.
final class PlantUMLReply: @unchecked Sendable {
    let send: (Data?, String?) -> Void
    init(_ send: @escaping (Data?, String?) -> Void) { self.send = send }
}
