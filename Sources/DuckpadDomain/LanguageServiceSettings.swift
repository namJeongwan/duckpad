import Foundation

public struct LanguageProjectSettings: Codable, Equatable, Sendable {
    public var serverID: String?
    public var interpreterPath: String
    public init(serverID: String? = nil, interpreterPath: String = "") { self.serverID = serverID; self.interpreterPath = interpreterPath }
    public var isValid: Bool {
        (serverID.map(LanguageServiceContribution.validIdentifier) ?? true)
            && (interpreterPath.isEmpty || (interpreterPath.hasPrefix("/") && !interpreterPath.contains("\0") && interpreterPath.utf8.count <= 4096))
    }
    private enum CodingKeys: String, CodingKey { case serverID, server, interpreterPath }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        serverID = try values.decodeIfPresent(String.self, forKey: .serverID) ?? values.decodeIfPresent(String.self, forKey: .server)
        interpreterPath = try values.decodeIfPresent(String.self, forKey: .interpreterPath) ?? ""
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(serverID, forKey: .serverID); try values.encode(interpreterPath, forKey: .interpreterPath)
    }
}

public struct LanguageServiceSettings: Codable, Equatable, Sendable {
    public var serverID: String?
    public var interpreterPath: String
    /// Read-only migration seeds from the previous project-path development archive.
    /// New UI edits write only workspace/folder namespaces.
    public var projects: [String: LanguageProjectSettings]
    public var workspaces: [String: LanguageWorkspaceSettings]
    public init(serverID: String? = nil, interpreterPath: String = "", projects: [String: LanguageProjectSettings] = [:], workspaces: [String: LanguageWorkspaceSettings] = [:]) {
        self.serverID = serverID; self.interpreterPath = interpreterPath; self.projects = projects; self.workspaces = workspaces
    }
    public func server(forProject root: String, default defaultID: String) -> String { projects[root]?.serverID ?? serverID ?? defaultID }
    public func workspace(_ id: SessionID) -> LanguageWorkspaceSettings {
        workspaces[id.rawValue.uuidString] ?? .init(folders: Dictionary(uniqueKeysWithValues: projects.map { ("path:" + $0.key, $0.value) }))
    }
    /// Other workspaces never enter a launch packet or a provider's invalidation fingerprint.
    public func isolated(to id: SessionID) -> Self {
        .init(serverID: serverID, interpreterPath: interpreterPath, workspaces: [id.rawValue.uuidString: workspace(id)])
    }
    public func server(forProject root: String, workspaceID: SessionID, folder: LanguageServiceFolder?, default defaultID: String) -> String {
        let selected = workspace(workspaceID)
        return selected.folderSettings(folder, projectRoot: root).serverID ?? selected.serverID ?? serverID ?? defaultID
    }
    public var isValid: Bool {
        func path(_ value: String, optional: Bool = true) -> Bool {
            (optional && value.isEmpty) || (value.hasPrefix("/") && !value.contains("\0") && value.utf8.count <= 4096)
        }
        return (serverID.map(LanguageServiceContribution.validIdentifier) ?? true) && path(interpreterPath)
            && workspaces.count <= 64 && workspaces.allSatisfy { UUID(uuidString: $0.key) != nil && $0.value.isValid }
            && projects.count <= 64 && projects.allSatisfy { path($0.key, optional: false) && path($0.value.interpreterPath)
                && ($0.value.serverID.map(LanguageServiceContribution.validIdentifier) ?? true) }
    }
    private enum CodingKeys: String, CodingKey { case serverID, server, interpreterPath, projects, workspaces }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        serverID = try values.decodeIfPresent(String.self, forKey: .serverID) ?? values.decodeIfPresent(String.self, forKey: .server)
        interpreterPath = try values.decodeIfPresent(String.self, forKey: .interpreterPath) ?? ""
        projects = try values.decodeIfPresent([String: LanguageProjectSettings].self, forKey: .projects) ?? [:]
        workspaces = try values.decodeIfPresent([String: LanguageWorkspaceSettings].self, forKey: .workspaces) ?? [:]
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(serverID, forKey: .serverID); try values.encode(interpreterPath, forKey: .interpreterPath)
        try values.encode(projects, forKey: .projects)
        try values.encode(workspaces, forKey: .workspaces)
    }
}
