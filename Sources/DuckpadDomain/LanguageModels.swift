import Foundation

public struct LanguageID: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init(rawValue: String) {
        precondition(!rawValue.isEmpty, "LanguageID must not be empty")
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public static let plainText = Self(rawValue: "text")
}

public enum LanguageDetectionConfidence: Int, Codable, Sendable, Comparable {
    case fallback = 0
    case content = 1
    case extensionMatch = 2
    case specialFilename = 3
    case manual = 4

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum LanguageOverride: Codable, Equatable, Sendable {
    case automatic
    case manual(LanguageID)
}

public enum LanguageFilenameCasePolicy: String, Codable, Sendable {
    case sensitive
    case insensitive
}

public enum LanguageSupportTier: String, Codable, Sendable {
    case plain
    case structural
    case keywordComplete
}

public struct LanguageCommentSyntax: Codable, Equatable, Sendable {
    public let line: String?
    public let blockStart: String?
    public let blockEnd: String?

    public init(line: String? = nil, blockStart: String? = nil, blockEnd: String? = nil) {
        self.line = line
        self.blockStart = blockStart
        self.blockEnd = blockEnd
    }

    public var isUnambiguous: Bool { line != nil || (blockStart != nil && blockEnd != nil) }
}

public struct LanguageIndentation: Codable, Equatable, Sendable {
    public let width: Int
    public let useTabs: Bool

    public init(width: Int = 4, useTabs: Bool = false) {
        self.width = max(1, min(width, 16))
        self.useTabs = useTabs
    }
}

public struct LanguageCapabilities: Codable, Equatable, Sendable {
    public let comments: LanguageCommentSyntax
    public let indentation: LanguageIndentation
    public let supportsFolding: Bool
    public let supportsBraceMatching: Bool

    public init(
        comments: LanguageCommentSyntax = .init(),
        indentation: LanguageIndentation = .init(),
        supportsFolding: Bool = false,
        supportsBraceMatching: Bool = false
    ) {
        self.comments = comments
        self.indentation = indentation
        self.supportsFolding = supportsFolding
        self.supportsBraceMatching = supportsBraceMatching
    }
}

public struct LanguageDefinition: Codable, Equatable, Sendable, Identifiable {
    public let id: LanguageID
    public let displayName: String
    public let group: String
    public let lexerName: String
    public let supportTier: LanguageSupportTier
    public let keywordLists: [String]
    public let extensions: [String]
    public let filenames: [String]
    public let shebangTokens: [String]
    public let xmlRootNames: [String]
    public let contentSignatures: [String]
    public let detectionPriority: Int
    public let filenameCasePolicy: LanguageFilenameCasePolicy
    public let capabilities: LanguageCapabilities

    public init(
        id: LanguageID,
        displayName: String,
        group: String,
        lexerName: String,
        supportTier: LanguageSupportTier = .structural,
        keywordLists: [String] = [],
        extensions: [String] = [],
        filenames: [String] = [],
        shebangTokens: [String] = [],
        xmlRootNames: [String] = [],
        contentSignatures: [String] = [],
        detectionPriority: Int = 0,
        filenameCasePolicy: LanguageFilenameCasePolicy = .insensitive,
        capabilities: LanguageCapabilities = .init()
    ) {
        self.id = id
        self.displayName = displayName
        self.group = group
        self.lexerName = lexerName
        self.supportTier = supportTier
        self.keywordLists = keywordLists
        self.extensions = extensions
        self.filenames = filenames
        self.shebangTokens = shebangTokens
        self.xmlRootNames = xmlRootNames
        self.contentSignatures = contentSignatures
        self.detectionPriority = detectionPriority
        self.filenameCasePolicy = filenameCasePolicy
        self.capabilities = capabilities
    }
}

public struct LanguageDetection: Codable, Equatable, Sendable {
    public let languageID: LanguageID
    public let confidence: LanguageDetectionConfidence
    public let reason: String
    public let candidates: [LanguageID]

    public init(languageID: LanguageID, confidence: LanguageDetectionConfidence, reason: String, candidates: [LanguageID] = []) {
        self.languageID = languageID
        self.confidence = confidence
        self.reason = reason
        self.candidates = candidates
    }
}
