import AppKit

/// At most one pending snapshot waits for the UI, even while the main actor is busy.
final class SearchProgressDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: MultiFileSearchResults?
    private var scheduled = false
    private let receive: @MainActor @Sendable (MultiFileSearchResults) -> Void
    init(receive: @escaping @MainActor @Sendable (MultiFileSearchResults) -> Void) { self.receive = receive }
    func offer(_ value: MultiFileSearchResults) {
        lock.lock(); latest = value
        let enqueue = !scheduled; scheduled = true; lock.unlock()
        if enqueue { Task { @MainActor in self.deliver() } }
    }
    @MainActor private func deliver() {
        lock.lock(); let value = latest; latest = nil; scheduled = false; lock.unlock()
        if let value { receive(value) }
    }
}
