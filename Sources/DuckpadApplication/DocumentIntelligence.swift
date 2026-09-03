import DuckpadDomain
import Foundation

public struct DocumentIntelligenceCapture: Equatable, Sendable {
    public let buffer: EditorBufferDescriptor
    public let utf8: Data
    public let caretUTF8: Int
    public let languageID: LanguageID
    public let contextID: DocumentIntelligenceContextID

    public init(
        buffer: EditorBufferDescriptor,
        utf8: Data,
        caretUTF8: Int,
        languageID: LanguageID,
        contextID: DocumentIntelligenceContextID
    ) {
        self.buffer = buffer
        self.utf8 = utf8
        self.caretUTF8 = caretUTF8
        self.languageID = languageID
        self.contextID = contextID
    }
}

/// Opaque identity for the exact editor pane that supplied a capture.
public struct DocumentIntelligenceContextID: Hashable, Sendable {
    private let rawValue: UUID

    public init() { rawValue = UUID() }
}

public enum DocumentSymbolKind: String, Equatable, Sendable {
    case type
    case function
    case property
    case heading
    case section
}

public struct DocumentSymbol: Equatable, Sendable, Identifiable {
    public let name: String
    public let kind: DocumentSymbolKind
    public let line: Int
    public let range: SearchUTF8Range

    public init(name: String, kind: DocumentSymbolKind, line: Int, range: SearchUTF8Range) {
        self.name = name
        self.kind = kind
        self.line = line
        self.range = range
    }

    public var id: String { "\(range.location):\(kind.rawValue):\(name)" }
}

public struct DocumentOutline: Equatable, Sendable {
    public let buffer: EditorBufferDescriptor
    public let symbols: [DocumentSymbol]

    public init(buffer: EditorBufferDescriptor, symbols: [DocumentSymbol]) {
        self.buffer = buffer
        self.symbols = symbols
    }
}

public enum DocumentCompletionOutcome: Equatable, Sendable {
    case presented(count: Int)
    case noPrefix
    case noMatches
    case overBudget(actualBytes: Int, maximumBytes: Int)
    case unavailable
    case stale
}

public enum DocumentOutlineOutcome: Equatable, Sendable {
    case ready(DocumentOutline)
    case overBudget(actualBytes: Int, maximumBytes: Int)
    case unavailable
    case stale
}

@MainActor
public protocol DocumentIntelligenceEditorPort: EditorSelectionPort {
    var activeDocumentIntelligenceBuffer: EditorBufferDescriptor? { get }
    var activeDocumentIntelligenceByteLength: Int { get }
    func captureDocumentIntelligence(maximumBytes: Int) -> DocumentIntelligenceCapture?
    @discardableResult
    func presentCompletionItems(
        _ items: [String],
        replacingPrefixByteCount: Int,
        expectedBuffer: EditorBufferDescriptor,
        expectedCaretUTF8: Int,
        expectedContextID: DocumentIntelligenceContextID
    ) -> Bool
    func cancelCompletion()
}

public enum DocumentIntelligenceAnalyzer {
    public static let maximumInputBytes = 4 * 1_024 * 1_024
    public static let maximumCompletionItems = 200
    public static let maximumSymbolItems = 500
    public static let maximumTermBytes = 256
    public static let maximumSupplementalBytes = 256 * 1_024
    public static let maximumSymbolLineBytes = 16 * 1_024

    public struct Completion: Equatable, Sendable {
        public let prefix: String
        public let prefixByteCount: Int
        public let items: [String]
    }

    private struct CompletionCandidate {
        let term: String
        let folded: String
    }

    public static func completion(
        in capture: DocumentIntelligenceCapture,
        supplementalTerms: [String] = [],
        maximumItems: Int = 200
    ) -> Completion? {
        let itemLimit = min(maximumItems, maximumCompletionItems)
        guard itemLimit > 0,
              capture.utf8.count <= maximumInputBytes,
              capture.caretUTF8 >= 0,
              capture.caretUTF8 <= capture.utf8.count,
              let text = String(data: capture.utf8, encoding: .utf8),
              let caretUTF8 = text.utf8.index(
                text.utf8.startIndex,
                offsetBy: capture.caretUTF8,
                limitedBy: text.utf8.endIndex
              ),
              let caret = String.Index(caretUTF8, within: text) else { return nil }

        var prefixStart = caret
        var prefixByteCount = 0
        while prefixStart > text.startIndex {
            let previous = text.unicodeScalars.index(before: prefixStart)
            let scalar = text.unicodeScalars[previous]
            guard isWordScalar(scalar) else { break }
            prefixByteCount += utf8Width(of: scalar)
            guard prefixByteCount <= maximumTermBytes else {
                return Completion(prefix: "oversized", prefixByteCount: 0, items: [])
            }
            prefixStart = previous
        }
        let prefix = String(text[prefixStart..<caret])
        guard !prefix.isEmpty else { return Completion(prefix: "", prefixByteCount: 0, items: []) }

        let foldedPrefix = prefix.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        var candidates: [CompletionCandidate] = []
        var retained = Set<String>()
        func retainIfCandidate(_ term: String) {
            guard term != prefix, !retained.contains(term) else { return }
            let folded = term.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard folded.hasPrefix(foldedPrefix) else { return }
            let candidate = CompletionCandidate(term: term, folded: folded)
            var lower = 0
            var upper = candidates.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if completionPrecedes(candidates[middle], candidate) { lower = middle + 1 }
                else { upper = middle }
            }
            guard candidates.count < itemLimit || lower < itemLimit else { return }
            candidates.insert(candidate, at: lower)
            retained.insert(term)
            if candidates.count > itemLimit, let removed = candidates.popLast() {
                retained.remove(removed.term)
            }
        }

        _ = forEachBoundedWord(
            in: text,
            maximumBytes: capture.utf8.count,
            retainIfCandidate
        )
        var supplementalBudget = maximumSupplementalBytes
        for source in supplementalTerms where supplementalBudget > 0 {
            let consumed = forEachBoundedWord(
                in: source,
                maximumBytes: supplementalBudget,
                retainIfCandidate
            )
            supplementalBudget -= consumed
            if consumed < source.utf8.count { break }
        }
        return Completion(
            prefix: prefix,
            prefixByteCount: prefixByteCount,
            items: candidates.map(\.term)
        )
    }

    public static func symbols(
        in capture: DocumentIntelligenceCapture,
        maximumItems: Int = 500
    ) -> [DocumentSymbol] {
        let itemLimit = min(maximumItems, maximumSymbolItems)
        guard itemLimit > 0, capture.utf8.count <= maximumInputBytes else { return [] }
        var result: [DocumentSymbol] = []
        var lineStart = 0
        var lineNumber = 1
        func appendLine(endingAt lineEnd: Int) {
            guard result.count < itemLimit,
                  lineEnd >= lineStart,
                  lineEnd - lineStart <= maximumSymbolLineBytes,
                  lineCouldContainSymbol(
                    in: capture.utf8,
                    start: lineStart,
                    end: lineEnd,
                    languageID: capture.languageID
                  ) else { return }
            let line = String(decoding: capture.utf8[lineStart..<lineEnd], as: UTF8.self)
            if let parsed = parseSymbol(line: line, languageID: capture.languageID),
               let nameRange = line.range(of: parsed.name) {
                let localOffset = line[..<nameRange.lowerBound].utf8.count
                result.append(DocumentSymbol(
                    name: parsed.name,
                    kind: parsed.kind,
                    line: lineNumber,
                    range: SearchUTF8Range(
                        location: lineStart + localOffset,
                        length: parsed.name.utf8.count
                    )
                ))
            }
        }

        var cursor = 0
        var linesUntilCancellationCheck = 1_024
        while cursor < capture.utf8.count, result.count < itemLimit {
            let byte = capture.utf8[cursor]
            guard byte == 0x0A || byte == 0x0D else {
                cursor += 1
                continue
            }
            appendLine(endingAt: cursor)
            if byte == 0x0D,
               cursor + 1 < capture.utf8.count,
               capture.utf8[cursor + 1] == 0x0A {
                cursor += 2
            } else {
                cursor += 1
            }
            lineStart = cursor
            lineNumber += 1
            linesUntilCancellationCheck -= 1
            if linesUntilCancellationCheck == 0 {
                if Task.isCancelled { break }
                linesUntilCancellationCheck = 1_024
            }
        }
        if cursor == capture.utf8.count, result.count < itemLimit {
            appendLine(endingAt: cursor)
        }
        return result
    }

    /// Rejects ordinary ASCII-only lines before allocating a String. Every
    /// syntax accepted by `parseSymbol` contains one of these byte-level cues.
    private static func lineCouldContainSymbol(
        in data: Data,
        start: Int,
        end: Int,
        languageID: LanguageID
    ) -> Bool {
        var first = start
        while first < end && isASCIISymbolWhitespace(data[first]) { first += 1 }
        guard first < end else { return false }
        let firstByte = data[first]
        if languageID.rawValue == "markdown", firstByte == 0x23 { return true }
        if languageID.rawValue == "ini", firstByte == 0x5B { return true }
        if languageID.rawValue == "json", firstByte == 0x22 { return true }
        var cursor = first
        while cursor < end {
            let byte = data[cursor]
            if isASCIISymbolWhitespace(byte) || byte == 0x28 || byte >= 0x80 { return true }
            cursor += 1
        }
        return false
    }

    private static func isASCIISymbolWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x09 || byte == 0x0B || byte == 0x0C || byte == 0x20
    }

    @discardableResult
    private static func forEachBoundedWord(
        in text: String,
        maximumBytes: Int,
        _ body: (String) -> Void
    ) -> Int {
        guard maximumBytes > 0 else { return 0 }
        var consumed = 0
        var current = String.UnicodeScalarView()
        var currentBytes = 0
        var currentOverflowed = false
        func finishCurrent() {
            if !currentOverflowed, current.count >= 2 { body(String(current)) }
            current.removeAll(keepingCapacity: true)
            currentBytes = 0
            currentOverflowed = false
        }
        for scalar in text.unicodeScalars {
            let width = utf8Width(of: scalar)
            guard consumed <= maximumBytes - width else { return consumed }
            consumed += width
            if isWordScalar(scalar) {
                guard !currentOverflowed else { continue }
                if currentBytes <= maximumTermBytes - width {
                    current.append(scalar)
                    currentBytes += width
                } else {
                    current.removeAll(keepingCapacity: true)
                    currentBytes = 0
                    currentOverflowed = true
                }
            } else {
                finishCurrent()
            }
        }
        finishCurrent()
        return consumed
    }

    private static func completionPrecedes(
        _ lhs: CompletionCandidate,
        _ rhs: CompletionCandidate
    ) -> Bool {
        lhs.folded == rhs.folded ? lhs.term < rhs.term : lhs.folded < rhs.folded
    }

    private static func utf8Width(of scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case ...0x7F: 1
        case ...0x7FF: 2
        case ...0xFFFF: 3
        default: 4
        }
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "_" { return true }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter,
             .otherLetter, .decimalNumber, .letterNumber, .otherNumber,
             .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }

    private static func parseSymbol(
        line: String,
        languageID: LanguageID
    ) -> (name: String, kind: DocumentSymbolKind)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.first == "#" {
            let hashes = trimmed.prefix(while: { $0 == "#" })
            let remainder = trimmed.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
            if !remainder.isEmpty, languageID.rawValue == "markdown", hashes.count <= 6 {
                return (remainder, .heading)
            }
        }
        if languageID.rawValue == "ini",
           trimmed.first == "[", trimmed.last == "]", trimmed.count > 2 {
            return (String(trimmed.dropFirst().dropLast()), .section)
        }
        if languageID.rawValue == "json",
           trimmed.first == "\"", let closing = trimmed.dropFirst().firstIndex(of: "\"") {
            let name = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
            let suffix = trimmed[trimmed.index(after: closing)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, suffix.hasPrefix(":") { return (name, .property) }
        }

        var tokens = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let modifiers: Set<String> = [
            "public", "private", "fileprivate", "internal", "open", "static",
            "final", "override", "mutating", "nonmutating", "async", "export", "default",
            "abstract", "sealed", "virtual", "inline", "constexpr", "extern"
        ]
        while let first = tokens.first, modifiers.contains(first) { tokens.removeFirst() }
        guard let keyword = tokens.first else { return nil }
        let typeKeywords: Set<String> = [
            "class", "struct", "enum", "protocol", "actor", "interface", "trait", "type",
            "namespace", "module", "extension", "impl", "record"
        ]
        let functionKeywords: Set<String> = ["func", "def", "function", "fn", "sub", "proc"]
        let propertyKeywords: Set<String> = ["var", "let", "const"]
        let kind: DocumentSymbolKind?
        if typeKeywords.contains(keyword) { kind = .type }
        else if functionKeywords.contains(keyword) { kind = .function }
        else if propertyKeywords.contains(keyword) { kind = .property }
        else { kind = nil }
        if let kind, tokens.count >= 2,
           let name = cleanIdentifier(tokens[1]), !name.isEmpty {
            return (name, kind)
        }

        if let open = trimmed.firstIndex(of: "("),
           trimmed.contains("{") || trimmed.hasSuffix(":") {
            let prefix = trimmed[..<open].trimmingCharacters(in: .whitespaces)
            if let rawName = prefix.split(whereSeparator: { $0.isWhitespace || $0 == "." }).last,
               let name = cleanIdentifier(String(rawName)),
               !["if", "for", "while", "switch", "catch", "guard"].contains(name) {
                return (name, .function)
            }
        }
        return nil
    }

    private static func cleanIdentifier(_ raw: String) -> String? {
        let prefix = raw.prefix { character in
            character.unicodeScalars.allSatisfy(isWordScalar) || character == "`"
        }
        let cleaned = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        return cleaned.isEmpty ? nil : cleaned
    }
}

@MainActor
public final class DocumentIntelligenceUseCase {
    private weak var editor: (any DocumentIntelligenceEditorPort)?
    public let maximumDocumentBytes: Int

    public init(
        editor: any DocumentIntelligenceEditorPort,
        maximumDocumentBytes: Int = 4 * 1_024 * 1_024
    ) {
        self.editor = editor
        self.maximumDocumentBytes = min(
            max(1_024, maximumDocumentBytes),
            DocumentIntelligenceAnalyzer.maximumInputBytes
        )
    }

    public var isAvailable: Bool {
        guard let editor else { return false }
        return editor.activeDocumentIntelligenceBuffer != nil
            && editor.activeDocumentIntelligenceByteLength <= maximumDocumentBytes
    }

    public func complete(supplementalTerms: [String] = []) async -> DocumentCompletionOutcome {
        guard let editor, editor.activeDocumentIntelligenceBuffer != nil else { return .unavailable }
        let byteLength = editor.activeDocumentIntelligenceByteLength
        guard byteLength <= maximumDocumentBytes else {
            editor.cancelCompletion()
            return .overBudget(actualBytes: byteLength, maximumBytes: maximumDocumentBytes)
        }
        guard let capture = editor.captureDocumentIntelligence(maximumBytes: maximumDocumentBytes) else {
            return .unavailable
        }
        let completion = await Task.detached(priority: .userInitiated) {
            DocumentIntelligenceAnalyzer.completion(
                in: capture,
                supplementalTerms: supplementalTerms
            )
        }.value
        guard !Task.isCancelled else { return .stale }
        guard let completion else { return .stale }
        guard !completion.prefix.isEmpty else { return .noPrefix }
        guard !completion.items.isEmpty else { return .noMatches }
        return editor.presentCompletionItems(
            completion.items,
            replacingPrefixByteCount: completion.prefixByteCount,
            expectedBuffer: capture.buffer,
            expectedCaretUTF8: capture.caretUTF8,
            expectedContextID: capture.contextID
        ) ? .presented(count: completion.items.count) : .stale
    }

    public func outline() async -> DocumentOutlineOutcome {
        guard let editor, editor.activeDocumentIntelligenceBuffer != nil else { return .unavailable }
        let byteLength = editor.activeDocumentIntelligenceByteLength
        guard byteLength <= maximumDocumentBytes else {
            return .overBudget(actualBytes: byteLength, maximumBytes: maximumDocumentBytes)
        }
        guard let capture = editor.captureDocumentIntelligence(maximumBytes: maximumDocumentBytes) else {
            return .unavailable
        }
        let symbols = await Task.detached(priority: .userInitiated) {
            DocumentIntelligenceAnalyzer.symbols(in: capture)
        }.value
        guard !Task.isCancelled,
              editor.activeDocumentIntelligenceBuffer == capture.buffer else { return .stale }
        return .ready(DocumentOutline(buffer: capture.buffer, symbols: symbols))
    }

    @discardableResult
    public func reveal(_ symbol: DocumentSymbol, in outline: DocumentOutline) -> Bool {
        guard let editor,
              editor.activeDocumentIntelligenceBuffer == outline.buffer,
              outline.symbols.contains(symbol) else { return false }
        editor.selectAndReveal(symbol.range)
        return true
    }

    public func cancel() { editor?.cancelCompletion() }
}
