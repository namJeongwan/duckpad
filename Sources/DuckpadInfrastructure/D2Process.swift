import Foundation
import Darwin

/// File-backed streams, finite output and monotonic deadlines for one render.
enum D2Process {
    static func physicalPath(_ url: URL) throws -> String {
        guard let path = realpath(url.path, nil) else { throw D2Failure("invalidRuntime") }
        defer { free(path) }
        return String(cString: path)
    }
    static func run(_ executable: URL, arguments: [String], directory: URL, input: Data = Data(),
                    timeout: TimeInterval = 90, outputLimit: Int = 32 * 1024 * 1024) throws -> Data {
        try Task.checkCancellation()
        let name = UUID().uuidString
        let paths = ["in", "out", "err"].map { directory.appendingPathComponent(name + "." + $0) }
        try input.write(to: paths[0])
        for path in paths.dropFirst() { guard FileManager.default.createFile(atPath: path.path, contents: nil) else { throw D2Failure("renderFailed") } }
        defer { for path in paths { try? FileManager.default.removeItem(at: path) } }
        let stdin = try FileHandle(forReadingFrom: paths[0])
        let stdout = try FileHandle(forWritingTo: paths[1]), stderr = try FileHandle(forWritingTo: paths[2])
        defer { try? stdin.close(); try? stdout.close(); try? stderr.close() }
        let process = Process()
        process.executableURL = executable; process.arguments = arguments; process.currentDirectoryURL = directory
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": directory.path, "TMPDIR": directory.path, "PWD": try physicalPath(directory), "LANG": "en_US.UTF-8"]
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        let ownsGroup = getpgid(process.processIdentifier) == process.processIdentifier
        defer { if ownsGroup { kill(-process.processIdentifier, SIGKILL) } }
        func size(_ url: URL) -> Int {
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0, info.st_size <= Int.max else { return Int.max }
            return Int(info.st_size)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var failure: D2Failure?
        while process.isRunning {
            if Task<Never, Never>.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline {
                failure = D2Failure("timeout")
            } else if size(paths[1]) > outputLimit || size(paths[2]) > 65_536 { failure = D2Failure("outputLimit") }
            if failure != nil {
                process.terminate()
                if ownsGroup { kill(-process.processIdentifier, SIGTERM) }
                Thread.sleep(forTimeInterval: 0.05)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        try Task.checkCancellation()
        if let failure { throw failure }
        guard size(paths[1]) <= outputLimit, size(paths[2]) <= 65_536 else { throw D2Failure("outputLimit") }
        guard process.terminationStatus == 0 else {
            throw D2Failure("renderFailed", String(decoding: try Data(contentsOf: paths[2]), as: UTF8.self))
        }
        let reader = try FileHandle(forReadingFrom: paths[1]); defer { try? reader.close() }
        let bytes = try reader.read(upToCount: outputLimit + 1) ?? Data()
        guard bytes.count <= outputLimit else { throw D2Failure("outputLimit") }
        return bytes
    }
}
