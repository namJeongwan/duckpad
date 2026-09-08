import DuckpadApplication
import DuckpadDomain
import Foundation

final class SearchScanBarrierRegexEngine: RegexEnginePort, @unchecked Sendable {
    private let base: any RegexEnginePort
    private let condition = NSCondition()
    private var didEnterScan = false
    private var isScanReleased = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    init(base: any RegexEnginePort) {
        self.base = base
    }

    func waitUntilScanEntered() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if didEnterScan {
                condition.unlock()
                continuation.resume()
            } else {
                entryWaiters.append(continuation)
                condition.unlock()
            }
        }
    }

    func releaseScan() {
        condition.lock()
        isScanReleased = true
        condition.broadcast()
        condition.unlock()
    }

    func matches(
        pattern: String,
        utf8: Data,
        matchCase: Bool,
        dotMatchesNewline: Bool,
        restrictTo: SearchUTF8Range?,
        maximumMatches: Int
    ) throws(SearchFailure) -> [RegexEngineMatch] {
        waitAtBarrier()
        return try base.matches(
            pattern: pattern,
            utf8: utf8,
            matchCase: matchCase,
            dotMatchesNewline: dotMatchesNewline,
            restrictTo: restrictTo,
            maximumMatches: maximumMatches
        )
    }

    func directionalMatch(
        pattern: String,
        utf8: Data,
        matchCase: Bool,
        dotMatchesNewline: Bool,
        restrictTo: SearchUTF8Range,
        backwards: Bool
    ) throws(SearchFailure) -> RegexEngineMatch? {
        waitAtBarrier()
        return try base.directionalMatch(
            pattern: pattern,
            utf8: utf8,
            matchCase: matchCase,
            dotMatchesNewline: dotMatchesNewline,
            restrictTo: restrictTo,
            backwards: backwards
        )
    }

    private func waitAtBarrier() {
        condition.lock()
        didEnterScan = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        condition.unlock()
        for waiter in waiters { waiter.resume() }

        condition.lock()
        while !isScanReleased { condition.wait() }
        condition.unlock()
    }
}
