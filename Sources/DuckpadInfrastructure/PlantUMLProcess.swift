import Foundation
import Darwin

/// File-backed I/O avoids pipe deadlocks; every child has a time/output limit.
enum PlantUMLProcess {
    static func run(_ executable: URL, arguments: [String], directory: URL, input: Data = Data(), timeout: TimeInterval = 90) throws -> Data {
        let id = UUID().uuidString
        let stdin = directory.appendingPathComponent(id + ".in")
        let stdout = directory.appendingPathComponent(id + ".out")
        let stderr = directory.appendingPathComponent(id + ".err")
        try input.write(to: stdin)
        FileManager.default.createFile(atPath: stdout.path, contents: nil)
        FileManager.default.createFile(atPath: stderr.path, contents: nil)
        let reader = try FileHandle(forReadingFrom: stdin)
        let output = try FileHandle(forWritingTo: stdout)
        let error = try FileHandle(forWritingTo: stderr)
        defer {
            try? reader.close(); try? output.close(); try? error.close()
            for url in [stdin, stdout, stderr] { try? FileManager.default.removeItem(at: url) }
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        // Do not inherit JAVA_TOOL_OPTIONS, injection variables, or proxy settings.
        process.environment = ["PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
                               "HOME": directory.path, "TMPDIR": directory.path, "LANG": "en_US.UTF-8"]
        process.standardInput = reader; process.standardOutput = output; process.standardError = error
        try process.run()
        let ownsGroup = getpgid(process.processIdentifier) == process.processIdentifier
        defer { if ownsGroup { kill(-process.processIdentifier, SIGKILL) } }
        let deadline = Date().addingTimeInterval(timeout)
        var stopped = false
        while process.isRunning {
            let tooLarge = [stdout, stderr].contains {
                ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 32 * 1024 * 1024
            }
            if Date() >= deadline || tooLarge || Task<Never, Never>.isCancelled {
                stopped = true; process.terminate()
                Thread.sleep(forTimeInterval: 0.1)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        guard !stopped else { throw PlantUMLFailure("timeout") }
        guard process.terminationStatus == 0 else {
            let bytes = try Data(contentsOf: stderr)
            throw PlantUMLFailure("renderFailed", String(decoding: bytes.prefix(65536), as: UTF8.self))
        }
        return try Data(contentsOf: stdout)
    }
}
