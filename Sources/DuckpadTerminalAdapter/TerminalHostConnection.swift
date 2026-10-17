import Foundation
import DuckpadPluginSupport

/// One authenticated connection and PTY per surface; invalidation stops its shell.
@MainActor
final class TerminalHostConnection {
    private var connection: NSXPCConnection?
    private var proxy: (any DuckpadTerminalHostProtocol)?
    private(set) var master: FileHandle?
    var onExit: ((Int32) -> Void)?

    func start(directory: URL) async throws -> FileHandle {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/DuckpadTerminalHost.xpc")
        let requirement = try NativeInstallerXPC.requirement(for: helper, matchingSignerOf: Bundle.main.bundleURL)
        let connection = NSXPCConnection(serviceName: TerminalHostXPC.identifier)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: DuckpadTerminalHostProtocol.self)
        connection.interruptionHandler = { [weak self] in Task { @MainActor in self?.onExit?(1) } }
        connection.resume()
        self.connection = connection
        let handle: FileHandle = try await withCheckedThrowingContinuation { continuation in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: error)
            }) as? DuckpadTerminalHostProtocol else {
                continuation.resume(throwing: CocoaError(.executableNotLoadable)); return
            }
            let resources = Bundle.main.resourceURL!
            let environment = ["LANG": "en_US.UTF-8", "TERM": "xterm-ghostty",
                               "TERMINFO": resources.appendingPathComponent("terminfo").path,
                               "GHOSTTY_RESOURCES_DIR": resources.appendingPathComponent("ghostty").path]
            let reply: @Sendable (FileHandle?, String?) -> Void = { handle, error in
                if let handle { continuation.resume(returning: handle) }
                else { continuation.resume(throwing: NSError(domain: "DuckpadTerminal", code: 1, userInfo: [NSLocalizedDescriptionKey: error ?? "launch failed"])) }
            }
            proxy.start(directory: directory.path, environment: environment, rows: 24, columns: 80, withReply: reply)
        }
        guard self.connection === connection else {
            try? handle.close(); throw CancellationError()
        }
        master = handle
        // Use a separate proxy: an exit-wait error must not resume start twice.
        let exitProxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
            Task { @MainActor in self?.onExit?(1) }
        } as? DuckpadTerminalHostProtocol
        self.proxy = exitProxy
        let onExit: @Sendable (Int32) -> Void = { [weak self] status in Task { @MainActor in self?.onExit?(status) } }
        exitProxy?.waitForExit(withReply: onExit)
        return handle
    }

    func stop() {
        onExit = nil
        connection?.invalidate(); connection = nil; proxy = nil
        try? master?.close(); master = nil
    }
    isolated deinit { stop() }
}
