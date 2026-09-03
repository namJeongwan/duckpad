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

/// Keeps a restored recovery directory bound to the exact inode discovered
/// below its private parent. Operations use a duplicated descriptor rather
/// than reopening the user-visible path after validation.
public final class VerifiedRecoveryRoot: @unchecked Sendable {
    public let displayURL: URL
    fileprivate let entryName: String
    fileprivate let parentDescriptor: Int32
    fileprivate var rootDescriptor: Int32
    fileprivate var isDetached = false
    fileprivate let lock = NSLock()
    var resetBeforeRootUnlinkForTesting: (@Sendable () throws -> Void)?

    fileprivate init(displayURL: URL, entryName: String, parentDescriptor: Int32, rootDescriptor: Int32) {
        self.displayURL = displayURL.standardizedFileURL
        self.entryName = entryName
        self.parentDescriptor = parentDescriptor
        self.rootDescriptor = rootDescriptor
    }

    deinit {
        Darwin.close(rootDescriptor)
        Darwin.close(parentDescriptor)
    }

    fileprivate func duplicateRootDescriptor() throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        let descriptor = Darwin.dup(rootDescriptor)
        guard descriptor >= 0 else { throw LocalRecoveryStore.posix("duplicate recovery root") }
        return descriptor
    }

    fileprivate func duplicateWritableRootDescriptor() throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        if isDetached {
            guard mkdirat(parentDescriptor, entryName, 0o700) == 0 else {
                throw LocalRecoveryStore.posix("recreate detached recovery root")
            }
            let replacement = openat(
                parentDescriptor,
                entryName,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard replacement >= 0 else {
                throw LocalRecoveryStore.posix("open detached recovery root")
            }
            let previous = rootDescriptor
            rootDescriptor = replacement
            isDetached = false
            Darwin.close(previous)
            guard fsync(parentDescriptor) == 0 else {
                throw LocalRecoveryStore.posix("sync recreated recovery parent")
            }
        }
        let descriptor = Darwin.dup(rootDescriptor)
        guard descriptor >= 0 else { throw LocalRecoveryStore.posix("duplicate writable recovery root") }
        return descriptor
    }
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
    private let verifiedRoot: VerifiedRecoveryRoot?

    public init(root: URL, fault: RecoveryStoreFault = .none) {
        self.root = root.standardizedFileURL
        self.fault = fault
        verifiedRoot = nil
    }

    public init(verifiedRoot: VerifiedRecoveryRoot, fault: RecoveryStoreFault = .none) {
        root = verifiedRoot.displayURL
        self.fault = fault
        self.verifiedRoot = verifiedRoot
    }

    public static func defaultRoot(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Duckpad/Recovery", isDirectory: true)
    }

    public func loadLatest() async throws(SessionStoreError) -> StoredRecoveryArchive? {
        let root = self.root
        let verifiedRoot = self.verifiedRoot
        do {
            return try await Task.detached(priority: .utility) {
                guard let verifiedRoot else { return try Self.loadBlocking(root: root) }
                let descriptor = try verifiedRoot.duplicateRootDescriptor()
                defer { Darwin.close(descriptor) }
                return try Self.loadBlocking(rootDescriptor: descriptor)
            }.value
        } catch let error as SessionStoreError { throw error }
        catch { throw .corrupt(String(describing: error)) }
    }

    public func commit(
        _ archive: RecoveryArchive,
        generation: PersistenceGeneration
    ) async throws(SessionStoreError) -> SessionCommitResult {
        let root = self.root
        let fault = self.fault
        let verifiedRoot = self.verifiedRoot
        do {
            if let stored = try await Task.detached(priority: .utility, operation: {
                guard let verifiedRoot else { return try Self.loadBlocking(root: root) }
                let descriptor = try verifiedRoot.duplicateRootDescriptor()
                defer { Darwin.close(descriptor) }
                return try Self.loadBlocking(rootDescriptor: descriptor)
            }).value, stored.generation >= generation {
                guard stored.generation != generation || stored.archive == archive else {
                    throw SessionStoreError.corrupt("recovery generation collision")
                }
                return .superseded(durableGeneration: stored.generation)
            }
            let committed = try await Task.detached(priority: .utility) {
                guard let verifiedRoot else {
                    return try Self.commitBlocking(archive, generation: generation, root: root, fault: fault)
                }
                let descriptor = try verifiedRoot.duplicateWritableRootDescriptor()
                defer { Darwin.close(descriptor) }
                return try Self.commitBlocking(
                    archive,
                    generation: generation,
                    rootDescriptor: descriptor,
                    fault: fault
                )
            }.value
            return committed ? .committed : .superseded(durableGeneration: generation)
        } catch let error as SessionStoreError { throw error }
        catch { throw .unavailable(String(describing: error)) }
    }

    public func reset() async throws(SessionStoreError) {
        let root = self.root
        let verifiedRoot = self.verifiedRoot
        do {
            try await Task.detached(priority: .utility) {
                if let verifiedRoot {
                    try Self.resetVerifiedRoot(verifiedRoot)
                    return
                }
                guard FileManager.default.fileExists(atPath: root.path) else { return }
                try FileManager.default.removeItem(at: root)
                try Self.syncDirectory(root.deletingLastPathComponent())
            }.value
        } catch { throw .unavailable("reset recovery: \(error)") }
    }

    public nonisolated static func discoverVerifiedRoots(
        in container: URL,
        maximumRawEntries: Int = 1_024,
        maximumRoots: Int = 31
    ) -> [VerifiedRecoveryRoot] {
        guard maximumRawEntries > 0, maximumRoots > 0 else { return [] }
        let parent = Darwin.open(container.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { return [] }
        defer { Darwin.close(parent) }
        let streamDescriptor = Darwin.dup(parent)
        guard streamDescriptor >= 0, let stream = fdopendir(streamDescriptor) else {
            if streamDescriptor >= 0 { Darwin.close(streamDescriptor) }
            return []
        }
        defer { closedir(stream) }
        var roots: [VerifiedRecoveryRoot] = []
        var rawCount = 0
        while let pointer = readdir(stream) {
            var entry = pointer.pointee
            let name = withUnsafePointer(to: &entry.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            rawCount += 1
            guard rawCount <= maximumRawEntries else { return [] }
            guard !name.hasPrefix("."), UUID(uuidString: name) != nil else { continue }
            var entryInfo = stat()
            guard fstatat(parent, name, &entryInfo, AT_SYMLINK_NOFOLLOW) == 0,
                  entryInfo.st_mode & S_IFMT == S_IFDIR else { continue }
            let rootDescriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard rootDescriptor >= 0 else { continue }
            var openedInfo = stat()
            guard fstat(rootDescriptor, &openedInfo) == 0,
                  openedInfo.st_dev == entryInfo.st_dev,
                  openedInfo.st_ino == entryInfo.st_ino else {
                Darwin.close(rootDescriptor)
                continue
            }
            let parentCopy = Darwin.dup(parent)
            guard parentCopy >= 0 else {
                Darwin.close(rootDescriptor)
                return []
            }
            roots.append(VerifiedRecoveryRoot(
                displayURL: container.appendingPathComponent(name, isDirectory: true),
                entryName: name,
                parentDescriptor: parentCopy,
                rootDescriptor: rootDescriptor
            ))
            guard roots.count <= maximumRoots else { return [] }
        }
        return roots.sorted { $0.displayURL.lastPathComponent < $1.displayURL.lastPathComponent }
    }

    private static func resetVerifiedRoot(_ verifiedRoot: VerifiedRecoveryRoot) throws {
        verifiedRoot.lock.lock()
        defer { verifiedRoot.lock.unlock() }
        if verifiedRoot.isDetached { return }
        var openedInfo = stat()
        var entryInfo = stat()
        guard fstat(verifiedRoot.rootDescriptor, &openedInfo) == 0,
              fstatat(
                verifiedRoot.parentDescriptor,
                verifiedRoot.entryName,
                &entryInfo,
                AT_SYMLINK_NOFOLLOW
              ) == 0,
              entryInfo.st_mode & S_IFMT == S_IFDIR,
              openedInfo.st_dev == entryInfo.st_dev,
              openedInfo.st_ino == entryInfo.st_ino else {
            throw SessionStoreError.unavailable("verified recovery root identity changed")
        }
        var removedEntries = 0
        try removeContents(
            of: verifiedRoot.rootDescriptor,
            depth: 0,
            removedEntries: &removedEntries
        )
        try verifiedRoot.resetBeforeRootUnlinkForTesting?()
        var finalEntryInfo = stat()
        guard fstatat(
            verifiedRoot.parentDescriptor,
            verifiedRoot.entryName,
            &finalEntryInfo,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
        finalEntryInfo.st_mode & S_IFMT == S_IFDIR,
        openedInfo.st_dev == finalEntryInfo.st_dev,
        openedInfo.st_ino == finalEntryInfo.st_ino else {
            throw SessionStoreError.unavailable("verified recovery root replaced during reset")
        }
        guard unlinkat(
            verifiedRoot.parentDescriptor,
            verifiedRoot.entryName,
            AT_REMOVEDIR
        ) == 0 else { throw posix("remove verified recovery root") }
        verifiedRoot.isDetached = true
        guard fsync(verifiedRoot.parentDescriptor) == 0 else {
            throw posix("sync verified recovery parent")
        }
    }

    private static func removeContents(
        of directory: Int32,
        depth: Int,
        removedEntries: inout Int
    ) throws {
        guard depth <= 16 else { throw SessionStoreError.unavailable("recovery tree depth exceeds limit") }
        let copy = Darwin.dup(directory)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { Darwin.close(copy) }
            throw posix("enumerate recovery tree")
        }
        defer { closedir(stream) }
        while let pointer = readdir(stream) {
            var entry = pointer.pointee
            let name = withUnsafePointer(to: &entry.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            removedEntries += 1
            guard removedEntries <= 100_000 else {
                throw SessionStoreError.unavailable("recovery tree entry count exceeds limit")
            }
            var before = stat()
            guard fstatat(directory, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw posix("inspect recovery tree entry")
            }
            if before.st_mode & S_IFMT == S_IFDIR {
                let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw posix("open recovery tree directory") }
                do {
                    var opened = stat()
                    guard fstat(child, &opened) == 0,
                          opened.st_dev == before.st_dev,
                          opened.st_ino == before.st_ino else {
                        throw SessionStoreError.unavailable("recovery tree directory identity changed")
                    }
                    try removeContents(of: child, depth: depth + 1, removedEntries: &removedEntries)
                    var after = stat()
                    guard fstatat(directory, name, &after, AT_SYMLINK_NOFOLLOW) == 0,
                          after.st_dev == opened.st_dev,
                          after.st_ino == opened.st_ino else {
                        throw SessionStoreError.unavailable("recovery tree directory replaced during reset")
                    }
                    guard unlinkat(directory, name, AT_REMOVEDIR) == 0 else {
                        throw posix("remove recovery tree directory")
                    }
                    Darwin.close(child)
                } catch {
                    Darwin.close(child)
                    throw error
                }
            } else {
                guard unlinkat(directory, name, 0) == 0 else {
                    throw posix("remove recovery tree entry")
                }
            }
        }
        guard fsync(directory) == 0 else { throw posix("sync recovery tree directory") }
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

    private static func loadBlocking(rootDescriptor: Int32) throws -> StoredRecoveryArchive? {
        let generations = openat(
            rootDescriptor,
            "generations",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        if generations < 0, errno == ENOENT { return nil }
        guard generations >= 0 else { throw posix("open verified recovery generations") }
        defer { Darwin.close(generations) }
        let names = try directoryNames(in: generations, maximumEntries: 100_000)
        let candidates = names.compactMap { name -> (UInt64, String)? in
            guard !name.hasPrefix("."), let value = UInt64(name) else { return nil }
            return (value, name)
        }.sorted { $0.0 > $1.0 }
        var rejected = 0
        var rejectedNames: [String] = []
        for (value, name) in candidates {
            let directory = openat(
                generations,
                name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard directory >= 0 else {
                rejected += 1
                rejectedNames.append(name)
                continue
            }
            do {
                let stored = try loadGeneration(directory, expectedGeneration: value)
                for rejectedName in rejectedNames {
                    try removeDirectory(named: rejectedName, in: generations)
                }
                for orphan in names where orphan.hasPrefix(".tmp-") {
                    try removeDirectory(named: orphan, in: generations)
                }
                if !rejectedNames.isEmpty || names.contains(where: { $0.hasPrefix(".tmp-") }) {
                    guard fsync(generations) == 0 else {
                        throw posix("sync cleaned verified recovery generations")
                    }
                }
                Darwin.close(directory)
                return stored
            } catch {
                Darwin.close(directory)
                rejected += 1
                rejectedNames.append(name)
            }
        }
        if rejected > 0 { throw SessionStoreError.corrupt("no valid recovery generation") }
        return nil
    }

    private static func removeDirectory(named name: String, in parent: Int32) throws {
        let directory = openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directory >= 0 else { throw posix("open removable recovery directory") }
        do {
            var opened = stat()
            guard fstat(directory, &opened) == 0 else {
                throw posix("inspect removable recovery directory")
            }
            var removedEntries = 0
            try removeContents(of: directory, depth: 0, removedEntries: &removedEntries)
            var current = stat()
            guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  current.st_dev == opened.st_dev,
                  current.st_ino == opened.st_ino else {
                throw SessionStoreError.unavailable("recovery directory identity changed before removal")
            }
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else {
                throw posix("remove recovery directory")
            }
            Darwin.close(directory)
        } catch {
            Darwin.close(directory)
            throw error
        }
    }

    private static func loadGeneration(
        _ directory: Int32,
        expectedGeneration: UInt64
    ) throws -> StoredRecoveryArchive {
        let manifestData = try readRegularFile(
            in: directory,
            name: "manifest.json",
            maximumBytes: 16 * 1_024 * 1_024
        )
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
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
        let blobs = openat(
            directory,
            "blobs",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard blobs >= 0 else { throw posix("open verified recovery blobs") }
        defer { Darwin.close(blobs) }
        var buffers: [BufferID: EditorRecoverySnapshot] = [:]
        for record in manifest.buffers {
            guard record.file == "\(record.bufferID.rawValue.uuidString.lowercased()).utf8",
                  record.byteCount >= 0 else {
                throw SessionStoreError.corrupt("unsafe blob record")
            }
            let blob = try readRegularFile(
                in: blobs,
                name: record.file,
                maximumBytes: record.byteCount
            )
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

    private static func directoryNames(in directory: Int32, maximumEntries: Int) throws -> [String] {
        let copy = Darwin.dup(directory)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { Darwin.close(copy) }
            throw posix("enumerate verified recovery directory")
        }
        defer { closedir(stream) }
        var names: [String] = []
        while let pointer = readdir(stream) {
            var entry = pointer.pointee
            let name = withUnsafePointer(to: &entry.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            names.append(name)
            guard names.count <= maximumEntries else {
                throw SessionStoreError.corrupt("recovery directory entry count exceeds limit")
            }
        }
        return names
    }

    private static func readRegularFile(
        in directory: Int32,
        name: String,
        maximumBytes: Int
    ) throws -> Data {
        guard maximumBytes >= 0 else { throw SessionStoreError.corrupt("negative recovery file limit") }
        var before = stat()
        guard fstatat(directory, name, &before, AT_SYMLINK_NOFOLLOW) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0,
              UInt64(before.st_size) <= UInt64(maximumBytes) else {
            throw SessionStoreError.corrupt("unsafe recovery file")
        }
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posix("open verified recovery file") }
        defer { Darwin.close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              opened.st_dev == before.st_dev,
              opened.st_ino == before.st_ino,
              opened.st_size == before.st_size else {
            throw SessionStoreError.corrupt("recovery file identity changed")
        }
        var data = Data(count: Int(opened.st_size))
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            }
            guard count > 0 else { throw posix("read verified recovery file") }
            offset += count
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              after.st_dev == opened.st_dev,
              after.st_ino == opened.st_ino,
              after.st_size == opened.st_size,
              after.st_mtimespec.tv_sec == opened.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == opened.st_mtimespec.tv_nsec else {
            throw SessionStoreError.corrupt("recovery file changed during read")
        }
        return data
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

    private static func commitBlocking(
        _ archive: RecoveryArchive,
        generation: PersistenceGeneration,
        rootDescriptor: Int32,
        fault: RecoveryStoreFault
    ) throws -> Bool {
        guard Set(archive.buffers.keys) == Set(archive.session.buffers.keys) else {
            throw SessionStoreError.corrupt("archive buffer set mismatch")
        }
        guard fchmod(rootDescriptor, 0o700) == 0 else { throw posix("secure verified recovery root") }
        if mkdirat(rootDescriptor, "generations", 0o700) != 0, errno != EEXIST {
            throw posix("create verified recovery generations")
        }
        let generations = openat(
            rootDescriptor,
            "generations",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard generations >= 0 else { throw posix("open verified recovery generations") }
        defer { Darwin.close(generations) }
        guard fchmod(generations, 0o700) == 0 else { throw posix("secure verified recovery generations") }
        let temporaryName = ".tmp-\(generation.rawValue)-\(UUID().uuidString)"
        guard mkdirat(generations, temporaryName, 0o700) == 0 else {
            throw posix("create verified recovery generation")
        }
        let temporary = openat(
            generations,
            temporaryName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard temporary >= 0 else { throw posix("open verified recovery generation") }
        defer { Darwin.close(temporary) }
        guard mkdirat(temporary, "blobs", 0o700) == 0 else {
            throw posix("create verified recovery blobs")
        }
        let blobs = openat(
            temporary,
            "blobs",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard blobs >= 0 else { throw posix("open verified recovery blobs") }
        defer { Darwin.close(blobs) }
        var records: [BlobRecord] = []
        let ordered = archive.buffers.values.sorted {
            $0.bufferID.rawValue.uuidString < $1.bufferID.rawValue.uuidString
        }
        for (index, snapshot) in ordered.enumerated() {
            guard archive.session.buffers[snapshot.bufferID]?.revision == snapshot.revision,
                  String(data: snapshot.utf8, encoding: .utf8) != nil,
                  valid(snapshot.viewState, for: snapshot.utf8) else {
                throw SessionStoreError.corrupt("invalid archive buffer")
            }
            let file = "\(snapshot.bufferID.rawValue.uuidString.lowercased()).utf8"
            try writeDurable(snapshot.utf8, in: blobs, name: file)
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
        guard fsync(blobs) == 0 else { throw posix("sync verified recovery blobs") }
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
        try writeDurable(try encoder.encode(manifest), in: temporary, name: "manifest.json")
        guard fsync(temporary) == 0 else { throw posix("sync verified recovery generation") }
        if case .afterManifest = fault {
            throw SessionStoreError.unavailable("injected interruption after manifest")
        }
        let finalName = String(format: "%020llu", generation.rawValue)
        guard renameatx_np(
            generations,
            temporaryName,
            generations,
            finalName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            if errno == EEXIST {
                let winnerDescriptor = openat(
                    generations,
                    finalName,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard winnerDescriptor >= 0 else { throw posix("open winning verified recovery generation") }
                defer { Darwin.close(winnerDescriptor) }
                let winner = try loadGeneration(
                    winnerDescriptor,
                    expectedGeneration: generation.rawValue
                )
                guard winner.archive == archive else {
                    throw SessionStoreError.corrupt("recovery generation collision")
                }
                return false
            }
            throw posix("publish verified recovery generation")
        }
        if case .afterPublish = fault {
            throw SessionStoreError.unavailable("injected interruption after publish")
        }
        guard fsync(generations) == 0 else { throw posix("sync verified recovery generations") }
        try retainNewestTwo(in: generations)
        return true
    }

    private static func writeDurable(_ data: Data, in directory: Int32, name: String) throws {
        let descriptor = openat(
            directory,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else { throw posix("create verified recovery file") }
        var closeNeeded = true
        defer { if closeNeeded { Darwin.close(descriptor) } }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(
                    descriptor,
                    raw.baseAddress!.advanced(by: offset),
                    raw.count - offset
                )
                guard count > 0 else { throw posix("write verified recovery file") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw posix("fsync verified recovery file") }
        guard fcntl(descriptor, F_FULLFSYNC) == 0 else { throw posix("full sync verified recovery file") }
        guard fchmod(descriptor, 0o600) == 0 else { throw posix("chmod verified recovery file") }
        guard Darwin.close(descriptor) == 0 else { throw posix("close verified recovery file") }
        closeNeeded = false
    }

    private static func retainNewestTwo(in generations: Int32) throws {
        let ordered = try directoryNames(in: generations, maximumEntries: 100_000)
            .compactMap { UInt64($0).map { ($0, $0.description) } }
            .sorted { $0.0 > $1.0 }
        for (value, _) in ordered.dropFirst(2) {
            let name = String(format: "%020llu", value)
            let directory = openat(
                generations,
                name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard directory >= 0 else { throw posix("open old verified recovery generation") }
            do {
                var opened = stat()
                guard fstat(directory, &opened) == 0 else {
                    throw posix("inspect old verified recovery generation")
                }
                var removedEntries = 0
                try removeContents(of: directory, depth: 0, removedEntries: &removedEntries)
                var current = stat()
                guard fstatat(generations, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      current.st_dev == opened.st_dev,
                      current.st_ino == opened.st_ino else {
                    throw SessionStoreError.unavailable("old recovery generation identity changed")
                }
                guard unlinkat(generations, name, AT_REMOVEDIR) == 0 else {
                    throw posix("remove old verified recovery generation")
                }
                Darwin.close(directory)
            } catch {
                Darwin.close(directory)
                throw error
            }
        }
        guard fsync(generations) == 0 else { throw posix("sync retained verified generations") }
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
              state.caretUTF8 <= utf8.count,
              state.bookmarkedLines.count <= EditorViewState.maximumBookmarkCount else { return false }
        var maximumLine = 0
        var index = 0
        while index < utf8.count {
            if utf8[index] == 0x0D {
                maximumLine += 1
                if index + 1 < utf8.count, utf8[index + 1] == 0x0A { index += 1 }
            } else if utf8[index] == 0x0A {
                maximumLine += 1
            }
            index += 1
        }
        guard state.bookmarkedLines.allSatisfy({ $0 >= 0 && $0 <= maximumLine }) else { return false }
        guard isUTF8Boundary(state.anchorUTF8, in: utf8),
              isUTF8Boundary(state.caretUTF8, in: utf8) else { return false }
        if let secondary = state.secondaryViewState {
            guard state.splitOrientation != nil,
                  secondary.anchorUTF8 >= 0,
                  secondary.caretUTF8 >= 0,
                  secondary.firstVisibleLine >= 0,
                  secondary.horizontalScrollOffset >= 0,
                  secondary.anchorUTF8 <= utf8.count,
                  secondary.caretUTF8 <= utf8.count,
                  isUTF8Boundary(secondary.anchorUTF8, in: utf8),
                  isUTF8Boundary(secondary.caretUTF8, in: utf8) else { return false }
        } else if state.splitOrientation != nil {
            return false
        }
        return true
    }

    private static func isUTF8Boundary(_ offset: Int, in utf8: Data) -> Bool {
        offset == 0 || offset == utf8.count || (utf8[offset] & 0xC0) != 0x80
    }

    fileprivate static func posix(_ operation: String) -> SessionStoreError {
        .unavailable("\(operation): \(String(cString: strerror(errno)))")
    }
}
