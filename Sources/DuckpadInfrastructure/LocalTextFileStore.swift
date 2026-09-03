import CryptoKit
import Darwin
import DuckpadApplication
import DuckpadDomain
import Foundation

public enum AtomicWriteFault: Sendable {
    case none
    case afterTemporaryFileSync
    case replaceDestinationBeforeCommit(Data)
    case fullFileSync
    case directoryOpen
    case directorySync
    case directoryClose
    case directorySyncAndRollbackFailure
    case rollbackSwapFailure
}

/// Filesystem adapter. Every blocking syscall runs on a detached utility task;
/// the sibling-temp + fsync + rename sequence never exposes partial contents.
public actor LocalTextFileStore: TextFileStore {
    private struct ActiveSecurityScope: Sendable {
        let url: URL
        let bookmark: Data
        var owners: Set<UUID>
    }

    private struct StoredBookmark: Codable, Sendable {
        let path: String
        let bookmark: Data
    }

    private struct BookmarkArchive: Codable, Sendable {
        let schemaVersion: Int
        var entries: [StoredBookmark]
    }

    public static let maximumPersistedBookmarks = 100
    public static let maximumBookmarkArchiveBytes = 4 * 1_024 * 1_024
    private let fault: AtomicWriteFault
    private let bookmarkArchiveURL: URL
    private let securityScopedAccessRequired: Bool
    private let startSecurityScopedAccess: @Sendable (URL) -> Bool
    private let stopSecurityScopedAccess: @Sendable (URL) -> Void
    private let createSecurityScopedBookmark: @Sendable (URL) throws -> Data
    private let resolveSecurityScopedBookmark: @Sendable (Data) throws -> (URL, Bool)
    private var activeSecurityScopes: [String: ActiveSecurityScope] = [:]
    private var bookmarkArchive: BookmarkArchive?

    public init(
        fault: AtomicWriteFault = .none,
        bookmarkArchiveURL: URL = LocalTextFileStore.defaultBookmarkArchiveURL()
    ) {
        self.fault = fault
        self.bookmarkArchiveURL = bookmarkArchiveURL.standardizedFileURL
        securityScopedAccessRequired = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        startSecurityScopedAccess = { $0.startAccessingSecurityScopedResource() }
        stopSecurityScopedAccess = { $0.stopAccessingSecurityScopedResource() }
        createSecurityScopedBookmark = { url in
            try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
        resolveSecurityScopedBookmark = { data in
            var stale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            return (url, stale)
        }
    }

    init(
        fault: AtomicWriteFault = .none,
        bookmarkArchiveURL: URL,
        testingSecurityScopedAccessRequired: Bool,
        testingStartSecurityScopedAccess: @escaping @Sendable (URL) -> Bool,
        testingStopSecurityScopedAccess: @escaping @Sendable (URL) -> Void,
        testingCreateSecurityScopedBookmark: @escaping @Sendable (URL) throws -> Data,
        testingResolveSecurityScopedBookmark: @escaping @Sendable (Data) throws -> (URL, Bool)
    ) {
        self.fault = fault
        self.bookmarkArchiveURL = bookmarkArchiveURL.standardizedFileURL
        securityScopedAccessRequired = testingSecurityScopedAccessRequired
        startSecurityScopedAccess = testingStartSecurityScopedAccess
        stopSecurityScopedAccess = testingStopSecurityScopedAccess
        createSecurityScopedBookmark = testingCreateSecurityScopedBookmark
        resolveSecurityScopedBookmark = testingResolveSecurityScopedBookmark
    }

    public static func defaultBookmarkArchiveURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("Duckpad", isDirectory: true)
            .appendingPathComponent("document-bookmarks.json", isDirectory: false)
    }

    public func prepareSecurityScopedAccess(
        to url: URL,
        ownerID: UUID
    ) async throws(TextFileStoreError) -> SecurityScopedFileAccess {
        guard securityScopedAccessRequired else { return SecurityScopedFileAccess(url: url) }
        let requested = url.standardizedFileURL
        guard requested.isFileURL else { throw .invalidPath(url.absoluteString) }
        if var current = activeSecurityScopes[requested.path] {
            current.owners.insert(ownerID)
            activeSecurityScopes[requested.path] = current
            return SecurityScopedFileAccess(url: current.url, bookmark: current.bookmark)
        }

        var accessedURL = requested
        var started = startSecurityScopedAccess(requested)
        if !started {
            do {
                let archive = try loadBookmarkArchive()
                guard let stored = archive.entries.last(where: { $0.path == requested.path }) else {
                    throw TextFileStoreError.permissionDenied(requested.path)
                }
                accessedURL = try resolveSecurityScopedBookmark(stored.bookmark).0
                started = startSecurityScopedAccess(accessedURL)
            } catch let error as TextFileStoreError { throw error }
            catch { throw .permissionDenied(requested.path) }
        }
        guard started else { throw .permissionDenied(requested.path) }
        do {
            let canonical = try Self.canonicalize(accessedURL)
            if var current = activeSecurityScopes[canonical.path] {
                stopSecurityScopedAccess(accessedURL)
                current.owners.insert(ownerID)
                activeSecurityScopes[canonical.path] = current
                return SecurityScopedFileAccess(url: current.url, bookmark: current.bookmark)
            }
            let bookmark = try createSecurityScopedBookmark(canonical)
            try persistBookmark(bookmark, aliases: [requested.path, canonical.path])
            activeSecurityScopes[canonical.path] = ActiveSecurityScope(
                url: canonical,
                bookmark: bookmark,
                owners: [ownerID]
            )
            return SecurityScopedFileAccess(url: canonical, bookmark: bookmark)
        } catch let error as TextFileStoreError {
            stopSecurityScopedAccess(accessedURL)
            throw error
        } catch {
            stopSecurityScopedAccess(accessedURL)
            throw .io(String(describing: error))
        }
    }

    public func restoreSecurityScopedAccess(
        for binding: FileBinding,
        ownerID: UUID
    ) async throws(TextFileStoreError) -> FileBinding {
        guard securityScopedAccessRequired else { return binding }
        if var current = activeSecurityScopes[binding.canonicalPath] {
            current.owners.insert(ownerID)
            activeSecurityScopes[binding.canonicalPath] = current
            var updated = binding
            updated.securityScopedBookmark = current.bookmark
            return updated
        }
        let bookmark: Data
        if let embedded = binding.securityScopedBookmark { bookmark = embedded }
        else {
            do {
                guard let stored = try loadBookmarkArchive().entries.last(where: {
                    $0.path == binding.canonicalPath
                }) else { throw TextFileStoreError.permissionDenied(binding.canonicalPath) }
                bookmark = stored.bookmark
            } catch let error as TextFileStoreError { throw error }
            catch { throw .permissionDenied(binding.canonicalPath) }
        }
        let resolved: (URL, Bool)
        do { resolved = try resolveSecurityScopedBookmark(bookmark) }
        catch { throw .permissionDenied(binding.canonicalPath) }
        guard startSecurityScopedAccess(resolved.0) else { throw .permissionDenied(binding.canonicalPath) }
        do {
            let canonical = try Self.canonicalize(resolved.0)
            let refreshed = try createSecurityScopedBookmark(canonical)
            try persistBookmark(refreshed, aliases: [binding.canonicalPath, canonical.path])
            if var current = activeSecurityScopes[canonical.path] {
                stopSecurityScopedAccess(resolved.0)
                current.owners.insert(ownerID)
                activeSecurityScopes[canonical.path] = current
            } else {
                activeSecurityScopes[canonical.path] = ActiveSecurityScope(
                    url: canonical,
                    bookmark: refreshed,
                    owners: [ownerID]
                )
            }
            var updated = binding
            updated.securityScopedBookmark = refreshed
            if canonical.path != binding.canonicalPath {
                updated = FileBinding(
                    canonicalPath: canonical.path,
                    encoding: binding.encoding,
                    byteOrderMark: binding.byteOrderMark,
                    lineEnding: binding.lineEnding,
                    observedIdentity: Self.rebased(binding.observedIdentity, canonicalPath: canonical.path),
                    securityScopedBookmark: refreshed
                )
            }
            return updated
        } catch let error as TextFileStoreError {
            stopSecurityScopedAccess(resolved.0)
            throw error
        } catch {
            stopSecurityScopedAccess(resolved.0)
            throw .io(String(describing: error))
        }
    }

    public func releaseSecurityScopedAccess(forCanonicalPath path: String, ownerID: UUID) async {
        let key = URL(fileURLWithPath: path).standardizedFileURL.path
        guard var current = activeSecurityScopes[key] else { return }
        current.owners.remove(ownerID)
        if current.owners.isEmpty {
            activeSecurityScopes.removeValue(forKey: key)
            stopSecurityScopedAccess(current.url)
        } else {
            activeSecurityScopes[key] = current
        }
    }

    public func releaseAllSecurityScopedAccess(ownerID: UUID) async {
        for path in Array(activeSecurityScopes.keys) {
            await releaseSecurityScopedAccess(forCanonicalPath: path, ownerID: ownerID)
        }
    }

    public func reconcileSecurityScopedAccess(
        retainingCanonicalPaths paths: Set<String>,
        ownerID: UUID
    ) async {
        let retained = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        for path in Array(activeSecurityScopes.keys) where !retained.contains(path) {
            await releaseSecurityScopedAccess(forCanonicalPath: path, ownerID: ownerID)
        }
    }

    public func clearPersistedSecurityScopedBookmarks() async throws(TextFileStoreError) {
        bookmarkArchive = BookmarkArchive(schemaVersion: 1, entries: [])
        do {
            if FileManager.default.fileExists(atPath: bookmarkArchiveURL.path) {
                try FileManager.default.removeItem(at: bookmarkArchiveURL)
            }
        } catch { throw .io(String(describing: error)) }
    }

    private func loadBookmarkArchive() throws -> BookmarkArchive {
        if let bookmarkArchive { return bookmarkArchive }
        guard FileManager.default.fileExists(atPath: bookmarkArchiveURL.path) else {
            let empty = BookmarkArchive(schemaVersion: 1, entries: [])
            bookmarkArchive = empty
            return empty
        }
        do {
            let data = try Data(contentsOf: bookmarkArchiveURL, options: [.mappedIfSafe])
            guard data.count <= Self.maximumBookmarkArchiveBytes else {
                throw TextFileStoreError.io("document bookmark archive exceeds size limit")
            }
            let decoded = try JSONDecoder().decode(BookmarkArchive.self, from: data)
            guard decoded.schemaVersion == 1,
                  decoded.entries.count <= Self.maximumPersistedBookmarks,
                  decoded.entries.allSatisfy({
                      $0.path.hasPrefix("/") && $0.path.utf8.count <= 16 * 1_024
                          && !$0.bookmark.isEmpty
                  }),
                  Set(decoded.entries.map(\.path)).count == decoded.entries.count else {
                throw TextFileStoreError.io("invalid document bookmark archive")
            }
            bookmarkArchive = decoded
            return decoded
        } catch let error as TextFileStoreError { throw error }
        catch { throw TextFileStoreError.io(String(describing: error)) }
    }

    private func persistBookmark(_ bookmark: Data, aliases: [String]) throws {
        var archive = try loadBookmarkArchive()
        for path in aliases.map({ URL(fileURLWithPath: $0).standardizedFileURL.path }) {
            archive.entries.removeAll { $0.path == path }
            archive.entries.append(StoredBookmark(path: path, bookmark: bookmark))
        }
        if archive.entries.count > Self.maximumPersistedBookmarks {
            archive.entries.removeFirst(archive.entries.count - Self.maximumPersistedBookmarks)
        }
        do {
            let directory = bookmarkArchiveURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(archive)
            guard data.count <= Self.maximumBookmarkArchiveBytes else {
                throw TextFileStoreError.io("document bookmark archive exceeds size limit")
            }
            try data.write(to: bookmarkArchiveURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: bookmarkArchiveURL.path
            )
            bookmarkArchive = archive
        } catch let error as TextFileStoreError { throw error }
        catch { throw TextFileStoreError.io(String(describing: error)) }
    }

    public func canonicalURL(for url: URL) async throws(TextFileStoreError) -> URL {
        do { return try await Task.detached(priority: .utility) { try Self.canonicalize(url) }.value }
        catch let error as TextFileStoreError { throw error }
        catch { throw .io(String(describing: error)) }
    }

    public func read(from url: URL) async throws(TextFileStoreError) -> FileReadResult {
        do { return try await Task.detached(priority: .utility) { try Self.readBlocking(url) }.value }
        catch let error as TextFileStoreError { throw error }
        catch { throw .io(String(describing: error)) }
    }

    public func writeAtomically(
        _ data: Data,
        to url: URL,
        expectedIdentity: FileIdentity?,
        overwrite: Bool
    ) async throws(TextFileStoreError) -> FileWriteReceipt {
        let fault = self.fault
        let coordinatesSandboxWrite = securityScopedAccessRequired
        do {
            return try await Task.detached(priority: .utility) {
                if coordinatesSandboxWrite {
                    return try Self.coordinatedWriteBlocking(
                        data,
                        to: url,
                        expectedIdentity: expectedIdentity,
                        overwrite: overwrite,
                        fault: fault
                    )
                }
                return try Self.writeBlocking(
                    data,
                    to: url,
                    expectedIdentity: expectedIdentity,
                    overwrite: overwrite,
                    fault: fault
                )
            }.value
        } catch let error as TextFileStoreError { throw error }
        catch { throw .io(String(describing: error)) }
    }

    private static func coordinatedWriteBlocking(
        _ data: Data,
        to url: URL,
        expectedIdentity: FileIdentity?,
        overwrite: Bool,
        fault: AtomicWriteFault
    ) throws -> FileWriteReceipt {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<FileWriteReceipt, TextFileStoreError>?
        coordinator.coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                result = .success(try sandboxSafeWriteBlocking(
                    data,
                    to: coordinatedURL,
                    expectedIdentity: expectedIdentity,
                    overwrite: overwrite,
                    fault: fault
                ))
            } catch let error as TextFileStoreError {
                result = .failure(error)
            } catch {
                result = .failure(.io(String(describing: error)))
            }
        }
        if let result { return try result.get() }
        if let coordinationError { throw map(error: coordinationError, path: url.path) }
        throw TextFileStoreError.atomicWriteFailed("file coordination returned no result")
    }

    /// Foundation's atomic writer uses the sandbox's related-item safe-save
    /// extension for a user-selected file. Hand-rolled sibling names are not
    /// authorized by a file-scoped Powerbox grant.
    private static func sandboxSafeWriteBlocking(
        _ data: Data,
        to url: URL,
        expectedIdentity: FileIdentity?,
        overwrite: Bool,
        fault: AtomicWriteFault
    ) throws -> FileWriteReceipt {
        let canonical = try canonicalize(url)
        let current: FileIdentity?
        do { current = try readBlocking(canonical).identity }
        catch TextFileStoreError.notFound { current = nil }
        if let expectedIdentity {
            guard let current, sameObservedFile(current, expectedIdentity) else {
                throw TextFileStoreError.conflict(current: current)
            }
        } else if current != nil && !overwrite {
            throw TextFileStoreError.conflict(current: current)
        }
        if case .replaceDestinationBeforeCommit(let external) = fault {
            do { try external.write(to: canonical, options: [.atomic]) }
            catch { throw map(error: error, path: canonical.path) }
            throw TextFileStoreError.conflict(current: try? readBlocking(canonical).identity)
        }
        do { try data.write(to: canonical, options: [.atomic]) }
        catch { throw map(error: error, path: canonical.path) }
        let descriptor = Darwin.open(canonical.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw mapErrno(path: canonical.path) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0, Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 else {
            throw TextFileStoreError.durabilityFailure(
                state: .replacementVisibleDurabilityUncertain,
                current: try? readBlocking(canonical).identity,
                recoveryPath: nil,
                detail: String(describing: mapErrno(path: canonical.path))
            )
        }
        return FileWriteReceipt(identity: try readBlocking(canonical).identity)
    }

    private static func canonicalize(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw TextFileStoreError.invalidPath(url.absoluteString) }
        let standardized = url.standardizedFileURL
        if FileManager.default.fileExists(atPath: standardized.path) {
            return standardized.resolvingSymlinksInPath().standardizedFileURL
        }
        let parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
        guard !standardized.lastPathComponent.isEmpty else { throw TextFileStoreError.invalidPath(standardized.path) }
        return parent.appendingPathComponent(standardized.lastPathComponent).standardizedFileURL
    }

    private static func readBlocking(_ url: URL) throws -> FileReadResult {
        let canonical = try canonicalize(url)
        let data: Data
        do { data = try Data(contentsOf: canonical, options: [.mappedIfSafe]) }
        catch { throw map(error: error, path: canonical.path) }
        return FileReadResult(data: data, identity: try identity(for: canonical, data: data))
    }

    private static func writeBlocking(
        _ data: Data,
        to url: URL,
        expectedIdentity: FileIdentity?,
        overwrite: Bool,
        fault: AtomicWriteFault
    ) throws -> FileWriteReceipt {
        let canonical = try canonicalize(url)
        let path = canonical.path
        var remainingFault = fault

        let temporary = canonical.deletingLastPathComponent()
            .appendingPathComponent(".\(canonical.lastPathComponent).duckpad-\(UUID().uuidString).tmp")
        let temporaryPath = temporary.path
        var descriptor = Darwin.open(temporaryPath, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw mapErrno(path: temporaryPath) }
        var shouldUnlink = true
        defer {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            if shouldUnlink { _ = Darwin.unlink(temporaryPath) }
        }
        do {
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var written = 0
                while written < raw.count {
                    let count = Darwin.write(descriptor, base.advanced(by: written), raw.count - written)
                    guard count >= 0 else { throw mapErrno(path: temporaryPath) }
                    written += count
                }
            }
            guard Darwin.fsync(descriptor) == 0 else { throw mapErrno(path: temporaryPath) }
            if case .fullFileSync = remainingFault {
                remainingFault = .none
                throw TextFileStoreError.atomicWriteFailed("injected F_FULLFSYNC failure")
            }
            guard Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 else { throw mapErrno(path: temporaryPath) }
            if case .afterTemporaryFileSync = remainingFault {
                remainingFault = .none
                throw TextFileStoreError.atomicWriteFailed("injected failure after temporary fsync")
            }
            guard Darwin.close(descriptor) == 0 else { throw mapErrno(path: temporaryPath) }
            descriptor = -1
            if case .replaceDestinationBeforeCommit(let external) = remainingFault {
                remainingFault = .none
                do { try external.write(to: canonical) }
                catch { throw TextFileStoreError.io("race injection failed: \(error)") }
            }

            let directory = canonical.deletingLastPathComponent().path
            if let expectedIdentity {
                guard renameSwap(temporaryPath, path) else {
                    if errno == ENOENT { throw TextFileStoreError.conflict(current: nil) }
                    throw mapErrno(path: path)
                }
                shouldUnlink = false
                let displaced = try readBlocking(temporary).identity
                guard sameObservedFile(displaced, expectedIdentity) else {
                    try restoreAfterConflict(
                        temporaryPath: temporaryPath,
                        target: canonical,
                        directory: directory,
                        fault: &remainingFault
                    )
                    throw TextFileStoreError.conflict(current: rebased(displaced, canonicalPath: path))
                }
                try finishSwappedCommit(
                    temporaryPath: temporaryPath,
                    target: canonical,
                    directory: directory,
                    fault: &remainingFault
                )
            } else if overwrite {
                if renameSwap(temporaryPath, path) {
                    shouldUnlink = false
                    try finishSwappedCommit(
                        temporaryPath: temporaryPath,
                        target: canonical,
                        directory: directory,
                        fault: &remainingFault
                    )
                } else if errno == ENOENT {
                    guard renameExclusive(temporaryPath, path) else {
                        throw errno == EEXIST
                            ? TextFileStoreError.conflict(current: try? readBlocking(canonical).identity)
                            : mapErrno(path: path)
                    }
                    try finishExclusiveCommit(target: canonical, directory: directory, fault: &remainingFault)
                } else {
                    throw mapErrno(path: path)
                }
            } else {
                guard renameExclusive(temporaryPath, path) else {
                    if errno == EEXIST { throw TextFileStoreError.conflict(current: try? readBlocking(canonical).identity) }
                    throw mapErrno(path: path)
                }
                try finishExclusiveCommit(target: canonical, directory: directory, fault: &remainingFault)
            }
            shouldUnlink = false
        } catch let error as TextFileStoreError {
            throw error
        } catch {
            throw TextFileStoreError.atomicWriteFailed(String(describing: error))
        }
        return FileWriteReceipt(identity: try readBlocking(canonical).identity)
    }

    private static func renameSwap(_ first: String, _ second: String) -> Bool {
        renameatx_np(AT_FDCWD, first, AT_FDCWD, second, UInt32(RENAME_SWAP)) == 0
    }

    private static func renameExclusive(_ first: String, _ second: String) -> Bool {
        renameatx_np(AT_FDCWD, first, AT_FDCWD, second, UInt32(RENAME_EXCL)) == 0
    }

    private static func finishSwappedCommit(
        temporaryPath: String,
        target: URL,
        directory: String,
        fault: inout AtomicWriteFault
    ) throws {
        do {
            try syncDirectory(directory, fault: &fault)
        } catch let durabilityError as TextFileStoreError {
            if case .rollbackSwapFailure = fault {
                fault = .none
                throw TextFileStoreError.durabilityFailure(
                    state: .filesystemStateUncertain,
                    current: try? readBlocking(target).identity,
                    recoveryPath: temporaryPath,
                    detail: "directory durability failed and injected swap-back failure retained the displaced original"
                )
            }
            do {
                guard renameSwap(temporaryPath, target.path) else { throw mapErrno(path: target.path) }
                try syncDirectory(directory, fault: &fault)
                guard Darwin.unlink(temporaryPath) == 0 else { throw mapErrno(path: temporaryPath) }
                try syncDirectory(directory, fault: &fault)
                let restored = try? readBlocking(target).identity
                throw TextFileStoreError.durabilityFailure(
                    state: .originalRestored,
                    current: restored,
                    recoveryPath: nil,
                    detail: String(describing: durabilityError)
                )
            } catch let restored as TextFileStoreError where isRestoredFailure(restored) {
                throw restored
            } catch {
                throw TextFileStoreError.durabilityFailure(
                    state: .filesystemStateUncertain,
                    current: try? readBlocking(target).identity,
                    recoveryPath: FileManager.default.fileExists(atPath: temporaryPath) ? temporaryPath : nil,
                    detail: "directory durability failed and swap-back was not durable: \(error)"
                )
            }
        }
        guard Darwin.unlink(temporaryPath) == 0 else {
            throw TextFileStoreError.durabilityFailure(
                state: .replacementVisibleDurabilityUncertain,
                current: try? readBlocking(target).identity,
                recoveryPath: temporaryPath,
                detail: String(describing: mapErrno(path: temporaryPath))
            )
        }
        do { try syncDirectory(directory, fault: &fault) }
        catch {
            throw TextFileStoreError.durabilityFailure(
                state: .replacementVisibleDurabilityUncertain,
                current: try? readBlocking(target).identity,
                recoveryPath: nil,
                detail: String(describing: error)
            )
        }
    }

    private static func finishExclusiveCommit(
        target: URL,
        directory: String,
        fault: inout AtomicWriteFault
    ) throws {
        do { try syncDirectory(directory, fault: &fault) }
        catch let durabilityError {
            do {
                guard Darwin.unlink(target.path) == 0 else { throw mapErrno(path: target.path) }
                try syncDirectory(directory, fault: &fault)
                throw TextFileStoreError.durabilityFailure(
                    state: .originalRestored,
                    current: nil,
                    recoveryPath: nil,
                    detail: String(describing: durabilityError)
                )
            } catch let restored as TextFileStoreError where isRestoredFailure(restored) {
                throw restored
            } catch {
                throw TextFileStoreError.durabilityFailure(
                    state: .filesystemStateUncertain,
                    current: try? readBlocking(target).identity,
                    recoveryPath: nil,
                    detail: "directory durability failed and new target removal was not durable: \(error)"
                )
            }
        }
    }

    private static func restoreAfterConflict(
        temporaryPath: String,
        target: URL,
        directory: String,
        fault: inout AtomicWriteFault
    ) throws {
        guard renameSwap(temporaryPath, target.path) else {
            throw TextFileStoreError.durabilityFailure(
                state: .filesystemStateUncertain,
                current: try? readBlocking(target).identity,
                recoveryPath: temporaryPath,
                detail: "conflict swap-back failed"
            )
        }
        guard Darwin.unlink(temporaryPath) == 0 else {
            throw TextFileStoreError.durabilityFailure(
                state: .filesystemStateUncertain,
                current: try? readBlocking(target).identity,
                recoveryPath: temporaryPath,
                detail: "conflict candidate cleanup failed"
            )
        }
        do { try syncDirectory(directory, fault: &fault) }
        catch {
            throw TextFileStoreError.durabilityFailure(
                state: .filesystemStateUncertain,
                current: try? readBlocking(target).identity,
                recoveryPath: nil,
                detail: "conflict was restored but directory sync failed: \(error)"
            )
        }
    }

    private static func syncDirectory(_ path: String, fault: inout AtomicWriteFault) throws {
        if case .directoryOpen = fault {
            fault = .none
            throw TextFileStoreError.atomicWriteFailed("injected directory open failure")
        }
        var descriptor = Darwin.open(path, O_RDONLY)
        guard descriptor >= 0 else { throw mapErrno(path: path) }
        if case .directorySync = fault {
            fault = .none
            guard Darwin.close(descriptor) == 0 else { throw mapErrno(path: path) }
            throw TextFileStoreError.atomicWriteFailed("injected directory fsync failure")
        }
        if case .directorySyncAndRollbackFailure = fault {
            fault = .rollbackSwapFailure
            guard Darwin.close(descriptor) == 0 else { throw mapErrno(path: path) }
            throw TextFileStoreError.atomicWriteFailed("injected directory fsync failure before rollback failure")
        }
        guard Darwin.fsync(descriptor) == 0 else {
            let syncError = mapErrno(path: path)
            let closeResult = Darwin.close(descriptor)
            descriptor = -1
            if closeResult != 0 { throw mapErrno(path: path) }
            throw syncError
        }
        if case .directoryClose = fault {
            fault = .none
            let closeResult = Darwin.close(descriptor)
            descriptor = -1
            if closeResult != 0 { throw mapErrno(path: path) }
            throw TextFileStoreError.atomicWriteFailed("injected directory close failure")
        }
        guard Darwin.close(descriptor) == 0 else { throw mapErrno(path: path) }
    }

    private static func sameObservedFile(_ lhs: FileIdentity, _ rhs: FileIdentity) -> Bool {
        lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.byteCount == rhs.byteCount
            && lhs.modifiedNanoseconds == rhs.modifiedNanoseconds && lhs.contentToken == rhs.contentToken
    }

    private static func rebased(_ identity: FileIdentity, canonicalPath: String) -> FileIdentity {
        FileIdentity(
            canonicalPath: canonicalPath,
            device: identity.device,
            inode: identity.inode,
            byteCount: identity.byteCount,
            modifiedNanoseconds: identity.modifiedNanoseconds,
            contentToken: identity.contentToken
        )
    }

    private static func isRestoredFailure(_ error: TextFileStoreError) -> Bool {
        if case .durabilityFailure(state: .originalRestored, current: _, recoveryPath: _, detail: _) = error { return true }
        return false
    }

    private static func identity(for url: URL, data: Data) throws -> FileIdentity {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0 else { throw mapErrno(path: url.path) }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let nanos = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return FileIdentity(
            canonicalPath: url.path,
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            byteCount: UInt64(info.st_size),
            modifiedNanoseconds: nanos,
            contentToken: digest
        )
    }

    private static func map(error: Error, path: String) -> TextFileStoreError {
        let cocoa = error as NSError
        switch cocoa.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return .notFound(path)
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return .permissionDenied(path)
        default: return .io("\(path): \(cocoa.localizedDescription)")
        }
    }

    private static func mapErrno(path: String) -> TextFileStoreError {
        switch errno {
        case ENOENT: return .notFound(path)
        case EACCES, EPERM: return .permissionDenied(path)
        default: return .atomicWriteFailed("\(path): \(String(cString: strerror(errno)))")
        }
    }
}
