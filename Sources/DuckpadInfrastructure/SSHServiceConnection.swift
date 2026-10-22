import DuckpadApplication
import DuckpadPluginSupport
import Foundation

/// One authenticated XPC session per app. All windows and files share it;
/// request IDs allow cancellation without disconnecting other operations.
@MainActor final class SSHServiceConnection {
    static let shared = SSHServiceConnection()
    private var connection: NSXPCConnection?
    private var generation = UUID()
    private var pending: [UUID: CheckedContinuation<Data, any Error>] = [:]
    private var timeouts: [UUID: Task<Void, Never>] = [:]

    func request(_ data: Data) async throws -> Data {
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    let connection = try connected(), generation = generation
                    pending[id] = continuation
                    guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                        Task { @MainActor in self.failConnection(generation) }
                    }) as? DuckpadTerminalHostProtocol else { throw FileObservationError.unavailable }
                    proxy.readRemoteFile(data, requestID: id.uuidString) { response in
                        Task { @MainActor in
                            guard self.generation == generation, let continuation = self.pending.removeValue(forKey: id) else { return }
                            self.timeouts.removeValue(forKey: id)?.cancel()
                            if let response { continuation.resume(returning: response) }
                            else { continuation.resume(throwing: FileObservationError.invalidResponse) }
                        }
                    }
                    timeouts[id] = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(35)) } catch { return }
                        self?.cancel(id, error: FileObservationError.timedOut)
                    }
                } catch {
                    pending.removeValue(forKey: id)
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: { Task { @MainActor in self.cancel(id, error: CancellationError()) } }
    }
    private func connected() throws -> NSXPCConnection {
        if let connection { return connection }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/DuckpadTerminalHost.xpc")
        let requirement = try NativeInstallerXPC.requirement(for: helper, matchingSignerOf: Bundle.main.bundleURL)
        let connection = NSXPCConnection(serviceName: TerminalHostXPC.identifier)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: DuckpadTerminalHostProtocol.self)
        generation = UUID()
        let current = generation
        connection.interruptionHandler = { Task { @MainActor in self.failConnection(current) } }
        connection.invalidationHandler = { Task { @MainActor in self.failConnection(current) } }
        self.connection = connection
        connection.resume()
        return connection
    }
    private func cancel(_ id: UUID, error: any Error) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        timeouts.removeValue(forKey: id)?.cancel()
        let proxy = connection?.remoteObjectProxyWithErrorHandler { _ in } as? DuckpadTerminalHostProtocol
        proxy?.cancelRemoteFile(id.uuidString)
        continuation.resume(throwing: error)
    }
    private func failConnection(_ current: UUID) {
        guard generation == current else { return }
        generation = UUID()
        let connection = self.connection; self.connection = nil
        let waiting = pending; pending.removeAll()
        timeouts.values.forEach { $0.cancel() }; timeouts.removeAll()
        connection?.invalidate()
        for continuation in waiting.values { continuation.resume(throwing: FileObservationError.unavailable) }
    }
}
