import Foundation
import Darwin

enum WorkerChecks {
    static func run(root: URL, request: PlantUMLRequest) async throws {
        let runtime = PlantUMLRuntime(root: root, idleTimeout: 0.6)
        var small = request
        small.source = "@startuml\nAlice -> Bob: reusable worker\n@enduml"
        small.format = "svg"
        _ = try await runtime.perform(small)
        let first = await runtime.workerProcessIdentifier
        precondition(first != nil)
        try await Task.sleep(for: .milliseconds(350))
        small.format = "png"
        _ = try await runtime.perform(small)
        let same = await runtime.workerProcessIdentifier
        precondition(same == first, "PNG/SVG must reuse one JVM")
        try await Task.sleep(for: .milliseconds(350))
        let retained = await runtime.workerProcessIdentifier
        precondition(retained == first, "New request must reset idle expiry")
        try await Task.sleep(for: .milliseconds(350))
        let expired = await runtime.workerProcessIdentifier
        precondition(expired == nil, "Idle worker must terminate")
        precondition(kill(first!, 0) == -1 && errno == ESRCH)
        _ = try await runtime.perform(small)
        let restarted = await runtime.workerProcessIdentifier
        precondition(restarted != nil && restarted != first, "Render after idle must restart")
        kill(restarted!, SIGKILL)
        for _ in 0..<50 {
            if await runtime.workerProcessIdentifier == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await runtime.perform(small)
        let recovered = await runtime.workerProcessIdentifier
        precondition(recovered != nil && recovered != restarted, "Unexpected exit must restart")
        var invalid = small
        invalid.source = "@startuml\nAlice -> Bob: hi\nINVALID PLANTUML!!!\n@enduml"
        do { _ = try await runtime.perform(invalid); fatalError("Syntax errors must fail") }
        catch { let stopped = await runtime.workerProcessIdentifier; precondition(stopped == nil) }
        small.source = "@startuml\nAlice -> Bob: updated source\n@enduml"
        small.format = "svg"
        let updated = try await runtime.perform(small)
        precondition(String(decoding: updated, as: UTF8.self).contains("updated source"))
        let beforePathChange = await runtime.workerProcessIdentifier
        let originalJar = request.jarPath.map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent("plantuml-1.2026.8.jar")
        let copiedJar = root.appendingPathComponent("alternate-" + UUID().uuidString + ".jar")
        try FileManager.default.copyItem(at: originalJar, to: copiedJar)
        defer { try? FileManager.default.removeItem(at: copiedJar) }
        small.jarPath = copiedJar.path
        _ = try await runtime.perform(small)
        let afterPathChange = await runtime.workerProcessIdentifier
        precondition(afterPathChange != nil && afterPathChange != beforePathChange, "Runtime path changes must restart")
        var injection = small
        injection.source = "@startuml\n@@@format png\nAlice -> Bob: unsafe framing\n@enduml"
        do { _ = try await runtime.perform(injection); fatalError("Pipe controls must be rejected") }
        catch {}
        await runtime.stopWorker()
        let cancelling = Task { try await runtime.perform(request) }
        try await Task.sleep(for: .milliseconds(50))
        cancelling.cancel()
        do { _ = try await cancelling.value; fatalError("Cancelled rendering must fail") }
        catch { let stopped = await runtime.workerProcessIdentifier; precondition(stopped == nil) }
        print("Worker reuse, idle reset/expiry, restart, errors, path changes and cancellation checks passed")
    }
}
