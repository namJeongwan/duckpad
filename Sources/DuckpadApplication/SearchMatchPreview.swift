import DuckpadDomain
import Foundation

public struct SearchMatchPreview: Sendable, Equatable {
    public let text: String
    public let firstLine: Int
    public let matchLine: Int
    public let highlight: SearchUTF8Range
    public let syntaxContextPrefix: String
    public let languageDetectionPrefix: Data?
    public let syntax: [SearchPreviewSyntaxSpan]

    public init(text: String, firstLine: Int, matchLine: Int, highlight: SearchUTF8Range,
                syntaxContextPrefix: String = "", languageDetectionPrefix: Data? = nil,
                syntax: [SearchPreviewSyntaxSpan] = []) {
        self.text = text; self.firstLine = firstLine; self.matchLine = matchLine; self.highlight = highlight
        self.syntaxContextPrefix = syntaxContextPrefix; self.syntax = syntax
        self.languageDetectionPrefix = languageDetectionPrefix
    }

    public func withSyntax(_ syntax: [SearchPreviewSyntaxSpan]) -> Self {
        .init(text: text, firstLine: firstLine, matchLine: matchLine, highlight: highlight,
              syntaxContextPrefix: syntaxContextPrefix, languageDetectionPrefix: languageDetectionPrefix, syntax: syntax)
    }

    /// At most 32 KiB visible text, plus 64 KiB preceding lexer context and a 64 KiB BOF language probe.
    public static func extract(utf8: Data, range: SearchUTF8Range, line: Int) -> Self? {
        guard range.location >= 0, range.length >= 0, range.upperBound <= utf8.count, line > 0 else { return nil }
        let lowerBound = max(0, range.location - 16 * 1_024)
        let upperBound = min(utf8.count, range.location + 16 * 1_024)
        var start = range.location, end = range.location, preceding = 0, following = 0
        while start > lowerBound, preceding < 7 {
            start -= 1
            if utf8[start] == 10 {
                if start > lowerBound, utf8[start - 1] == 13 { start -= 1 }
                preceding += 1
            } else if utf8[start] == 13 { preceding += 1 }
        }
        if preceding == 7 {
            if utf8[start] == 13, start + 1 < utf8.count, utf8[start + 1] == 10 { start += 1 }
            start += 1; preceding -= 1
        }
        while start < range.location, utf8[start] & 0xc0 == 0x80 { start += 1 }
        while end < upperBound, following < 9 {
            if utf8[end] == 13 {
                following += 1
                if end + 1 < upperBound, utf8[end + 1] == 10 { end += 1 }
            } else if utf8[end] == 10 { following += 1 }
            end += 1
        }
        while end > range.location, end < utf8.count, utf8[end] & 0xc0 == 0x80 { end -= 1 }
        guard let text = String(data: utf8.subdata(in: start..<end), encoding: .utf8) else { return nil }
        var contextStart = max(0, start - 64 * 1_024)
        while contextStart < start, utf8[contextStart] & 0xc0 == 0x80 { contextStart += 1 }
        let prefix = String(data: utf8.subdata(in: contextStart..<start), encoding: .utf8) ?? ""
        return .init(text: text, firstLine: max(1, line - preceding), matchLine: line,
                     highlight: .init(location: range.location - start, length: min(range.length, end - range.location)),
                     syntaxContextPrefix: prefix, languageDetectionPrefix: Data(utf8.prefix(64 * 1_024)))
    }
}

extension SearchWorkspaceUseCase {
    public func preview(_ match: SearchMatch) async -> SearchMatchPreview? {
        guard let capture = previewCapture(for: match) else { return nil }
        let worker = Task.detached(priority: .userInitiated) { () -> SearchMatchPreview? in
            guard !Task.isCancelled, let snapshot = try? capture.materializedSnapshot(), !Task.isCancelled else { return nil }
            return SearchMatchPreview.extract(utf8: snapshot.utf8, range: match.range, line: match.line)
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }
}
