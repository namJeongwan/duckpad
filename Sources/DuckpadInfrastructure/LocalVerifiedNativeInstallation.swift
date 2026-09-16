import Darwin
import DuckpadApplication
import Foundation

/// Immutable descriptor ownership. No operation changes file offsets after
/// construction. Deinitialization closes the snapshot after activation.
final class LocalVerifiedNativeInstallation: VerifiedNativePluginInstallation, @unchecked Sendable {
    struct Entry {
        let name: String
        let descriptor: Int32
        let snapshot: stat
    }
    let directory: URL
    private let descriptor: Int32
    private let snapshot: stat
    private let entries: [Entry]

    init(directory: URL, descriptor: Int32, snapshot: stat, entries: [Entry]) {
        self.directory = directory
        self.descriptor = descriptor
        self.snapshot = snapshot
        self.entries = entries
    }

    deinit {
        entries.forEach { Darwin.close($0.descriptor) }
        Darwin.close(descriptor)
    }

    func validateForLoading() throws {
        var current = stat()
        guard lstat(directory.path, &current) == 0, Self.matches(current, snapshot),
              fstat(descriptor, &current) == 0, Self.matches(current, snapshot) else {
            throw NativePluginValidationFailure.changedPackage
        }
        for entry in entries {
            guard fstat(entry.descriptor, &current) == 0, Self.matches(current, entry.snapshot),
                  fstatat(descriptor, entry.name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  Self.matches(current, entry.snapshot) else { throw NativePluginValidationFailure.changedPackage }
        }
    }

    private static func matches(_ value: stat, _ snapshot: stat) -> Bool {
        value.st_dev == snapshot.st_dev && value.st_ino == snapshot.st_ino &&
        value.st_mode == snapshot.st_mode && value.st_uid == snapshot.st_uid &&
        value.st_size == snapshot.st_size &&
        value.st_mtimespec.tv_sec == snapshot.st_mtimespec.tv_sec &&
        value.st_mtimespec.tv_nsec == snapshot.st_mtimespec.tv_nsec &&
        value.st_ctimespec.tv_sec == snapshot.st_ctimespec.tv_sec &&
        value.st_ctimespec.tv_nsec == snapshot.st_ctimespec.tv_nsec
    }
}
