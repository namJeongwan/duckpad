import Darwin
import DuckpadApplication
import DuckpadDomain
import Foundation

/// Bundled rg discovers names using the same ignore rules as folder content search.
/// The development fallback only enumerates names; neither path reads file contents.
public struct LocalFolderFileNameIndex: FolderFileNameIndexing {
    private let executable: URL?
    public init(executable: URL? = RipgrepFolderSearchBackend.bundledExecutable) { self.executable = executable }

    public func index(in folder: URL, maximumEntries: Int = 20_000) async throws -> FolderFileNameIndex {
        guard maximumEntries > 0, maximumEntries <= 100_000 else { throw WorkspaceBrowserFailure.entryLimitExceeded(maximumEntries) }
        let process = executable.map { RipgrepProcess(executable: $0, timeout: .seconds(30)) }
        let worker = Task.detached(priority: .userInitiated) {
            try self.indexBlocking(folder: folder, maximumEntries: maximumEntries, process: process)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel(); process?.cancel() }
    }

    public func readFile(in folder: URL, root expected: FolderFileNameRoot, relativePath: String) async throws -> WorkspaceFileRead {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let root = try FolderSearchRoot(path: folder.path)
            guard root.fileNameRoot == expected, let handle = root.open(relativePath) else {
                throw WorkspaceBrowserFailure.invalidPath(relativePath)
            }
            defer { Darwin.close(handle.descriptor) }
            let limit = LocalWorkspaceRootStore.maximumOpenFileBytes
            guard UInt64(handle.info.st_size) <= limit else { throw WorkspaceBrowserFailure.fileTooLarge(actual: UInt64(handle.info.st_size), limit: limit) }
            guard let file = try root.read(handle, maximumBytes: Int(limit)) else { throw WorkspaceBrowserFailure.invalidPath(relativePath) }
            try root.validate(); try Task.checkCancellation()
            return WorkspaceFileRead(url: URL(fileURLWithPath: file.path), result: .init(data: file.data, identity: file.identity))
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private func indexBlocking(folder: URL, maximumEntries: Int, process: RipgrepProcess?) throws -> FolderFileNameIndex {
        let root = try FolderSearchRoot(path: folder.path)
        var paths: [String] = [], skipped = 0, observed = 0, nameBytes = 0, truncated = false
        func admit(_ relative: String) throws -> Bool {
            try Task.checkCancellation(); try process?.check()
            guard observed < maximumEntries, relative.utf8.count <= 16 * 1_024 * 1_024 - nameBytes else { truncated = true; return false }
            observed += 1; nameBytes += relative.utf8.count
            guard let file = root.open(relative) else { skipped += 1; return true }
            Darwin.close(file.descriptor)
            paths.append(relative)
            return true
        }
        if let process {
            let status = try process.run(arguments: ["--no-config", "--no-messages", "--no-ignore-global", "--no-ignore-parent", "--no-require-git", "--files", "--null", "."], directory: root.descriptor) { record in
                guard let name = String(data: record, encoding: .utf8) else { throw FolderSearchFailure.enumerationFailed("unsupported file name") }
                return try admit(name.hasPrefix("./") ? String(name.dropFirst(2)) : name)
            }
            guard status == 0 || status == 1 else { throw FolderSearchFailure.enumerationFailed("filename enumeration failed") }
        } else {
            // Foundation enumeration exposes /private/var even when URL normalization
            // presents the selected root as /var. Derive relative names from realpath.
            guard let resolved = Darwin.realpath(root.url.path, nil) else { throw FolderSearchFailure.invalidRoot(folder.path) }
            let base = String(cString: resolved); free(resolved)
            let prefix = base == "/" ? "/" : base + "/"
            let keys: [URLResourceKey] = [.isDirectoryKey]
            guard let iterator = FileManager.default.enumerator(at: root.url, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in skipped += 1; return true }) else {
                throw FolderSearchFailure.invalidRoot(folder.path)
            }
            for case let url as URL in iterator {
                try Task.checkCancellation()
                guard observed < maximumEntries else { truncated = true; break }
                let values = try url.resourceValues(forKeys: Set(keys))
                if values.isDirectory == true { observed += 1; continue }
                guard url.path.hasPrefix(prefix) else { skipped += 1; continue }
                let relative = String(url.path.dropFirst(prefix.count))
                if try !admit(relative) { break }
            }
        }
        try root.validate(); try Task.checkCancellation()
        return FolderFileNameIndex(root: root.fileNameRoot, relativePaths: paths, isTruncated: truncated, skippedCount: skipped)
    }
}
