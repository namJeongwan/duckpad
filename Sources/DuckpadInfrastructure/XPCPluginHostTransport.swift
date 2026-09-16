import DuckpadApplication
import DuckpadDomain
import DuckpadPluginSupport
import Foundation

/// Production transport for the embedded, separately sandboxed XPC service.
/// It sends one bounded value frame per connection and invalidates the
/// connection on completion, timeout, cancellation, interruption, or error.
public actor XPCPluginHostTransport: PluginHostTransport {
    private final class Invocation: @unchecked Sendable {
        private let lock = NSLock()
        private let connection: NSXPCConnection
        private var continuation: CheckedContinuation<ExtensionHostResponse, any Error>?
        private var pendingResult: Result<ExtensionHostResponse, any Error>?
        private var finished = false

        init(connection: NSXPCConnection) { self.connection = connection }

        func install(_ continuation: CheckedContinuation<ExtensionHostResponse, any Error>) {
            lock.lock()
            if let pendingResult {
                self.pendingResult = nil
                lock.unlock()
                continuation.resume(with: pendingResult)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func finish(_ result: Result<ExtensionHostResponse, any Error>) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let continuation = continuation
            self.continuation = nil
            if continuation == nil { pendingResult = result }
            lock.unlock()
            connection.invalidate()
            continuation?.resume(with: result)
        }
    }

    private let serviceName: String
    private var active: (id: UUID, invocation: Invocation)?
    private var invokingRequestIDs: Set<UUID> = []
    private var cancelledRequestIDs: Set<UUID> = []

    public init(serviceName: String = DuckpadPluginXPCService.bundleIdentifier) {
        self.serviceName = serviceName
    }

    public func invoke(_ request: ExtensionHostRequest) async throws -> ExtensionHostResponse {
        guard invokingRequestIDs.insert(request.requestID).inserted else {
            throw ExtensionFailure.hostUnavailable("duplicate plugin request ID")
        }
        defer {
            invokingRequestIDs.remove(request.requestID)
            cancelledRequestIDs.remove(request.requestID)
        }
        let started = DispatchTime.now().uptimeNanoseconds
        for attempt in 0..<3 {
            guard !cancelledRequestIDs.contains(request.requestID), !Task.isCancelled else {
                throw ExtensionFailure.cancelled
            }
            let elapsed = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            guard elapsed < UInt64(request.limits.timeoutMilliseconds) else {
                throw ExtensionFailure.timedOut
            }
            let remaining = request.limits.timeoutMilliseconds - UInt32(elapsed)
            do { return try await invokeOnce(request, localTimeoutMilliseconds: remaining) }
            catch let failure as ExtensionFailure {
                guard attempt < 2, Self.isRestartableConnectionFailure(failure),
                      !Task.isCancelled,
                      !cancelledRequestIDs.contains(request.requestID) else {
                    if cancelledRequestIDs.contains(request.requestID) { throw ExtensionFailure.cancelled }
                    throw failure
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        throw ExtensionFailure.hostUnavailable("plugin runtime restart attempts exhausted")
    }

    private func invokeOnce(
        _ request: ExtensionHostRequest,
        localTimeoutMilliseconds: UInt32
    ) async throws -> ExtensionHostResponse {
        guard active == nil else { throw ExtensionFailure.hostUnavailable("plugin host is busy") }
        let frame = try PluginFrameCodec.encode(request)
        let connection = NSXPCConnection(serviceName: serviceName)
        let invocation = Invocation(connection: connection)
        active = (request.requestID, invocation)
        defer { if active?.id == request.requestID { active = nil } }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                invocation.install(continuation)
                connection.remoteObjectInterface = NSXPCInterface(with: DuckpadPluginXPCProtocol.self)
                connection.interruptionHandler = {
                    invocation.finish(.failure(ExtensionFailure.hostUnavailable("plugin runtime interrupted")))
                }
                connection.invalidationHandler = {
                    invocation.finish(.failure(ExtensionFailure.hostUnavailable("plugin runtime invalidated")))
                }
                connection.resume()
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    invocation.finish(.failure(ExtensionFailure.hostUnavailable(String(describing: error))))
                }) as? DuckpadPluginXPCProtocol else {
                    invocation.finish(.failure(ExtensionFailure.hostUnavailable("plugin runtime proxy unavailable")))
                    return
                }
                proxy.invoke(frame) { responseFrame, failure in
                    do {
                        if let failure { throw ExtensionFailure.hostUnavailable(failure) }
                        guard let responseFrame else {
                            throw ExtensionFailure.hostUnavailable("plugin runtime returned no frame")
                        }
                        invocation.finish(.success(try PluginFrameCodec.decode(
                            ExtensionHostResponse.self,
                            from: responseFrame
                        )))
                    } catch {
                        invocation.finish(.failure(error))
                    }
                }
                Task.detached {
                    try? await Task.sleep(for: .milliseconds(localTimeoutMilliseconds))
                    invocation.finish(.failure(ExtensionFailure.timedOut))
                }
            }
        } onCancel: {
            invocation.finish(.failure(ExtensionFailure.cancelled))
        }
    }

    private nonisolated static func isRestartableConnectionFailure(_ failure: ExtensionFailure) -> Bool {
        guard case .hostUnavailable(let detail) = failure else { return false }
        return detail.hasPrefix("plugin runtime interrupted")
            || detail.hasPrefix("plugin runtime invalidated")
            || detail.hasPrefix("plugin runtime proxy unavailable")
            || detail.hasPrefix("Error Domain=NSCocoaErrorDomain")
            || detail.hasPrefix("Error Domain=NSXPCConnectionErrorDomain")
    }

    public func cancel(requestID: UUID) async {
        guard invokingRequestIDs.contains(requestID) else { return }
        cancelledRequestIDs.insert(requestID)
        if let active, active.id == requestID {
            active.invocation.finish(.failure(ExtensionFailure.cancelled))
        }
    }
}
