import Foundation
import Darwin
import DuckpadApplication
import DuckpadDomain

/// Only the installer XPC service calls this writer in production. Its caller
/// chooses no path: packages are immutable, named by their verified digest.
public actor ManagedNativePackageStore {
    private let root: URL
    private let verifier: LocalExtensionPackageLoader
    public init(root: URL) {
        self.root = root.standardizedFileURL
        verifier = LocalExtensionPackageLoader(root: root, bundledPackages: [])
    }

    public static func appRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Duckpad/NativePluginModules", isDirectory: true)
    }

    public func install(files: [String: Data]) async throws -> String {
        let package = try await verifier.verify(files: files)
        guard package.manifest.runtime.kind == "native", package.manifest.api.contains(ExtensionWorkspaceUseCase.apiVersion) else { throw ExtensionFailure.unsupportedAPI }
        guard NativeModuleCompatibility.supportsCurrentProcess(package.module) else { throw ExtensionFailure.hostUnavailable("native module architecture mismatch") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard root.resolvingSymlinksInPath().path == root.path else { throw ExtensionFailure.invalidPackagePath }
        var info = stat()
        guard lstat(root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == geteuid(), (info.st_mode & 0o022) == 0 else { throw ExtensionFailure.invalidPackagePath }
        let destination = root.appendingPathComponent(package.packageDigest + ".duckpad-plugin")
        if FileManager.default.fileExists(atPath: destination.path) {
            let (existing, _) = try await verifier.readPackage(at: destination)
            guard existing.packageDigest == package.packageDigest else { throw ExtensionFailure.signatureMismatch }
            return package.packageDigest
        }
        let staging = root.appendingPathComponent(".install-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        for (name, bytes) in files {
            let file = staging.appendingPathComponent(name)
            let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, name == "module.dylib" ? 0o500 : 0o400)
            guard fd >= 0 else { throw ExtensionFailure.invalidPackagePath }
            defer { close(fd) }
            try bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    guard count > 0 else { throw ExtensionFailure.hostUnavailable("native package write failed") }
                    offset += count
                }
            }
            guard fsync(fd) == 0 else { throw ExtensionFailure.hostUnavailable("native package flush failed") }
        }
        guard renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            // Another app window/process can finish the same immutable install.
            let (existing, _) = try await verifier.readPackage(at: destination)
            guard existing.packageDigest == package.packageDigest else { throw ExtensionFailure.signatureMismatch }
            return package.packageDigest
        }
        return package.packageDigest
    }
}
