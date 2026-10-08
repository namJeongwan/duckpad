import Foundation
import Darwin

/// Process termination callbacks and the runtime may both request cleanup.
final class PlantUMLProcessGroup: @unchecked Sendable {
    let ownsGroup: Bool
    private let lock = NSLock()
    private var identifier: Int32?

    init(_ pid: Int32) {
        ownsGroup = getpgid(pid) == pid
        identifier = ownsGroup ? pid : nil
    }
    func terminate() {
        lock.lock(); defer { lock.unlock() }
        guard let pid = identifier else { return }
        identifier = nil
        // A leader may already have exited while its descendants still own this group.
        // Consume the ID immediately, so repeated/idle cleanup cannot signal a reused PID.
        kill(-pid, SIGKILL)
    }
}
