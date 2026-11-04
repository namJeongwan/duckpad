import Foundation

/// JSON values used by declarative plugins, without exposing LSP implementation types.
public enum LanguageServiceValue: Codable, Equatable, Sendable {
    case object([String: LanguageServiceValue]), array([LanguageServiceValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode(Double.self) { self = .number(item) }
        else if let item = try? value.decode([String: Self].self) { self = .object(item) }
        else { self = .array(try value.decode([Self].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .string(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .bool(let item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }
    public func isValid(depth: Int = 0) -> Bool {
        guard depth <= 12 else { return false }
        switch self {
        case .object(let values): return values.count <= 64 && values.allSatisfy { $0.key.utf8.count <= 128 && $0.value.isValid(depth: depth + 1) }
        case .array(let values): return values.count <= 64 && values.allSatisfy { $0.isValid(depth: depth + 1) }
        case .string(let value): return value.utf8.count <= 4096 && !value.contains("\0") && (!value.contains("${") || ["${interpreter}", "${projectRoot}"].contains(value))
        case .number(let value): return value.isFinite
        case .bool, .null: return true
        }
    }
}

public struct LanguageServiceInterpreter: Codable, Equatable, Sendable {
    public let projectPaths: [String]
    public let executableNames: [String]
    public init(projectPaths: [String], executableNames: [String]) {
        self.projectPaths = projectPaths; self.executableNames = executableNames
    }
}

public struct LanguageServiceServer: Codable, Equatable, Sendable {
    public let id: String
    public let command: [String]
    public let initializationOptions: LanguageServiceValue?
    public let configuration: LanguageServiceValue?
    public let installHint: String
    public init(id: String, command: [String], initializationOptions: LanguageServiceValue? = nil,
                configuration: LanguageServiceValue? = nil, installHint: String = "") {
        self.id = id; self.command = command; self.initializationOptions = initializationOptions
        self.configuration = configuration; self.installHint = installHint
    }
}

/// A signed, optional language plugin owns all language-specific policy.
public struct LanguageServiceContribution: Codable, Equatable, Sendable {
    public let languageID: String
    public let displayName: String
    public let defaultServerID: String
    public let servers: [LanguageServiceServer]
    public let projectRootMarkers: [String]
    public let projectExecutableDirectories: [String]
    public let interpreter: LanguageServiceInterpreter?
    public init(languageID: String, displayName: String, defaultServerID: String, servers: [LanguageServiceServer],
                projectRootMarkers: [String], projectExecutableDirectories: [String] = [], interpreter: LanguageServiceInterpreter? = nil) {
        self.languageID = languageID; self.displayName = displayName; self.defaultServerID = defaultServerID
        self.servers = servers; self.projectRootMarkers = projectRootMarkers
        self.projectExecutableDirectories = projectExecutableDirectories; self.interpreter = interpreter
    }
    public static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9._+-]*$"#, options: .regularExpression) != nil
    }
    public static func validRelativePath(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && !value.hasPrefix("/") && !value.contains("\\") && !value.contains("\0")
            && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    public var isValid: Bool {
        Self.validIdentifier(languageID) && !displayName.isEmpty && displayName.utf8.count <= 128
            && !servers.isEmpty && servers.count <= 8 && Set(servers.map(\.id)).count == servers.count
            && servers.contains { $0.id == defaultServerID }
            && servers.allSatisfy { server in
                Self.validIdentifier(server.id) && server.id != "disabled" && !server.command.isEmpty && server.command.count <= 32
                    && Self.validIdentifier(server.command[0]) && server.command.allSatisfy { $0.utf8.count <= 4096 && !$0.contains("\0") }
                    && (server.configuration?.isValid() ?? true) && (server.initializationOptions?.isValid() ?? true)
                    && server.installHint.utf8.count <= 1024
            }
            && projectRootMarkers.count <= 32 && projectRootMarkers.allSatisfy(Self.validRelativePath)
            && projectExecutableDirectories.count <= 16 && projectExecutableDirectories.allSatisfy(Self.validRelativePath)
            && (interpreter.map { rule in rule.projectPaths.count <= 16 && rule.projectPaths.allSatisfy(Self.validRelativePath)
                && !rule.executableNames.isEmpty && rule.executableNames.count <= 16 && rule.executableNames.allSatisfy(Self.validIdentifier) } ?? true)
    }
}
