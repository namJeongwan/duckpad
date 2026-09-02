import CryptoKit
import Darwin
import DuckpadApplication
import DuckpadDomain
import Foundation

public enum RecoveryStoreFault: Sendable {
    case none
    case afterFirstBlob
    case syncBlobsDirectory
    case beforeManifest
    case afterManifest
    case afterPublish
}

/// Versioned crash-recovery store. A generation becomes discoverable only when
/// its manifest and every referenced blob are complete and the generation
/// directory has been atomically published.
public actor LocalRecoveryStore: RecoveryStore {
    private struct BlobRecord: Codable {
        let bufferID: BufferID
        let revision: UInt64
        let file: String
        let byteCount: Int
        let sha256: String
        let viewState: EditorViewState
    }

    private struct Manifest: Codable {
        let schemaVersion: Int
        let generation: UInt64
        let session: ScratchSession
        let buffers: [BlobRecord]
    }

    public let root: URL
    private let fault: RecoveryStoreFault

    public init(root: URL, fault: RecoveryStoreFault = .none) {
        self.root = root.standardizedFileURL
        self.fault = fault
    }

    public static func defaultRoot(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Duckpad/Recovery", isDirectory: true)
    }

    public func loadLatest() async throws(SessionStoreError) -> StoredRecoveryArchive? {
        let root = self.root
        do {
            return try await Task.detached(priority: .utility) { try Self.loadBlocking(root: root) }.value
        } catch let error as SessionStoreError { throw error }
        catch { throw .corrupt(String(describing: error)) }
    }

    public func commit(
        _ archive: RecoveryArchive,
        generation: PersistenceGeneration
    ) async throws(SessionStoreError) -> SessionCommitResult {
        let root = self.root
        let fault = self.fault
        do {
            if let stored = try await Task.detached(priority: .utility, operation: {
                try Self.loadBlocking(root: root)
            }).value, stored.generation >= generation {
                guard stored.generation != generation || stored.archive == archive else {
                    throw SessionStoreError.corrupt("recovery generation collision")
                }
                return .superseded(durableGeneration: stored.generation)
            }
            let committed = try await Task.detached(priority: .utility) {
                try Self.commitBlocking(archive, generation: generation, root: root, fault: fault)
            }.value
            return committed ? .committed : .superseded(durableGeneration: generation)
        } catch let error as SessionStoreError { throw error }
        catch { throw .unavailable(String(describing: error)) }
    }

    public func reset() async throws(SessionStoreError) {
        let root = self.root
        do {
            try await Task.detached(priority: .utility) {
                guard FileManager.default.fileExists(atPath: root.path) else { return }
                try FileManager.default.removeItem(at: root)
                try Self.syncDirectory(root.deletingLastPathComponent())
            }.value
        } catch { throw .unavailable("reset recovery: \(error)") }
    }

    private static func loadBlocking(root: URL) throws -> StoredRecoveryArchive? {
        let generations = root.appendingPathComponent("generations", isDirectory: true)
        guard FileManager.default.fileExists(atPath: generations.path) else { return nil }
        let names = try FileManager.default.contentsOfDirectory(atPath: generations.path)
        let candidates = names.compactMap { name -> (UInt64, String)? in
            guard !name.hasPrefix("."), let value = UInt64(name) else { return nil }
            return (value, name)
        }.sorted { $0.0 > $1.0 }
        var rejected = 0
        var rejectedDirectories: [URL] = []
        for (value, name) in candidates {
            let directory = generations.appendingPathComponent(name, isDirectory: true)
            do {
                let stored = try loadGeneration(
                    directory,
                    expectedGeneration: value
                )
                for rejectedDirectory in rejectedDirectories {
                    try FileManager.default.removeItem(at: rejectedDirectory)
                }
                try cleanupOrphans(in: generations)
                if !rejectedDirectories.isEmpty { try syncDirectory(generations) }
                return stored
            } catch {
                rejected += 1
                rejectedDirectories.append(directory)
            }
        }
        if rejected > 0 { throw SessionStoreError.corrupt("no valid recovery generation") }
        return nil
    }

    private static func loadGeneration(_ directory: URL, expectedGeneration: UInt64) throws -> StoredRecoveryArchive {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(Manifest.self, from: data)
        guard manifest.schemaVersion == 1, manifest.generation == expectedGeneration else {
            throw SessionStoreError.corrupt("manifest version/generation mismatch")
        }
        let restoredSession = try ScratchSession(
            id: manifest.session.id,
            tabs: manifest.session.tabs,
            documents: manifest.session.documents,
            buffers: manifest.session.buffers,
            fileBindings: manifest.session.fileBindings,
            activeTabID: manifest.session.activeTabID,
            activationHistory: manifest.session.activationHistory,
            nextUntitledNumber: manifest.session.recoveryNextUntitledNumber
        )
        guard Set(manifest.buffers.map(\.bufferID)).count == manifest.buffers.count,
              Set(manifest.buffers.map(\.bufferID)) == Set(restoredSession.buffers.keys) else {
            throw SessionStoreError.corrupt("manifest buffer set mismatch")
        }
        var buffers: [BufferID: EditorRecoverySnapshot] = [:]
        for record in manifest.buffers {
            guard record.file == "\(record.bufferID.rawValue.uuidString.lowercased()).utf8",
                  record.byteCount >= 0 else {
                throw SessionStoreError.corrupt("unsafe blob record")
            }
            let blobURL = directory.appendingPathComponent("blobs", isDirectory: true).appendingPathComponent(record.file)
            let blob = try Data(contentsOf: blobURL, options: [.mappedIfSafe])
            guard blob.count == record.byteCount, digest(blob) == record.sha256,
                  String(data: blob, encoding: .utf8) != nil,
                  restoredSession.buffers[record.bufferID]?.revision == record.revision,
                  valid(record.viewState, for: blob) else {
                throw SessionStoreError.corrupt("blob validation failed")
            }
            buffers[record.bufferID] = EditorRecoverySnapshot(
                bufferID: record.bufferID,
                revision: record.revision,
                utf8: blob,
                viewState: record.viewState
            )
        }
        return StoredRecoveryArchive(
            archive: RecoveryArchive(session: restoredSession, buffers: buffers),
            generation: PersistenceGeneration(rawValue: expectedGeneration)
        )
    }

    private static func commitBlocking(
        _ archive: RecoveryArchive,
        generation: PersistenceGeneration,
        root: URL,
        fault: RecoveryStoreFault
    ) throws -> Bool {
        guard Set(archive.buffers.keys) == Set(archive.session.buffers.keys) else {
            throw SessionStoreError.corrupt("archive buffer set mismatch")
        }
        let generations = root.appendingPathComponent("generations", isDirectory: true)
        try secureDirectoryChain(root)
        try secureDirectoryChain(generations)
        let temporary = generations.appendingPathComponent(
            ".tmp-\(generation.rawValue)-\(UUID().uuidString)",
            isDirectory: true
        )
        let blobs = temporary.appendingPathComponent("blobs", isDirectory: true)
        try secureDirectory(temporary)
        try secureDirectory(blobs)
        var records: [BlobRecord] = []
        let ordered = archive.buffers.values.sorted { $0.bufferID.rawValue.uuidString < $1.bufferID.rawValue.uuidString }
        for (index, snapshot) in ordered.enumerated() {
            guard archive.session.buffers[snapshot.bufferID]?.revision == snapshot.revision,
                  String(data: snapshot.utf8, encoding: .utf8) != nil,
                  valid(snapshot.viewState, for: snapshot.utf8) else {
                throw SessionStoreError.corrupt("invalid archive buffer")
            }
            let file = "\(snapshot.bufferID.rawValue.uuidString.lowercased()).utf8"
            try writeDurable(snapshot.utf8, to: blobs.appendingPathComponent(file))
            records.append(BlobRecord(
                bufferID: snapshot.bufferID,
                revision: snapshot.revision,
                file: file,
                byteCount: snapshot.utf8.count,
                sha256: digest(snapshot.utf8),
                viewState: snapshot.viewState
            ))
            if index == 0, case .afterFirstBlob = fault {
                throw SessionStoreError.unavailable("injected interruption after blob")
            }
        }
        if case .syncBlobsDirectory = fault {
            throw SessionStoreError.unavailable("injected blobs directory sync failure")
        }
        // File fsync does not make the containing directory entry durable.
        // The manifest must never reference blobs whose names were not synced.
        try syncDirectory(blobs)
        if case .beforeManifest = fault {
            throw SessionStoreError.unavailable("injected interruption before manifest")
        }
        let manifest = Manifest(
            schemaVersion: 1,
            generation: generation.rawValue,
            session: archive.session,
            buffers: records
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try writeDurable(try encoder.encode(manifest), to: temporary.appendingPathComponent("manifest.json"))
        try syncDirectory(temporary)
        if case .afterManifest = fault {
            throw SessionStoreError.unavailable("injected interruption after manifest")
        }
        let final = generations.appendingPathComponent(String(format: "%020llu", generation.rawValue), isDirectory: true)
        guard renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, final.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST {
                let winner = try loadGeneration(final, expectedGeneration: generation.rawValue)
                guard winner.archive == archive else {
                    throw SessionStoreError.corrupt("recovery generation collision")
                }
                return false
            }
            throw posix("publish recovery generation")
        }
        if case .afterPublish = fault {
            throw SessionStoreError.unavailable("injected interruption after publish")
        }
        try syncDirectory(generations)
        try retainNewestTwo(in: generations)
        return true
    }

    private static func secureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(url.path, 0o700) == 0 else { throw posix("chmod directory") }
    }

    private static func secureDirectoryChain(_ url: URL) throws {
        var missing: [URL] = []
        var cursor = url
        while !FileManager.default.fileExists(atPath: cursor.path) {
            missing.append(cursor)
            let parent = cursor.deletingLastPathComponent()
            guard parent.path != cursor.path else { break }
            cursor = parent
        }
        for directory in missing.reversed() {
            try secureDirectory(directory)
            try syncDirectory(directory.deletingLastPathComponent())
        }
        try secureDirectory(url)
    }

    private static func writeDurable(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posix("create recovery file") }
        var closeNeeded = true
        defer { if closeNeeded { _ = Darwin.close(descriptor) } }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard count > 0 else { throw posix("write recovery file") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw posix("fsync recovery file") }
        guard fcntl(descriptor, F_FULLFSYNC) == 0 else { throw posix("full sync recovery file") }
        guard fchmod(descriptor, 0o600) == 0 else { throw posix("chmod recovery file") }
        guard Darwin.close(descriptor) == 0 else { throw posix("close recovery file") }
        closeNeeded = false
    }

    private static func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posix("open recovery directory") }
        guard fsync(descriptor) == 0 else {
            let error = posix("sync recovery directory")
            _ = Darwin.close(descriptor)
            throw error
        }
        guard Darwin.close(descriptor) == 0 else { throw posix("close recovery directory") }
    }

    private static func retainNewestTwo(in generations: URL) throws {
        let entries = try FileManager.default.contentsOfDirectory(atPath: generations.path)
        let ordered = entries.compactMap { UInt64($0).map { ($0, $0.description) } }.sorted { $0.0 > $1.0 }
        for (_, name) in ordered.dropFirst(2) {
            try FileManager.default.removeItem(at: generations.appendingPathComponent(String(format: "%020llu", UInt64(name)!)))
        }
        try syncDirectory(generations)
    }

    private static func cleanupOrphans(in generations: URL) throws {
        var removed = false
        for name in try FileManager.default.contentsOfDirectory(atPath: generations.path) where name.hasPrefix(".tmp-") {
            try FileManager.default.removeItem(at: generations.appendingPathComponent(name))
            removed = true
        }
        if removed { try syncDirectory(generations) }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func valid(_ state: EditorViewState, for utf8: Data) -> Bool {
        guard state.anchorUTF8 >= 0,
              state.caretUTF8 >= 0,
              state.firstVisibleLine >= 0,
              state.horizontalScrollOffset >= 0,
              state.anchorUTF8 <= utf8.count,
              state.caretUTF8 <= utf8.count else { return false }
        return isUTF8Boundary(state.anchorUTF8, in: utf8)
            && isUTF8Boundary(state.caretUTF8, in: utf8)
    }

    private static func isUTF8Boundary(_ offset: Int, in utf8: Data) -> Bool {
        offset == 0 || offset == utf8.count || (utf8[offset] & 0xC0) != 0x80
    }

    private static func posix(_ operation: String) -> SessionStoreError {
        .unavailable("\(operation): \(String(cString: strerror(errno)))")
    }
}
