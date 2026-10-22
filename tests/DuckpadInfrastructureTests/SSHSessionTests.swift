import Darwin
import DuckpadApplication
import DuckpadDomain
@testable import DuckpadInfrastructure
import Foundation
import Testing

private final class MasterLifetime: @unchecked Sendable {
    private let condition = NSCondition()
    private var value = 0, closing = false, closed = false
    private var hold = false, enteredShutdown = false
    func change(_ active: Bool) {
        condition.lock(); defer { condition.unlock() }
        if !active {
            closing = true
            while hold { condition.wait() }
        }
        value += active ? 1 : -1
    }
    var count: Int { condition.lock(); defer { condition.unlock() }; return value }
    var isClosing: Bool { condition.lock(); defer { condition.unlock() }; return closing }
    var didClose: Bool { condition.lock(); defer { condition.unlock() }; return closed }
    func holdRetirement() { condition.lock(); hold = true; condition.unlock() }
    func releaseRetirement() { condition.lock(); hold = false; condition.broadcast(); condition.unlock() }
    var didEnterShutdown: Bool { condition.lock(); defer { condition.unlock() }; return enteredShutdown }
    func markEnteredShutdown() { condition.lock(); enteredShutdown = true; condition.unlock() }
    func markClosed() { condition.lock(); closed = true; condition.unlock() }
}

@Suite struct SSHSessionTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @Test func hostDiscoveryHandlesIncludesCyclesAndNeverExecutesOrBlocksOnSpecialFiles() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let ssh = root.appendingPathComponent(".ssh"), includes = ssh.appendingPathComponent("conf.d")
        try FileManager.default.createDirectory(at: includes, withIntermediateDirectories: true)
        try Data("Host=primary secondary *.invalid !excluded\nInclude conf.d/*\nMatch exec \"touch SHOULD_NOT_EXIST\"\n".utf8).write(to: ssh.appendingPathComponent("config"))
        try Data("hOsT \"한글\" third # comment\nInclude config\n".utf8).write(to: includes.appendingPathComponent("aliases"))
        #expect(mkfifo(includes.appendingPathComponent("fifo").path, 0o600) == 0)
        let clock = ContinuousClock(); let start = clock.now
        let aliases = try SSHHostCatalog(home: root).hosts(configuration: ssh.appendingPathComponent("config"))
        #expect(Set(aliases) == Set(["primary", "secondary", "third"]))
        #expect(start.duration(to: clock.now) < .seconds(1))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("SHOULD_NOT_EXIST").path))
        let cancelled = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try SSHHostCatalog(home: root).hosts(configuration: ssh.appendingPathComponent("config"))
        }
        do { _ = try await cancelled.value; Issue.record("Cancelled discovery succeeded") } catch is CancellationError { }
    }
    @Test(arguments: ["/bin/sh", "/bin/zsh"]) func directoryProtocolQuotesPathsAndPreservesHiddenAndUnicodeFiles(shell: String) async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("logs ' $(touch SHOULD_NOT_EXIST)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("child"), withIntermediateDirectories: true)
        for name in [".hidden", "a 한글🦆.log", "quote'file", "line\nbreak"] { try Data().write(to: folder.appendingPathComponent(name)) }
        let command = "cd '" + root.path + "'\n" + SSHDirectoryReader.command(path: folder.path)
        let data = try await Task.detached { try SSHReadProcess().run(executable: URL(fileURLWithPath: shell), arguments: ["-c", command], maximumOutput: 2 * 1_024 * 1_024) }.value
        let listing = try SSHDirectoryReader.parse(data)
        let physicalPath = try #require(realpath(folder.path, nil))
        defer { free(physicalPath) }
        #expect(listing.path == String(cString: physicalPath))
        #expect(listing.entries.first == .init(name: "child", isDirectory: true))
        #expect(Set(listing.entries.map(\.name)) == Set(["child", ".hidden", "a 한글🦆.log", "quote'file"]))
        #expect(!listing.isTruncated)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("SHOULD_NOT_EXIST").path))
        #expect(throws: FileObservationError.self) { _ = try SSHDirectoryReader.parse(Data("DUCKPADDIR1\0/log\0F\0bad\0".utf8)) }
        let truncated = try SSHDirectoryReader.parse(Data("DUCKPADDIR1\0/log\0F\0a\0T\0".utf8))
        #expect(truncated.isTruncated)
        for path in [folder.appendingPathComponent("missing").path, folder.appendingPathComponent("quote'file").path] {
            let command = SSHDirectoryReader.command(path: path)
            let response = try await Task.detached {
                try SSHReadProcess().run(executable: URL(fileURLWithPath: shell), arguments: ["-c", command], maximumOutput: 1_024)
            }.value
            #expect(throws: FileObservationError.directoryUnavailable) { _ = try SSHDirectoryReader.parse(response) }
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DUCKPAD_TEST_SSH_CONFIGURATION"] != nil))
    func realSSHReusesTransportLimitsChannelsAndIsolatesCancellation() async throws {
        let environment = ProcessInfo.processInfo.environment
        let configuration = URL(fileURLWithPath: try #require(environment["DUCKPAD_TEST_SSH_CONFIGURATION"]))
        let root = try #require(environment["DUCKPAD_TEST_SSH_ROOT"])
        let lifetime = MasterLifetime()
        let pool = SSHConnectionPool(idleTimeout: .milliseconds(200), lifetime: { lifetime.change($0) })
        do {
            let first = try await pool.execute(host: "fixture", configuration: configuration, command: "printf '%s' \"$SSH_CONNECTION\"", maximumOutput: 512)
            let listing = try await SSHDirectoryReader(pool: pool, configuration: configuration).list(host: "fixture", path: root)
            #expect(listing.entries.contains { $0.name == "a.log" })
            let reader = SSHFileObservationReader(configuration: configuration, pool: pool)
            for name in ["a.log", "b.log"] {
                let read = try await reader.read(.ssh(RemoteFileLocation(host: "fixture", path: root + "/" + name)!), after: nil, maximumBytes: 16_384)
                #expect(read.data == Data("한글 🦆\n".utf8))
            }
            let connections = try await withThrowingTaskGroup(of: Data.self) { group in
                for _ in 0..<12 {
                    group.addTask { try await pool.execute(host: "fixture", configuration: configuration, command: "sleep 0.05; printf '%s' \"$SSH_CONNECTION\"", maximumOutput: 512) }
                }
                var values = [Data](); for try await value in group { values.append(value) }; return values
            }
            #expect(connections.count == 12 && connections.allSatisfy { $0 == first })
            let cancelled = Task { try await pool.execute(host: "fixture", configuration: configuration, command: "sleep 60", maximumOutput: 128) }
            try await Task.sleep(for: .milliseconds(50)); cancelled.cancel()
            let start = ContinuousClock.now
            do { _ = try await cancelled.value; Issue.record("Cancelled SSH request succeeded") } catch { }
            #expect(start.duration(to: .now) < .seconds(2))
            let next = try await pool.execute(host: "fixture", configuration: configuration, command: "printf '%s' \"$SSH_CONNECTION\"", maximumOutput: 512)
            #expect(next == first)
            try await Task.sleep(for: .milliseconds(400))
            let reconnected = try await pool.execute(host: "fixture", configuration: configuration, command: "printf '%s' \"$SSH_CONNECTION\"", maximumOutput: 512)
            #expect(reconnected != first)
            await pool.shutdown()
            #expect(lifetime.count == 0)
        } catch { await pool.shutdown(); throw error }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DUCKPAD_TEST_SSH_CONFIGURATION"] != nil))
    func shutdownWaitsForMasterAlreadyRetiredByIdleExpiry() async throws {
        let configuration = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["DUCKPAD_TEST_SSH_CONFIGURATION"]))
        let lifetime = MasterLifetime(); lifetime.holdRetirement()
        defer { lifetime.releaseRetirement() }
        let pool = SSHConnectionPool(idleTimeout: .milliseconds(1), lifetime: { lifetime.change($0) })
        do {
            _ = try await pool.execute(host: "fixture", configuration: configuration, command: "true", maximumOutput: 128)
            for _ in 0..<500 where !lifetime.isClosing { try await Task.sleep(for: .milliseconds(5)) }
            #expect(lifetime.isClosing)
            let closing = Task { lifetime.markEnteredShutdown(); await pool.shutdown(); lifetime.markClosed() }
            for _ in 0..<500 where !lifetime.didEnterShutdown { try await Task.sleep(for: .milliseconds(5)) }
            #expect(lifetime.didEnterShutdown)
            try await Task.sleep(for: .milliseconds(30))
            #expect(!lifetime.didClose)
            lifetime.releaseRetirement()
            await closing.value
            #expect(lifetime.count == 0 && lifetime.didClose)
            do {
                _ = try await pool.execute(host: "fixture", configuration: configuration, command: "true", maximumOutput: 128)
                Issue.record("Closed pool reconnected")
            } catch { }
        } catch { lifetime.releaseRetirement(); await pool.shutdown(); throw error }
    }

}
