import Foundation

/// Bounded retries for SSH transport failures. Cancellation, decoding, file
/// limits and persistence failures never start another connection attempt.
public struct RemoteConnectionRetryPolicy: Sendable {
    public let delays: [Duration]
    public init(delays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]) { self.delays = delays }
    public func delay(after error: any Error, retry: Int) -> Duration? {
        guard delays.indices.contains(retry), Self.isConnectionFailure(error) else { return nil }
        return delays[retry]
    }
    public static func isConnectionFailure(_ error: any Error) -> Bool {
        switch error as? FileObservationError {
        // OpenSSH currently reports exit 255 for both failed authentication
        // and a lost transport. Neither retries bypass host/key verification.
        case .unavailable, .timedOut, .authentication: return true
        default: return false
        }
    }
    public func run<Value: Sendable>(operation: @Sendable () async throws -> Value,
        onRetry: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> Value {
        var retry = 0
        while true {
            try Task.checkCancellation()
            do {
                let value = try await operation()
                try Task.checkCancellation()
                return value
            } catch {
                try Task.checkCancellation()
                guard let delay = delay(after: error, retry: retry) else { throw error }
                retry += 1
                await onRetry(retry, delays.count)
                try await Task.sleep(for: delay)
            }
        }
    }
}
