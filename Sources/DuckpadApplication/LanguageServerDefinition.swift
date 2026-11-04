/// Shared launch policy used by both the client and its authenticated helper.
/// Derived from a signed plugin declaration; the helper re-verifies its inventory.
public struct LanguageServerDefinition: Equatable, Sendable {
    public let id: String
    public let languageIDs: [String]
    public let command: [String]
    public let projectRootMarkers: [String]
    public let projectExecutableDirectories: [String]

    public init(id: String, languageIDs: [String], command: [String], projectRootMarkers: [String],
                projectExecutableDirectories: [String] = []) {
        self.id = id
        self.languageIDs = languageIDs
        self.command = command
        self.projectRootMarkers = projectRootMarkers
        self.projectExecutableDirectories = projectExecutableDirectories
    }
}
