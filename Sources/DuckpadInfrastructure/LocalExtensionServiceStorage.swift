import CryptoKit
import Darwin
import DuckpadApplication
import DuckpadDomain
import Foundation

/// Each publisher/plugin gets private opaque state. No filesystem path reaches the guest.
public actor LocalExtensionServiceStorage: ExtensionServiceStorage {
    private let root: URL
    private let maximumBytes = ExtensionListProtocol.maximumStateBytes
    public init(root: URL) { self.root = root }
    public func load(_ identity: ExtensionServiceRegistration) throws -> Data {
        let directory = try directory(identity)
        let fd = open(directory.appendingPathComponent("state.bin").path, O_RDONLY | O_NOFOLLOW)
        if fd < 0 {
            if errno == ENOENT { return Data() }
            throw ExtensionFailure.hostUnavailable("plugin state could not be opened")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_size >= 0, info.st_size <= maximumBytes else {
            throw ExtensionFailure.invalidPackagePath
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw ExtensionFailure.limitExceeded("plugin state") }
        return data
    }
    public func save(_ data: Data, for identity: ExtensionServiceRegistration) throws {
        guard data.count <= maximumBytes else { throw ExtensionFailure.limitExceeded("plugin state") }
        let directory = try directory(identity)
        let file = directory.appendingPathComponent("state.bin")
        let temporary = directory.appendingPathComponent(UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ExtensionFailure.hostUnavailable("plugin state could not be saved") }
        defer { close(fd); unlink(temporary.path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        guard fsync(fd) == 0, rename(temporary.path, file.path) == 0 else {
            throw ExtensionFailure.hostUnavailable("plugin state could not be committed")
        }
    }
    private func directory(_ identity: ExtensionServiceRegistration) throws -> URL {
        let name = identity.extensionID.rawValue
        guard name.range(of: #"^[a-z0-9]+(?:[.-][a-z0-9-]+)+$"#, options: .regularExpression) != nil,
              identity.publisherFingerprint.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
            throw ExtensionFailure.invalidPackagePath
        }
        let publisher = root.appendingPathComponent(name).appendingPathComponent(identity.publisherFingerprint)
        let command = SHA256.hash(data: Data(identity.command.id.rawValue.utf8)).map { String(format: "%02x", $0) }.joined()
        let directories = [root, root.appendingPathComponent(name), publisher, publisher.appendingPathComponent(command)]
        for url in directories {
            if mkdir(url.path, 0o700) != 0 && errno != EEXIST { throw ExtensionFailure.hostUnavailable("plugin storage directory") }
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else {
                throw ExtensionFailure.invalidPackagePath
            }
        }
        return directories.last!
    }
}
