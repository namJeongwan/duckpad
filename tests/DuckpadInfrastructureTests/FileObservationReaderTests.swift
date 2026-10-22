import DuckpadApplication
import DuckpadDomain
@testable import DuckpadInfrastructure
import Foundation
import Testing

@Suite struct FileObservationReaderTests {
    @Test func localReaderTracksAppendReplacementTruncationAndBoundedReads() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("app.log")
        try Data("first".utf8).write(to: file)
        let reader = LocalFileObservationReader()
        var read = try await reader.read(.local(file.path), after: nil, maximumBytes: 3)
        #expect(read.data == Data("fir".utf8)); #expect(read.hasMore)
        read = try await reader.read(.local(file.path), after: read.cursor, maximumBytes: 64)
        #expect(read.data == Data("st".utf8)); #expect(!read.reset)
        try Data("replaced 한글".utf8).write(to: file, options: .atomic)
        read = try await reader.read(.local(file.path), after: read.cursor, maximumBytes: 64)
        #expect(read.reset); #expect(read.data == Data("replaced 한글".utf8))
        try Data("short".utf8).write(to: file)
        read = try await reader.read(.local(file.path), after: read.cursor, maximumBytes: 64)
        #expect(read.reset); #expect(read.data == Data("short".utf8))
        var decoder = FileTailUTF8Decoder()
        #expect(throws: FileObservationError.self) { _ = try decoder.decode(Data([0xFF])) }
    }

    @Test(arguments: ["/bin/sh", "/bin/zsh"]) func sshRangeProtocolQuotesPathsAndDetectsRotationOnMacOS(shell: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("app ' $(touch SHOULD_NOT_EXIST).log")
        try Data("first 한글\n".utf8).write(to: file)
        let location = try #require(RemoteFileLocation(host: "test-alias", path: file.path))
        func run(_ cursor: FileObservationCursor?) async throws -> FileObservationRead {
            let command = "cd '" + root.path + "'\n" + SSHFileObservationReader.shellCommand(remote: location, cursor: cursor, maximumBytes: 4)
            let bytes = try await Task.detached {
                try SSHReadProcess().run(executable: URL(fileURLWithPath: shell), arguments: ["-c", command], maximumOutput: 516)
            }.value
            return try SSHFileObservationReader.parse(bytes, maximumBytes: 4)
        }
        var read = try await run(nil)
        #expect(read.data == Data("firs".utf8)); #expect(read.hasMore)
        read = try await run(read.cursor)
        #expect(read.data.count <= 4)
        try Data("new".utf8).write(to: file, options: .atomic)
        read = try await run(read.cursor)
        #expect(read.reset); #expect(read.data == Data("new".utf8))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("SHOULD_NOT_EXIST").path))
    }

    @Test func sshProcessEnforcesOutputTimeoutAndCancellation() async throws {
        #expect(throws: FileObservationError.tooLarge) {
            _ = try SSHReadProcess().run(executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: [], maximumOutput: 128)
        }
        #expect(throws: FileObservationError.timedOut) {
            _ = try SSHReadProcess().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"], maximumOutput: 128, timeout: .milliseconds(30))
        }
        let process = SSHReadProcess()
        let work = Task.detached {
            try process.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"], maximumOutput: 128)
        }
        try await Task.sleep(for: .milliseconds(20))
        process.cancel()
        do { _ = try await work.value; Issue.record("Cancelled SSH child succeeded") }
        catch { #expect(error as? FileObservationError == .cancelled) }
    }

    @Test func sshResponseRejectsMalformedOrUnboundedMetadata() throws {
        for data in ["banner\n", "DUCKPAD1 a:b 5 0 0\nhello", "DUCKPAD1 1:2 1 2 0\n", "DUCKPAD1 1:2 3 0 0\nlong"] {
            #expect(throws: FileObservationError.self) {
                _ = try SSHFileObservationReader.parse(Data(data.utf8), maximumBytes: 3)
            }
        }
        #expect(RemoteFileLocation(host: "-oProxyCommand=bad", path: "/tmp/log") == nil)
        #expect(RemoteFileLocation(host: "host;bad", path: "/tmp/log") == nil)
        #expect(RemoteFileLocation(host: "host", path: "relative") == nil)
    }
}
