import Foundation
import DuckpadApplication
import DuckpadDomain
import DuckpadPluginSupport

public struct NativeInstallerClient: Sendable {
    public init() {}
    public func install(files: [String: Data]) async throws {
        let frame = try JSONEncoder().encode(files)
        guard frame.count <= NativeInstallerXPC.maximumFrameBytes else { throw ExtensionFailure.limitExceeded("native package") }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/DuckpadNativeInstaller.xpc")
        let requirement = try NativeInstallerXPC.requirement(for: helper)
        let call = Call()
        call.connection.remoteObjectInterface = NSXPCInterface(with: DuckpadNativeInstallerProtocol.self)
        call.connection.setCodeSigningRequirement(requirement)
        call.connection.invalidationHandler = { call.finish(.failure(ExtensionFailure.hostUnavailable("native installer disconnected"))) }
        call.connection.interruptionHandler = { call.finish(.failure(ExtensionFailure.hostUnavailable("native installer interrupted"))) }
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(30)); call.finish(.failure(ExtensionFailure.hostUnavailable("native installer timed out"))) } catch {}
        }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                call.start(continuation, frame: frame)
            }
        } onCancel: { call.finish(.failure(CancellationError())) }
    }

    private final class Call: @unchecked Sendable {
        let connection = NSXPCConnection(serviceName: NativeInstallerXPC.identifier)
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var result: Result<Void, Error>?
        func start(_ continuation: CheckedContinuation<Void, Error>, frame: Data) {
            lock.lock()
            if let result { lock.unlock(); continuation.resume(with: result); return }
            self.continuation = continuation
            lock.unlock()
            connection.resume()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ self.finish(.failure($0)) }) as? DuckpadNativeInstallerProtocol else {
                finish(.failure(ExtensionFailure.hostUnavailable("native installer unavailable"))); return
            }
            proxy.install(frame) { digest, error in
                if let digest, error == nil, digest.count == 64 { self.finish(.success(())) }
                else { self.finish(.failure(ExtensionFailure.hostUnavailable(error ?? "native installation failed"))) }
            }
        }
        func finish(_ result: Result<Void, Error>) {
            lock.lock()
            guard self.result == nil else { lock.unlock(); return }
            self.result = result
            let continuation = self.continuation; self.continuation = nil
            lock.unlock()
            connection.invalidate()
            continuation?.resume(with: result)
        }
    }
}
