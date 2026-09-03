import DuckpadApplication
import DuckpadDomain
import Foundation

public enum LanguageManifestError: Error, Equatable, Sendable {
    case missingResource
    case invalid(String)
}

public struct LanguageManifestLoader: Sendable {
    private struct Manifest: Decodable { let version: Int; let languages: [Entry] }
    private struct Entry: Decodable {
        let id: String
        let name: String
        let group: String
        let lexer: String
        var supportTier: LanguageSupportTier = .structural
        var keywords: [String] = []
        var extensions: [String] = []
        var filenames: [String] = []
        var shebang: [String] = []
        var xmlRoots: [String] = []
        var contentSignatures: [String] = []
        var detectionPriority: Int = 0
        var caseSensitiveFilename: Bool = false
        var lineComment: String?
        var blockComment: [String]?
        var tabWidth: Int = 4
        var useTabs: Bool = false
        var fold: Bool = false
        var braces: Bool = false

        private enum CodingKeys: String, CodingKey {
            case id, name, group, lexer, supportTier, keywords, extensions, filenames, shebang, xmlRoots, contentSignatures, detectionPriority
            case caseSensitiveFilename, lineComment, blockComment, tabWidth, useTabs, fold, braces
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            group = try c.decode(String.self, forKey: .group)
            lexer = try c.decode(String.self, forKey: .lexer)
            supportTier = try c.decodeIfPresent(LanguageSupportTier.self, forKey: .supportTier) ?? .structural
            keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
            extensions = try c.decodeIfPresent([String].self, forKey: .extensions) ?? []
            filenames = try c.decodeIfPresent([String].self, forKey: .filenames) ?? []
            shebang = try c.decodeIfPresent([String].self, forKey: .shebang) ?? []
            xmlRoots = try c.decodeIfPresent([String].self, forKey: .xmlRoots) ?? []
            contentSignatures = try c.decodeIfPresent([String].self, forKey: .contentSignatures) ?? []
            detectionPriority = try c.decodeIfPresent(Int.self, forKey: .detectionPriority) ?? 0
            caseSensitiveFilename = try c.decodeIfPresent(Bool.self, forKey: .caseSensitiveFilename) ?? false
            lineComment = try c.decodeIfPresent(String.self, forKey: .lineComment)
            blockComment = try c.decodeIfPresent([String].self, forKey: .blockComment)
            tabWidth = try c.decodeIfPresent(Int.self, forKey: .tabWidth) ?? 4
            useTabs = try c.decodeIfPresent(Bool.self, forKey: .useTabs) ?? false
            fold = try c.decodeIfPresent(Bool.self, forKey: .fold) ?? false
            braces = try c.decodeIfPresent(Bool.self, forKey: .braces) ?? false
        }
    }

    public init() {}

    public func load(_ data: Data) throws(LanguageManifestError) -> LanguageRegistry {
        do {
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard manifest.version == 1, manifest.languages.count >= 60 else {
                throw LanguageManifestError.invalid("version 1 and at least 60 languages are required")
            }
            let definitions = try manifest.languages.map { entry -> LanguageDefinition in
                guard !entry.id.isEmpty, !entry.name.isEmpty, !entry.lexer.isEmpty,
                      (1...16).contains(entry.tabWidth),
                      entry.blockComment == nil || entry.blockComment?.count == 2,
                      entry.keywords.count <= 16,
                      entry.keywords.allSatisfy({ $0.utf8.count <= 32_768 }) else {
                    throw LanguageManifestError.invalid("invalid entry \(entry.id)")
                }
                return LanguageDefinition(
                    id: LanguageID(rawValue: entry.id), displayName: entry.name,
                    group: entry.group, lexerName: entry.lexer, supportTier: entry.supportTier,
                    keywordLists: entry.keywords,
                    extensions: entry.extensions, filenames: entry.filenames,
                    shebangTokens: entry.shebang, xmlRootNames: entry.xmlRoots,
                    contentSignatures: entry.contentSignatures,
                    detectionPriority: entry.detectionPriority,
                    filenameCasePolicy: entry.caseSensitiveFilename ? .sensitive : .insensitive,
                    capabilities: .init(
                        comments: .init(line: entry.lineComment,
                                        blockStart: entry.blockComment?.first,
                                        blockEnd: entry.blockComment?.last),
                        indentation: .init(width: entry.tabWidth, useTabs: entry.useTabs),
                        supportsFolding: entry.fold,
                        supportsBraceMatching: entry.braces
                    )
                )
            }
            do { return try LanguageRegistry(definitions: definitions) }
            catch { throw LanguageManifestError.invalid("registry validation failed: \(error)") }
        } catch let error as LanguageManifestError { throw error }
        catch { throw LanguageManifestError.invalid("JSON decode failed: \(error)") }
    }

    public func loadBundled() throws(LanguageManifestError) -> LanguageRegistry {
        guard let url = DuckpadInfrastructureResources.bundle.url(
            forResource: "Languages",
            withExtension: "json"
        ) else {
            throw .missingResource
        }
        do { return try load(Data(contentsOf: url)) }
        catch let error as LanguageManifestError { throw error }
        catch { throw .invalid("resource read failed: \(error)") }
    }

    public static let fallbackRegistry: LanguageRegistry = try! LanguageRegistry(definitions: [
        LanguageDefinition(id: .plainText, displayName: "Plain Text", group: "Text", lexerName: "null", supportTier: .plain)
    ])
}
