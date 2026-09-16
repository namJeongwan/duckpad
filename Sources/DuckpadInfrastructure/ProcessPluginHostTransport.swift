import Darwin
import DuckpadApplication
import DuckpadDomain
import DuckpadPluginSupport
import Foundation

/// Development/test-only transport. Distribution builds use
/// `XPCPluginHostTransport` and do not include this executable.
public actor ProcessPluginHostTransport: PluginHostTransport {
    private final class TerminalArbiter: @unchecked Sendable {
        enum Cause { case completed, failed, cancelled, timedOut }
        private let lock = NSLock(); private var cause: Cause?
        func claim(_ candidate: Cause) -> Bool { lock.lock(); defer { lock.unlock() }; guard cause == nil else { return false }; cause = candidate; return true }
        func current() -> Cause? { lock.lock(); defer { lock.unlock() }; return cause }
    }
    private final class ProcessExitSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var exited = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func markExited() {
            lock.lock()
            guard !exited else { lock.unlock(); return }
            exited = true
            let pending = waiters
            waiters.removeAll(keepingCapacity: false)
            lock.unlock()
            for waiter in pending { waiter.resume() }
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if exited {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }
    }
    private let executableURL: URL
    private let requestedExecutableURL: URL
    private let permitsInjectedDevelopmentHelper: Bool
    private struct ActiveHost {
        let id: UUID
        let process: Process
        let input: Pipe
        let output: Pipe
        let errors: Pipe
        let terminal: TerminalArbiter
        let exit: ProcessExitSignal
    }
    private var active: ActiveHost?

    public init(executableURL: URL, permitsInjectedDevelopmentHelper: Bool = false) {
        self.requestedExecutableURL = executableURL.standardizedFileURL
        self.executableURL = executableURL.resolvingSymlinksInPath().standardizedFileURL
        self.permitsInjectedDevelopmentHelper = permitsInjectedDevelopmentHelper
    }

    public nonisolated static func siblingOfCurrentExecutable() -> URL {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: "/nonexistent/duckpad-app"))
            .deletingLastPathComponent().appendingPathComponent("DuckpadPluginHost")
            .resolvingSymlinksInPath().standardizedFileURL
    }

    public func invoke(_ request: ExtensionHostRequest) async throws -> ExtensionHostResponse {
        guard active == nil else { throw ExtensionFailure.hostUnavailable("plugin host is busy") }
        try validateExecutable()
        let process = Process(); let input = Pipe(); let output = Pipe(); let errors = Pipe()
        let exit = ProcessExitSignal()
        process.executableURL = executableURL; process.arguments = []
        process.environment = [:]; process.standardInput = input; process.standardOutput = output; process.standardError = errors
        process.terminationHandler = { _ in exit.markExited() }
        do { try process.run() } catch { throw ExtensionFailure.hostUnavailable("plugin host launch failed") }
        let terminal = TerminalArbiter()
        active = ActiveHost(id: request.requestID, process: process, input: input, output: output, errors: errors, terminal: terminal, exit: exit)
        defer { if active?.id == request.requestID { active = nil } }
        let timeout = request.limits.timeoutMilliseconds
        return try await withTaskCancellationHandler {
            do {
                return try await withThrowingTaskGroup(of: ExtensionHostResponse.self) { group in
                    group.addTask {
                        try input.fileHandleForWriting.write(contentsOf: PluginFrameCodec.encode(request))
                        try input.fileHandleForWriting.close()
                        async let stderr = Self.readCapped(errors.fileHandleForReading, maximum: 8 * 1_024)
                        let response = try Self.readResponse(output.fileHandleForReading)
                        await exit.wait()
                        let diagnostic = try await stderr
                        guard process.terminationReason == .exit && process.terminationStatus == 0 else {
                            throw ExtensionFailure.hostUnavailable("plugin host exit \(process.terminationStatus): \(String(decoding: diagnostic, as: UTF8.self))")
                        }
                        guard terminal.claim(.completed) else {
                            switch terminal.current() { case .timedOut: throw ExtensionFailure.timedOut; default: throw ExtensionFailure.cancelled }
                        }
                        return response
                    }
                    group.addTask {
                        try await Task.sleep(for: .milliseconds(timeout))
                        guard terminal.claim(.timedOut) else { throw CancellationError() }
                        await Self.terminateAndReap(process: process, input: input, output: output, errors: errors, exit: exit)
                        throw ExtensionFailure.timedOut
                    }
                    defer { group.cancelAll() }
                    guard let first = try await group.next() else { throw ExtensionFailure.hostUnavailable("plugin host ended") }
                    return first
                }
            } catch let failure as ExtensionFailure {
                await Self.terminateAndReap(process: process, input: input, output: output, errors: errors, exit: exit)
                switch terminal.current() {
                case .cancelled: throw ExtensionFailure.cancelled
                case .timedOut: throw ExtensionFailure.timedOut
                default: _ = terminal.claim(.failed); throw failure
                }
            } catch {
                await Self.terminateAndReap(process: process, input: input, output: output, errors: errors, exit: exit)
                switch terminal.current() {
                case .cancelled: throw ExtensionFailure.cancelled
                case .timedOut: throw ExtensionFailure.timedOut
                default: _ = terminal.claim(.failed); throw ExtensionFailure.hostUnavailable(String(describing: error))
                }
            }
        } onCancel: {
            _ = terminal.claim(.cancelled)
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            try? errors.fileHandleForReading.close()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    public func cancel(requestID: UUID) async {
        guard let active, active.id == requestID else { return }
        _ = active.terminal.claim(.cancelled)
        await Self.terminateAndReap(process: active.process, input: active.input, output: active.output, errors: active.errors, exit: active.exit)
    }

    private nonisolated static func readResponse(_ handle: FileHandle) throws -> ExtensionHostResponse {
        let prefix = try readExactly(4, handle)
        let length = prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length <= PluginFrameCodec.maximumFrameBytes else { throw ExtensionFailure.limitExceeded("IPC response") }
        var frame = prefix; frame.append(try readExactly(Int(length), handle))
        if let trailing = try handle.read(upToCount: 1), !trailing.isEmpty {
            throw ExtensionFailure.hostUnavailable("plugin host emitted trailing bytes")
        }
        return try PluginFrameCodec.decode(ExtensionHostResponse.self, from: frame)
    }

    private nonisolated static func readExactly(_ count: Int, _ handle: FileHandle) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else { throw ExtensionFailure.hostUnavailable("truncated IPC response") }
            data.append(chunk)
        }
        return data
    }

    private nonisolated static func readCapped(_ handle: FileHandle, maximum: Int) throws -> Data {
        var data = Data()
        while let chunk = try handle.read(upToCount: min(4_096, maximum + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximum else { throw ExtensionFailure.limitExceeded("plugin host stderr") }
        }
        return data
    }

    private func validateExecutable() throws {
        var info = stat()
        guard lstat(requestedExecutableURL.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              requestedExecutableURL.resolvingSymlinksInPath().standardizedFileURL.path == executableURL.path,
              executableURL.resolvingSymlinksInPath().standardizedFileURL.path == executableURL.path else {
            throw ExtensionFailure.hostUnavailable("plugin host identity invalid")
        }
        guard permitsInjectedDevelopmentHelper || executableURL.path == Self.siblingOfCurrentExecutable().standardizedFileURL.path else {
            throw ExtensionFailure.hostUnavailable("plugin host is not the app-owned sibling")
        }
    }

    private nonisolated static func terminateAndReap(process: Process, input: Pipe, output: Pipe, errors: Pipe, exit: ProcessExitSignal) async {
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
        if process.isRunning { process.terminate() }
        for _ in 0..<10 where process.isRunning { try? await Task.sleep(for: .milliseconds(5)) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        await exit.wait()
    }
}
