import DuckpadDomain
import Foundation

public enum LanguageRegistryError: Error, Equatable, Sendable {
    case emptyRegistry
    case duplicateID(LanguageID)
    case invalidDefinition(LanguageID, String)
    case unknownLanguage(LanguageID)
}

public struct LanguageRegistry: Sendable {
    public let definitions: [LanguageDefinition]
    private let byID: [LanguageID: LanguageDefinition]

    public init(definitions: [LanguageDefinition]) throws(LanguageRegistryError) {
        guard !definitions.isEmpty else { throw .emptyRegistry }
        var indexed: [LanguageID: LanguageDefinition] = [:]
        var displayNames: [String: LanguageID] = [:]
        var filenames: [String: LanguageID] = [:]
        for definition in definitions {
            guard !definition.displayName.isEmpty, !definition.group.isEmpty,
                  !definition.lexerName.isEmpty else {
                throw .invalidDefinition(definition.id, "name, group, and lexer are required")
            }
            guard indexed[definition.id] == nil else { throw .duplicateID(definition.id) }
            let displayNameKey = definition.displayName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard displayNames[displayNameKey] == nil else {
                throw .invalidDefinition(definition.id, "duplicate display name: \(definition.displayName)")
            }
            displayNames[displayNameKey] = definition.id
            for raw in definition.extensions {
                let key = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                guard !key.isEmpty else { throw .invalidDefinition(definition.id, "empty extension") }
            }
            for raw in definition.filenames {
                let key = raw.lowercased()
                guard !key.isEmpty, filenames[key] == nil else {
                    throw .invalidDefinition(definition.id, "duplicate or empty filename: \(raw)")
                }
                filenames[key] = definition.id
            }
            indexed[definition.id] = definition
        }
        guard indexed[.plainText]?.lexerName == "null" else {
            throw .invalidDefinition(.plainText, "a resolvable null-lexer fallback is required")
        }
        self.definitions = definitions.sorted {
            let groupOrder = $0.group.localizedStandardCompare($1.group)
            return groupOrder == .orderedSame
                ? $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                : groupOrder == .orderedAscending
        }
        byID = indexed
    }

    public subscript(id: LanguageID) -> LanguageDefinition? { byID[id] }

    public func require(_ id: LanguageID) throws(LanguageRegistryError) -> LanguageDefinition {
        guard let definition = byID[id] else { throw .unknownLanguage(id) }
        return definition
    }
}

public struct LanguageDetector: Sendable {
    public let registry: LanguageRegistry
    public let maximumContentProbeBytes: Int

    public init(registry: LanguageRegistry, maximumContentProbeBytes: Int = 65_536) {
        self.registry = registry
        self.maximumContentProbeBytes = max(256, min(maximumContentProbeBytes, 1_048_576))
    }

    /// Deterministic precedence: manual > exact special filename > shebang >
    /// XML root > longest extension > plain text. Ties use stable LanguageID.
    public func detect(
        filename: String?,
        contentPrefix: Data,
        override: LanguageOverride = .automatic
    ) -> LanguageDetection {
        if case .manual(let id) = override {
            guard registry[id] != nil else {
                return .init(languageID: .plainText, confidence: .manual,
                             reason: "manual language unavailable: \(id.rawValue)")
            }
            return .init(languageID: id, confidence: .manual, reason: "manual override")
        }
        let ordered = registry.definitions.sorted { $0.id < $1.id }
        if let basename = filename.map({ URL(fileURLWithPath: $0).lastPathComponent }), !basename.isEmpty {
            if let definition = ordered.first(where: { definition in
                definition.filenames.contains { candidate in
                    switch definition.filenameCasePolicy {
                    case .sensitive: candidate == basename
                    case .insensitive: candidate.caseInsensitiveCompare(basename) == .orderedSame
                    }
                }
            }) {
                return .init(languageID: definition.id, confidence: .specialFilename, reason: "filename \(basename)")
            }
        }

        let prefix = normalizedPrefix(contentPrefix)
        if let interpreter = shebangInterpreter(in: prefix) {
            if let definition = ordered.first(where: { definition in
                definition.shebangTokens.contains { $0.lowercased() == interpreter }
            }) {
                return .init(languageID: definition.id, confidence: .content, reason: "shebang")
            }
        }

        if let root = xmlRootName(in: prefix),
           let definition = ordered.first(where: {
               $0.xmlRootNames.contains { $0.caseInsensitiveCompare(root) == .orderedSame }
           }) {
            return .init(languageID: definition.id, confidence: .content, reason: "XML root \(root)")
        }

        if let basename = filename.map({ URL(fileURLWithPath: $0).lastPathComponent.lowercased() }) {
            let matches = ordered.flatMap { definition in
                definition.extensions.compactMap { ext -> (LanguageDefinition, Int)? in
                    let normalized = ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    return basename.hasSuffix(".\(normalized)") ? (definition, normalized.count) : nil
                }
            }
            let longest = matches.map(\.1).max() ?? 0
            let candidates = matches.filter { $0.1 == longest }.map(\.0)
            let signatureMatches = candidates.filter { definition in
                definition.contentSignatures.contains { prefix.localizedCaseInsensitiveContains($0) }
            }
            let pool = signatureMatches.isEmpty ? candidates : signatureMatches
            if let best = pool.sorted(by: {
                $0.detectionPriority == $1.detectionPriority
                    ? $0.id < $1.id : $0.detectionPriority > $1.detectionPriority
            }).first {
                return .init(
                    languageID: best.id,
                    confidence: .extensionMatch,
                    reason: candidates.count > 1 ? "ambiguous extension resolved deterministically" : "extension",
                    candidates: candidates.map(\.id).sorted()
                )
            }
        }
        return .init(languageID: .plainText, confidence: .fallback, reason: "plain-text fallback")
    }

    private func normalizedPrefix(_ data: Data) -> String {
        var bytes = Data(data.prefix(maximumContentProbeBytes))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        while !bytes.isEmpty {
            if let decoded = String(data: bytes, encoding: .utf8) { return decoded }
            bytes.removeLast()
        }
        return ""
    }

    private func shebangInterpreter(in text: String) -> String? {
        guard text.hasPrefix("#!") else { return nil }
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r" }
        var tokens = firstLine.dropFirst(2).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return nil }
        let executable = URL(fileURLWithPath: tokens.removeFirst()).lastPathComponent.lowercased()
        guard executable == "env" else { return executable }
        while let first = tokens.first {
            if first.contains("=") && !first.hasPrefix("=") { tokens.removeFirst(); continue }
            guard first.hasPrefix("-") else { break }
            tokens.removeFirst()
            if first == "-S" || first == "--" { break }
            if first == "-u" || first == "--unset", !tokens.isEmpty { tokens.removeFirst() }
        }
        guard let command = tokens.first else { return nil }
        return URL(fileURLWithPath: command).lastPathComponent.lowercased()
    }

    private func xmlRootName(in text: String) -> String? {
        var cursor = text.startIndex
        while let open = text[cursor...].firstIndex(of: "<") {
            let next = text.index(after: open)
            guard next < text.endIndex else { return nil }
            if text[next...].hasPrefix("?") || text[next...].hasPrefix("!") {
                guard let close = text[next...].firstIndex(of: ">") else { return nil }
                cursor = text.index(after: close)
                continue
            }
            var end = next
            while end < text.endIndex {
                let scalar = text[end]
                if scalar.isWhitespace || scalar == ">" || scalar == "/" { break }
                end = text.index(after: end)
            }
            guard end > next else { return nil }
            return String(text[next..<end]).split(separator: ":").last.map(String.init)
        }
        return nil
    }
}

public struct ActiveLanguageContext: Equatable, Sendable {
    public let tabID: TabID
    public let documentID: DocumentID
    public let buffer: EditorBufferDescriptor
    public let filename: String?
    public let override: LanguageOverride
}

public enum LanguageServiceState: Equatable, Sendable {
    case ready(LanguageDetection, stylingFallback: Bool)
    /// A persisted manual choice is no longer present in the current registry.
    /// The requested ID remains in the session until the user explicitly picks
    /// Auto or another available language, while the editor uses this safe fallback.
    case unavailableManual(requestedID: LanguageID, fallback: LanguageID)
    case degraded(String)
}

@MainActor
public final class LanguageWorkspaceUseCase {
    public let registry: LanguageRegistry
    private let detector: LanguageDetector
    private let workspace: ScratchWorkspaceUseCase
    private weak var editor: (any LanguageEditorPort)?
    private let maximumStyleBytes: Int
    private let configurationIssue: String?
    private struct AppliedLanguage: Equatable {
        let configuration: EditorLanguageConfiguration
        let overBudget: Bool
    }
    private var appliedLanguageByBuffer: [BufferID: AppliedLanguage] = [:]
    private var registryValidationIssue: String?

    public private(set) var state: LanguageServiceState = .degraded("not initialized")
    public var onStateChange: ((LanguageServiceState) -> Void)?

    public init(
        registry: LanguageRegistry,
        workspace: ScratchWorkspaceUseCase,
        editor: any LanguageEditorPort,
        maximumStyleBytes: Int = 16 * 1_024 * 1_024,
        configurationIssue: String? = nil
    ) {
        self.registry = registry
        detector = LanguageDetector(registry: registry)
        self.workspace = workspace
        self.editor = editor
        self.maximumStyleBytes = max(1_024, maximumStyleBytes)
        self.configurationIssue = configurationIssue
    }

    @discardableResult
    public func validateAndRefresh() -> LanguageServiceState {
        guard validateRegistry() else { return state }
        return refreshActive()
    }

    @discardableResult
    public func validateRegistry() -> Bool {
        if let configurationIssue {
            registryValidationIssue = configurationIssue
            publish(.degraded(configurationIssue))
            return false
        }
        let unresolved = Set(registry.definitions.map(\.lexerName)).filter {
            !(editor?.supportsLexer(named: $0) ?? false)
        }.sorted()
        guard unresolved.isEmpty else {
            let issue = "Unavailable Lexilla lexer(s): \(unresolved.joined(separator: ", "))"
            registryValidationIssue = issue
            publish(.degraded(issue))
            return false
        }
        registryValidationIssue = nil
        return true
    }

    @discardableResult
    public func refreshActive() -> LanguageServiceState {
        if let issue = configurationIssue ?? registryValidationIssue { return publish(.degraded(issue)) }
        guard let context = workspace.activeLanguageContext(), let editor else {
            return publish(.degraded("No active editor buffer"))
        }
        let detection = detector.detect(
            filename: context.filename,
            contentPrefix: editor.detectionPrefix(maximumBytes: detector.maximumContentProbeBytes),
            override: context.override
        )
        guard let definition = registry[detection.languageID] else {
            return publish(.degraded("Language unavailable: \(detection.languageID.rawValue)"))
        }
        let configuration = EditorLanguageConfiguration(
            languageID: definition.id,
            lexerName: definition.lexerName,
            keywords: definition.keywordLists,
            indentation: definition.capabilities.indentation,
            folding: definition.capabilities.supportsFolding,
            braceMatching: definition.capabilities.supportsBraceMatching,
            maximumStyleBytes: maximumStyleBytes
        )
        let applied = AppliedLanguage(
            configuration: configuration,
            overBudget: editor.activeDocumentByteLength > maximumStyleBytes
        )
        if appliedLanguageByBuffer[context.buffer.bufferID] != applied {
            guard editor.applyLanguage(configuration) else {
                return publish(.degraded("Failed to activate lexer: \(definition.lexerName)"))
            }
            appliedLanguageByBuffer[context.buffer.bufferID] = applied
        }
        if case .manual(let requestedID) = context.override,
           registry[requestedID] == nil {
            return publish(.unavailableManual(
                requestedID: requestedID,
                fallback: definition.id
            ))
        }
        return publish(.ready(detection, stylingFallback: editor.isLanguageStylingFallback))
    }

    @discardableResult
    public func setOverride(_ override: LanguageOverride) async -> WorkspaceActionOutcome {
        guard let context = workspace.activeLanguageContext() else {
            return .rejected(.invalidRecoveryState("no active tab"))
        }
        if case .manual(let id) = override, registry[id] == nil {
            return .rejected(.invalidRecoveryState("unknown language \(id.rawValue)"))
        }
        let outcome = await workspace.setLanguageOverride(override, for: context.tabID)
        if case .applied = outcome { _ = refreshActive() }
        return outcome
    }

    public func applyTheme(_ palette: EditorThemePalette) { editor?.applyTheme(palette) }

    public func toggleLineComment() -> EditorEditOutcome? {
        guard case .ready(let detection, _) = state,
              let prefix = registry[detection.languageID]?.capabilities.comments.line else { return nil }
        return editor?.toggleLineComment(prefix: prefix)
    }

    @discardableResult
    private func publish(_ newState: LanguageServiceState) -> LanguageServiceState {
        state = newState
        onStateChange?(newState)
        return newState
    }
}
