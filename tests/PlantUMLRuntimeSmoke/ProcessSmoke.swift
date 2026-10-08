import Foundation

@main struct ProcessSmoke {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plantuml-process-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let heartbeat = root.appendingPathComponent("heartbeat")
        let child = "/bin/sh -c 'trap \"\" TERM; while :; do echo alive >> \"$1\"; sleep .05; done' _ heartbeat & "
        for timeout in [true, false] {
            try? FileManager.default.removeItem(at: heartbeat)
            do {
                _ = try PlantUMLProcess.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", child + (timeout ? "sleep 5" : "sleep .2")], directory: root, timeout: timeout ? 0.3 : 2)
                precondition(!timeout)
            } catch let error as PlantUMLFailure { precondition(timeout && error.code == "timeout") }
            let size = try Data(contentsOf: heartbeat).count
            precondition(size > 0)
            Thread.sleep(forTimeInterval: 0.2)
            let after = try Data(contentsOf: heartbeat).count
            precondition(after == size, "Descendant must stop when its job ends")
        }
        print("SIGTERM-resistant descendants stopped on timeout and normal parent exit")
    }
}
