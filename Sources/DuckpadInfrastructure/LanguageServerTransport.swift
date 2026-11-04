import Foundation
import Darwin
import JSONRPC
import DuckpadApplication
import DuckpadPluginSupport

private actor LanguageServerPipeWriter {
    let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
    func write(_ data: Data) throws { try handle.write(contentsOf: data) }
}

@MainActor final class LanguageServerTransport {
    private var connection: NSXPCConnection?
    private var process: LanguageServerProcessSession?
    private var input: FileHandle?
    private var output: FileHandle?
    private var continuation: AsyncStream<Data>.Continuation?

    func start(_ request: LanguageServerLaunchRequest) async throws -> (DataChannel, LanguageServerLaunchContext) {
        var started = false
        defer { if !started { stop() } }
        let handles: (FileHandle, FileHandle, LanguageServerLaunchContext)
        if Bundle.main.bundleURL.pathExtension == "app" {
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/DuckpadTerminalHost.xpc")
            let requirement = try NativeInstallerXPC.requirement(for: helper, matchingSignerOf: Bundle.main.bundleURL)
            let connection = NSXPCConnection(serviceName: TerminalHostXPC.identifier)
            connection.setCodeSigningRequirement(requirement)
            connection.remoteObjectInterface = NSXPCInterface(with: DuckpadTerminalHostProtocol.self)
            connection.invalidationHandler = { @Sendable [weak self] in Task { @MainActor in self?.stop() } }
            connection.interruptionHandler = { @Sendable [weak self] in Task { @MainActor in self?.stop() } }
            self.connection = connection; connection.resume()
            let data = try JSONEncoder().encode(request)
            handles = try await withCheckedThrowingContinuation { reply in
                // A dedicated connection owns this one launch and its pipes.
                var completed = false
                let finish: @MainActor (Result<(FileHandle, FileHandle, LanguageServerLaunchContext), any Error>) -> Void = { result in
                    guard !completed else { return }; completed = true; reply.resume(with: result)
                }
                let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable _ in
                    Task { @MainActor in finish(.failure(CocoaError(.executableLoad))) }
                } as? DuckpadTerminalHostProtocol
                proxy?.startLanguageServer(data) { input, output, contextData in
                    Task { @MainActor in
                        if let input, let output, let contextData,
                           let context = try? JSONDecoder().decode(LanguageServerLaunchContext.self, from: contextData) {
                            finish(.success((input, output, context)))
                        }
                        else { finish(.failure(CocoaError(.executableLoad))) }
                    }
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(5))
                    if !completed { finish(.failure(CocoaError(.executableLoad))); self.stop() }
                }
            }
        } else {
            let process = LanguageServerProcessSession(); self.process = process
            handles = try await process.start(request, home: NSHomeDirectory())
        }
        input = handles.0; output = handles.1
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(64))
        self.continuation = continuation
        handles.1.readabilityHandler = { handle in
            // read(upToCount:) can wait to fill the requested size on a pipe.
            // A single POSIX read delivers each available LSP frame immediately.
            var bytes = Data(count: 65_536)
            let count = bytes.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress!, $0.count) }
            if count < 0 && errno == EINTR { return }
            guard count > 0 else { handle.readabilityHandler = nil; continuation.finish(); return }
            bytes.count = count
            if case .dropped = continuation.yield(bytes) { handle.readabilityHandler = nil; continuation.finish() }
        }
        let writer = LanguageServerPipeWriter(handles.0)
        started = true
        return (DataChannel(writeHandler: { try await writer.write($0) }, dataSequence: stream), handles.2)
    }

    func stop() {
        continuation?.finish(); continuation = nil
        output?.readabilityHandler = nil
        try? input?.close(); try? output?.close(); input = nil; output = nil
        process?.stop(); process = nil
        let connection = self.connection; self.connection = nil
        connection?.invalidationHandler = nil; connection?.interruptionHandler = nil; connection?.invalidate()
    }
}
