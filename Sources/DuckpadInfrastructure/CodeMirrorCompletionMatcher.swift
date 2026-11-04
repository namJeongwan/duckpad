import Foundation
import JavaScriptCore
import DuckpadApplication

/// CodeMirror's actual fuzzy matcher, isolated from AppKit and editor state.
public actor CodeMirrorCompletionMatcher: DocumentCompletionMatching {
    private var context: JSContext?
    public init() {}
    public func matches(_ query: String, candidates: [String], limit: Int) -> [DocumentCompletionMatch] {
        guard !Task.isCancelled, query.utf8.count <= 256 else { return [] }
        if context == nil {
            guard let url = Bundle.module.url(forResource: "matcher", withExtension: "js", subdirectory: "CompletionMatching"),
                  let script = try? String(contentsOf: url, encoding: .utf8), let context = JSContext() else { return [] }
            context.evaluateScript(script); self.context = context
        }
        let locale = Locale(identifier: "en_US_POSIX")
        let folded = candidates.map { $0.folding(options: .diacriticInsensitive, locale: locale) }
        guard let function = context?.objectForKeyedSubscript("DuckpadCompletionMatching")?.objectForKeyedSubscript("matches"),
              let rows = function.call(withArguments: [query.folding(options: .diacriticInsensitive, locale: locale), folded, min(500, limit)])?.toArray() as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let index = row["index"] as? Int, let score = row["score"] as? Int,
                  let ranges = row["ranges"] as? [Int], ranges.count % 2 == 0 else { return nil }
            guard candidates.indices.contains(index) else { return nil }
            return .init(index: index, score: score, ranges: folded[index].utf16.count != candidates[index].utf16.count ? [] : stride(from: 0, to: ranges.count, by: 2).map {
                NSRange(location: ranges[$0], length: ranges[$0 + 1] - ranges[$0])
            })
        }
    }
}
