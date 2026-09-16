import Foundation
import Darwin
import DuckpadApplication
import DuckpadLocalization

/// Reads the immutable execution copy written by the native installer service.
@MainActor final class NativePluginInstallation {
    enum Failure: LocalizedError {
        case authorizationRequired, changedPackage
        var errorDescription: String? {
            switch self {
            case .authorizationRequired: return L10n.text("The native plugin is being installed. Please try again shortly.")
            case .changedPackage: return L10n.text("The installed native plugin has changed. Reinstall its signed package before running it.")
            }
        }
    }
    let directory: URL
    private init(directory: URL) {
        self.directory = directory
    }

    func validate(_ registration: ExtensionServiceRegistration) throws { try Self.validate(registration, at: directory) }

    static func open(_ registration: ExtensionServiceRegistration, root: URL) throws -> NativePluginInstallation {
        let directory = root.appendingPathComponent(registration.packageDigest + ".duckpad-plugin")
        guard FileManager.default.fileExists(atPath: directory.path) else { throw Failure.authorizationRequired }
        let installation = NativePluginInstallation(directory: directory)
        try validate(registration, at: directory)
        return installation
    }

    private static func validate(_ registration: ExtensionServiceRegistration, at directory: URL) throws {
        guard let files = registration.nativeFiles else { throw Failure.changedPackage }
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { throw Failure.changedPackage }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard Set(names) == Set(files.keys) else { throw Failure.changedPackage }
        for (name, bytes) in files {
            guard validName(name) else { throw Failure.changedPackage }
            let file = directory.appendingPathComponent(name)
            try requireFile(file, maximumBytes: bytes.count)
            guard try Data(contentsOf: file) == bytes else { throw Failure.changedPackage }
        }
    }
    private static func requireFile(_ file: URL, maximumBytes: Int) throws {
        var info = stat()
        guard lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_size >= 0, info.st_size <= maximumBytes else { throw Failure.changedPackage }
    }
    private static func validName(_ name: String) -> Bool { !name.isEmpty && name != "." && name != ".." && !name.contains("/") }
}
