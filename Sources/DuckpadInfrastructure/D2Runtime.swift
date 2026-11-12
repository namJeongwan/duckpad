import Foundation
import CryptoKit
#if canImport(DuckpadPluginSupport)
import DuckpadPluginSupport
#endif

/// One bounded SVG render in the authenticated helper, with a private runtime cache.
public actor D2Runtime {
    public static let version = "0.9.0"
    static var runtimeDirectoryName: String { "v" + version + "-" + archiveArchitecture }
    private let root: URL
    private var busy = false
    public init(root: URL) { self.root = root.standardizedFileURL }

    public func perform(_ request: D2Request) async throws -> Data {
        try Task.checkCancellation()
        guard !request.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.source.utf8.count <= 512 * 1024, !request.source.contains("\0"),
              (request.executablePath?.utf8.count ?? 0) <= 4096,
              request.executablePath?.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) != true else {
            throw D2Failure("invalidInput")
        }
        guard !busy else { throw D2Failure("busy") }
        busy = true; defer { busy = false }
        try prepareDirectory(root)
        let job = root.appendingPathComponent("job-" + UUID().uuidString, isDirectory: true)
        try prepareDirectory(job)
        defer { try? FileManager.default.removeItem(at: job) }
        let executable = try await resolveExecutable(request.executablePath, install: request.install, job: job)
        try Task.checkCancellation()
        let profile = try Self.sandboxProfile(executable: executable, job: job)
        let executablePath = try D2Process.physicalPath(executable)
        let bytes = try D2Process.run(URL(fileURLWithPath: "/usr/bin/sandbox-exec"), arguments: ["-p", profile, executablePath,
            "--layout=dagre", "--theme=\(request.dark ? 200 : 0)", "--pad=16", "--scale=1", "--bundle=true",
            "--timeout=85", "--target=", "--stdout-format=svg", "-", "-"], directory: job, input: Data(request.source.utf8))
        guard !bytes.isEmpty, bytes.count <= 32 * 1024 * 1024,
              String(decoding: bytes.prefix(4096), as: UTF8.self).contains("<svg") else { throw D2Failure("renderFailed") }
        return bytes
    }

    static func sandboxProfile(executable: URL, job: URL) throws -> String {
        let executablePath = try D2Process.physicalPath(executable), jobPath = try D2Process.physicalPath(job)
        func quote(_ path: String) -> String {
            "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return """
        (version 1)
        (allow default)
        (deny network*)
        (deny file-read-data)
        (allow file-read-metadata)
        (allow file-read-data (literal "/dev/random") (literal "/dev/urandom")
          (literal "/") (subpath "/System") (subpath "/usr/lib") (subpath "/usr/share")
          (literal \(quote(executablePath))) (subpath \(quote(jobPath))))
        (deny file-write*)
        (allow file-write* (subpath \(quote(jobPath))))
        (deny process-exec)
        (allow process-exec (literal \(quote(executablePath))))
        """
    }

    private func resolveExecutable(_ path: String?, install: Bool, job: URL) async throws -> URL {
        if let path, !path.isEmpty {
            do { return try validateExecutable(URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)) }
            catch { throw D2Failure("invalidRuntime") }
        }
        let managed = root.appendingPathComponent(Self.runtimeDirectoryName).appendingPathComponent("d2")
        if install { try await installRuntime(job: job) }
        if FileManager.default.fileExists(atPath: managed.path) {
            let executable = try validateExecutable(managed)
            guard try Self.sha(Data(contentsOf: executable)) == Self.binarySHA else { throw D2Failure("checksum") }
            return executable
        }
        for path in ["/opt/homebrew/bin/d2", "/usr/local/bin/d2"] {
            if let executable = try? validateExecutable(URL(fileURLWithPath: path)) { return executable }
        }
        throw D2Failure("missingRuntime")
    }

    private func validateExecutable(_ url: URL) throws -> URL {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        let values = try canonical.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 4, size <= 256 * 1024 * 1024,
              FileManager.default.isExecutableFile(atPath: canonical.path) else { throw D2Failure("invalidRuntime") }
        let file = try FileHandle(forReadingFrom: canonical); defer { try? file.close() }
        let header = try file.read(upToCount: 4) ?? Data()
        guard [[UInt8](arrayLiteral: 0xcf, 0xfa, 0xed, 0xfe), [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca]].contains(Array(header)) else {
            throw D2Failure("invalidRuntime")
        }
        return canonical
    }

    private func prepareDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard url.resolvingSymlinksInPath().standardizedFileURL.path == url.path,
              try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
              try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw D2Failure("invalidRuntime") }
    }

    private func installRuntime(job: URL) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 180
        configuration.httpShouldSetCookies = false; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let name = "d2-v\(Self.version)-macos-\(Self.archiveArchitecture).tar.gz"
        let url = URL(string: "https://github.com/d2lang/d2/releases/download/v\(Self.version)/\(name)")!
        let temporary: URL, response: URLResponse
        do { (temporary, response) = try await session.download(from: url) }
        catch {
            try Task.checkCancellation()
            throw D2Failure("downloadFailed", error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              (try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 64 * 1024 * 1024 else { throw D2Failure("downloadFailed") }
        let bytes = try Data(contentsOf: temporary)
        guard Self.sha(bytes) == Self.archiveSHA else { throw D2Failure("checksum") }
        try Task.checkCancellation()
        let archive = job.appendingPathComponent("runtime.tar.gz")
        try bytes.write(to: archive)
        let prefix = "d2-v" + Self.version
        _ = try D2Process.run(URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-xzf", archive.path, "-C", job.path,
            prefix + "/bin/d2", prefix + "/LICENSE.txt", prefix + "/THIRD_PARTY_NOTICES.txt"], directory: job)
        let binary = job.appendingPathComponent(prefix + "/bin/d2")
        guard (try binary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 64 * 1024 * 1024 else { throw D2Failure("checksum") }
        let executable = try Data(contentsOf: binary)
        guard Self.sha(executable) == Self.binarySHA else { throw D2Failure("checksum") }
        let destination = root.appendingPathComponent(Self.runtimeDirectoryName, isDirectory: true)
        try prepareDirectory(destination)
        try Task.checkCancellation()
        try executable.write(to: destination.appendingPathComponent("d2"), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.appendingPathComponent("d2").path)
        for name in ["LICENSE.txt", "THIRD_PARTY_NOTICES.txt"] {
            let license = try Data(contentsOf: job.appendingPathComponent(prefix + "/" + name))
            guard license.count <= 1024 * 1024 else { throw D2Failure("checksum") }
            try license.write(to: destination.appendingPathComponent(name), options: .atomic)
        }
    }

    private static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    #if arch(arm64)
    private static let archiveArchitecture = "arm64"
    private static let archiveSHA = "eaf6c0c143e56dd9fa97bfb6df25ea9c1ebce40245f056a0768cf1a6c15d3064"
    private static let binarySHA = "e8ba501a413bac33a4d93014c475b804de10fb2863a391583e23a8d88160e311"
    #else
    private static let archiveArchitecture = "amd64"
    private static let archiveSHA = "cad39576a480d6bb02ea142fef1726647914b0d2da51ccc9b30b660a2b1babf0"
    private static let binarySHA = "a59c3d378681d2e5f7cffd7fceaaf000842a04b3ef0356f4ea90cff91256e217"
    #endif
}
