import Foundation

/// Folder identity is stable for registered roots; path identities preserve
/// settings for standalone project folders that have not been added to the sidebar.
public struct LanguageServiceFolder: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let path: String
    public let displayName: String
    public init(id: String, path: String, displayName: String) {
        self.id = id; self.path = path; self.displayName = displayName
    }
    public static func project(_ path: String) -> Self {
        .init(id: "path:" + path, path: path, displayName: URL(fileURLWithPath: path).lastPathComponent)
    }
    public func contains(_ documentPath: String) -> Bool {
        documentPath == path || documentPath.hasPrefix(path == "/" ? "/" : path + "/")
    }
    public static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\0") && path.utf8.count <= 16_384
    }
    public static func validKey(_ key: String) -> Bool {
        UUID(uuidString: key) != nil || (key.hasPrefix("path:") && validPath(String(key.dropFirst(5))))
    }
    public var isValid: Bool {
        Self.validKey(id) && Self.validPath(path) && displayName.utf8.count <= 512 && !displayName.contains("\0")
    }
}

/// A value snapshot inside one persisted SessionID namespace.
public struct LanguageWorkspaceSettings: Codable, Equatable, Sendable {
    public var serverID: String?
    public var interpreterPath: String
    public var folders: [String: LanguageProjectSettings]
    public init(serverID: String? = nil, interpreterPath: String = "", folders: [String: LanguageProjectSettings] = [:]) {
        self.serverID = serverID; self.interpreterPath = interpreterPath; self.folders = folders
    }
    public func folderSettings(_ folder: LanguageServiceFolder?, projectRoot: String) -> LanguageProjectSettings {
        if let folder, let direct = folders[folder.id] ?? folders["path:" + folder.path] { return direct }
        return folders["path:" + projectRoot] ?? .init()
    }
    public var isValid: Bool {
        LanguageProjectSettings(serverID: serverID, interpreterPath: interpreterPath).isValid
            && folders.count <= 64 && folders.allSatisfy { LanguageServiceFolder.validKey($0.key) && $0.value.isValid }
    }
    private enum CodingKeys: String, CodingKey { case serverID, interpreterPath, folders }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        serverID = try values.decodeIfPresent(String.self, forKey: .serverID)
        interpreterPath = try values.decodeIfPresent(String.self, forKey: .interpreterPath) ?? ""
        folders = try values.decodeIfPresent([String: LanguageProjectSettings].self, forKey: .folders) ?? [:]
    }
}
