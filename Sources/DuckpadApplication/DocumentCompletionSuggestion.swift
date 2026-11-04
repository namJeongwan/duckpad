import Foundation
import DuckpadDomain

public struct DocumentCompletionSuggestion: Equatable, Sendable {
    public enum Source: String, Sendable { case document, keyword, languageServer }
    public var label: String
    public var detail: String
    public var documentation: String
    public var kind: Int
    public var source: Source
    public var filterText: String
    public var sortText: String
    public var insertText: String
    public var insertRange: SearchUTF8Range
    public var replaceRange: SearchUTF8Range
    public var additionalEdits: [SearchReplacementEdit]
    public var matches: [NSRange]
    public var resolutionID: UUID?
    /// Continuation lines are relative to the indentation of the insertion line.
    public var adjustIndentation: Bool

    public init(label: String, detail: String = "", documentation: String = "", kind: Int = 1,
                source: Source = .document, filterText: String? = nil, sortText: String? = nil,
                insertText: String? = nil, insertRange: SearchUTF8Range, replaceRange: SearchUTF8Range? = nil,
                additionalEdits: [SearchReplacementEdit] = [], matches: [NSRange] = []) {
        self.label = label; self.detail = detail; self.documentation = documentation; self.kind = kind
        self.source = source; self.filterText = filterText ?? label; self.sortText = sortText ?? label
        self.insertText = insertText ?? label; self.insertRange = insertRange
        self.replaceRange = replaceRange ?? insertRange; self.additionalEdits = additionalEdits; self.matches = matches
        self.resolutionID = nil; self.adjustIndentation = false
    }
}

@MainActor public protocol RichDocumentCompletionEditorPort: DocumentIntelligenceEditorPort {
    var isCompletionSuggestionVisible: Bool { get }
    /// An empty list clears old candidates while the same request awaits its provider.
    func presentCompletionSuggestions(_ suggestions: [DocumentCompletionSuggestion], capture: DocumentIntelligenceCapture) -> Bool
}

@MainActor public protocol DocumentCompletionProviding: AnyObject {
    func completions(in capture: DocumentIntelligenceCapture, prefixRange: SearchUTF8Range) async throws -> [DocumentCompletionSuggestion]
    func resolve(_ suggestion: DocumentCompletionSuggestion, capture: DocumentIntelligenceCapture) async -> DocumentCompletionSuggestion?
    func shutdown()
    func retire(bufferID: BufferID)
}

extension DocumentCompletionProviding {
    public func resolve(_ suggestion: DocumentCompletionSuggestion, capture: DocumentIntelligenceCapture) async -> DocumentCompletionSuggestion? { suggestion }
    public func retire(bufferID: BufferID) {}
}

public struct DocumentCompletionMatch: Sendable {
    public let index: Int
    public let score: Int
    public let ranges: [NSRange]
    public init(index: Int, score: Int, ranges: [NSRange]) { self.index = index; self.score = score; self.ranges = ranges }
}

public protocol DocumentCompletionMatching: Sendable {
    func matches(_ query: String, candidates: [String], limit: Int) async -> [DocumentCompletionMatch]
}
