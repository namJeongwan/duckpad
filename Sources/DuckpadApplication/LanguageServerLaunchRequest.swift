import Foundation
import DuckpadDomain

/// Server commands come only from the signed plugin snapshot, independently
/// verified by the helper. isValid checks shape; it does not grant authority.
public struct LanguageServerLaunchRequest: Codable, Sendable {
    public let workspaceID: SessionID
    public let folder: LanguageServiceFolder?
    public let registration: LanguageServerRegistration
    public let serverID: String
    public let documentPath: String
    public let settings: LanguageServiceSettings
    public var languageID: String { registration.service.languageID }
    public init(registration: LanguageServerRegistration, documentPath: String, serverID: String? = nil,
                settings: LanguageServiceSettings = .init(), workspaceID: SessionID = SessionID(), folder: LanguageServiceFolder? = nil) {
        self.workspaceID = workspaceID; self.folder = folder
        self.registration = registration; self.serverID = serverID ?? registration.service.defaultServerID
        self.documentPath = documentPath; self.settings = settings.isolated(to: workspaceID)
    }
    public var definition: LanguageServerDefinition? { registration.definition(serverID: serverID) }
    public var isValid: Bool {
        registration.service.isValid && definition != nil && settings.isValid
            && (folder.map { $0.isValid && $0.contains(documentPath) } ?? true)
            && settings.workspaces.keys.allSatisfy { $0 == workspaceID.rawValue.uuidString }
            && registration.packageDigest.utf8.count == 64 && registration.extensionID.rawValue.utf8.count <= 128
            && registration.packageFiles.count == 3 && registration.packageFiles.values.allSatisfy { $0.count <= 65_536 }
            && documentPath.hasPrefix("/") && documentPath.utf8.count <= 16_384 && !documentPath.contains("\0")
    }
    public var command: [String] { definition?.command ?? [] }
}
