import DuckpadDomain
import Foundation

/// Syntax-based candidates, not type-resolved semantic references.
public struct Declaration: Equatable, Sendable {
    public let name: String
    public let kind: DocumentSymbolKind
    public let range: SearchUTF8Range
    public let line: Int
    public let scope: Range<Int>
    public let depth: Int
    public let isProjectVisible: Bool
}

public struct DeclarationIndex: Sendable {
    public static let maximumBytes = 4 * 1_024 * 1_024
    public let declarations: [Declaration]
    public let isComplete: Bool
    private let words: [Word]
    struct Word: Sendable { let text: String; let range: Range<Int>; let qualified: Bool; let line: Int }

    init(declarations: [Declaration], words: [Word], isComplete: Bool) {
        self.declarations = declarations; self.words = words; self.isComplete = isComplete
    }

    private func token(at offset: Int) -> Word? {
        // Binary search keeps clicking near the end of a large file bounded.
        var lower = 0, upper = words.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if words[middle].range.upperBound < offset { lower = middle + 1 } else { upper = middle }
        }
        guard lower < words.count else { return nil }
        if words[lower].range.contains(offset) { return words[lower] }
        if lower + 1 < words.count, words[lower + 1].range.contains(offset) { return words[lower + 1] }
        return words[lower].range.upperBound == offset ? words[lower] : nil
    }

    public func word(at offset: Int) -> String? { token(at: offset)?.text }
    /// Mouse hit testing must stay inside the token, unlike a caret at its trailing edge.
    public func navigationRange(at offset: Int) -> Range<Int>? {
        guard let word = token(at: offset), word.range.contains(offset) else { return nil }
        return word.range
    }
    public func isQualified(at offset: Int) -> Bool { token(at: offset)?.qualified == true }

    public func candidates(named name: String, at offset: Int? = nil) -> [Declaration] {
        let matches = declarations.filter { $0.name == name && (offset.map($0.scope.contains) ?? $0.isProjectVisible) }
        guard offset != nil, let depth = matches.map(\.depth).max() else { return matches }
        return matches.filter { $0.depth == depth }
    }

    public func matches(named name: String, kind: SymbolNavigationKind, at offset: Int? = nil) -> [SymbolNavigationMatch] {
        if kind == .declarations { return candidates(named: name, at: offset).map(SymbolNavigationMatch.init) }
        let declarationOffsets = Set(declarations.map(\.range.location))
        var matches: [SymbolNavigationMatch] = []
        for word in words where word.text == name && !declarationOffsets.contains(word.range.lowerBound) {
            if Task.isCancelled { break }
            matches.append(.init(name: name, range: .init(location: word.range.lowerBound, length: word.range.count), line: word.line))
            // One extra result lets callers mark their 200-result budget as partial.
            if matches.count == 201 { break }
        }
        return matches
    }
}

/// Runs bounded document analysis separately from editor/UI routing.
public protocol DeclarationAnalyzing: Sendable {
    func index(utf8: Data, language: String) async -> DeclarationIndex
}

public actor BuiltinDeclarationAnalyzer: DeclarationAnalyzing {
    private var cached: (Data, String, DeclarationIndex)?
    public init() {}
    public func index(utf8: Data, language: String) -> DeclarationIndex {
        if let cached, cached.0 == utf8, cached.1 == language { return cached.2 }
        let result = DeclarationParser.parse(utf8, language: language)
        if !Task.isCancelled, utf8.count <= DeclarationIndex.maximumBytes { cached = (utf8, language, result) }
        return result
    }
}

public enum DeclarationLanguage {
    public static func forFilename(_ name: String) -> String? {
        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "swift": "swift"
        case "js", "jsx", "mjs", "cjs": "javascript"
        case "ts", "tsx": "typescript"
        case "py", "pyi": "python"
        case "rs": "rust"
        case "go": "go"
        case "c", "h": "c"
        case "cc", "cpp", "cxx", "hpp", "hh": "cpp"
        case "java": "java"
        case "cs": "csharp"
        case "proto": "protobuf"
        default: nil
        }
    }
    public static func isCompatible(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || (Set([lhs, rhs]).isSubset(of: ["javascript", "typescript"]))
            || (Set([lhs, rhs]).isSubset(of: ["c", "cpp"]))
    }
    public static let supported: Set<String> = ["swift", "javascript", "typescript", "python", "rust", "go", "c", "cpp", "java", "csharp", "protobuf"]
}
