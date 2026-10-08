import Foundation

@main struct RuntimeSmoke {
    static func main() async throws {
        try WorkerGroupChecks.run()
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let runtime = PlantUMLRuntime(root: root.appendingPathComponent("runtime"))
        let job = root.appendingPathComponent("entropy-probe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: job) }
        let profile = PlantUMLRuntime.sandboxProfile(javaHome: job, jar: job.appendingPathComponent("unused.jar"), job: job)
        for device in ["/dev/random", "/dev/urandom"] {
            let bytes = try PlantUMLProcess.run(URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
                arguments: ["-p", profile, "/bin/dd", "if=" + device, "bs=32", "count=1"], directory: job)
            precondition(bytes.count == 32, "Renderer must use OS entropy instead of slow fallback")
        }
        let outside = root.appendingPathComponent("entropy-outside-" + UUID().uuidString)
        try Data("PRIVATE_FILE_MUST_STAY_BLOCKED".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        do {
            _ = try PlantUMLProcess.run(URL(fileURLWithPath: "/usr/bin/sandbox-exec"),
                arguments: ["-p", profile, "/bin/cat", outside.path], directory: job)
            fatalError("OS entropy access must not allow reading private files")
        } catch { print("OS entropy readable; private file reads remain denied") }
        let source = try String(contentsOf: root.appendingPathComponent("input.puml"), encoding: .utf8)
        var request = PlantUMLRequest(source: source, format: "svg", javaPath: CommandLine.arguments[2], jarPath: CommandLine.arguments[3])
        if CommandLine.arguments.contains("--install") { request.javaPath = nil; request.jarPath = nil; request.install = true }
        let coldStart = ProcessInfo.processInfo.systemUptime
        let svg = try await runtime.perform(request)
        let coldTime = ProcessInfo.processInfo.systemUptime - coldStart
        let pid = await runtime.workerProcessIdentifier
        let text = String(decoding: svg, as: UTF8.self)
        precondition(text.contains("<svg") && text.contains("고객"))
        try svg.write(to: root.appendingPathComponent("result.svg"))
        var pngRequest = request; pngRequest.format = "png"
        let warmStart = ProcessInfo.processInfo.systemUptime
        let png = try await runtime.perform(pngRequest)
        let warmTime = ProcessInfo.processInfo.systemUptime - warmStart
        let reusedPID = await runtime.workerProcessIdentifier
        precondition(pid != nil && pid == reusedPID, "Full sequence PNG/SVG must reuse JVM")
        print(String(format: "Full sequence: first %.3fs; reused %.3fs", coldTime, warmTime))
        precondition(png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))
        try png.write(to: root.appendingPathComponent("result.png"))
        let secret = root.appendingPathComponent("outside-job-secret.json")
        try Data(#"{"secret":"DO_NOT_LEAK_PLANTUML_TEST"}"#.utf8).write(to: secret)
        defer { try? FileManager.default.removeItem(at: secret) }
        var include = request; include.install = false
        include.source = "@startuml\n!$value = %load_json(\"\(secret.path)\")\nAlice -> Bob: $value\n@enduml"
        do {
            let output = try await runtime.perform(include)
            precondition(!String(decoding: output, as: UTF8.self).contains("DO_NOT_LEAK_PLANTUML_TEST"))
        } catch { print("Local file include rejected") }
        for invalid in [
            PlantUMLRequest(source: source, format: "../../escape", javaPath: request.javaPath, jarPath: request.jarPath),
            PlantUMLRequest(source: "@startuml\nAlice -> Bob: hi\nTHIS IS NOT VALID PLANTUML!!!\n@enduml", format: "svg", javaPath: request.javaPath, jarPath: request.jarPath),
            PlantUMLRequest(source: source, format: "svg", javaPath: "/bin/sh", jarPath: request.jarPath)
        ] {
            do { _ = try await runtime.perform(invalid); fatalError("Invalid render must fail") }
            catch { print("Rejected invalid request:", String(describing: error)) }
        }
        print("PlantUML Korean sequence PNG/SVG and invalid-input checks passed")
        await runtime.stopWorker()
        let pngColdStart = ProcessInfo.processInfo.systemUptime
        let firstPNG = try await runtime.perform(pngRequest)
        let pngColdTime = ProcessInfo.processInfo.systemUptime - pngColdStart
        let pngWarmStart = ProcessInfo.processInfo.systemUptime
        let nextPNG = try await runtime.perform(pngRequest)
        let pngWarmTime = ProcessInfo.processInfo.systemUptime - pngWarmStart
        precondition(firstPNG == nextPNG, "Reused preview must render the current request correctly")
        print(String(format: "Same full sequence PNG preview: first %.3fs; reused %.3fs", pngColdTime, pngWarmTime))
        await runtime.stopWorker()
        try await WorkerChecks.run(root: root.appendingPathComponent("runtime"), request: request)
    }
}
