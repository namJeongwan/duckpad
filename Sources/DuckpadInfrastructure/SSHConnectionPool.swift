import Darwin
import DuckpadApplication
import DuckpadDomain
import Foundation

/// One foreground-owned OpenSSH master per destination/configuration. Only the
/// private control socket is shared; cancelling one request leaves peers alive.
public actor SSHConnectionPool {
    public static let shared = SSHConnectionPool()
    private struct Key: Hashable { let host: String; let configuration: URL? }
    private struct Entry {
        let id: UUID
        let socket: String
        let state: MasterState
        let worker: Task<Void, Never>
        var clients = 0
        var channels = 0
        var idle: Task<Void, Never>?
    }
    private final class MasterState: @unchecked Sendable {
        let process = SSHReadProcess()
        private let lock = NSLock()
        private var result: FileObservationError?
        func finish(_ error: FileObservationError) { lock.lock(); result = error; lock.unlock() }
        func failure() -> FileObservationError? { lock.lock(); defer { lock.unlock() }; return result }
    }
    private var entries: [Key: Entry] = [:]
    private var retiring: [UUID: Task<Void, Never>] = [:]
    private var stopped = false
    private let lifetime: @Sendable (Bool) -> Void
    private let idleTimeout: Duration
    public init(idleTimeout: Duration = .seconds(60), lifetime: @escaping @Sendable (Bool) -> Void = { _ in }) {
        self.idleTimeout = idleTimeout; self.lifetime = lifetime
    }

    public func execute(host: String, configuration: URL?, command: String, maximumOutput: Int) async throws -> Data {
        guard !stopped, RemoteFileLocation(host: host, path: "/") != nil else { throw FileObservationError.invalidResponse }
        try Task.checkCancellation()
        let key = Key(host: host, configuration: configuration)
        if let old = entries[key], old.state.failure() != nil {
            entries.removeValue(forKey: key); retire(old)
        }
        if entries[key] == nil {
            if entries.count >= 32, let idle = entries.first(where: { $0.value.clients == 0 }) {
                entries.removeValue(forKey: idle.key); retire(idle.value)
            }
            guard entries.count < 32 else { throw FileObservationError.unavailable }
            var template = Array("/tmp/duckpad-ssh.XXXXXX".utf8CString)
            guard let directory = mkdtemp(&template) else { throw FileObservationError.unavailable }
            let root = String(cString: directory), socket = root + "/control"
            let state = MasterState(), lifetime = lifetime
            let arguments = Self.options(configuration) + ["-M", "-N", "-S", socket,
                "-o", "ControlPersist=no", "-o", "ForkAfterAuthentication=no", "--", host]
            lifetime(true)
            let worker = Task.detached(priority: .utility) {
                defer { try? FileManager.default.removeItem(atPath: root); lifetime(false) }
                do {
                    _ = try state.process.run(executable: URL(fileURLWithPath: "/usr/bin/ssh"), arguments: arguments,
                                              maximumOutput: 1_024, timeout: nil)
                    state.finish(.unavailable)
                } catch { state.finish((error as? FileObservationError) ?? .unavailable) }
            }
            entries[key] = Entry(id: UUID(), socket: socket, state: state, worker: worker)
        }
        entries[key]!.idle?.cancel(); entries[key]!.idle = nil
        entries[key]!.clients += 1
        let entry = entries[key]!
        var channel = false
        defer { release(key, id: entry.id, channel: channel) }
        let process = SSHReadProcess()
        return try await withTaskCancellationHandler {
            let deadline = ContinuousClock.now + .seconds(15)
            while !FileManager.default.fileExists(atPath: entry.socket) {
                try Task.checkCancellation()
                if let error = entry.state.failure() { throw error }
                guard ContinuousClock.now < deadline else { throw FileObservationError.timedOut }
                try await Task.sleep(for: .milliseconds(10))
            }
            try Task.checkCancellation()
            while entries[key]?.id == entry.id, entries[key]!.channels >= 8 {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard entries[key]?.id == entry.id else { throw FileObservationError.unavailable }
            entries[key]!.channels += 1; channel = true
            // Never silently establish a second transport if the master died.
            let arguments = Self.options(configuration) + ["-S", entry.socket, "-o", "ControlMaster=no",
                "-o", "ProxyCommand=/usr/bin/false", "--", host, command]
            let worker = Task.detached(priority: .utility) {
                try process.run(executable: URL(fileURLWithPath: "/usr/bin/ssh"), arguments: arguments, maximumOutput: maximumOutput)
            }
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: { process.cancel() }
    }

    private func release(_ key: Key, id: UUID, channel: Bool) {
        guard entries[key]?.id == id else { return }
        entries[key]!.clients -= 1
        if channel { entries[key]!.channels -= 1 }
        guard entries[key]!.clients == 0 else { return }
        if !FileManager.default.fileExists(atPath: entries[key]!.socket) {
            if let removed = entries.removeValue(forKey: key) { retire(removed) }
            return
        }
        let timeout = idleTimeout
        entries[key]!.idle = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            await self?.expire(key, id: id)
        }
    }
    private func expire(_ key: Key, id: UUID) {
        guard entries[key]?.id == id, entries[key]?.clients == 0 else { return }
        if let removed = entries.removeValue(forKey: key) { retire(removed) }
    }
    private func retire(_ entry: Entry) {
        entry.idle?.cancel(); entry.state.process.cancel()
        retiring[entry.id] = entry.worker
        Task { [weak self] in
            await entry.worker.value
            await self?.finishedRetiring(entry.id)
        }
    }
    private func finishedRetiring(_ id: UUID) { retiring.removeValue(forKey: id) }
    public func shutdown() async {
        stopped = true
        let active = Array(entries.values)
        entries.removeAll()
        for entry in active { retire(entry) }
        // Include masters already removed by TTL, eviction or connect-cancel.
        // Their process reaping/socket cleanup still owns a helper transaction.
        let pending = Array(retiring.values)
        for worker in pending { await worker.value }
    }
    private static func options(_ configuration: URL?) -> [String] {
        (configuration.map { ["-F", $0.path] } ?? []) + ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2",
            "-o", "ClearAllForwardings=yes", "-o", "ForwardAgent=no", "-o", "ForwardX11=no",
            "-o", "PermitLocalCommand=no", "-o", "RemoteCommand=none", "-o", "RequestTTY=no"]
    }
}
