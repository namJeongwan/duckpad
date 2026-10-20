import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import Foundation

/// Exercises the signed child from the actual sandboxed app, using generated files.
enum RipgrepPackagedSmoke {
    private final class FirstResult: @unchecked Sendable {
        private let lock = NSLock()
        private var instant: ContinuousClock.Instant?
        func record(_ result: FolderSearchResultSet) {
            guard result.matchCount > 0 else { return }
            lock.lock(); if instant == nil { instant = .now }; lock.unlock()
        }
        func milliseconds(since start: ContinuousClock.Instant) -> Double? {
            lock.lock(); defer { lock.unlock() }
            return instant.map { RipgrepPackagedSmoke.milliseconds(start.duration(to: $0)) }
        }
    }
    private static func milliseconds(_ value: Duration) -> Double {
        let c = value.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }
    static func run() async throws {
        guard let helper = RipgrepFolderSearchBackend.bundledExecutable else { throw SmokeFailure.missingHelper }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-rg-smoke-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("ignored/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ignored"), withIntermediateDirectories: true)
        try Data("needleValue".utf8).write(to: root.appendingPathComponent("ignored/excluded.swift"))
        let data = Data((String(repeating: "let sampleValue = loadConfiguration(identifier: 12345) // source text\n", count: 500) + "let needleValue = 7\n").utf8)
        for index in 0..<256 { try data.write(to: root.appendingPathComponent("source-\(index).swift")) }
        let useCase = FolderSearchUseCase(store: LocalFolderSearchFileStore(), regexEngine: ICURegexEngine(),
            backend: RipgrepFolderSearchBackend(executable: helper))
        for pattern in ["needleValue", "absentNeedle"] {
            let first = FirstResult(), start = ContinuousClock.now
            let result = try await useCase.search(rootPath: root.path, query: .init(pattern: pattern), onProgress: { first.record($0) })
            guard result.matchCount == (pattern == "needleValue" ? 256 : 0), !result.isTruncated,
                  result.searchedFileCount == 256 else { throw SmokeFailure.incorrectResults }
            print("DUCKPAD_RG_PROFILE pattern=\(pattern) first_ms=\(first.milliseconds(since: start).map(String.init(describing:)) ?? "none") total_ms=\(milliseconds(start.duration(to: .now))) files=\(result.searchedFileCount) bytes=\(result.searchedByteCount)")
        }
        let baseline = FolderSearchUseCase(store: LocalFolderSearchFileStore(), regexEngine: ICURegexEngine())
        for pattern in ["needleValue", "absentNeedle"] {
            let query = SearchQuery(pattern: pattern, fileMask: "source-*.swift")
            let start = ContinuousClock.now
            let result = try await baseline.search(rootPath: root.path, query: query)
            guard result.matchCount == (pattern == "needleValue" ? 256 : 0), !result.isTruncated,
                  result.searchedFileCount == 256 else { throw SmokeFailure.incorrectResults }
            print("DUCKPAD_NATIVE_PROFILE pattern=\(pattern) total_ms=\(milliseconds(start.duration(to: .now))) files=\(result.searchedFileCount) bytes=\(result.searchedByteCount)")
        }
        let utf16 = try TextFileCodec.encode("한글 Straße ab12\r\n", encoding: .utf16LittleEndian, byteOrderMark: .present)
        try utf16.write(to: root.appendingPathComponent("unicode.txt"))
        for query in [SearchQuery(pattern: "strasse", fileMask: "*.txt"),
                      SearchQuery(pattern: "(?<=ab)(\\d+)", options: .init(mode: .regularExpression), fileMask: "*.txt")] {
            let result = try await useCase.search(rootPath: root.path, query: query)
            guard result.matchCount == 1, !result.isTruncated else { throw SmokeFailure.incorrectResults }
        }
        try Data("hiddenNeedle".utf8).write(to: root.appendingPathComponent(".hidden.txt"))
        for visible in [false, true] {
            let result = try await useCase.search(rootPath: root.path,
                query: .init(pattern: "hiddenNeedle", options: .init(includeHiddenFiles: visible), fileMask: ".hidden.txt"))
            guard result.matchCount == (visible ? 1 : 0), !result.isTruncated else { throw SmokeFailure.incorrectResults }
        }
        let indexer = LocalFolderFileNameIndex(executable: helper)
        let names = try await indexer.index(in: root, includeHiddenFiles: true)
        guard names.relativePaths.contains(".hidden.txt"),
              try await indexer.readFile(in: root, root: names.root, relativePath: ".hidden.txt").result.data == Data("hiddenNeedle".utf8) else {
            throw SmokeFailure.incorrectResults
        }
        print("DUCKPAD_RIPGREP_READY signed sandbox discovery + ignore rules + native immutable reads + UTF-16 + ICU regex")
    }
    static func runWorkspace(store: LocalWorkspaceRootStore, expectDiscoveryLimit: Bool) async throws {
        let roots = try await store.loadRoots()
        guard let helper = RipgrepFolderSearchBackend.bundledExecutable,
              !roots.isEmpty, roots.allSatisfy(\.isAvailable) else { throw SmokeFailure.missingHelper }
        let search = FolderSearchUseCase(store: LocalFolderSearchFileStore(), regexEngine: ICURegexEngine(),
            backend: RipgrepFolderSearchBackend(executable: helper))
        for root in roots {
            for query in [SearchQuery(pattern: "desc"), SearchQuery(pattern: "desc", fileMask: "*.duckpad-missing-regression")] {
                let result = try await search.search(rootPath: root.canonicalPath, query: query)
                if query.fileMask != nil {
                    guard result.matchCount == 0, !expectDiscoveryLimit || result.isTruncated else { throw SmokeFailure.incorrectResults }
                }
                print("DUCKPAD_RG_WORKSPACE_READY masked=\(query.fileMask != nil) matches=\(result.matchCount) files=\(result.searchedFileCount) truncated=\(result.isTruncated)")
            }
        }
    }
    private enum SmokeFailure: Error { case missingHelper, incorrectResults }
}
