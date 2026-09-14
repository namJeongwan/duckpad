import DuckpadDomain
import Foundation

public enum FileLocationOperation: Sendable {
    case move(URL)
    case trash
}

/// A completed filesystem change, even if acquiring a new bookmark failed.
public struct FileLocationReceipt: Sendable {
    public let identity: FileIdentity
    public init(identity: FileIdentity) { self.identity = identity }
}
