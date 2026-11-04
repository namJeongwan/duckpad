import Foundation
import DuckpadDomain

/// Resolved by the helper, which can inspect project ancestors outside the sandbox.
public struct LanguageServerLaunchContext: Codable, Equatable, Sendable {
    public let workspaceID: SessionID
    public let folderID: String?
    public let settingsKey: String
    public let rootPath: String
    public let serverID: String
    public let interpreterPath: String?
    public init(rootPath: String, serverID: String, interpreterPath: String? = nil, settingsKey: String, workspaceID: SessionID = SessionID(), folderID: String? = nil) {
        self.workspaceID = workspaceID; self.folderID = folderID
        self.settingsKey = settingsKey
        self.rootPath = rootPath; self.serverID = serverID; self.interpreterPath = interpreterPath
    }
    public var root: URL { URL(fileURLWithPath: rootPath) }
}
