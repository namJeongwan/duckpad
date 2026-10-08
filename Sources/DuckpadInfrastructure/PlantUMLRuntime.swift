import Foundation
import CryptoKit
#if canImport(DuckpadPluginSupport)
import DuckpadPluginSupport
#endif

/// Runs in the authenticated installer helper, never in Duckpad's UI process.
public actor PlantUMLRuntime {
    private let root: URL
    private var busy = false
    private var worker: PlantUMLWorker?
    private var idleTask: Task<Void, Never>?
    private var idleGeneration = UUID()
    private let idleTimeout: TimeInterval
    private let keepAlive: @Sendable (Bool) -> Void
    public init(root: URL, keepAlive: @escaping @Sendable (Bool) -> Void = { _ in }) {
        self.root = root; self.keepAlive = keepAlive; self.idleTimeout = 600
    }
    // Short expiry is injectable for lifecycle regression tests; production always uses ten minutes.
    init(root: URL, idleTimeout: TimeInterval) {
        self.root = root; self.idleTimeout = idleTimeout; self.keepAlive = { _ in }
    }
    var workerProcessIdentifier: Int32? { worker?.processIdentifier }
    public static let jarVersion = "1.2026.8"
    private static let jarURL = URL(string: "https://github.com/plantuml/plantuml/releases/download/v1.2026.8/plantuml-lgpl-1.2026.8.jar")!
    private static let jarSHA = "99e271611aa65a2319c0a4502ae9a4289f02933fdcc4f96a4e2f62a9b4e5b4ce"
    private static let jarHashes: Set<String> = [jarSHA, "5e1ecfa8ecd32c90b03bbf3b1eb6f020943f98ab0fcf4032be31a0002ee2c462"]

    public func perform(_ request: PlantUMLRequest) async throws -> Data {
        try Task.checkCancellation()
        guard request.source.utf8.count <= 512 * 1024, ["png", "svg"].contains(request.format),
              request.source.components(separatedBy: "@startuml").count == 2,
              request.source.components(separatedBy: "@enduml").count == 2 else { throw PlantUMLFailure("invalidInput") }
        guard !busy else { throw PlantUMLFailure("busy") }
        busy = true; defer { busy = false }
        let lines = request.source.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("@startuml") }),
              let end = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "@enduml" }), start < end,
              !lines.contains(where: { $0.hasPrefix("@@@format ") }),
              !lines[(start + 1)..<end].contains(where: {
                  let line = $0.trimmingCharacters(in: .whitespaces)
                  return line.hasPrefix("@start") || line.hasPrefix("@end")
              }) else { throw PlantUMLFailure("invalidInput") }
        // Pipe mode needs complete, column-zero boundaries and no trailing commands.
        let source = "@startuml\n" + lines[(start + 1)..<end].joined(separator: "\n") + "\n@enduml"
        idleTask?.cancel(); idleTask = nil; idleGeneration = UUID()
        defer { if worker != nil { scheduleIdleExpiry() } }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let job = root.appendingPathComponent("job-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: job) }
        let java = try await resolveJava(request.javaPath, install: request.install, job: job)
        let jar = try await resolveJar(request.jarPath, install: request.install)
        if worker?.java != java || worker?.jar != jar || worker?.processIdentifier == nil { stopWorker() }
        if worker == nil { worker = try PlantUMLWorker(java: java, jar: jar, root: root, keepAlive: keepAlive) }
        do {
            let bytes = try worker!.render(source: source, format: request.format)
            guard !bytes.isEmpty, bytes.count <= 32 * 1024 * 1024 else { throw PlantUMLFailure("renderFailed") }
            if request.format == "png" {
                guard bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw PlantUMLFailure("renderFailed") }
            } else {
                guard String(decoding: bytes.prefix(4096), as: UTF8.self).contains("<svg") else { throw PlantUMLFailure("renderFailed") }
            }
            return bytes
        } catch {
            stopWorker(); throw error
        }
    }

    private func scheduleIdleExpiry() {
        let generation = UUID(); idleGeneration = generation
        let timeout = idleTimeout
        idleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            await self?.expireWorker(generation)
        }
    }
    private func expireWorker(_ generation: UUID) {
        guard generation == idleGeneration, !busy else { return }
        stopWorker()
    }
    func stopWorker() {
        idleGeneration = UUID(); idleTask?.cancel(); idleTask = nil
        worker?.stop(); worker = nil
    }

    /// Java can read its runtime, fonts and OS entropy, but no user data or network.
    static func sandboxProfile(javaHome: URL, jar: URL, job: URL) -> String {
        func quote(_ path: String) -> String {
            "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return """
        (version 1)
        (allow default)
        (deny network*)
        (deny file-read-data)
        (allow file-read-metadata)
        ;; JVM SecureRandom otherwise falls back to slow threaded seed generation.
        (allow file-read-data (literal "/dev/random") (literal "/dev/urandom"))
        (allow file-read-data (literal "/") (subpath "/System") (subpath "/usr") (subpath \(quote(javaHome.path))) (literal \(quote(jar.path))) (subpath \(quote(job.path))))
        (deny file-write*)
        (allow file-write* (subpath \(quote(job.path))))
        """
    }

    private func resolveJava(_ path: String?, install: Bool, job: URL) async throws -> URL {
        if let path, !path.isEmpty { return try validateJava(URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)) }
        var candidates = [root.appendingPathComponent("Java/Contents/Home/bin/java"),
                          URL(fileURLWithPath: "/opt/homebrew/opt/openjdk/bin/java"),
                          URL(fileURLWithPath: "/usr/local/opt/openjdk/bin/java")]
        for parent in ["/Library/Java/JavaVirtualMachines", FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Java/JavaVirtualMachines",
                       FileManager.default.homeDirectoryForCurrentUser.path + "/.local/share/mise/installs/java"] {
            let base = URL(fileURLWithPath: parent)
            for url in (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
                candidates.append(url.appendingPathComponent("Contents/Home/bin/java"))
                candidates.append(url.appendingPathComponent("bin/java"))
            }
        }
        for url in candidates where !install && FileManager.default.isExecutableFile(atPath: url.path) {
            if let valid = try? validateJava(url) { return valid }
        }
        if let managed = try? validateJava(root.appendingPathComponent("Java/Contents/Home/bin/java")) { return managed }
        guard install else { throw PlantUMLFailure("missingJava") }
        #if arch(arm64)
        let architecture = "aarch64"
        #else
        let architecture = "x64"
        #endif
        let api = URL(string: "https://api.adoptium.net/v3/assets/latest/21/hotspot?architecture=\(architecture)&image_type=jre&os=mac&vendor=eclipse")!
        let (metadata, response) = try await URLSession.shared.data(from: api)
        guard (response as? HTTPURLResponse)?.statusCode == 200, metadata.count <= 1024 * 1024,
              let assets = try JSONSerialization.jsonObject(with: metadata) as? [[String: Any]],
              let binary = assets.first?["binary"] as? [String: Any], let package = binary["package"] as? [String: Any],
              let link = package["link"] as? String, let sha = package["checksum"] as? String,
              let url = URL(string: link), url.scheme == "https", url.host == "github.com",
              url.path.hasPrefix("/adoptium/temurin21-binaries/releases/download/"), sha.count == 64 else { throw PlantUMLFailure("downloadFailed") }
        let archive = job.appendingPathComponent("java.tar.gz")
        try await download(url, sha: sha, to: archive, limit: 128 * 1024 * 1024)
        let listing = try PlantUMLProcess.run(URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-tzf", archive.path], directory: job)
        let entries = String(decoding: listing, as: UTF8.self).split(separator: "\n")
        guard !entries.isEmpty, entries.count <= 4096,
              entries.allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }) else { throw PlantUMLFailure("downloadFailed") }
        let staging = job.appendingPathComponent("unpacked")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        _ = try PlantUMLProcess.run(URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xzf", archive.path, "-C", staging.path, "--no-same-owner", "--no-same-permissions", "--safe-writes"], directory: job)
        let roots = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
        guard roots.count == 1 else { throw PlantUMLFailure("downloadFailed") }
        _ = try validateJava(roots[0].appendingPathComponent("Contents/Home/bin/java"))
        let destination = root.appendingPathComponent("Java")
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw PlantUMLFailure("invalidJava") }
        try FileManager.default.moveItem(at: roots[0], to: destination)
        return try validateJava(destination.appendingPathComponent("Contents/Home/bin/java"))
    }

    private func validateJava(_ value: URL) throws -> URL {
        var java = value.resolvingSymlinksInPath()
        if java.pathExtension == "jdk" || java.pathExtension == "jre" { java.appendPathComponent("Contents/Home/bin/java") }
        else if java.lastPathComponent != "java" { java.appendPathComponent("bin/java") }
        let home = java.deletingLastPathComponent().deletingLastPathComponent()
        guard java.lastPathComponent == "java", java.deletingLastPathComponent().lastPathComponent == "bin",
              FileManager.default.isExecutableFile(atPath: java.path),
              FileManager.default.fileExists(atPath: home.appendingPathComponent("lib/modules").path) else { throw PlantUMLFailure("invalidJava") }
        // Structural validation only; execution happens inside the renderer profile.
        return java
    }

    private func resolveJar(_ path: String?, install: Bool) async throws -> URL {
        let jar = path.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }?
            .resolvingSymlinksInPath() ?? root.appendingPathComponent("plantuml-\(Self.jarVersion).jar")
        if !FileManager.default.fileExists(atPath: jar.path) {
            guard path == nil || path?.isEmpty == true, install else { throw PlantUMLFailure("missingJar") }
            try await download(Self.jarURL, sha: Self.jarSHA, to: jar, limit: 32 * 1024 * 1024)
        }
        let attributes = try jar.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard attributes.isRegularFile == true, (attributes.fileSize ?? Int.max) <= 32 * 1024 * 1024,
              Self.jarHashes.contains(Self.sha(try Data(contentsOf: jar))) else { throw PlantUMLFailure("checksum", Self.jarVersion) }
        return jar
    }

    private func download(_ url: URL, sha: String, to destination: URL, limit: Int) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45; configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (temporary, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              ((try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max) <= limit else { throw PlantUMLFailure("downloadFailed") }
        let bytes = try Data(contentsOf: temporary)
        guard Self.sha(bytes) == sha else { throw PlantUMLFailure("checksum") }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
    private static func sha(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
}
