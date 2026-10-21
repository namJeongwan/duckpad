import Foundation

/// Literal, case/diacritic-insensitive filename and path terms, shared by discovery and UI.
public struct FileNameQuery: Sendable {
    private let terms: [String]
    private let phrase: String
    public var isEmpty: Bool { terms.isEmpty }

    public init(_ text: String) {
        terms = Self.fold(text).split(whereSeparator: \.isWhitespace).map(String.init)
        phrase = terms.joined(separator: " ")
    }

    public static func fold(_ text: String) -> String {
        if text.utf8.allSatisfy({ $0 < 0x80 }) { return text.lowercased() }
        return text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    public func matches(path: String) -> Bool {
        guard !isEmpty else { return true }
        let folded = Self.fold(path)
        return terms.allSatisfy { folded.contains($0) }
    }

    public func rank(name: String, path: String) -> Int? {
        rank(foldedName: Self.fold(name), foldedPath: Self.fold(path))
    }

    public func rank(foldedName name: String, foldedPath path: String) -> Int? {
        guard terms.allSatisfy({ name.contains($0) || path.contains($0) }) else { return nil }
        return isEmpty || name == phrase ? 0 : name.hasPrefix(phrase) ? 1 : name.contains(phrase) ? 2
            : terms.allSatisfy({ name.contains($0) }) ? 3 : 4
    }
}
