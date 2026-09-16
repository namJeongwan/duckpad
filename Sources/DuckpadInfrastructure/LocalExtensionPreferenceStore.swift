import Darwin
import DuckpadApplication
import DuckpadDomain
import Foundation

public actor LocalExtensionPreferenceStore: ExtensionGrantStorePort {
    private let root: URL
    private let syncDirectory: @Sendable (Int32) -> Int32
    private var lastGeneration: UInt64 = 0
    public init(root: URL, syncDirectory: @escaping @Sendable (Int32) -> Int32 = { Darwin.fsync($0) }) {
        self.root = root.standardizedFileURL
        self.syncDirectory = syncDirectory
    }
    public nonisolated static func defaultRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Duckpad/ExtensionPolicy", isDirectory: true)
    }

    public func loadPolicy() async throws -> ExtensionPolicySnapshot {
        guard FileManager.default.fileExists(atPath: root.path) else { return ExtensionPolicySnapshot() }
        let directory = try openRoot(create: false); defer { close(directory) }
        let descriptor = openat(directory, "policy-v1.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0, errno == ENOENT { return ExtensionPolicySnapshot() }
        guard descriptor >= 0 else { throw ExtensionFailure.hostUnavailable("extension policy unavailable") }
        defer { close(descriptor) }
        var info = stat(); guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), info.st_size >= 0, info.st_size <= 1_024 * 1_024 else {
            throw ExtensionFailure.hostUnavailable("unsafe extension policy")
        }
        let data = try readAll(descriptor, count: Int(info.st_size))
        let policy = try JSONDecoder().decode(ExtensionPolicySnapshot.self, from: data)
        guard valid(policy) else { throw ExtensionFailure.hostUnavailable("corrupt extension policy") }
        lastGeneration = policy.generation
        return policy
    }

    public func savePolicy(_ policy: ExtensionPolicySnapshot) async throws -> ExtensionPolicyCommit {
        guard valid(policy), policy.generation > lastGeneration else { throw ExtensionFailure.hostUnavailable("stale or invalid extension policy") }
        let data = try JSONEncoder().encode(policy)
        guard data.count <= 1_024 * 1_024 else { throw ExtensionFailure.limitExceeded("extension policy bytes") }
        let directory = try openRoot(create: true)
        defer { close(directory) }
        let temporary = ".policy-\(UUID().uuidString)"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ExtensionFailure.hostUnavailable("policy create failed") }
        var published = false
        defer { close(descriptor); if !published { unlinkat(directory, temporary, 0) } }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard count > 0 else { throw ExtensionFailure.hostUnavailable("policy write failed") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw ExtensionFailure.hostUnavailable("policy sync failed") }
        guard renameat(directory, temporary, directory, "policy-v1.json") == 0 else { throw ExtensionFailure.hostUnavailable("policy rename failed") }
        published = true
        // rename already published this generation. Advance the monotonic
        // guard even when directory durability cannot be proven so an
        // immediate retry cannot re-authorize the same snapshot.
        lastGeneration = policy.generation
        guard syncDirectory(directory) == 0 else { return .durabilityUncertain }
        return .committed
    }

    private func valid(_ policy: ExtensionPolicySnapshot) -> Bool {
        policy.schemaVersion == 1 && policy.enabled.count <= 64 && policy.grants.count <= 1_024 &&
        policy.revokedPublisherFingerprints.count <= 256 && policy.disabledPackageDigests.count <= 256 &&
        policy.enabled.allSatisfy { $0.rawValue.utf8.count <= 128 } &&
        policy.revokedPublisherFingerprints.allSatisfy { $0.utf8.count == 64 } &&
        policy.disabledPackageDigests.allSatisfy { $0.utf8.count == 64 } &&
        policy.grants.allSatisfy {
            $0.extensionID.rawValue.utf8.count <= 128 && $0.packageDigest.utf8.count == 64 &&
            $0.publisherFingerprint.utf8.count == 64 && $0.capabilitySchemaDigest.utf8.count == 64
        }
    }

    private func openRoot(create: Bool) throws -> Int32 {
        var info = stat()
        if lstat(root.path, &info) != 0 {
            guard create, errno == ENOENT else { throw ExtensionFailure.hostUnavailable("extension preference root unavailable") }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard lstat(root.path, &info) == 0 else { throw ExtensionFailure.hostUnavailable("extension preference root unavailable") }
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, (info.st_mode & S_IFLNK) == 0, info.st_uid == geteuid() else {
            throw ExtensionFailure.hostUnavailable("unsafe extension preference root")
        }
        guard chmod(root.path, 0o700) == 0 else { throw ExtensionFailure.hostUnavailable("extension preference permissions") }
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ExtensionFailure.hostUnavailable("extension preference root unavailable") }
        return descriptor
    }

    private func readAll(_ descriptor: Int32, count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count); var offset = 0
        while offset < count {
            let readCount = bytes.withUnsafeMutableBytes { raw in Darwin.read(descriptor, raw.baseAddress!.advanced(by: offset), count - offset) }
            guard readCount > 0 else { throw ExtensionFailure.hostUnavailable("truncated extension policy") }
            offset += readCount
        }
        return Data(bytes)
    }
}
