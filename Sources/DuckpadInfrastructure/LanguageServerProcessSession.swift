import Foundation
import DuckpadApplication
import DuckpadDomain

/// Runs only in the existing signed, unsandboxed helper (or command-line tests).
public final class LanguageServerProcessSession: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var error: Pipe?
    public init() {}
    public static func projectRoot(for request: LanguageServerLaunchRequest) -> URL {
        let parent = URL(fileURLWithPath: request.documentPath).deletingLastPathComponent()
        let markers = request.definition?.projectRootMarkers ?? []
        var current = parent
        for _ in 0..<64 {
            if markers.contains(where: { FileManager.default.fileExists(atPath: current.appendingPathComponent($0).path) }) { return current }
            let next = current.deletingLastPathComponent()
            if next == current { break }; current = next
        }
        return parent
    }
    public func start(_ request: LanguageServerLaunchRequest, home: String) async throws -> (FileHandle, FileHandle, LanguageServerLaunchContext) {
        guard request.isValid else { throw CocoaError(.executableLoad) }
        try await LanguageServerRegistrationVerifier.verify(request.registration)
        try Task.checkCancellation()
        return try startVerified(request, home: home)
    }
    private func startVerified(_ request: LanguageServerLaunchRequest, home: String) throws -> (FileHandle, FileHandle, LanguageServerLaunchContext) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, request.isValid, process == nil else { throw CocoaError(.executableLoad) }
        let root = Self.projectRoot(for: request)
        let service = request.registration.service
        let serverID = request.settings.server(forProject: root.path, workspaceID: request.workspaceID, folder: request.folder, default: service.defaultServerID)
        guard serverID == request.serverID, let definition = request.definition, definition.languageIDs.contains(request.languageID) else { throw CocoaError(.executableLoad) }
        let paths = definition.projectExecutableDirectories.map { root.appendingPathComponent($0).path } + [
                     "\(home)/Library/Application Support/Duckpad/LanguageServers/bin", "\(home)/.local/share/mise/shims",
                     "\(home)/.local/bin", "\(home)/.rbenv/shims", "\(home)/.asdf/shims", "\(home)/.cargo/bin",
                     "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let interpreter = try LanguageInterpreterResolver.resolve(rule: service.interpreter, settings: request.settings, root: root, searchPaths: paths, workspaceID: request.workspaceID, folder: request.folder)
        guard let command = definition.command.first,
              paths.contains(where: { FileManager.default.isExecutableFile(atPath: "\($0)/\(command)") }) else { throw CocoaError(.fileNoSuchFile) }
        let task = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env"); task.arguments = definition.command
        task.currentDirectoryURL = root
        task.environment = ["HOME": home, "USER": NSUserName(), "LOGNAME": NSUserName(), "PATH": paths.joined(separator: ":"),
                            "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
        task.standardInput = stdin; task.standardOutput = stdout; task.standardError = stderr
        stderr.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        do { try task.run() } catch { stderr.fileHandleForReading.readabilityHandler = nil; throw error }
        process = task; input = stdin; output = stdout; self.error = stderr
        return (stdin.fileHandleForWriting, stdout.fileHandleForReading,
                .init(rootPath: root.path, serverID: serverID, interpreterPath: interpreter, settingsKey: request.registration.settingsKey, workspaceID: request.workspaceID, folderID: request.folder?.id))
    }
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        try? input?.fileHandleForWriting.close()
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        error?.fileHandleForReading.readabilityHandler = nil
        input = nil; output = nil; error = nil; process = nil
    }
    deinit { stop() }
}
