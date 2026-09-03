import DuckpadDomain
import Foundation

public struct FolderSearchFile: Equatable, Sendable {
    public let path: String
    public let relativePath: String
    public let data: Data
    public let identity: FileIdentity

    public init(path: String, relativePath: String, data: Data, identity: FileIdentity) {
        self.path = path
        self.relativePath = relativePath
        self.data = data
        self.identity = identity
    }
}

public struct FolderSearchEnumeration: Equatable, Sendable {
    public let rootPath: String
    public let files: [FolderSearchFile]
    public let isTruncated: Bool
    public let skippedFileCount: Int
    public let totalBytes: Int

    public init(rootPath: String, files: [FolderSearchFile], isTruncated: Bool, skippedFileCount: Int, totalBytes: Int) {
        self.rootPath = rootPath
        self.files = files
        self.isTruncated = isTruncated
        self.skippedFileCount = skippedFileCount
        self.totalBytes = totalBytes
    }
}

public protocol FolderSearchFileStore: Sendable {
    func enumerateTextCandidates(
        rootPath: String,
        maximumFiles: Int,
        maximumDocumentBytes: Int,
        maximumTotalBytes: Int
    ) async throws(FolderSearchFailure) -> FolderSearchEnumeration
}

public final class FolderSearchUseCase: Sendable {
    private let store: any FolderSearchFileStore
    private let regexEngine: any RegexEnginePort
    public let limits: FolderSearchLimits

    public init(
        store: any FolderSearchFileStore,
        regexEngine: any RegexEnginePort,
        limits: FolderSearchLimits = FolderSearchLimits()
    ) {
        self.store = store
        self.regexEngine = regexEngine
        self.limits = limits
    }

    public func search(rootPath: String, query: SearchQuery) async throws(FolderSearchFailure) -> FolderSearchResultSet {
        guard limits.maximumFiles > 0, limits.maximumFiles <= 100_000,
              limits.maximumDocumentBytes > 0,
              limits.maximumTotalBytes > 0,
              limits.maximumMatches > 0, limits.maximumMatches <= 100_000,
              limits.maximumResultBytes > 0,
              limits.maximumPatternBytes > 0, limits.maximumPatternBytes <= 64 * 1_024,
              limits.maximumRegularExpressionBytes > 0 else { throw .invalidLimits }
        guard query.pattern.utf8.count <= limits.maximumPatternBytes else {
            throw .search(.patternTooLarge(actual: query.pattern.utf8.count, limit: limits.maximumPatternBytes))
        }
        do { _ = try SearchPatternCodec.patternData(for: query) }
        catch let error { throw .search(error) }
        if query.options.mode == .regularExpression {
            do {
                _ = try regexEngine.matches(
                    pattern: query.pattern,
                    utf8: Data(),
                    matchCase: query.options.matchCase,
                    dotMatchesNewline: query.options.dotMatchesNewline,
                    restrictTo: nil,
                    maximumMatches: 1
                )
            } catch let error { throw .search(error) }
        }

        let enumeration = try await store.enumerateTextCandidates(
            rootPath: rootPath,
            maximumFiles: limits.maximumFiles,
            maximumDocumentBytes: limits.maximumDocumentBytes,
            maximumTotalBytes: limits.maximumTotalBytes
        )
        let limits = limits
        let regexEngine = regexEngine
        let task = Task.detached(priority: .userInitiated) {
            var documents: [FolderSearchDocumentResult] = []
            var remainingMatches = limits.maximumMatches
            var remainingResultBytes = limits.maximumResultBytes
            let rootBytes = enumeration.rootPath.utf8.count + 64
            guard rootBytes <= remainingResultBytes else {
                return FolderSearchResultSet(
                    rootPath: enumeration.rootPath, documents: [], isTruncated: true,
                    searchedFileCount: 0, skippedFileCount: enumeration.skippedFileCount,
                    searchedByteCount: 0
                )
            }
            remainingResultBytes -= rootBytes
            var skipped = enumeration.skippedFileCount
            var truncated = enumeration.isTruncated
            var searchedFiles = 0
            var searchedBytes = 0
            var fileIndex = 0
            while fileIndex < enumeration.files.count {
                if Task.isCancelled { throw FolderSearchFailure.search(.cancelled) }
                let file = enumeration.files[fileIndex]
                fileIndex += 1
                let decoded: DecodedTextFile
                do { decoded = try TextFileCodec.decode(file.data) }
                catch {
                    skipped += 1
                    continue
                }
                let utf8 = Data(decoded.text.utf8)
                if query.options.mode == .regularExpression,
                   utf8.count > min(limits.maximumDocumentBytes, limits.maximumRegularExpressionBytes) {
                    skipped += 1
                    truncated = true
                    continue
                }
                searchedFiles += 1
                searchedBytes += file.data.count
                let snapshot = SearchBufferSnapshot(
                    tabID: TabID(),
                    title: file.relativePath,
                    bufferID: BufferID(),
                    revision: 0,
                    utf8: utf8
                )
                let scan: SearchEngineScan
                do {
                    scan = try SearchEngine.scan(
                        in: snapshot,
                        query: query,
                        limit: remainingMatches + 1,
                        regexEngine: regexEngine,
                        maximumResultBytes: remainingResultBytes
                    )
                } catch let error as SearchFailure {
                    throw FolderSearchFailure.search(error)
                }
                var matches: [FolderSearchMatch] = []
                var exhaustedResultBudget = false
                let documentBytes = Self.estimatedDocumentResultBytes(file)
                for source in scan.matches.prefix(remainingMatches) {
                    let matchBytes = Self.estimatedMatchResultBytes(source)
                    let required = Self.saturatedAdd(matchBytes, matches.isEmpty ? documentBytes : 0)
                    guard required <= remainingResultBytes else {
                        exhaustedResultBudget = true
                        break
                    }
                    remainingResultBytes -= required
                    matches.append(FolderSearchMatch(
                        range: source.range,
                        line: source.line,
                        column: source.column,
                        snippet: source.snippet
                    ))
                }
                if !matches.isEmpty {
                    documents.append(FolderSearchDocumentResult(
                        path: file.path,
                        relativePath: file.relativePath,
                        identity: file.identity,
                        matches: matches
                    ))
                }
                remainingMatches -= matches.count
                if exhaustedResultBudget || !scan.isComplete || scan.matches.count > matches.count || remainingMatches == 0 {
                    truncated = true
                    break
                }
            }
            if fileIndex < enumeration.files.count { truncated = true }
            return FolderSearchResultSet(
                rootPath: enumeration.rootPath,
                documents: documents,
                isTruncated: truncated,
                searchedFileCount: searchedFiles,
                skippedFileCount: skipped,
                searchedByteCount: searchedBytes
            )
        }
        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }
        catch let error as FolderSearchFailure { throw error }
        catch is CancellationError { throw .search(.cancelled) }
        catch { throw .enumerationFailed(String(describing: error)) }
    }

    private static func estimatedDocumentResultBytes(_ file: FolderSearchFile) -> Int {
        [
            file.path.utf8.count,
            file.relativePath.utf8.count,
            file.identity.canonicalPath.utf8.count,
            file.identity.contentToken.utf8.count,
            384,
            MemoryLayout<Int>.stride,
        ].reduce(0, saturatedAdd)
    }

    private static func estimatedMatchResultBytes(_ match: SearchMatch) -> Int {
        saturatedAdd(match.snippet.utf8.count, 128)
    }

    private static func saturatedAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}
