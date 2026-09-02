import DuckpadDomain
import Foundation

public struct RegexEngineMatch: Equatable, Sendable {
    public let range: SearchUTF8Range
    public let captures: [SearchUTF8Range?]
    public init(range: SearchUTF8Range, captures: [SearchUTF8Range?]) {
        self.range = range
        self.captures = captures
    }
}

public protocol RegexEnginePort: Sendable {
    func matches(
        pattern: String,
        utf8: Data,
        matchCase: Bool,
        dotMatchesNewline: Bool,
        restrictTo: SearchUTF8Range?,
        maximumMatches: Int
    ) throws(SearchFailure) -> [RegexEngineMatch]
    func directionalMatch(
        pattern: String,
        utf8: Data,
        matchCase: Bool,
        dotMatchesNewline: Bool,
        restrictTo: SearchUTF8Range,
        backwards: Bool
    ) throws(SearchFailure) -> RegexEngineMatch?
}

public struct SearchBufferSnapshot: Equatable, Sendable {
    public let tabID: TabID
    public let title: String
    public let bufferID: BufferID
    public let revision: UInt64
    public let utf8: Data

    public init(tabID: TabID, title: String, bufferID: BufferID, revision: UInt64, utf8: Data) {
        self.tabID = tabID
        self.title = title
        self.bufferID = bufferID
        self.revision = revision
        self.utf8 = utf8
    }
}

private struct SearchCaptureDescriptor: Sendable {
    let tabID: TabID
    let title: String
    let capture: EditorRecoveryCapture
}

private struct SearchSelectionCandidate: Sendable {
    let tabID: TabID
    let bufferID: BufferID
    let revision: UInt64
    let range: SearchUTF8Range?
}

public struct ActiveSearchRequest: Equatable, Sendable {
    public let patternUTF8: Data
    public let mode: SearchMode
    public let matchCase: Bool
    public let wholeWord: Bool
    public let direction: SearchDirection
    public let wrapAround: Bool
    public let restrictTo: SearchUTF8Range?

    public init(patternUTF8: Data, options: SearchOptions, restrictTo: SearchUTF8Range?) {
        self.patternUTF8 = patternUTF8
        mode = options.mode
        matchCase = options.matchCase
        wholeWord = options.wholeWord
        direction = options.direction
        wrapAround = options.wrapAround
        self.restrictTo = restrictTo
    }
}

public struct SearchReplacementEdit: Equatable, Sendable {
    public let range: SearchUTF8Range
    public let replacementUTF8: Data

    public init(range: SearchUTF8Range, replacementUTF8: Data) {
        self.range = range
        self.replacementUTF8 = replacementUTF8
    }
}

@MainActor
public protocol SearchEditorPort: EditorPort {
    func activeSelectionUTF8Range() -> SearchUTF8Range?
    func findActive(_ request: ActiveSearchRequest) throws(SearchFailure) -> SearchUTF8Range?
    func selectAndReveal(_ range: SearchUTF8Range)
    func replaceActive(
        range: SearchUTF8Range,
        with replacementUTF8: Data,
        expectedRevision: UInt64
    ) -> EditorEditOutcome
    func replaceActiveBatch(
        _ edits: [SearchReplacementEdit],
        expectedRevision: UInt64,
        accept: ([EditorIncrementalEdit]) -> EditorEditOutcome
    ) -> EditorEditOutcome
}

public enum SearchPatternCodec {
    public static func patternData(for query: SearchQuery) throws(SearchFailure) -> Data {
        guard !query.pattern.isEmpty else { throw .emptyPattern }
        switch query.options.mode {
        case .normal, .regularExpression:
            return Data(query.pattern.utf8)
        case .extended:
            return try decodeExtended(query.pattern)
        }
    }

    public static func replacementData(for query: SearchQuery) throws(SearchFailure) -> Data {
        switch query.options.mode {
        case .normal, .regularExpression:
            return Data(query.replacement.utf8)
        case .extended:
            return try decodeExtended(query.replacement)
        }
    }

    public static func decodeExtended(_ value: String) throws(SearchFailure) -> Data {
        let bytes = Array(value.utf8)
        var output = Data()
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x5C else {
                output.append(bytes[index])
                index += 1
                continue
            }
            let escapeOffset = index
            index += 1
            guard index < bytes.count else { throw .invalidExtendedEscape(offset: escapeOffset) }
            switch bytes[index] {
            case 0x6E: output.append(0x0A) // n
            case 0x72: output.append(0x0D) // r
            case 0x74: output.append(0x09) // t
            case 0x30: output.append(0x00) // 0
            case 0x5C: output.append(0x5C)
            default: throw .invalidExtendedEscape(offset: escapeOffset)
            }
            index += 1
        }
        return output
    }
}

public struct SearchEngineScan: Sendable {
    public let matches: [SearchMatch]
    public let isComplete: Bool
    public let resultBytes: Int
}

public enum SearchEngine {
    public static func matches(
        in snapshot: SearchBufferSnapshot,
        query: SearchQuery,
        restrictTo restriction: SearchUTF8Range? = nil,
        limit: Int = 100_000,
        regexEngine: any RegexEnginePort,
        maximumResultBytes: Int = 32 * 1_024 * 1_024,
        includeReplacement: Bool = false,
        maximumReplacementBytes: Int = 16 * 1_024 * 1_024
    ) throws(SearchFailure) -> [SearchMatch] {
        try scan(
            in: snapshot, query: query, restrictTo: restriction, limit: limit,
            regexEngine: regexEngine, maximumResultBytes: maximumResultBytes,
            includeReplacement: includeReplacement,
            maximumReplacementBytes: maximumReplacementBytes
        ).matches
    }

    public static func scan(
        in snapshot: SearchBufferSnapshot,
        query: SearchQuery,
        restrictTo restriction: SearchUTF8Range? = nil,
        limit: Int = 100_000,
        regexEngine: any RegexEnginePort,
        maximumResultBytes: Int = 32 * 1_024 * 1_024,
        includeReplacement: Bool = false,
        maximumReplacementBytes: Int = 16 * 1_024 * 1_024
    ) throws(SearchFailure) -> SearchEngineScan {
        guard let text = String(data: snapshot.utf8, encoding: .utf8) else { throw .invalidUTF8Range }
        let searchData = try SearchPatternCodec.patternData(for: query)
        guard let pattern = String(data: searchData, encoding: .utf8) else { throw .invalidUTF8Range }
        let source = query.options.mode == .regularExpression ? pattern : escapedRegex(pattern)
        let literalReplacement = query.options.mode == .regularExpression
            ? nil
            : try SearchPatternCodec.replacementData(for: query)
        let rawMatches: [RegexEngineMatch]
        if query.options.mode != .regularExpression, query.options.matchCase, !query.options.wholeWord {
            rawMatches = try literalMatches(
                pattern: searchData, utf8: snapshot.utf8,
                restrictTo: restriction, maximumMatches: limit
            )
        } else {
            rawMatches = try regexEngine.matches(
                pattern: source, utf8: snapshot.utf8,
                matchCase: query.options.matchCase,
                dotMatchesNewline: query.options.dotMatchesNewline,
                restrictTo: restriction, maximumMatches: limit
            )
        }
        var lineCursor = SearchLineCursor(utf8: snapshot.utf8)
        var results: [SearchMatch] = []
        var resultBytes = 0
        var complete = rawMatches.count < limit
        for rawMatch in rawMatches {
            if Task.isCancelled { throw .cancelled }
            guard let swiftRange = stringRange(rawMatch.range, in: text) else { throw .invalidUTF8Range }
            if query.options.wholeWord, !isWholeWord(range: swiftRange, text: text) { continue }
            let location = lineCursor.location(at: rawMatch.range.location)
            let replacement = includeReplacement && query.options.mode == .regularExpression
                ? try expandedReplacement(
                    query.replacement, match: rawMatch.range,
                    captures: rawMatch.captures, utf8: snapshot.utf8,
                    maximumBytes: maximumReplacementBytes
                )
                : (includeReplacement ? literalReplacement : nil)
            let estimated = location.snippet.utf8.count
                + rawMatch.captures.count * MemoryLayout<SearchUTF8Range?>.stride
                + (replacement?.count ?? 0) + 96
            let (nextResultBytes, overflow) = resultBytes.addingReportingOverflow(estimated)
            if overflow || nextResultBytes > maximumResultBytes {
                complete = false
                break
            }
            resultBytes = nextResultBytes
            results.append(SearchMatch(
                tabID: snapshot.tabID,
                bufferID: snapshot.bufferID,
                revision: snapshot.revision,
                range: rawMatch.range,
                line: location.line,
                column: location.column,
                snippet: location.snippet,
                captures: rawMatch.captures,
                replacementUTF8: replacement
            ))
            if results.count >= limit { break }
        }
        return SearchEngineScan(matches: results, isComplete: complete, resultBytes: resultBytes)
    }

    public static func replacement(
        for match: SearchMatch,
        in snapshot: SearchBufferSnapshot,
        query: SearchQuery
    ) throws(SearchFailure) -> Data {
        guard let replacement = match.replacementUTF8 else { throw .replacementFailed }
        return replacement
    }

    private static func stringRange(_ range: SearchUTF8Range, in text: String) -> Range<String.Index>? {
        guard range.location >= 0, range.length >= 0,
              let lowerUTF8 = text.utf8.index(text.utf8.startIndex, offsetBy: range.location, limitedBy: text.utf8.endIndex),
              let upperUTF8 = text.utf8.index(lowerUTF8, offsetBy: range.length, limitedBy: text.utf8.endIndex),
              let lower = String.Index(lowerUTF8, within: text),
              let upper = String.Index(upperUTF8, within: text) else { return nil }
        return lower..<upper
    }

    private static func isWholeWord(range matchRange: Range<String.Index>, text: String) -> Bool {
        func isWord(_ character: Character) -> Bool {
            character.unicodeScalars.contains { scalar in
                switch scalar.properties.generalCategory {
                case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter,
                     .otherLetter, .decimalNumber, .letterNumber, .otherNumber,
                     .nonspacingMark, .spacingMark, .enclosingMark, .connectorPunctuation:
                    return true
                default:
                    return false
                }
            }
        }
        let leftOK = matchRange.lowerBound == text.startIndex
            || !isWord(text[text.index(before: matchRange.lowerBound)])
        let rightOK = matchRange.upperBound == text.endIndex
            || !isWord(text[matchRange.upperBound])
        return leftOK && rightOK
    }

    private static func escapedRegex(_ value: String) -> String {
        let metacharacters = CharacterSet(charactersIn: "\\.^$|?*+()[]{}")
        return String(value.unicodeScalars.flatMap { scalar -> [Character] in
            let character = Character(String(scalar))
            return metacharacters.contains(scalar) ? ["\\", character] : [character]
        })
    }

    private static func literalMatches(
        pattern: Data,
        utf8: Data,
        restrictTo: SearchUTF8Range?,
        maximumMatches: Int
    ) throws(SearchFailure) -> [RegexEngineMatch] {
        guard !pattern.isEmpty else { throw .emptyPattern }
        let lower = restrictTo?.location ?? 0
        let upper = restrictTo?.upperBound ?? utf8.count
        guard lower >= 0, upper >= lower, upper <= utf8.count else { throw .invalidUTF8Range }
        var cursor = lower
        var found: [RegexEngineMatch] = []
        while cursor <= upper, found.count < maximumMatches {
            if Task.isCancelled { throw .cancelled }
            guard let range = utf8.range(of: pattern, in: cursor..<upper) else { break }
            let match = SearchUTF8Range(location: range.lowerBound, length: range.count)
            found.append(RegexEngineMatch(range: match, captures: []))
            cursor = max(range.upperBound, cursor + 1)
        }
        return found
    }

    private static func expandedReplacement(
        _ template: String,
        match: SearchUTF8Range,
        captures: [SearchUTF8Range?],
        utf8: Data,
        maximumBytes: Int
    ) throws(SearchFailure) -> Data {
        var output = Data()
        let bytes = Array(template.utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x5C, index + 1 < bytes.count {
                output.append(bytes[index + 1])
                index += 2
            } else if bytes[index] == 0x24, index + 1 < bytes.count, bytes[index + 1] == 0x24 {
                output.append(0x24)
                index += 2
            } else if bytes[index] == 0x24, index + 1 < bytes.count, bytes[index + 1] == 0x7B {
                throw .unsupportedReplacement
            } else if bytes[index] == 0x24, index + 1 < bytes.count,
                      bytes[index + 1] >= 0x30, bytes[index + 1] <= 0x39 {
                var captureIndex = Int(bytes[index + 1] - 0x30)
                var consumed = 2
                if index + 2 < bytes.count, bytes[index + 2] >= 0x30, bytes[index + 2] <= 0x39 {
                    captureIndex = captureIndex * 10 + Int(bytes[index + 2] - 0x30)
                    consumed = 3
                }
                let selected = captureIndex == 0 ? Optional(match)
                    : (captureIndex <= captures.count ? captures[captureIndex - 1] : nil)
                if let range = selected,
                   range.location >= 0, range.length >= 0,
                   range.location <= utf8.count, range.length <= utf8.count - range.location {
                    guard range.length <= maximumBytes - min(output.count, maximumBytes) else {
                        throw .documentTooLarge(actual: .max, limit: maximumBytes)
                    }
                    output.append(utf8[range.location..<range.upperBound])
                }
                index += consumed
            } else {
                output.append(bytes[index])
                index += 1
            }
            guard output.count <= maximumBytes else {
                throw .documentTooLarge(actual: output.count, limit: maximumBytes)
            }
        }
        return output
    }
}

/// One pass per immutable snapshot. Line and snippet lookup are O(log lines);
/// columns are explicitly one-based UTF-8 byte columns, matching result ranges.
private struct SearchLineCursor {
    private let utf8: Data
    private var scannedOffset = 0
    private var lineNumber = 1
    private var lineStart = 0
    private var snippetCache: [Int: String] = [:]

    init(utf8: Data) {
        self.utf8 = utf8
    }

    mutating func location(at offset: Int) -> (line: Int, column: Int, snippet: String) {
        let safe = min(max(0, offset), utf8.count)
        while scannedOffset < safe {
            if utf8[scannedOffset] == 0x0D {
                if scannedOffset + 1 < safe, utf8[scannedOffset + 1] == 0x0A { scannedOffset += 1 }
                lineNumber += 1
                lineStart = scannedOffset + 1
            } else if utf8[scannedOffset] == 0x0A {
                lineNumber += 1
                lineStart = scannedOffset + 1
            }
            scannedOffset += 1
        }
        let snippet: String
        if let cached = snippetCache[lineNumber] {
            snippet = cached
        } else {
            var end = lineStart
            while end < utf8.count, utf8[end] != 0x0A, utf8[end] != 0x0D { end += 1 }
            snippet = Self.snippet(utf8[lineStart..<end])
            snippetCache[lineNumber] = snippet
        }
        return (lineNumber, max(1, safe - lineStart + 1), snippet)
    }

    private static func snippet(_ bytes: Data.SubSequence) -> String {
        String(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces).prefix(240))
    }
}

public actor SearchGenerationCoordinator {
    private var generation: UInt64 = 0

    public init() {}

    public func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    public func cancel() { generation &+= 1 }
    public func isCurrent(_ candidate: UInt64) -> Bool { candidate == generation }
}

@MainActor
public final class SearchWorkspaceUseCase {
    private struct RetainedSelection {
        let tabID: TabID
        let bufferID: BufferID
        let revision: UInt64
        let queryKey: SearchQuery
        let range: SearchUTF8Range
    }
    private struct LastFind {
        let tabID: TabID
        let bufferID: BufferID
        let revision: UInt64
        let queryKey: SearchQuery
        let range: SearchUTF8Range
    }
    private let workspace: ScratchWorkspaceUseCase
    private let editor: any SearchEditorPort
    private let regexEngine: any RegexEnginePort
    private let generations = SearchGenerationCoordinator()
    private var scanTask: Task<SearchResultSet, any Error>?
    private var scanGeneration: UInt64?
    private var findTask: Task<SearchSelectionCandidate, any Error>?
    private var retainedSelection: RetainedSelection?
    private var lastFind: LastFind?
    public let limits: SearchLimits

    public init(
        workspace: ScratchWorkspaceUseCase,
        editor: any SearchEditorPort,
        regexEngine: any RegexEnginePort,
        limits: SearchLimits = SearchLimits()
    ) {
        self.workspace = workspace
        self.editor = editor
        self.regexEngine = regexEngine
        self.limits = limits
    }

    public func cancel() async {
        scanTask?.cancel()
        findTask?.cancel()
        scanTask = nil
        findTask = nil
        scanGeneration = nil
        await generations.cancel()
    }

    public func find(_ query: SearchQuery) async throws -> SearchUTF8Range? {
        scanTask?.cancel()
        findTask?.cancel()
        let generation = await generations.begin()
        let data = try SearchPatternCodec.patternData(for: query)
        guard data.count <= limits.maximumPatternBytes else {
            throw SearchFailure.patternTooLarge(actual: data.count, limit: limits.maximumPatternBytes)
        }
        let restriction = try selectionRestriction(for: query)
        let found: SearchUTF8Range?
        if query.options.mode == .regularExpression {
            guard let tab = workspace.snapshot().tabs.first(where: \.isActive),
                  let capture = editor.recoveryCapture(for: tab.buffer.bufferID) else { return nil }
            let selection = editor.activeSelectionUTF8Range() ?? SearchUTF8Range(location: 0, length: 0)
            let regexLimit = limits.maximumRegularExpressionBytes
            let regexEngine = regexEngine
            let queryKey = Self.findQueryKey(query)
            let previous = lastFind
            let task = Task.detached(priority: .userInitiated) { () throws -> SearchSelectionCandidate in
                let materialized = try capture.materializedSnapshot()
                guard materialized.utf8.count <= regexLimit else {
                    throw SearchFailure.documentTooLarge(actual: materialized.utf8.count, limit: regexLimit)
                }
                let scope = restriction ?? SearchUTF8Range(location: 0, length: materialized.utf8.count)
                let samePrevious = previous?.tabID == tab.id
                    && previous?.bufferID == materialized.bufferID
                    && previous?.revision == materialized.revision
                    && previous?.queryKey == queryKey
                    && previous?.range == selection
                let isInitialSelectionScope = query.options.scope == .selection
                    && !samePrevious && selection == scope
                var boundary = query.options.direction == .forward
                    ? (isInitialSelectionScope ? scope.location : selection.upperBound)
                    : (isInitialSelectionScope ? scope.upperBound : selection.location)
                boundary = min(max(boundary, scope.location), scope.upperBound)
                var firstRegion: SearchUTF8Range?
                var firstRegionExhausted = false
                if samePrevious, let previous, previous.range.length == 0 {
                    firstRegionExhausted = query.options.direction == .forward
                        ? previous.range.location >= scope.upperBound
                        : previous.range.location <= scope.location
                    if !firstRegionExhausted {
                        boundary = Self.adjacentUTF8Boundary(
                            from: boundary, backwards: query.options.direction == .backward,
                            utf8: materialized.utf8
                        )
                    }
                }
                if !firstRegionExhausted {
                    firstRegion = query.options.direction == .forward
                        ? SearchUTF8Range(location: boundary, length: max(0, scope.upperBound - boundary))
                        : SearchUTF8Range(location: scope.location, length: max(0, boundary - scope.location))
                }
                let directionalPattern = Self.directionalPattern(for: query)
                var match: RegexEngineMatch?
                if let firstRegion {
                    match = try regexEngine.directionalMatch(
                        pattern: directionalPattern, utf8: materialized.utf8,
                        matchCase: query.options.matchCase,
                        dotMatchesNewline: query.options.dotMatchesNewline,
                        restrictTo: firstRegion,
                        backwards: query.options.direction == .backward
                    )
                }
                if match == nil, query.options.wrapAround {
                    let wrapRegion: SearchUTF8Range
                    if firstRegion == nil {
                        wrapRegion = scope
                    } else {
                        wrapRegion = query.options.direction == .forward
                            ? SearchUTF8Range(location: scope.location, length: max(0, boundary - scope.location))
                            : SearchUTF8Range(location: boundary, length: max(0, scope.upperBound - boundary))
                    }
                    match = try regexEngine.directionalMatch(
                        pattern: directionalPattern, utf8: materialized.utf8,
                        matchCase: query.options.matchCase,
                        dotMatchesNewline: query.options.dotMatchesNewline,
                        restrictTo: wrapRegion,
                        backwards: query.options.direction == .backward
                    )
                }
                return SearchSelectionCandidate(
                    tabID: tab.id, bufferID: materialized.bufferID,
                    revision: materialized.revision, range: match?.range
                )
            }
            findTask = task
            let candidate = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            if findTask != nil { findTask = nil }
            guard await generations.isCurrent(generation) else { throw SearchFailure.cancelled }
            let current = workspace.snapshot()
            guard current.tabs.first(where: \.isActive)?.id == candidate.tabID,
                  current.activeBuffer?.bufferID == candidate.bufferID,
                  current.activeBuffer?.revision == candidate.revision else {
                throw SearchFailure.staleRevision(
                    expected: candidate.revision,
                    actual: current.activeBuffer?.revision ?? 0
                )
            }
            found = candidate.range
        } else {
            found = try editor.findActive(ActiveSearchRequest(patternUTF8: data, options: query.options, restrictTo: restriction))
        }
        if let found {
            editor.selectAndReveal(found)
            if let tab = workspace.snapshot().tabs.first(where: \.isActive) {
                lastFind = LastFind(
                    tabID: tab.id, bufferID: tab.buffer.bufferID,
                    revision: tab.buffer.revision,
                    queryKey: Self.findQueryKey(query), range: found
                )
            }
        }
        return found
    }

    public func findAll(_ query: SearchQuery) async throws -> SearchResultSet {
        guard limits.maximumDocumentBytes > 0, limits.maximumMatches > 0,
              limits.maximumMatches <= 100_000, limits.maximumConcurrentDocuments > 0,
              limits.maximumConcurrentDocuments <= 16, limits.maximumPatternBytes > 0,
              limits.maximumPatternBytes <= 64 * 1_024,
              limits.maximumRegularExpressionBytes > 0,
              limits.maximumResultBytes > 0, limits.maximumReplacementBytes > 0,
              limits.maximumFinalDocumentBytes > 0 else { throw SearchFailure.invalidLimits }
        let patternBytes = query.pattern.utf8.count
        guard patternBytes <= limits.maximumPatternBytes else {
            throw SearchFailure.patternTooLarge(actual: patternBytes, limit: limits.maximumPatternBytes)
        }
        scanTask?.cancel()
        findTask?.cancel()
        let generation = await generations.begin()
        let workspaceSnapshot = workspace.snapshot()
        let selectedRange = try selectionRestriction(for: query)
        let tabs = query.options.scope == .allOpenDocuments
            ? workspaceSnapshot.tabs
            : workspaceSnapshot.tabs.filter(\.isActive)
        var captures: [SearchCaptureDescriptor] = []
        for tab in tabs {
            guard let capture = editor.recoveryCapture(for: tab.buffer.bufferID) else { continue }
            captures.append(SearchCaptureDescriptor(
                tabID: tab.id,
                title: tab.title,
                capture: capture
            ))
        }
        let limits = limits
        let regexEngine = regexEngine
        let task = Task.detached(priority: .userInitiated) {
            var documents: [SearchDocumentResult] = []
            var remaining = limits.maximumMatches
            var searchedBytes = 0
            var truncated = false
            var remainingResultBytes = limits.maximumResultBytes
            for (index, descriptor) in captures.enumerated() {
                if Task.isCancelled { throw SearchFailure.cancelled }
                let materialized = try descriptor.capture.materializedSnapshot()
                if materialized.utf8.count > limits.maximumDocumentBytes
                    || (query.options.mode == .regularExpression
                        && materialized.utf8.count > limits.maximumRegularExpressionBytes) {
                    truncated = true
                    continue
                }
                searchedBytes += materialized.utf8.count
                let snapshot = SearchBufferSnapshot(
                    tabID: descriptor.tabID,
                    title: descriptor.title,
                    bufferID: materialized.bufferID,
                    revision: materialized.revision,
                    utf8: materialized.utf8
                )
                let restriction = captures.count == 1 ? selectedRange : nil
                let foundScan = try SearchEngine.scan(
                    in: snapshot, query: query, restrictTo: restriction,
                    limit: remaining + 1, regexEngine: regexEngine,
                    maximumResultBytes: remainingResultBytes
                )
                remainingResultBytes -= min(remainingResultBytes, foundScan.resultBytes)
                let found = foundScan.matches
                let accepted = Array(found.prefix(remaining))
                if !accepted.isEmpty {
                    documents.append(SearchDocumentResult(tabID: descriptor.tabID, title: descriptor.title, matches: accepted))
                }
                remaining -= accepted.count
                if !foundScan.isComplete || found.count > accepted.count || remaining == 0 {
                    truncated = !foundScan.isComplete || found.count > accepted.count || index + 1 < captures.count
                    break
                }
            }
            return SearchResultSet(
                generation: generation, documents: documents,
                isTruncated: truncated, searchedByteCount: searchedBytes
            )
        }
        scanTask = task
        scanGeneration = generation
        defer {
            if scanGeneration == generation {
                scanTask = nil
                scanGeneration = nil
            }
        }
        let result: SearchResultSet
        do {
            result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }
        catch is CancellationError { throw SearchFailure.cancelled }
        catch { throw error }
        guard await generations.isCurrent(generation) else { throw SearchFailure.cancelled }
        return result
    }

    public func replaceCurrentThenFind(_ query: SearchQuery) async throws -> SearchUTF8Range? {
        guard query.replacement.utf8.count <= limits.maximumReplacementBytes else {
            throw SearchFailure.patternTooLarge(actual: query.replacement.utf8.count, limit: limits.maximumReplacementBytes)
        }
        await workspace.waitForPendingPersistence()
        guard let active = workspace.snapshot().activeBuffer else { return nil }
        let fixedSelectionScope = try selectionRestriction(for: query)
        let selection = editor.activeSelectionUTF8Range()
        let activeTab = workspace.snapshot().tabs.first(where: \.isActive)
        let capture = editor.recoveryCapture(for: active.bufferID)
        let snapshot: SearchBufferSnapshot?
        if let activeTab, let capture {
            snapshot = try await Task.detached(priority: .userInitiated) {
                let materialized = try capture.materializedSnapshot()
                return SearchBufferSnapshot(tabID: activeTab.id, title: activeTab.title, bufferID: materialized.bufferID, revision: materialized.revision, utf8: materialized.utf8)
            }.value
        } else { snapshot = nil }
        if let selection, let snapshot {
            guard snapshot.utf8.count <= limits.maximumDocumentBytes else {
                throw SearchFailure.documentTooLarge(actual: snapshot.utf8.count, limit: limits.maximumDocumentBytes)
            }
            if query.options.mode == .regularExpression,
               snapshot.utf8.count > limits.maximumRegularExpressionBytes {
                throw SearchFailure.documentTooLarge(actual: snapshot.utf8.count, limit: limits.maximumRegularExpressionBytes)
            }
            let matchingScan = try SearchEngine.scan(
                in: snapshot, query: query, restrictTo: selection,
                limit: 2, regexEngine: regexEngine,
                maximumResultBytes: limits.maximumResultBytes,
                includeReplacement: true,
                maximumReplacementBytes: limits.maximumReplacementBytes
            )
            guard matchingScan.isComplete else {
                throw SearchFailure.documentTooLarge(actual: matchingScan.resultBytes, limit: limits.maximumResultBytes)
            }
            let matching = matchingScan.matches
            if let match = matching.first, match.range == selection {
                let replacement = try SearchEngine.replacement(for: match, in: snapshot, query: query)
                let base = snapshot.utf8.count - selection.length
                let (finalBytes, overflow) = base.addingReportingOverflow(replacement.count)
                guard !overflow, replacement.count <= limits.maximumReplacementBytes,
                      finalBytes <= limits.maximumFinalDocumentBytes else {
                    throw SearchFailure.documentTooLarge(
                        actual: overflow ? .max : finalBytes,
                        limit: limits.maximumFinalDocumentBytes
                    )
                }
                guard let reservation = await workspace.reserveEditorBatch(
                    bufferID: active.bufferID, expectedRevision: active.revision, editCount: 1
                ) else {
                    throw SearchFailure.staleRevision(
                        expected: active.revision,
                        actual: workspace.snapshot().activeBuffer?.revision ?? active.revision
                    )
                }
                guard !Task.isCancelled else {
                    workspace.cancelEditorBatch(reservation)
                    throw SearchFailure.cancelled
                }
                let outcome = editor.replaceActiveBatch(
                    [SearchReplacementEdit(range: selection, replacementUTF8: replacement)],
                    expectedRevision: active.revision
                ) { [workspace] edits in workspace.commitEditorBatch(reservation, edits: edits) }
                if case .rejected = outcome { workspace.cancelEditorBatch(reservation) }
                if case .rejected(let current) = outcome {
                    throw SearchFailure.staleRevision(expected: active.revision, actual: current)
                }
                if case .accepted(let newRevision) = outcome, let fixedSelectionScope {
                    rebaseRetainedSelection(
                        query: query, tabID: snapshot.tabID, bufferID: snapshot.bufferID,
                        oldRevision: snapshot.revision, newRevision: newRevision,
                        range: fixedSelectionScope,
                        replaced: selection, replacementByteCount: replacement.count
                    )
                }
            }
        }
        return try await find(query)
    }

    public func replaceAll(_ query: SearchQuery) async throws -> Int {
        guard query.options.scope != .allOpenDocuments else { throw SearchFailure.invalidLimits }
        guard query.replacement.utf8.count <= limits.maximumReplacementBytes else {
            throw SearchFailure.patternTooLarge(actual: query.replacement.utf8.count, limit: limits.maximumReplacementBytes)
        }
        await workspace.waitForPendingPersistence()
        guard let tab = workspace.snapshot().tabs.first(where: \.isActive),
              let capture = editor.recoveryCapture(for: tab.buffer.bufferID) else { return 0 }
        let snapshot = try await Task.detached(priority: .userInitiated) {
            let materialized = try capture.materializedSnapshot()
            return SearchBufferSnapshot(
                tabID: tab.id, title: tab.title, bufferID: materialized.bufferID,
                revision: materialized.revision, utf8: materialized.utf8
            )
        }.value
        guard snapshot.utf8.count <= limits.maximumDocumentBytes else {
            throw SearchFailure.documentTooLarge(actual: snapshot.utf8.count, limit: limits.maximumDocumentBytes)
        }
        if query.options.mode == .regularExpression,
           snapshot.utf8.count > limits.maximumRegularExpressionBytes {
            throw SearchFailure.documentTooLarge(actual: snapshot.utf8.count, limit: limits.maximumRegularExpressionBytes)
        }
        let restriction = try selectionRestriction(for: query)
        let maximumMatches = limits.maximumMatches
        let maximumResultBytes = limits.maximumResultBytes
        let maximumReplacementBytes = limits.maximumReplacementBytes
        let regexEngine = regexEngine
        let matchScan = try await Task.detached(priority: .userInitiated) {
            try SearchEngine.scan(
                in: snapshot, query: query, restrictTo: restriction,
                limit: maximumMatches + 1, regexEngine: regexEngine,
                maximumResultBytes: maximumResultBytes,
                includeReplacement: true,
                maximumReplacementBytes: maximumReplacementBytes
            )
        }.value
        guard matchScan.isComplete else {
            throw SearchFailure.documentTooLarge(actual: matchScan.resultBytes, limit: maximumResultBytes)
        }
        let matchesWithOverflow = matchScan.matches
        guard matchesWithOverflow.count <= limits.maximumMatches else {
            throw SearchFailure.documentTooLarge(actual: matchesWithOverflow.count, limit: limits.maximumMatches)
        }
        let matches = matchesWithOverflow
        guard !matches.isEmpty else { return 0 }
        guard UInt64(matches.count) <= UInt64.max - snapshot.revision else {
            throw SearchFailure.staleRevision(expected: snapshot.revision, actual: .max)
        }
        let edits = try await Task.detached(priority: .userInitiated) {
            try matches.reversed().map { match in
                SearchReplacementEdit(
                    range: match.range,
                    replacementUTF8: try SearchEngine.replacement(for: match, in: snapshot, query: query)
                )
            }
        }.value
        var finalByteCount = snapshot.utf8.count
        var aggregateReplacementBytes = 0
        for edit in edits {
            guard edit.range.location >= 0, edit.range.length >= 0,
                  edit.range.location <= snapshot.utf8.count,
                  edit.range.length <= snapshot.utf8.count - edit.range.location else {
                throw SearchFailure.invalidUTF8Range
            }
            let (aggregate, aggregateOverflow) = aggregateReplacementBytes.addingReportingOverflow(edit.replacementUTF8.count)
            guard !aggregateOverflow, aggregate <= limits.maximumReplacementBytes else {
                throw SearchFailure.documentTooLarge(actual: aggregateOverflow ? .max : aggregate, limit: limits.maximumReplacementBytes)
            }
            aggregateReplacementBytes = aggregate
            finalByteCount -= edit.range.length
            let (next, overflow) = finalByteCount.addingReportingOverflow(edit.replacementUTF8.count)
            guard !overflow, next <= limits.maximumFinalDocumentBytes else {
                throw SearchFailure.documentTooLarge(actual: overflow ? .max : next, limit: limits.maximumFinalDocumentBytes)
            }
            finalByteCount = next
        }
        guard let reservation = await workspace.reserveEditorBatch(
            bufferID: snapshot.bufferID,
            expectedRevision: snapshot.revision,
            editCount: edits.count
        ) else {
            if Task.isCancelled { throw SearchFailure.cancelled }
            throw SearchFailure.staleRevision(
                expected: snapshot.revision,
                actual: workspace.snapshot().activeBuffer?.revision ?? snapshot.revision
            )
        }
        guard !Task.isCancelled else {
            workspace.cancelEditorBatch(reservation)
            throw SearchFailure.cancelled
        }
        let batchOutcome = editor.replaceActiveBatch(edits, expectedRevision: snapshot.revision) { [workspace] editorEdits in
            workspace.commitEditorBatch(reservation, edits: editorEdits)
        }
        if case .rejected = batchOutcome { workspace.cancelEditorBatch(reservation) }
        switch batchOutcome {
        case .accepted: return matches.count
        case .rejected(let actual):
            throw SearchFailure.staleRevision(expected: snapshot.revision, actual: actual)
        }
    }

    public func activate(_ match: SearchMatch) async throws(SearchFailure) {
        let before = workspace.snapshot()
        guard let target = before.tabs.first(where: { $0.id == match.tabID }),
              target.buffer.bufferID == match.bufferID,
              target.buffer.revision == match.revision else { throw .cancelled }
        let outcome = await workspace.activate(tabID: match.tabID)
        let after = workspace.snapshot()
        guard case .applied = outcome,
              after.activeBuffer?.bufferID == match.bufferID,
              after.activeBuffer?.revision == match.revision else {
            throw .staleRevision(expected: match.revision, actual: after.activeBuffer?.revision ?? 0)
        }
        editor.selectAndReveal(match.range)
    }

    private nonisolated static func scan(
        _ snapshots: [SearchBufferSnapshot],
        query: SearchQuery,
        selection: SearchUTF8Range?,
        generation: UInt64,
        limits: SearchLimits,
        regexEngine: any RegexEnginePort
    ) throws(SearchFailure) -> SearchResultSet {
        var documents: [SearchDocumentResult] = []
        var remaining = limits.maximumMatches
        var byteCount = 0
        var truncated = false
        for (index, snapshot) in snapshots.enumerated() {
            if Task.isCancelled { throw .cancelled }
            if snapshot.utf8.count > limits.maximumDocumentBytes {
                truncated = true
                continue
            }
            if query.options.mode == .regularExpression,
               snapshot.utf8.count > limits.maximumRegularExpressionBytes {
                truncated = true
                continue
            }
            byteCount += snapshot.utf8.count
            let restriction = snapshots.count == 1 ? selection : nil
            let matches = try SearchEngine.matches(
                in: snapshot, query: query, restrictTo: restriction,
                limit: remaining + 1, regexEngine: regexEngine
            )
            let accepted = Array(matches.prefix(remaining))
            if !accepted.isEmpty { documents.append(SearchDocumentResult(tabID: snapshot.tabID, title: snapshot.title, matches: accepted)) }
            remaining -= accepted.count
            if matches.count > accepted.count || remaining == 0 {
                truncated = matches.count > accepted.count || index + 1 < snapshots.count
                break
            }
        }
        return SearchResultSet(generation: generation, documents: documents, isTruncated: truncated, searchedByteCount: byteCount)
    }

    private func selectionRestriction(for query: SearchQuery) throws(SearchFailure) -> SearchUTF8Range? {
        guard query.options.scope == .selection,
              let tab = workspace.snapshot().tabs.first(where: \.isActive) else {
            retainedSelection = nil
            if query.options.scope == .selection { throw .noSelection }
            return nil
        }
        let keyed = Self.selectionQueryKey(query)
        if let retainedSelection,
           retainedSelection.tabID == tab.id,
           retainedSelection.bufferID == tab.buffer.bufferID,
           retainedSelection.revision == tab.buffer.revision,
           retainedSelection.queryKey == keyed {
            return retainedSelection.range
        }
        let invalidatedRetainedScope = retainedSelection != nil
        retainedSelection = nil
        guard let range = editor.activeSelectionUTF8Range(), range.length > 0 else {
            throw invalidatedRetainedScope ? .invalidSelection : .noSelection
        }
        retainedSelection = RetainedSelection(
            tabID: tab.id, bufferID: tab.buffer.bufferID,
            revision: tab.buffer.revision, queryKey: keyed, range: range
        )
        return range
    }

    private func rebaseRetainedSelection(
        query: SearchQuery,
        tabID: TabID,
        bufferID: BufferID,
        oldRevision: UInt64,
        newRevision: UInt64,
        range: SearchUTF8Range,
        replaced: SearchUTF8Range,
        replacementByteCount: Int
    ) {
        guard query.options.scope == .selection,
              retainedSelection?.tabID == tabID,
              retainedSelection?.bufferID == bufferID,
              retainedSelection?.revision == oldRevision,
              retainedSelection?.queryKey == Self.selectionQueryKey(query),
              replaced.location >= range.location,
              replaced.upperBound <= range.upperBound else {
            retainedSelection = nil
            return
        }
        let (withoutReplaced, underflow) = range.length.subtractingReportingOverflow(replaced.length)
        let (newLength, overflow) = withoutReplaced.addingReportingOverflow(replacementByteCount)
        guard !underflow, !overflow else {
            retainedSelection = nil
            return
        }
        retainedSelection = RetainedSelection(
            tabID: tabID, bufferID: bufferID, revision: newRevision,
            queryKey: Self.selectionQueryKey(query),
            range: SearchUTF8Range(location: range.location, length: newLength)
        )
    }

    private nonisolated static func selectionQueryKey(_ query: SearchQuery) -> SearchQuery {
        var key = query
        key.replacement = ""
        key.options.direction = .forward
        return key
    }

    private nonisolated static func findQueryKey(_ query: SearchQuery) -> SearchQuery {
        var key = query
        key.replacement = ""
        return key
    }

    /// ICU evaluates these fixed-width Unicode-category assertions while it
    /// streams candidates under one time/stack budget. This is equivalent to
    /// SearchEngine's L/M/N/Pc predicate and does not cap accepted matches by
    /// an intermediate rejected-candidate array.
    private nonisolated static func directionalPattern(for query: SearchQuery) -> String {
        guard query.options.wholeWord else { return query.pattern }
        let word = "\\p{L}\\p{M}\\p{N}\\p{Pc}"
        return "(?<![\(word)])(?:\(query.pattern))(?![\(word)])"
    }

    private nonisolated static func adjacentUTF8Boundary(from position: Int, backwards: Bool, utf8: Data) -> Int {
        if backwards {
            var candidate = max(0, position - 1)
            while candidate > 0, (utf8[candidate] & 0xC0) == 0x80 { candidate -= 1 }
            return candidate
        }
        var candidate = min(utf8.count, position + 1)
        while candidate < utf8.count, (utf8[candidate] & 0xC0) == 0x80 { candidate += 1 }
        return candidate
    }
}
