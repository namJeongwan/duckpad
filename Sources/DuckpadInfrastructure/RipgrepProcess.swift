import Darwin
import DuckpadDomain
import Foundation

/// Each search owns its child PIDs. Signalling and reaping share one lock so a
/// cancelled request can never signal a PID that has already been reused.
final class RipgrepProcess: @unchecked Sendable {
    struct Exit: Equatable {
        let status: Int32
        let outputLimitReached: Bool
    }
    private let lock = NSLock()
    private var children: Set<pid_t> = []
    private var cancelled = false
    private var timedOut = false
    private let deadline: ContinuousClock.Instant
    let executable: URL

    init(executable: URL, timeout: Duration) { self.executable = executable; deadline = .now + timeout }
    func cancel(timedOut: Bool = false) {
        lock.lock()
        self.cancelled = true; self.timedOut = self.timedOut || timedOut
        for pid in children { Darwin.kill(pid, SIGTERM) }
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(200)) { [self] in
            lock.lock(); defer { lock.unlock() }
            for pid in children { Darwin.kill(pid, SIGKILL) }
        }
    }
    func check() throws {
        if ContinuousClock.now >= deadline { cancel(timedOut: true) }
        lock.lock(); let stop = cancelled, expired = timedOut; lock.unlock()
        if stop { throw FolderSearchFailure.search(expired ? .timedOut : .cancelled) }
    }
    private func reap(_ pid: pid_t, status: inout Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid || result < 0 && errno == ECHILD { children.remove(pid); return true }
        return false
    }
    private func signal(_ pid: pid_t, _ value: Int32) {
        lock.lock(); defer { lock.unlock() }
        if children.contains(pid) { Darwin.kill(pid, value) }
    }

    /// NUL records are bounded and delivered synchronously for natural backpressure.
    /// Returning false stops this child normally (for an explicit result/input cap).
    func run(arguments: [String], directory: Int32,
             maximumOutputBytes: Int = 32 * 1_024 * 1_024,
             onRecord: (Data) throws -> Bool) throws -> Exit {
        try check()
        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else { throw FolderSearchFailure.enumerationFailed("ripgrep pipe unavailable") }
        defer { Darwin.close(pipeFDs[0]); Darwin.close(pipeFDs[1]) }
        _ = fcntl(pipeFDs[0], F_SETFL, O_NONBLOCK)
        _ = fcntl(pipeFDs[0], F_SETFD, FD_CLOEXEC); _ = fcntl(pipeFDs[1], F_SETFD, FD_CLOEXEC)
        let null = Darwin.open("/dev/null", O_RDWR | O_CLOEXEC)
        guard null >= 0 else { throw FolderSearchFailure.enumerationFailed("ripgrep null stream unavailable") }
        defer { Darwin.close(null) }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else {
            throw FolderSearchFailure.enumerationFailed("ripgrep spawn unavailable")
        }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawn_file_actions_adddup2(&actions, null, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, pipeFDs[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, null, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addfchdir_np(&actions, directory) == 0 else {
            throw FolderSearchFailure.enumerationFailed("ripgrep stream setup failed")
        }
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let env = [strdup("LC_ALL=en_US.UTF-8"), nil]
        defer { for pointer in argv { free(pointer) }; for pointer in env { free(pointer) } }
        var pid: pid_t = 0
        lock.lock()
        if cancelled { lock.unlock(); try check(); throw FolderSearchFailure.search(.cancelled) }
        let spawned = executable.path.withCString { path in
            argv.withUnsafeBufferPointer { arguments in
                env.withUnsafeBufferPointer { environment in
                    posix_spawn(&pid, path, &actions, &attributes,
                        UnsafeMutablePointer(mutating: arguments.baseAddress!), UnsafeMutablePointer(mutating: environment.baseAddress!))
                }
            }
        }
        if spawned == 0 { children.insert(pid) }
        lock.unlock()
        guard spawned == 0 else { throw FolderSearchFailure.enumerationFailed("ripgrep could not start") }
        Darwin.close(pipeFDs[1]); pipeFDs[1] = -1
        var reaped = false, status: Int32 = 0
        defer {
            if !reaped {
                signal(pid, SIGKILL)
                while !reap(pid, status: &status) { usleep(1_000) }
            }
        }
        var pending = Data(), outputBytes = 0
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        var outputLimitReached = false
        var stopped = false, stopTime: ContinuousClock.Instant?, eof = false
        while !eof {
            try check()
            var pollFD = pollfd(fd: pipeFDs[0], events: Int16(POLLIN | POLLHUP), revents: 0)
            _ = Darwin.poll(&pollFD, 1, 20)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(pipeFDs[0], $0.baseAddress, $0.count) }
            if count > 0 {
                // A discovery budget yields incomplete results, not an I/O failure.
                // After stopping, drain without retaining or counting child output.
                if !stopped && count > maximumOutputBytes - outputBytes {
                    outputLimitReached = true; stopped = true; stopTime = .now
                    signal(pid, SIGTERM); pending.removeAll(keepingCapacity: false)
                }
                if !stopped {
                    outputBytes += count
                    pending.append(buffer, count: count)
                    var start = pending.startIndex
                    while let end = pending[start...].firstIndex(of: 0) {
                        guard end - start <= 64 * 1_024 else { throw FolderSearchFailure.enumerationFailed("ripgrep path limit exceeded") }
                        if try !onRecord(Data(pending[start..<end])) {
                            stopped = true; stopTime = .now; signal(pid, SIGTERM); break
                        }
                        start = end + 1
                    }
                    if stopped { pending.removeAll(keepingCapacity: false) }
                    else if start > pending.startIndex { pending.removeSubrange(pending.startIndex..<start) }
                    guard pending.count <= 64 * 1_024 else { throw FolderSearchFailure.enumerationFailed("ripgrep path limit exceeded") }
                }
            } else if count == 0 { eof = true }
            else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                throw FolderSearchFailure.enumerationFailed("ripgrep stream failed")
            }
            if let stopTime, stopTime.duration(to: .now) > .milliseconds(200) { signal(pid, SIGKILL) }
        }
        while !reap(pid, status: &status) {
            try check()
            if let stopTime, stopTime.duration(to: .now) > .milliseconds(200) { signal(pid, SIGKILL) }
            usleep(1_000)
        }
        reaped = true
        try check()
        guard stopped || pending.isEmpty else { throw FolderSearchFailure.enumerationFailed("ripgrep returned an incomplete path") }
        if stopped { return Exit(status: 0, outputLimitReached: outputLimitReached) }
        guard status & 0x7F == 0 else { throw FolderSearchFailure.enumerationFailed("ripgrep exited unexpectedly") }
        return Exit(status: (status >> 8) & 0xFF, outputLimitReached: false)
    }
}
