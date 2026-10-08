import Foundation
import Darwin

/// One sandboxed JVM. The runtime actor serializes requests and owns idle expiry.
final class PlantUMLWorker {
    let java: URL
    let jar: URL
    let directory: URL
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let delimiter = Data(("DUCKPAD_" + UUID().uuidString + "\n").utf8)
    private let keepAlive: @Sendable (Bool) -> Void
    private var holdingTransaction = false
    private var processGroup: PlantUMLProcessGroup?
    var processIdentifier: Int32? { process.isRunning ? process.processIdentifier : nil }

    init(java: URL, jar: URL, root: URL, keepAlive: @escaping @Sendable (Bool) -> Void) throws {
        self.java = java; self.jar = jar; self.keepAlive = keepAlive
        directory = root.appendingPathComponent("worker-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        do {
            let profile = PlantUMLRuntime.sandboxProfile(javaHome: java.deletingLastPathComponent().deletingLastPathComponent(),
                                                        jar: jar, job: directory)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            process.arguments = ["-p", profile, java.path, "-Xmx512m", "-Djava.awt.headless=true",
                "-Djava.io.tmpdir=" + directory.path, "-Duser.home=" + directory.path,
                "-DPLANTUML_SECURITY_PROFILE=SANDBOX", "-DPLANTUML_LIMIT_SIZE=16384",
                "-jar", jar.path, "-charset", "UTF-8", "-pipe", "-pipeNoStderr", "-stdrpt:1",
                "-pipedelimitor", String(decoding: delimiter.dropLast(), as: UTF8.self)]
            process.currentDirectoryURL = directory
            process.environment = ["PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
                "HOME": directory.path, "TMPDIR": directory.path, "LANG": "en_US.UTF-8"]
            process.standardInput = input.fileHandleForReading
            process.standardOutput = output.fileHandleForWriting
            process.standardError = errors.fileHandleForWriting
            keepAlive(true); holdingTransaction = true
            try process.run()
            let group = PlantUMLProcessGroup(process.processIdentifier)
            processGroup = group
            process.terminationHandler = { _ in group.terminate() }
            try input.fileHandleForReading.close()
            try output.fileHandleForWriting.close()
            try errors.fileHandleForWriting.close()
            for handle in [input.fileHandleForWriting, output.fileHandleForReading, errors.fileHandleForReading] {
                let fd = handle.fileDescriptor
                guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else { throw PlantUMLFailure("renderFailed") }
            }
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else { throw PlantUMLFailure("renderFailed") }
        } catch { stop(); throw error }
    }

    func render(source: String, format: String, timeout: TimeInterval = 90) throws -> Data {
        let request = Data(("@@@format " + format + "\n" + source + "\n").utf8)
        var written = 0
        var bytes = Data(), diagnostic = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw PlantUMLFailure("timeout") }
            var fds = [pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: errors.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: input.fileHandleForWriting.fileDescriptor,
                              events: written < request.count ? Int16(POLLOUT) : 0, revents: 0)]
            guard poll(&fds, nfds_t(fds.count), 20) >= 0 || errno == EINTR else { throw PlantUMLFailure("renderFailed") }
            if written < request.count && fds[2].revents & Int16(POLLOUT) != 0 {
                let amount = request.withUnsafeBytes { buffer in
                    Darwin.write(fds[2].fd, buffer.baseAddress!.advanced(by: written), min(65536, request.count - written))
                }
                if amount > 0 { written += amount }
                else if errno != EAGAIN && errno != EINTR { throw PlantUMLFailure("renderFailed") }
            }
            try drain(fds[0].fd, into: &bytes, limit: 32 * 1024 * 1024 + delimiter.count)
            try drain(fds[1].fd, into: &diagnostic, limit: 65536)
            if bytes.suffix(delimiter.count) == delimiter {
                bytes.removeLast(delimiter.count)
                // pipeNoStderr suppresses error images and writes protocolVersion/status instead.
                guard !bytes.starts(with: Data("protocolVersion=".utf8)), diagnostic.isEmpty else {
                    throw PlantUMLFailure("renderFailed", String(decoding: (bytes + diagnostic).prefix(65536), as: UTF8.self))
                }
                return bytes
            }
            guard process.isRunning, fds[0].revents & Int16(POLLHUP | POLLERR | POLLNVAL) == 0 else {
                throw PlantUMLFailure("renderFailed", String(decoding: diagnostic, as: UTF8.self))
            }
        }
    }

    private func drain(_ fd: Int32, into data: inout Data, limit: Int) throws {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                guard data.count + count <= limit else { throw PlantUMLFailure("renderFailed") }
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 || errno == EAGAIN { return }
            else if errno != EINTR { throw PlantUMLFailure("renderFailed") }
        }
    }

    func stop() {
        processGroup?.terminate()
        if process.isRunning {
            if processGroup?.ownsGroup != true { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        for pipe in [input, output, errors] {
            try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close()
        }
        try? FileManager.default.removeItem(at: directory)
        if holdingTransaction { keepAlive(false); holdingTransaction = false }
    }
    deinit { stop() }
}
