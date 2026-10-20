import Foundation

/// Comma/semicolon separated filename globs. ! excludes, * and ? match characters.
public struct SearchFileMask: Sendable {
    private let included: [[Character]]
    private let excluded: [[Character]]

    public init(_ source: String) throws(SearchFailure) {
        guard source.utf8.count <= 4096 else { throw .patternTooLarge(actual: source.utf8.count, limit: 4096) }
        let parts = source.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard parts.count <= 64 else { throw .patternTooLarge(actual: parts.count, limit: 64) }
        var included: [[Character]] = [], excluded: [[Character]] = []
        for part in parts {
            guard part.count <= 256 else { throw .patternTooLarge(actual: part.count, limit: 256) }
            let negative = part.hasPrefix("!")
            let pattern = Array((negative ? String(part.dropFirst()) : part).precomposedStringWithCanonicalMapping.lowercased())
            if negative { excluded.append(pattern) } else { included.append(pattern) }
        }
        self.included = included; self.excluded = excluded
    }
    public func matches(_ nameOrPath: String) -> Bool {
        let name = String(nameOrPath.split(separator: "/").last ?? "").precomposedStringWithCanonicalMapping.lowercased()
        let text = Array(name)
        return (included.isEmpty || included.contains { Self.matches(text, $0) }) && !excluded.contains { Self.matches(text, $0) }
    }
    private static func matches(_ text: [Character], _ pattern: [Character]) -> Bool {
        var t = 0, p = 0, star: Int?, retry = 0
        while t < text.count {
            if p < pattern.count, pattern[p] != "*", pattern[p] == "?" || pattern[p] == text[t] { t += 1; p += 1 }
            else if p < pattern.count, pattern[p] == "*" { star = p; p += 1; retry = t }
            else if let star { retry += 1; t = retry; p = star + 1 }
            else { return false }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }
}
