import Darwin
import DuckpadApplication
import DuckpadDomain
import Foundation

/// rg handles ignore-aware discovery; each file is confirmed as it arrives.
/// SearchEngine confirms immutable bytes; it remains the authority for replacement.
public struct RipgrepFolderSearchBackend: FolderSearchBackend {
    public let executable: URL
    private let regexEngine: any RegexEnginePort
    private let timeout: Duration
    private let maximumDiscoveryBytes: Int

    public init(executable: URL, regexEngine: any RegexEnginePort = ICURegexEngine(), timeout: Duration = .seconds(30), maximumDiscoveryBytes: Int = 32 * 1_024 * 1_024) {
        self.executable = executable; self.regexEngine = regexEngine; self.timeout = timeout
        self.maximumDiscoveryBytes = maximumDiscoveryBytes
    }
    public static var bundledExecutable: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/rg")
        // A damaged installed helper must fail visibly instead of changing ignore scope.
        return Bundle.main.bundleURL.pathExtension == "app" ? url : nil
    }
    public func search(rootPath: String, query: SearchQuery, limits: FolderSearchLimits, excluding: FolderSearchExclusions,
                       onProgress: FolderSearchProgress?) async throws(FolderSearchFailure) -> FolderSearchResultSet {
        guard maximumDiscoveryBytes > 0 else { throw .invalidLimits }
        let process = RipgrepProcess(executable: executable, timeout: timeout)
        let worker = Task.detached(priority: .userInitiated) {
            try self.searchBlocking(rootPath: rootPath, query: query, limits: limits, excluding: excluding, process: process, onProgress: onProgress)
        }
        do {
            return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel(); process.cancel() }
        } catch let error as FolderSearchFailure { throw error }
        catch let error as SearchFailure { throw .search(error) }
        catch { throw .enumerationFailed("folder search could not be completed") }
    }

    private func searchBlocking(rootPath: String, query: SearchQuery, limits: FolderSearchLimits,
                                excluding: FolderSearchExclusions, process: RipgrepProcess, onProgress: FolderSearchProgress?) throws -> FolderSearchResultSet {
        let root = try FolderSearchRoot(path: rootPath)
        let mask = try query.fileMask.map(SearchFileMask.init)
        var documents: [FolderSearchDocumentResult] = []
        var files = 0, bytes = 0, skipped = 0, matches = 0
        var resultBytes = root.url.path.utf8.count + 64
        var truncated = resultBytes > limits.maximumResultBytes
        var exhaustedResults = truncated
        var lastProgress = ContinuousClock.now
        var reported = false

        func result(incomplete: Bool) -> FolderSearchResultSet {
            .init(rootPath: root.url.path, documents: documents, isTruncated: incomplete || truncated,
                  searchedFileCount: files, skippedFileCount: skipped, searchedByteCount: bytes)
        }
        func progress() {
            guard let onProgress else { return }
            let now = ContinuousClock.now
            if !reported && !documents.isEmpty || lastProgress.duration(to: now) >= .milliseconds(50) {
                reported = true; lastProgress = now; onProgress(result(incomplete: true))
            }
        }
        func confirm(_ file: FolderSearchFile) throws {
            try process.check()
            let utf8: Data
            do { utf8 = try FolderSearchUseCase.searchableUTF8(file.data) }
            catch { skipped += 1; return }
            if query.options.mode == .regularExpression && utf8.count > limits.maximumRegularExpressionBytes {
                skipped += 1; truncated = true; return
            }
            let snapshot = SearchBufferSnapshot(tabID: TabID(), title: file.relativePath, bufferID: BufferID(), revision: 0, utf8: utf8)
            let scan = try SearchEngine.scan(in: snapshot, query: query, limit: limits.maximumMatches - matches + 1,
                regexEngine: regexEngine, maximumResultBytes: max(0, limits.maximumResultBytes - resultBytes))
            try process.check()
            var accepted: [FolderSearchMatch] = []
            let documentBytes = file.path.utf8.count + file.relativePath.utf8.count + file.identity.canonicalPath.utf8.count
                + file.identity.contentToken.utf8.count + 384 + MemoryLayout<Int>.stride
            for source in scan.matches {
                let needed = source.snippet.utf8.count + 128 + (accepted.isEmpty ? documentBytes : 0)
                guard matches < limits.maximumMatches, needed <= limits.maximumResultBytes - resultBytes else { truncated = true; exhaustedResults = true; break }
                resultBytes += needed; matches += 1
                accepted.append(.init(range: source.range, line: source.line, column: source.column, snippet: source.snippet))
            }
            if !accepted.isEmpty {
                documents.append(.init(path: file.path, relativePath: file.relativePath, identity: file.identity, matches: accepted))
            }
            if !scan.isComplete || matches == limits.maximumMatches { truncated = true; exhaustedResults = true }
            progress()
        }
        if truncated { return result(incomplete: false) }
        let status = try process.run(arguments: ["--no-config", "--no-messages", "--no-ignore-global", "--no-ignore-parent", "--no-require-git", "--files", "--null", "."], directory: root.descriptor, maximumOutputBytes: maximumDiscoveryBytes) { record in
            try process.check()
            guard let emitted = String(data: record, encoding: .utf8) else {
                throw FolderSearchFailure.enumerationFailed("ripgrep returned an unsupported path")
            }
            let relative = emitted.hasPrefix("./") ? String(emitted.dropFirst(2)) : emitted
            if let mask, !mask.matches(relative) { return true }
            if excluding.contains(root.url.appendingPathComponent(relative).path) { return true }
            guard files < limits.maximumFiles else { truncated = true; return false }
            guard let handle = root.open(relative) else { skipped += 1; return true }
            defer { Darwin.close(handle.descriptor) }
            guard handle.info.st_size <= limits.maximumDocumentBytes else { skipped += 1; return true }
            guard handle.info.st_size <= limits.maximumTotalBytes - bytes else { truncated = true; return false }
            files += 1; bytes += Int(handle.info.st_size)
            let file: FolderSearchFile
            do {
                guard let read = try root.read(handle, maximumBytes: Int(handle.info.st_size)) else { skipped += 1; return true }
                file = read
            } catch let failure as FolderSearchFailure { throw failure }
            catch { skipped += 1; return true }
            try confirm(file)
            return !exhaustedResults
        }
        if status.outputLimitReached { truncated = true }
        if status.status != 0 && status.status != 1 { throw FolderSearchFailure.enumerationFailed("ripgrep could not enumerate the complete folder") }
        try root.validate(); try process.check()
        return result(incomplete: false)
    }
}
