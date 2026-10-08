import Foundation

/// Each authenticated connection owns and cancels only its own render task.
final class PlantUMLWork: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    func start(_ operation: @escaping @Sendable () async -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return false }
        task = Task { [weak self] in
            await operation()
            self?.finish()
        }
        return true
    }
    private func finish() { lock.lock(); task = nil; lock.unlock() }
    func cancel() { lock.lock(); task?.cancel(); lock.unlock() }
}
