import Foundation

public enum SearchMode: String, CaseIterable, Codable, Sendable {
    case normal
    case extended
    case regularExpression
}

public enum SearchDirection: String, Codable, Sendable {
    case forward
    case backward
}

public enum SearchScope: String, Codable, Sendable {
    case document
    case selection
    case allOpenDocuments
}

public struct SearchOptions: Equatable, Sendable {
    public var mode: SearchMode
    public var matchCase: Bool
    public var wholeWord: Bool
    public var dotMatchesNewline: Bool
    public var wrapAround: Bool
    public var direction: SearchDirection
    public var scope: SearchScope

    public init(
        mode: SearchMode = .normal,
        matchCase: Bool = false,
        wholeWord: Bool = false,
        dotMatchesNewline: Bool = false,
        wrapAround: Bool = true,
        direction: SearchDirection = .forward,
        scope: SearchScope = .document
    ) {
        self.mode = mode
        self.matchCase = matchCase
        self.wholeWord = wholeWord
        self.dotMatchesNewline = dotMatchesNewline
        self.wrapAround = wrapAround
        self.direction = direction
        self.scope = scope
    }
}

public struct SearchQuery: Equatable, Sendable {
    public var pattern: String
    public var replacement: String
    public var options: SearchOptions

    public init(pattern: String, replacement: String = "", options: SearchOptions = SearchOptions()) {
        self.pattern = pattern
        self.replacement = replacement
        self.options = options
    }
}

public struct SearchUTF8Range: Hashable, Codable, Sendable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }

    public var upperBound: Int {
        let (value, overflow) = location.addingReportingOverflow(length)
        return overflow ? Int.max : value
    }
}

public struct SearchMatch: Hashable, Sendable {
    public let tabID: TabID
    public let bufferID: BufferID
    public let revision: UInt64
    public let range: SearchUTF8Range
    public let line: Int
    public let column: Int
    public let snippet: String
    public let captures: [SearchUTF8Range?]
    /// Replacement bytes computed by the same compiled matcher that produced
    /// this result. This avoids regex recompilation/rematching during Replace All.
    public let replacementUTF8: Data?

    public init(
        tabID: TabID,
        bufferID: BufferID,
        revision: UInt64,
        range: SearchUTF8Range,
        line: Int,
        column: Int,
        snippet: String,
        captures: [SearchUTF8Range?] = [],
        replacementUTF8: Data? = nil
    ) {
        self.tabID = tabID
        self.bufferID = bufferID
        self.revision = revision
        self.range = range
        self.line = line
        self.column = column
        self.snippet = snippet
        self.captures = captures
        self.replacementUTF8 = replacementUTF8
    }
}

public struct SearchDocumentResult: Equatable, Sendable {
    public let tabID: TabID
    public let title: String
    public let matches: [SearchMatch]

    public init(tabID: TabID, title: String, matches: [SearchMatch]) {
        self.tabID = tabID
        self.title = title
        self.matches = matches
    }
}

public struct SearchResultSet: Equatable, Sendable {
    public let generation: UInt64
    public let documents: [SearchDocumentResult]
    public let isTruncated: Bool
    public let searchedByteCount: Int

    public init(generation: UInt64, documents: [SearchDocumentResult], isTruncated: Bool, searchedByteCount: Int) {
        self.generation = generation
        self.documents = documents
        self.isTruncated = isTruncated
        self.searchedByteCount = searchedByteCount
    }

    public var matchCount: Int { documents.reduce(0) { $0 + $1.matches.count } }
}

public struct SearchLimits: Equatable, Sendable {
    public var maximumDocumentBytes: Int
    public var maximumMatches: Int
    public var maximumConcurrentDocuments: Int
    public var maximumPatternBytes: Int
    public var maximumRegularExpressionBytes: Int
    public var maximumResultBytes: Int
    public var maximumReplacementBytes: Int
    public var maximumFinalDocumentBytes: Int

    public init(
        maximumDocumentBytes: Int = 64 * 1_024 * 1_024,
        maximumMatches: Int = 100_000,
        maximumConcurrentDocuments: Int = 4,
        maximumPatternBytes: Int = 64 * 1_024,
        maximumRegularExpressionBytes: Int = 8 * 1_024 * 1_024,
        maximumResultBytes: Int = 32 * 1_024 * 1_024,
        maximumReplacementBytes: Int = 16 * 1_024 * 1_024,
        maximumFinalDocumentBytes: Int = 128 * 1_024 * 1_024
    ) {
        self.maximumDocumentBytes = maximumDocumentBytes
        self.maximumMatches = maximumMatches
        self.maximumConcurrentDocuments = maximumConcurrentDocuments
        self.maximumPatternBytes = maximumPatternBytes
        self.maximumRegularExpressionBytes = maximumRegularExpressionBytes
        self.maximumResultBytes = maximumResultBytes
        self.maximumReplacementBytes = maximumReplacementBytes
        self.maximumFinalDocumentBytes = maximumFinalDocumentBytes
    }
}

public enum SearchFailure: Error, Equatable, Sendable {
    case emptyPattern
    case invalidExtendedEscape(offset: Int)
    case invalidRegularExpression(String)
    case documentTooLarge(actual: Int, limit: Int)
    case staleRevision(expected: UInt64, actual: UInt64)
    case invalidUTF8Range
    case noSelection
    case invalidSelection
    case cancelled
    case replacementFailed
    case invalidLimits
    case patternTooLarge(actual: Int, limit: Int)
    case tooComplex
    case timedOut
    case unsupportedReplacement
}
