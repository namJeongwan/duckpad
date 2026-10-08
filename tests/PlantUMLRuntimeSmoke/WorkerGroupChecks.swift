import Foundation
import Darwin

enum WorkerGroupChecks {
    static func run() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("duckpad-worker-group-" + UUID().uuidString)
        let java = root.appendingPathComponent("bin/java")
        try FileManager.default.createDirectory(at: java.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("#!/bin/sh\n/bin/sleep 120 &\necho $! > child.pid\n/bin/sleep .1\nexit 0\n".utf8).write(to: java)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: java.path)
        let worker = try PlantUMLWorker(java: java, jar: root.appendingPathComponent("unused.jar"), root: root, keepAlive: { _ in })
        defer { worker.stop() }
        do { _ = try worker.render(source: "@startuml\nAlice -> Bob\n@enduml", format: "svg", timeout: 2); fatalError("Fake leader must fail") }
        catch {}
        let pidText = try String(contentsOf: worker.directory.appendingPathComponent("child.pid"), encoding: .utf8)
        let child = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines))!
        worker.stop()
        Thread.sleep(forTimeInterval: 0.1)
        if kill(child, 0) == 0 {
            kill(child, SIGKILL) // Clean up only the child this disposable fixture created.
            throw PlantUMLFailure("renderFailed", "Exited JVM left a surviving child")
        }
        worker.stop() // Repeated cleanup must be harmless.
        print("Exited worker leader and descendants are cleaned up exactly once")
    }
}
