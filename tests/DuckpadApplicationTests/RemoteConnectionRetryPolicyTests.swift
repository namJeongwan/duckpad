import DuckpadApplication
import Foundation
import Testing

private actor RetryCounter {
    var calls = 0, announcements = [Int]()
    func run(failures: Int, error: FileObservationError = .unavailable) throws -> Int {
        calls += 1
        if calls <= failures { throw error }
        return calls
    }
    func announce(_ attempt: Int) { announcements.append(attempt) }
}

struct RemoteConnectionRetryPolicyTests {
    @Test func retriesThreeTimesAndRecoversOrPropagatesLastFailure() async throws {
        let policy = RemoteConnectionRetryPolicy(delays: [.zero, .zero, .zero])
        let recovering = RetryCounter()
        let result = try await policy.run(operation: { try await recovering.run(failures: 3) },
            onRetry: { attempt, total in #expect(total == 3); await recovering.announce(attempt) })
        #expect(result == 4)
        #expect(await recovering.announcements == [1, 2, 3])
        let offline = RetryCounter()
        await #expect(throws: FileObservationError.unavailable) {
            try await policy.run { try await offline.run(failures: 10) }
        }
        #expect(await offline.calls == 4)
    }
    @Test(arguments: [FileObservationError.cancelled, .directoryUnavailable, .invalidUTF8, .tooLarge, .invalidResponse, .persistence])
    func permanentFailuresNeverRetry(_ error: FileObservationError) async {
        let counter = RetryCounter()
        await #expect(throws: error) {
            try await RemoteConnectionRetryPolicy(delays: [.zero]).run { try await counter.run(failures: 10, error: error) }
        }
        #expect(await counter.calls == 1)
    }
    @Test func cancellationDuringBackoffDoesNotStartAnotherAttempt() async throws {
        let counter = RetryCounter()
        let operation = Task {
            try await RemoteConnectionRetryPolicy(delays: [.seconds(30)]).run(operation: {
                try await counter.run(failures: 10)
            }, onRetry: { attempt, _ in await counter.announce(attempt) })
        }
        while await counter.announcements.isEmpty { await Task.yield() }
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(await counter.calls == 1)
    }
}
