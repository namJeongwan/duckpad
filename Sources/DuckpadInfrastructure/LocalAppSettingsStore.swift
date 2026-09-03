import Darwin
import DuckpadApplication
import DuckpadDomain
import Foundation

public enum LocalAppSettingsStoreFault: Sendable {
    case none
    case beforeRename
    case afterRename
}

public actor LocalAppSettingsStore: AppSettingsStore {
    public nonisolated static let maximumBytes = 1 * 1_024 * 1_024

    private let archiveURL: URL
    private let fileManager: FileManager
    private let fault: LocalAppSettingsStoreFault
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        archiveURL: URL,
        fileManager: FileManager = .default,
        fault: LocalAppSettingsStoreFault = .none
    ) {
        self.archiveURL = archiveURL.standardizedFileURL
        self.fileManager = fileManager
        self.fault = fault
        encoder.outputFormatting = [.sortedKeys]
    }

    public static func defaultArchiveURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("Duckpad", isDirectory: true)
            .appendingPathComponent("Settings-v1.json", isDirectory: false)
    }

    public func load() async throws(AppSettingsStoreError) -> AppSettings? {
        let directory = Darwin.open(
            archiveURL.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        if directory < 0 {
            if errno == ENOENT { return nil }
            throw .readFailed(Self.posixMessage("open settings directory"))
        }
        defer { Darwin.close(directory) }

        let descriptor = Darwin.openat(
            directory,
            archiveURL.lastPathComponent,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        )
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw .readFailed(Self.posixMessage("open settings archive"))
        }
        defer { Darwin.close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0 else {
            throw .readFailed(Self.posixMessage("inspect settings archive"))
        }
        guard (before.st_mode & S_IFMT) == S_IFREG else {
            throw .corrupt("settings archive is not a regular file")
        }
        guard before.st_size >= 0, before.st_size <= Self.maximumBytes else {
            throw .corrupt("settings archive exceeds the size limit")
        }

        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while data.count <= Self.maximumBytes {
            let requested = min(buffer.count, Self.maximumBytes + 1 - data.count)
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, requested)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw .readFailed(Self.posixMessage("read settings archive"))
            }
            data.append(buffer, count: count)
        }
        guard data.count <= Self.maximumBytes else {
            throw .corrupt("settings archive exceeds the size limit")
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0 else {
            throw .readFailed(Self.posixMessage("reinspect settings archive"))
        }
        guard Self.sameSnapshot(before, after), Int64(data.count) == after.st_size else {
            throw .readFailed("settings archive changed while reading")
        }
        do {
            return try decoder.decode(AppSettings.self, from: data)
        } catch {
            throw .corrupt(error.localizedDescription)
        }
    }

    public func save(_ settings: AppSettings) async throws(AppSettingsStoreError) {
        let data: Data
        do {
            data = try encoder.encode(settings)
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
        guard data.count <= Self.maximumBytes else {
            throw .writeFailed("settings archive exceeds the size limit")
        }

        let directoryURL = archiveURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
        guard chmod(directoryURL.path, 0o700) == 0 else {
            throw .writeFailed(Self.posixMessage("secure settings directory"))
        }
        let directory = Darwin.open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directory >= 0 else {
            throw .writeFailed(Self.posixMessage("open settings directory"))
        }
        defer { Darwin.close(directory) }

        let temporaryName = ".duckpad-settings-\(UUID().uuidString).tmp"
        let descriptor = Darwin.openat(
            directory,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw .writeFailed(Self.posixMessage("create settings temporary file"))
        }
        var descriptorOpen = true
        var published = false
        defer {
            if descriptorOpen { Darwin.close(descriptor) }
            if !published { _ = unlinkat(directory, temporaryName, 0) }
        }

        do {
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let count = Darwin.write(
                        descriptor,
                        raw.baseAddress!.advanced(by: offset),
                        raw.count - offset
                    )
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else {
                        throw AppSettingsStoreError.writeFailed(
                            Self.posixMessage("write settings temporary file")
                        )
                    }
                    offset += count
                }
            }
            guard fchmod(descriptor, 0o600) == 0 else {
                throw AppSettingsStoreError.writeFailed(Self.posixMessage("secure settings temporary file"))
            }
            guard fsync(descriptor) == 0 else {
                throw AppSettingsStoreError.writeFailed(Self.posixMessage("sync settings temporary file"))
            }
            guard fcntl(descriptor, F_FULLFSYNC) == 0 else {
                throw AppSettingsStoreError.writeFailed(Self.posixMessage("full sync settings temporary file"))
            }
            guard Darwin.close(descriptor) == 0 else {
                throw AppSettingsStoreError.writeFailed(Self.posixMessage("close settings temporary file"))
            }
            descriptorOpen = false
            if case .beforeRename = fault {
                throw AppSettingsStoreError.writeFailed("injected interruption before settings publish")
            }
            guard renameat(directory, temporaryName, directory, archiveURL.lastPathComponent) == 0 else {
                throw AppSettingsStoreError.writeFailed(Self.posixMessage("publish settings archive"))
            }
            published = true
            if case .afterRename = fault {
                throw AppSettingsStoreError.writeUncertain("injected interruption after settings publish")
            }
            guard fsync(directory) == 0 else {
                throw AppSettingsStoreError.writeUncertain(Self.posixMessage("sync settings directory"))
            }
        } catch let failure as AppSettingsStoreError {
            throw failure
        } catch {
            throw .writeFailed(error.localizedDescription)
        }
    }

    private static func sameSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func posixMessage(_ operation: String) -> String {
        "\(operation): \(String(cString: strerror(errno)))"
    }
}
