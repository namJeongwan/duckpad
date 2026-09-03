import Foundation

public struct ExtensionID: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: any Encoder) throws { var value = encoder.singleValueContainer(); try value.encode(rawValue) }
}

public struct ExtensionCommandID: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: any Encoder) throws { var value = encoder.singleValueContainer(); try value.encode(rawValue) }
}

public struct SemanticVersion: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let major: UInt16
    public let minor: UInt16
    public let patch: UInt16

    public init(major: UInt16, minor: UInt16, patch: UInt16) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(_ value: String) {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3,
              let major = UInt16(pieces[0]), let minor = UInt16(pieces[1]),
              let patch = UInt16(pieces[2]),
              pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
    public var description: String { "\(major).\(minor).\(patch)" }
}

public struct ExtensionAPIRange: Codable, Equatable, Sendable {
    public let minimum: SemanticVersion
    public let maximumExclusive: SemanticVersion

    public init(minimum: SemanticVersion, maximumExclusive: SemanticVersion) {
        self.minimum = minimum
        self.maximumExclusive = maximumExclusive
    }

    public func contains(_ version: SemanticVersion) -> Bool {
        minimum <= version && version < maximumExclusive
    }
}

public enum ExtensionCapability: String, Codable, CaseIterable, Sendable {
    case documentsRead = "documents.read"
    case documentsWrite = "documents.write"
    case uiNotifications = "ui.notifications"
}

public enum ExtensionCapabilityScope: String, Codable, CaseIterable, Sendable {
    case selection
    case activeDocument = "active"
}

public struct ExtensionCapabilityRequest: Codable, Hashable, Sendable {
    public let id: ExtensionCapability
    public let scope: ExtensionCapabilityScope
    public init(id: ExtensionCapability, scope: ExtensionCapabilityScope) { self.id = id; self.scope = scope }
}

public struct ExtensionCommandContribution: Codable, Equatable, Sendable {
    public enum InputScope: String, Codable, Sendable { case selection, document }
    public let id: ExtensionCommandID
    public let title: String
    public let operation: UInt32
    public let inputScope: InputScope
    public init(id: ExtensionCommandID, title: String, operation: UInt32, inputScope: InputScope) {
        self.id = id; self.title = title; self.operation = operation; self.inputScope = inputScope
    }
}

public struct ExtensionKeybindingContribution: Codable, Equatable, Sendable {
    public let command: ExtensionCommandID
    public let key: String
    public init(command: ExtensionCommandID, key: String) { self.command = command; self.key = key }
}

public struct ExtensionSnippetContribution: Codable, Equatable, Sendable {
    public let language: String
    public let prefix: String
    public let body: String
    public init(language: String, prefix: String, body: String) {
        self.language = language; self.prefix = prefix; self.body = body
    }
}

public struct ExtensionThemeContribution: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public init(id: String, label: String) { self.id = id; self.label = label }
}

public struct ExtensionLanguageContribution: Codable, Equatable, Sendable {
    public let id: String
    public let extensions: [String]
    public init(id: String, extensions: [String]) { self.id = id; self.extensions = extensions }
}

public struct ExtensionContributions: Codable, Equatable, Sendable {
    public let commands: [ExtensionCommandContribution]
    public let keybindings: [ExtensionKeybindingContribution]
    public let snippets: [ExtensionSnippetContribution]
    public let themes: [ExtensionThemeContribution]
    public let languages: [ExtensionLanguageContribution]

    public init(
        commands: [ExtensionCommandContribution] = [],
        keybindings: [ExtensionKeybindingContribution] = [],
        snippets: [ExtensionSnippetContribution] = [],
        themes: [ExtensionThemeContribution] = [],
        languages: [ExtensionLanguageContribution] = []
    ) {
        self.commands = commands; self.keybindings = keybindings
        self.snippets = snippets; self.themes = themes; self.languages = languages
    }
}

public struct ExtensionRuntimeManifest: Codable, Equatable, Sendable {
    public let kind: String
    public let module: String
    public let abi: String
    public init(kind: String, module: String, abi: String) {
        self.kind = kind; self.module = module; self.abi = abi
    }
}

public struct ExtensionPublisher: Codable, Equatable, Sendable {
    public let id: String
    public let keyID: String
    public init(id: String, keyID: String) { self.id = id; self.keyID = keyID }
}

public struct ExtensionManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let id: ExtensionID
    public let name: String
    public let version: SemanticVersion
    public let api: ExtensionAPIRange
    public let publisher: ExtensionPublisher
    public let runtime: ExtensionRuntimeManifest
    public let capabilities: [ExtensionCapabilityRequest]
    public let contributes: ExtensionContributions

    public init(
        schemaVersion: Int = 1,
        id: ExtensionID,
        name: String,
        version: SemanticVersion,
        api: ExtensionAPIRange,
        publisher: ExtensionPublisher,
        runtime: ExtensionRuntimeManifest,
        capabilities: [ExtensionCapabilityRequest],
        contributes: ExtensionContributions
    ) {
        self.schemaVersion = schemaVersion; self.id = id; self.name = name
        self.version = version; self.api = api; self.publisher = publisher
        self.runtime = runtime; self.capabilities = capabilities; self.contributes = contributes
    }
}

public struct LoadedExtensionPackage: Equatable, Sendable {
    public enum TrustSource: String, Codable, Sendable { case bundled, userImported }
    public let manifest: ExtensionManifest
    public let module: Data
    public let packageDigest: String
    public let publisherFingerprint: String
    public let signatureDigest: String
    public let capabilitySchemaDigest: String
    public let trustSource: TrustSource
    public init(manifest: ExtensionManifest, module: Data, packageDigest: String, publisherFingerprint: String, signatureDigest: String, capabilitySchemaDigest: String, trustSource: TrustSource) {
        self.manifest = manifest; self.module = module
        self.packageDigest = packageDigest; self.publisherFingerprint = publisherFingerprint
        self.signatureDigest = signatureDigest; self.capabilitySchemaDigest = capabilitySchemaDigest; self.trustSource = trustSource
    }
}

public struct ExtensionGrant: Codable, Hashable, Sendable {
    public let extensionID: ExtensionID
    public let capability: ExtensionCapability
    public let scope: ExtensionCapabilityScope
    public let packageDigest: String
    public let publisherFingerprint: String
    public let version: SemanticVersion
    public let capabilitySchemaDigest: String
    public let generation: UInt64
    public init(extensionID: ExtensionID, capability: ExtensionCapability, scope: ExtensionCapabilityScope, packageDigest: String, publisherFingerprint: String, version: SemanticVersion, capabilitySchemaDigest: String, generation: UInt64) {
        self.extensionID = extensionID; self.capability = capability; self.scope = scope
        self.packageDigest = packageDigest; self.publisherFingerprint = publisherFingerprint
        self.version = version; self.capabilitySchemaDigest = capabilitySchemaDigest; self.generation = generation
    }
}

public struct ExtensionPolicySnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generation: UInt64
    public let enabled: Set<ExtensionID>
    public let grants: Set<ExtensionGrant>
    public let revokedPublisherFingerprints: Set<String>
    public let disabledPackageDigests: Set<String>
    public init(schemaVersion: Int = 1, generation: UInt64 = 0, enabled: Set<ExtensionID> = [], grants: Set<ExtensionGrant> = [], revokedPublisherFingerprints: Set<String> = [], disabledPackageDigests: Set<String> = []) {
        self.schemaVersion = schemaVersion; self.generation = generation; self.enabled = enabled
        self.grants = grants; self.revokedPublisherFingerprints = revokedPublisherFingerprints
        self.disabledPackageDigests = disabledPackageDigests
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, generation, enabled, grants, revokedPublisherFingerprints, disabledPackageDigests }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        generation = try values.decode(UInt64.self, forKey: .generation)
        enabled = try values.decode(Set<ExtensionID>.self, forKey: .enabled)
        grants = try values.decode(Set<ExtensionGrant>.self, forKey: .grants)
        revokedPublisherFingerprints = try values.decode(Set<String>.self, forKey: .revokedPublisherFingerprints)
        disabledPackageDigests = try values.decodeIfPresent(Set<String>.self, forKey: .disabledPackageDigests) ?? []
    }
}

public struct ExtensionUTF8Range: Codable, Equatable, Sendable {
    public let location: Int
    public let length: Int
    public init(location: Int, length: Int) { self.location = location; self.length = length }
}

public struct ExtensionInvocationContext: Codable, Equatable, Sendable {
    public let extensionID: ExtensionID
    public let commandID: ExtensionCommandID
    public let operation: UInt32
    public let inputScope: ExtensionCommandContribution.InputScope
    public let tabID: TabID
    public let bufferID: BufferID
    public let revision: UInt64
    public let selection: ExtensionUTF8Range
    public let utf8: Data

    public init(extensionID: ExtensionID, commandID: ExtensionCommandID, operation: UInt32, inputScope: ExtensionCommandContribution.InputScope, tabID: TabID, bufferID: BufferID, revision: UInt64, selection: ExtensionUTF8Range, utf8: Data) {
        self.extensionID = extensionID; self.commandID = commandID; self.operation = operation
        self.inputScope = inputScope
        self.tabID = tabID; self.bufferID = bufferID; self.revision = revision
        self.selection = selection; self.utf8 = utf8
    }
}

public struct ExtensionTextEdit: Codable, Equatable, Sendable {
    public let range: ExtensionUTF8Range
    public let replacementUTF8: Data
    public init(range: ExtensionUTF8Range, replacementUTF8: Data) {
        self.range = range; self.replacementUTF8 = replacementUTF8
    }
}

public struct ExtensionCommandResult: Codable, Equatable, Sendable {
    public let edits: [ExtensionTextEdit]
    public let status: String?
    public init(edits: [ExtensionTextEdit], status: String? = nil) {
        self.edits = edits; self.status = status
    }
}

public enum ExtensionFailure: Error, Equatable, Sendable {
    case malformedManifest(String)
    case unsupportedAPI
    case unknownCapability(String)
    case invalidPackagePath
    case untrustedPublisher
    case signatureMismatch
    case duplicateIdentifier(ExtensionID)
    case disabled(ExtensionID)
    case permissionDenied(ExtensionCapability)
    case unknownCommand(ExtensionCommandID)
    case invalidModule(String)
    case hostUnavailable(String)
    case busy
    case timedOut
    case cancelled
    case invalidResult(String)
    case staleContext
    case limitExceeded(String)
}
