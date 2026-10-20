import Darwin
import DuckpadApplication
import DuckpadDomain
import Foundation
import Testing
@testable import DuckpadInfrastructure

private final class RipgrepProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [FolderSearchResultSet] = []
    func add(_ value: FolderSearchResultSet) { lock.lock(); values.append(value); lock.unlock() }
    func snapshots() -> [FolderSearchResultSet] { lock.lock(); defer { lock.unlock() }; return values }
}

@Suite(.serialized)
struct RipgrepFolderSearchTests {
    private var executable: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/ripgrep/15.1.0/native/rg")
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-rg-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func search(_ root: URL, _ query: SearchQuery, limits: FolderSearchLimits = .init(),
                        progress: FolderSearchProgress? = nil) async throws -> FolderSearchResultSet {
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))
        return try await FolderSearchUseCase(store: LocalFolderSearchFileStore(), regexEngine: ICURegexEngine(), limits: limits,
            backend: RipgrepFolderSearchBackend(executable: executable)).search(rootPath: root.path, query: query, onProgress: progress)
    }
    @Test func ignoresMasksUnicodeAndUTF16KeepTheSameConfirmedRanges() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("ignored/\n*.log\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ignored"), withIntermediateDirectories: true)
        try Data("duck".utf8).write(to: root.appendingPathComponent("ignored/a.swift"))
        try Data("duck".utf8).write(to: root.appendingPathComponent("a.log"))
        try Data("duck DUCK duckling\nStraße ſ K 한글".utf8).write(to: root.appendingPathComponent("source.SWIFT"))
        try TextFileCodec.encode("한글 DUCK\r\nduck", encoding: .utf16LittleEndian, byteOrderMark: .present).write(to: root.appendingPathComponent("unicode.txt"))
        let result = try await search(root, .init(pattern: "duck", options: .init(wholeWord: true)))
        #expect(result.matchCount == 4)
        #expect(Set(result.documents.map(\.relativePath)) == ["source.SWIFT", "unicode.txt"])
        #expect(!result.isTruncated)
        let masked = try await search(root, .init(pattern: "duck", fileMask: "*.swift;!*.txt"))
        #expect(masked.documents.map(\.relativePath) == ["source.SWIFT"])
        #expect(masked.matchCount == 3)
        for pattern in ["strasse", "s", "k", "K", "한글"] {
            let fast = try await search(root, .init(pattern: pattern, fileMask: "*.swift"))
            let baseline = try await FolderSearchUseCase(store: LocalFolderSearchFileStore(), regexEngine: ICURegexEngine())
                .search(rootPath: root.path, query: .init(pattern: pattern, fileMask: "*.swift"))
            #expect(fast.documents.map(\.matches) == baseline.documents.filter { $0.relativePath == "source.SWIFT" }.map(\.matches))
        }
    }
    @Test func regexExtendedNulAndMultilinePatternsRetainNativeSemantics() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("ab12\r\nab34\r한글 A\0B\nC\nDUCK duck".utf8).write(to: root.appendingPathComponent("-sample.txt"))
        let queries: [SearchQuery] = [
            .init(pattern: "(?<=ab)(\\d+)", options: .init(mode: .regularExpression)),
            .init(pattern: "ab.*한글", options: .init(mode: .regularExpression, dotMatchesNewline: true)),
            .init(pattern: "(?=ab)", options: .init(mode: .regularExpression)),
            .init(pattern: "\\0B\\nC", options: .init(mode: .extended)),
            .init(pattern: "A\0B\nC", options: .init(matchCase: true)),
            .init(pattern: "DUCK", options: .init(matchCase: true)),
        ]
        for query in queries {
            let fast = try await search(root, query)
            let baseline = try await FolderSearchUseCase(store: LocalFolderSearchFileStore(), regexEngine: ICURegexEngine()).search(rootPath: root.path, query: query)
            #expect(fast.documents.map(\.matches) == baseline.documents.map(\.matches))
            #expect(!fast.isTruncated)
        }
    }
    @Test func filesAreConfirmedBeforeInputLimitsStopEnumeration() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<40 { try Data("needle".utf8).write(to: root.appendingPathComponent("source-\(index).txt")) }
        let byFiles = try await search(root, .init(pattern: "needle"), limits: .init(maximumFiles: 1))
        #expect(byFiles.isTruncated); #expect(byFiles.matchCount == 1); #expect(byFiles.searchedFileCount == 1)
        let byBytes = try await search(root, .init(pattern: "needle"), limits: .init(maximumTotalBytes: 12))
        #expect(byBytes.isTruncated); #expect(byBytes.matchCount == 2); #expect(byBytes.searchedByteCount == 12)
        let byMatches = try await search(root, .init(pattern: "needle"), limits: .init(maximumMatches: 2))
        #expect(byMatches.isTruncated); #expect(byMatches.matchCount == 2)
    }
    @Test func progressIsIncompleteAndCancellingOneSearchDoesNotPoisonTheNext() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let data = Data((String(repeating: "source text\n", count: 1000) + "needle\n").utf8)
        for index in 0..<256 { try data.write(to: root.appendingPathComponent("source-\(index).txt")) }
        let probe = RipgrepProgressProbe(), gate = DispatchSemaphore(value: 0)
        let task = Task { try await search(root, .init(pattern: "needle"), progress: {
            probe.add($0); _ = gate.wait(timeout: .now() + 2)
        }) }
        for _ in 0..<500 where probe.snapshots().isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        #expect(!probe.snapshots().isEmpty)
        #expect(probe.snapshots().allSatisfy { $0.isTruncated })
        task.cancel(); gate.signal()
        do { _ = try await task.value; Issue.record("cancelled search completed") }
        catch let failure as FolderSearchFailure { #expect(failure == .search(.cancelled)) }
        let next = try await search(root, .init(pattern: "needle"))
        #expect(next.matchCount == 256); #expect(!next.isTruncated)
    }
    @Test func verifiedInputBytesRemainImmutableAndSymlinksAreExcluded() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("source.txt")
        try Data("needle".utf8).write(to: path)
        let access = try FolderSearchRoot(path: root.path)
        let handle = try #require(access.open("source.txt")); defer { Darwin.close(handle.descriptor) }
        let read = try access.read(handle, maximumBytes: 6)
        let frozen = try #require(read)
        try Data("changed".utf8).write(to: path)
        #expect(frozen.data == Data("needle".utf8))
        #expect(try Data(contentsOf: path) != frozen.data)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root)
        #expect(access.open("link/source.txt") == nil)
    }
    @Test func discoveryOutputBudgetStopsNormallyInsteadOfFailingTheSearch() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let access = try FolderSearchRoot(path: root.path)
        let process = RipgrepProcess(executable: URL(fileURLWithPath: "/usr/bin/printf"), timeout: .seconds(2))
        let status = try process.run(arguments: [String(repeating: "entry\\0", count: 256)], directory: access.descriptor,
                                     maximumOutputBytes: 64) { _ in true }
        #expect(status.status == 0)
        #expect(status.outputLimitReached)
    }
    @Test func maskedDiscoveryBudgetReturnsAnExplicitlyTruncatedResult() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<100 { try Data("needle".utf8).write(to: root.appendingPathComponent("source-\(index).txt")) }
        let backend = RipgrepFolderSearchBackend(executable: executable, maximumDiscoveryBytes: 64)
        let result = try await FolderSearchUseCase(store: LocalFolderSearchFileStore(), regexEngine: ICURegexEngine(), backend: backend)
            .search(rootPath: root.path, query: .init(pattern: "needle", fileMask: "*.absent"))
        #expect(result.isTruncated)
        #expect(result.matchCount == 0)
        #expect(result.searchedFileCount == 0)
    }
    @Test func confirmedMatchesSurviveDiscoveryOutputTruncation() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("needle".utf8).write(to: root.appendingPathComponent("source.txt"))
        let helper = root.appendingPathComponent("discovery.sh")
        let script = "#!/bin/sh\nprintf 'source.txt\\0'\n/bin/sleep 0.05\nprintf '" + String(repeating: "source.txt\\0", count: 256) + "'\n"
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let backend = RipgrepFolderSearchBackend(executable: helper, maximumDiscoveryBytes: 64)
        let result = try await FolderSearchUseCase(store: LocalFolderSearchFileStore(), regexEngine: ICURegexEngine(), backend: backend)
            .search(rootPath: root.path, query: .init(pattern: "needle"))
        #expect(result.isTruncated)
        #expect(result.matchCount == 1)
        #expect(result.documents.map(\.relativePath) == ["source.txt"])
    }
    @Test func deadlinesAndMalformedOutputFailWithoutHanging() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let access = try FolderSearchRoot(path: root.path)
        let slow = RipgrepProcess(executable: URL(fileURLWithPath: "/bin/sleep"), timeout: .milliseconds(30))
        let start = ContinuousClock.now
        do { _ = try slow.run(arguments: ["5"], directory: access.descriptor) { _ in true }; Issue.record("expected deadline") }
        catch let failure as FolderSearchFailure { #expect(failure == .search(.timedOut)) }
        #expect(start.duration(to: .now) < .seconds(1))
        let bounded = RipgrepProcess(executable: URL(fileURLWithPath: "/usr/bin/printf"), timeout: .seconds(2))
        let exit = try bounded.run(arguments: [String(repeating: "x", count: 4096)], directory: access.descriptor, maximumOutputBytes: 64) { _ in true }
        #expect(exit.status == 0 && exit.outputLimitReached)
        let malformed = RipgrepProcess(executable: URL(fileURLWithPath: "/usr/bin/printf"), timeout: .seconds(2))
        do { _ = try malformed.run(arguments: ["unterminated"], directory: access.descriptor) { _ in true }; Issue.record("expected incomplete record failure") }
        catch let failure as FolderSearchFailure { if case .enumerationFailed = failure {} else { Issue.record("unexpected failure") } }
    }
}
