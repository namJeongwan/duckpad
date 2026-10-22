import Darwin
import DuckpadApplication
import Foundation

/// Own and reap each child under the same lock used for cancellation. No shell
/// is involved locally, and stdout/stderr are drained together with hard limits.
final class SSHReadProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t?
    private var cancelled = false

    func cancel() {
        lock.lock(); cancelled = true
        if let pid { kill(pid, SIGTERM) }
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(200)) { [self] in
            lock.lock(); defer { lock.unlock() }
            if let pid { kill(pid, SIGKILL) }
        }
    }

    func run(executable: URL, arguments: [String], maximumOutput: Int, timeout: Duration? = .seconds(30)) throws -> Data {
        var output: [Int32] = [0, 0], errors: [Int32] = [0, 0]
        guard pipe(&output) == 0 else { throw FileObservationError.unavailable }
        defer { output.forEach { Darwin.close($0) } }
        guard pipe(&errors) == 0 else { throw FileObservationError.unavailable }
        defer { errors.forEach { Darwin.close($0) } }
        for fd in output + errors { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        for fd in [output[0], errors[0]] { _ = fcntl(fd, F_SETFL, O_NONBLOCK) }
        let null = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard null >= 0 else { throw FileObservationError.unavailable }
        defer { Darwin.close(null) }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw FileObservationError.unavailable }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw FileObservationError.unavailable }
        defer { posix_spawnattr_destroy(&attributes) }
        // Swift/XPC worker threads can block termination signals. Never pass
        // that mask (or ignored dispositions) into an owned OpenSSH process.
        var signalMask = sigset_t(), signalDefaults = sigset_t()
        sigemptyset(&signalMask); sigemptyset(&signalDefaults)
        for signal in [SIGTERM, SIGINT, SIGHUP, SIGQUIT] { sigaddset(&signalDefaults, signal) }
        guard posix_spawnattr_setsigmask(&attributes, &signalMask) == 0,
              posix_spawnattr_setsigdefault(&attributes, &signalDefaults) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)) == 0,
              posix_spawn_file_actions_adddup2(&actions, null, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO) == 0 else { throw FileObservationError.unavailable }
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        defer { argv.compactMap { $0 }.forEach { free($0) } }
        let environment = ProcessInfo.processInfo.environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { environment.compactMap { $0 }.forEach { free($0) } }
        var child: pid_t = 0
        lock.lock()
        if cancelled { lock.unlock(); throw FileObservationError.cancelled }
        let launched = argv.withUnsafeBufferPointer {
            arguments in environment.withUnsafeBufferPointer { values in
                posix_spawn(&child, executable.path, &actions, &attributes,
                    UnsafeMutablePointer(mutating: arguments.baseAddress!), UnsafeMutablePointer(mutating: values.baseAddress!))
            }
        }
        if launched == 0 { pid = child }
        lock.unlock()
        guard launched == 0 else { throw FileObservationError.unavailable }
        Darwin.close(output[1]); output[1] = -1
        Darwin.close(errors[1]); errors[1] = -1
        let deadline = timeout.map { ContinuousClock.now + $0 }
        var result = Data(), errorBytes = 0, status: Int32 = 0
        var failure: FileObservationError?
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            for fd in [output[0], errors[0]] {
                while true {
                    let count = Darwin.read(fd, &buffer, buffer.count)
                    if count <= 0 { break }
                    if fd == output[0] {
                        if result.count <= maximumOutput - count { result.append(contentsOf: buffer.prefix(count)) }
                        else { failure = .tooLarge; cancel() }
                    } else {
                        errorBytes += count
                        if errorBytes > 64 * 1_024 { failure = .invalidResponse; cancel() }
                    }
                }
            }
            lock.lock()
            let stopped = cancelled
            let reaped = waitpid(child, &status, WNOHANG)
            if reaped == child || reaped < 0 && errno == ECHILD { pid = nil }
            lock.unlock()
            if reaped == child {
                // Bytes already queued in the pipe can outlive the process.
                while true {
                    let count = Darwin.read(output[0], &buffer, buffer.count)
                    if count <= 0 { break }
                    guard result.count <= maximumOutput - count else { throw FileObservationError.tooLarge }
                    result.append(contentsOf: buffer.prefix(count))
                }
                if let failure { throw failure }
                if stopped { throw FileObservationError.cancelled }
                guard status == 0 else { throw status == 255 << 8 ? FileObservationError.authentication : .unavailable }
                return result
            }
            if reaped < 0 && errno != EINTR { cancel(); throw FileObservationError.unavailable }
            if let deadline, ContinuousClock.now >= deadline, failure == nil { failure = .timedOut; cancel() }
            var descriptors = [pollfd(fd: output[0], events: Int16(POLLIN), revents: 0),
                               pollfd(fd: errors[0], events: Int16(POLLIN), revents: 0)]
            _ = poll(&descriptors, 2, timeout == nil ? 100 : 5)
        }
    }
}
