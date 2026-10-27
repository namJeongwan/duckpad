import Foundation
import Darwin
import XPC
import DuckpadPluginSupport
import DuckpadTerminalBridge
import DuckpadApplication
import DuckpadInfrastructure

private final class ShellSession: NSObject, DuckpadTerminalHostProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [UUID: Task<Void, Never>] = [:]
    private let remotePool = SSHConnectionPool(lifetime: { active in
        if active { xpc_transaction_begin() } else { xpc_transaction_end() }
    })
    private var master: FileHandle?
    private var child: pid_t = 0
    private var stopped = false
    private var started = false
    private var exitStatus: Int32?
    private var exitReply: ((Int32) -> Void)?
    private let home: String
    private let name: String

    init(home: String, name: String) { self.home = home; self.name = name }

    func readRemoteFile(_ data: Data, requestID: String, withReply reply: @escaping @Sendable (Data?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !started, !stopped, data.count <= 32 * 1_024, observations.count < 64,
              let id = UUID(uuidString: requestID), observations[id] == nil,
              let request = try? JSONDecoder().decode(RemoteFileReadRequest.self, from: data) else { reply(nil); return }
        xpc_transaction_begin()
        observations[id] = Task { [self] in
            let response: RemoteFileReadResponse
            do {
                if let path = request.configurationPath {
                    guard path.hasPrefix("/"), path.utf8.count <= 16_384,
                          !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw FileObservationError.invalidResponse }
                }
                let configuration = request.configurationPath.map { URL(fileURLWithPath: $0) }
                switch request.operation {
                case .read:
                    let reader = SSHFileObservationReader(configuration: configuration, pool: remotePool)
                    response = .init(read: try await reader.read(.ssh(request.location), after: request.cursor, maximumBytes: request.maximumBytes))
                case .directory:
                    let reader = SSHDirectoryReader(pool: remotePool, configuration: configuration)
                    response = .init(directory: try await reader.list(host: request.location.host, path: request.homeDirectory ? nil : request.location.path))
                case .hosts:
                    let worker = Task.detached { try SSHHostCatalog().hosts(configuration: configuration) }
                    response = .init(hosts: try await withTaskCancellationHandler {
                        try await worker.value
                    } onCancel: { worker.cancel() })
                }
            } catch {
                response = .init(error: (error as? FileObservationError) ?? .unavailable)
            }
            reply(try? JSONEncoder().encode(response))
            finishObservation(id)
            xpc_transaction_end()
        }
    }
    func cancelRemoteFile(_ requestID: String) {
        guard let id = UUID(uuidString: requestID) else { return }
        lock.lock(); defer { lock.unlock() }
        observations[id]?.cancel()
    }
    private func finishObservation(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        observations.removeValue(forKey: id)
    }

    func waitForExit(withReply reply: @escaping (Int32) -> Void) {
        lock.lock(); defer { lock.unlock() }
        if let exitStatus { reply(exitStatus) } else { exitReply = reply }
    }

    func start(directory: String, environment: [String: String], rows: UInt16, columns: UInt16,
               withReply reply: @escaping (FileHandle?, String?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !started, !stopped, observations.isEmpty, directory.utf8.count < 4096, !directory.contains("\0"),
              directory.hasPrefix("/"), environment.count <= 32 else { reply(nil, "invalid launch request"); return }
        started = true
        var env = ["HOME": home, "USER": name, "LOGNAME": name, "SHELL": "/bin/zsh",
                   "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                   "TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "Duckpad"]
        for key in TerminalLocaleEnvironment.keys + ["TERM", "TERMINFO", "GHOSTTY_RESOURCES_DIR"] {
            if let value = environment[key], value.utf8.count < 4096, !value.contains("\0") { env[key] = value }
        }
        if let resources = env["GHOSTTY_RESOURCES_DIR"] {
            if let original = ProcessInfo.processInfo.environment["ZDOTDIR"] { env["GHOSTTY_ZSH_ZDOTDIR"] = original }
            env["ZDOTDIR"] = URL(fileURLWithPath: resources).appendingPathComponent("shell-integration/zsh").path
        }
        let values = env.map { strdup("\($0.key)=\($0.value)") }
        defer { values.forEach { free($0) } }
        var terminated = values + [nil]
        var pid: pid_t = 0
        let fd = terminated.withUnsafeMutableBufferPointer {
            dp_terminal_spawn("/bin/zsh", directory, $0.baseAddress, max(1, rows), max(1, columns), &pid)
        }
        guard fd >= 0 else { reply(nil, String(cString: strerror(errno))); return }
        child = pid
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        master = handle
        xpc_transaction_begin()
        reply(handle, nil)
        DispatchQueue.global(qos: .utility).async { [self] in
            // Reaping and termination share the lock, so a reused PID is never signalled.
            while true {
                lock.lock()
                var status: Int32 = 0
                let result = waitpid(child, &status, WNOHANG)
                if result == child || (result < 0 && errno == ECHILD) {
                    child = 0; master = nil
                    let code: Int32 = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
                    exitStatus = code
                    let reply = exitReply; exitReply = nil
                    lock.unlock()
                    reply?(code)
                    break
                }
                lock.unlock()
                Thread.sleep(forTimeInterval: 0.1)
            }
            xpc_transaction_end()
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        for task in observations.values { task.cancel() }
        Task { await remotePool.shutdown() }
        if child > 0 {
            if let master {
                let foreground = tcgetpgrp(master.fileDescriptor)
                if foreground > 0, foreground != child { kill(-foreground, SIGKILL) }
            }
            // Give the login shell time to hang up its background jobs.
            kill(-child, SIGHUP)
            kill(child, SIGHUP)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) { [self] in
                lock.lock(); defer { lock.unlock() }
                if child > 0 { kill(-child, SIGKILL); kill(child, SIGKILL) }
            }
        }
        master = nil
    }
}

private final class Listener: NSObject, NSXPCListenerDelegate {
    let requirement: String
    let home: String
    let name: String
    override init() {
        do {
            let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            guard Bundle(url: app)?.bundleIdentifier == "com.namjeongwan.duckpad",
                  getuid() == geteuid(), getuid() != 0 else { throw CocoaError(.executableNotLoadable) }
            requirement = try NativeInstallerXPC.requirement(for: app, matchingSignerOf: Bundle.main.bundleURL)
            guard let account = getpwuid(getuid()) else { throw CocoaError(.fileNoSuchFile) }
            home = String(cString: account.pointee.pw_dir)
            name = String(cString: account.pointee.pw_name)
        } catch { fatalError("Terminal host identity validation failed") }
        super.init()
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == geteuid() else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: DuckpadTerminalHostProtocol.self)
        let session = ShellSession(home: home, name: name)
        connection.exportedObject = session
        connection.invalidationHandler = { session.stop() }
        connection.interruptionHandler = { session.stop() }
        connection.resume()
        return true
    }
}
private let delegate = Listener()
let listener = NSXPCListener.service()
listener.delegate = delegate
withExtendedLifetime(delegate) { listener.resume() }
