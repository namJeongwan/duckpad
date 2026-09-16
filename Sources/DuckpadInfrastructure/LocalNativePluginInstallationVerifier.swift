import Darwin
import DuckpadApplication
import Foundation

public struct LocalNativePluginInstallationVerifier: NativePluginInstallationVerifying {
    public init() {}

    public func open(_ registration: ExtensionServiceRegistration, root: URL) async throws -> any VerifiedNativePluginInstallation {
        let task = Task.detached(priority: .utility) {
            try Self.verify(registration, root: root)
        }
        return try await withTaskCancellationHandler {
            let verified = try await task.value
            try Task.checkCancellation()
            return verified
        } onCancel: { task.cancel() }
    }

    private static func verify(_ registration: ExtensionServiceRegistration, root: URL) throws -> LocalVerifiedNativeInstallation {
        try Task.checkCancellation()
        guard registration.packageDigest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              let files = registration.nativeFiles, files["module.dylib"] != nil,
              files.count <= 64, files.values.allSatisfy({ $0.count <= 16 * 1_024 * 1_024 }),
              files.values.reduce(0, { $0 + $1.count }) <= 32 * 1_024 * 1_024,
              files.keys.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\\") && !$0.contains("\0") }) else {
            throw NativePluginValidationFailure.changedPackage
        }
        let directory = root.appendingPathComponent(registration.packageDigest + ".duckpad-plugin").standardizedFileURL
        guard directory.resolvingSymlinksInPath().path == directory.path else { throw NativePluginValidationFailure.changedPackage }
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw errno == ENOENT ? NativePluginValidationFailure.installationRequired : .changedPackage
        }
        var entries: [LocalVerifiedNativeInstallation.Entry] = []
        var transferred = false
        defer {
            if !transferred {
                entries.forEach { Darwin.close($0.descriptor) }
                Darwin.close(descriptor)
            }
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else { throw NativePluginValidationFailure.changedPackage }
        guard Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == Set(files.keys) else {
            throw NativePluginValidationFailure.changedPackage
        }
        for (name, expected) in files {
            try Task.checkCancellation()
            let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard file >= 0 else { throw NativePluginValidationFailure.changedPackage }
            var snapshot = stat()
            guard fstat(file, &snapshot) == 0, snapshot.st_mode & S_IFMT == S_IFREG,
                  snapshot.st_uid == geteuid(), snapshot.st_mode & 0o022 == 0,
                  snapshot.st_size == expected.count else {
                Darwin.close(file)
                throw NativePluginValidationFailure.changedPackage
            }
            entries.append(.init(name: name, descriptor: file, snapshot: snapshot))
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            var offset = 0
            while offset < expected.count {
                try Task.checkCancellation()
                let amount = min(buffer.count, expected.count - offset)
                let count = buffer.withUnsafeMutableBytes { Darwin.read(file, $0.baseAddress, amount) }
                if count < 0, errno == EINTR { continue }
                guard count > 0, expected.withUnsafeBytes({ raw in
                    buffer.withUnsafeBytes { memcmp($0.baseAddress!, raw.baseAddress!.advanced(by: offset), count) == 0 }
                }) else { throw NativePluginValidationFailure.changedPackage }
                offset += count
            }
        }
        let verified = LocalVerifiedNativeInstallation(directory: directory, descriptor: descriptor, snapshot: info, entries: entries)
        transferred = true
        try verified.validateForLoading()
        return verified
    }
}
