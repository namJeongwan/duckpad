import Foundation
import DuckpadDomain

/// An authorized registration tied to the exact signed package snapshot.
public struct LanguageServerRegistration: Codable, Equatable, Sendable {
    public let extensionID: ExtensionID
    public let packageDigest: String
    public let service: LanguageServiceContribution
    public let packageFiles: [String: Data]
    public var settingsKey: String { extensionID.rawValue + "/" + service.languageID }
    public init(extensionID: ExtensionID, packageDigest: String, service: LanguageServiceContribution, packageFiles: [String: Data]) {
        self.extensionID = extensionID; self.packageDigest = packageDigest; self.service = service; self.packageFiles = packageFiles
    }
    public func definition(serverID: String) -> LanguageServerDefinition? {
        guard let server = service.servers.first(where: { $0.id == serverID }) else { return nil }
        return .init(id: server.id, languageIDs: [service.languageID], command: server.command,
                     projectRootMarkers: service.projectRootMarkers, projectExecutableDirectories: service.projectExecutableDirectories)
    }
}
