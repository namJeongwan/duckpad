import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import Foundation
import Testing

/// Opt-in stage measurements use generated files, never a user's documents.
@Suite(.serialized)
struct FolderSearchPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DUCKPAD_PROFILE_FOLDER_SEARCH"] == "1"))
    func generatedProjectSearchStages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let body = String(repeating: "let sampleValue = loadConfiguration(identifier: 12345) // source text\n", count: 500) + "let needleValue = 7\n"
        let data = Data(body.utf8)
        for index in 0..<256 { try data.write(to: root.appendingPathComponent("source-\(index).swift")) }
        let store = LocalFolderSearchFileStore(), clock = ContinuousClock()
        func report(_ name: String, _ duration: Duration) {
            let c = duration.components
            print("FOLDER_PROFILE \(name)=\(Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15)ms")
        }
        let start = clock.now
        let listing = try await store.enumerateTextCandidates(rootPath: root.path, maximumFiles: 1000, maximumDocumentBytes: 1_048_576, maximumTotalBytes: 32 * 1_048_576)
        report("enumerate_read_hash", start.duration(to: clock.now))
        var snapshots: [SearchBufferSnapshot] = []
        let decodeStart = clock.now
        for file in listing.files {
            let decoded = try TextFileCodec.decode(file.data)
            snapshots.append(.init(tabID: TabID(), title: file.relativePath, bufferID: BufferID(), revision: 0, utf8: Data(decoded.text.utf8)))
        }
        report("decode_including_line_endings", decodeStart.duration(to: clock.now))
        for matchCase in [false, true] {
            for pattern in ["absentNeedle", "needleValue", "sampleValue"] {
                let query = SearchQuery(pattern: pattern, options: .init(matchCase: matchCase))
                let scanStart = clock.now
                var count = 0
                for snapshot in snapshots { count += try SearchEngine.scan(in: snapshot, query: query, regexEngine: ICURegexEngine()).matches.count }
                report("scan_\(matchCase ? "case" : "nocase")_\(pattern)_\(count)", scanStart.duration(to: clock.now))
            }
        }
        let totalStart = clock.now
        let result = try await FolderSearchUseCase(store: store, regexEngine: ICURegexEngine()).search(rootPath: root.path, query: .init(pattern: "needleValue"))
        report("full_search_\(result.searchedFileCount)files_\(result.searchedByteCount)bytes", totalStart.duration(to: clock.now))
        let rg = URL(fileURLWithPath: "/opt/homebrew/bin/rg")
        if FileManager.default.isExecutableFile(atPath: rg.path) {
            let process = Process(); process.executableURL = rg
            process.arguments = ["--json", "--no-ignore", "-i", "needleValue", root.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            let rgStart = clock.now
            try process.run(); process.waitUntilExit()
            report("rg_reference_including_process_start", rgStart.duration(to: clock.now))
            #expect(process.terminationStatus == 0)
        }
        #expect(result.matchCount == 256)
    }
}
