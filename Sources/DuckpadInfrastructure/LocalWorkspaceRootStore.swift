import CryptoKit
import Darwin
import DuckpadApplication
import DuckpadDomain
import Foundation

public actor LocalWorkspaceRootStore: WorkspaceRootStore {
    private struct ScopeAttempt {
        let allowed: Bool
        let newlyAcquired: Bool
    }

    private struct RootIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    private struct RootAccess: Sendable {
        let id: WorkspaceRootID
        let url: URL
        let identity: RootIdentity
    }

    private struct StoredRoot: Codable {
        let id: WorkspaceRootID
        var bookmark: Data
        var lastKnownPath: String
        var displayName: String
        var expandedRelativePaths: [String]
        var selectedRelativePath: String?
    }

    private struct Archive: Codable {
        let schemaVersion: Int
        var roots: [StoredRoot]
    }

    public static let maximumArchiveBytes = 1 * 1_024 * 1_024
    public static let maximumDirectoryEntries = 10_000
    public static let maximumOpenFileBytes: UInt64 = 1 * 1_024 * 1_024 * 1_024
    private let archiveURL: URL
    private let directoryEntryLimit: Int
    private let beforeOpeningEntry: (@Sendable (String) -> Void)?
    private let afterReadingDirectoryEntry: (@Sendable () -> Void)?
    private let securityScopedAccessRequired: Bool
    private let startSecurityScopedAccess: @Sendable (URL) -> Bool
    private let stopSecurityScopedAccess: @Sendable (URL) -> Void
    private let canonicalizeRoot: @Sendable (URL) throws -> URL
    private var archive = Archive(schemaVersion: 1, roots: [])
    private var activeURLs: [WorkspaceRootID: URL] = [:]
    private var activeRootIdentities: [WorkspaceRootID: RootIdentity] = [:]
    private var scopedAccessURLs: [WorkspaceRootID: URL] = [:]
    private var loaded = false

    public init(archiveURL: URL = LocalWorkspaceRootStore.defaultArchiveURL()) {
        self.archiveURL = archiveURL.standardizedFileURL
        directoryEntryLimit = Self.maximumDirectoryEntries
        beforeOpeningEntry = nil
        afterReadingDirectoryEntry = nil
        securityScopedAccessRequired = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        startSecurityScopedAccess = { $0.startAccessingSecurityScopedResource() }
        stopSecurityScopedAccess = { $0.stopAccessingSecurityScopedResource() }
        canonicalizeRoot = Self.canonicalRoot
    }

    init(
        archiveURL: URL,
        directoryEntryLimit: Int = LocalWorkspaceRootStore.maximumDirectoryEntries,
        testingBeforeOpeningEntry: (@Sendable (String) -> Void)? = nil,
        testingAfterReadingDirectoryEntry: (@Sendable () -> Void)? = nil,
        testingSecurityScopedAccessRequired: Bool? = nil,
        testingStartSecurityScopedAccess: (@Sendable (URL) -> Bool)? = nil,
        testingStopSecurityScopedAccess: (@Sendable (URL) -> Void)? = nil,
        testingCanonicalizeRoot: (@Sendable (URL) throws -> URL)? = nil
    ) {
        precondition(directoryEntryLimit > 0)
        self.archiveURL = archiveURL.standardizedFileURL
        self.directoryEntryLimit = directoryEntryLimit
        beforeOpeningEntry = testingBeforeOpeningEntry
        afterReadingDirectoryEntry = testingAfterReadingDirectoryEntry
        securityScopedAccessRequired = testingSecurityScopedAccessRequired
            ?? (ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)
        startSecurityScopedAccess = testingStartSecurityScopedAccess
            ?? { $0.startAccessingSecurityScopedResource() }
        stopSecurityScopedAccess = testingStopSecurityScopedAccess
            ?? { $0.stopAccessingSecurityScopedResource() }
        canonicalizeRoot = testingCanonicalizeRoot ?? Self.canonicalRoot
    }

    public static func defaultArchiveURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("Duckpad", isDirectory: true)
            .appendingPathComponent("workspace-roots.json", isDirectory: false)
    }

    public func loadRoots() async throws(WorkspaceBrowserFailure) -> [WorkspaceRoot] {
        try loadIfNeeded()
        let originalArchive = archive
        var roots: [WorkspaceRoot] = []
        var changed = false
        var seenPaths: Set<String> = []
        var seenResolvedPaths: Set<String> = []
        var newlyAcquiredScopes: Set<WorkspaceRootID> = []
        do {
            for index in archive.roots.indices {
                let record = archive.roots[index]
                guard roots.count < WorkspaceRoot.maximumRootCount else {
                    throw WorkspaceBrowserFailure.rootLimitExceeded(WorkspaceRoot.maximumRootCount)
                }
                guard !record.displayName.isEmpty,
                      record.displayName.utf8.count <= 1_024,
                      record.lastKnownPath.hasPrefix("/"),
                      record.lastKnownPath.utf8.count <= 16 * 1_024,
                      record.expandedRelativePaths.count <= WorkspaceRoot.maximumExpandedPathCount,
                      record.expandedRelativePaths.allSatisfy(Self.isValidRelativePath),
                      record.selectedRelativePath.map(Self.isValidRelativePath) ?? true else {
                    throw WorkspaceBrowserFailure.corruptStore("invalid workspace root record")
                }
                guard seenPaths.insert(URL(fileURLWithPath: record.lastKnownPath).standardizedFileURL.path).inserted else {
                    throw WorkspaceBrowserFailure.corruptStore("duplicate workspace root path")
                }
                guard let resolved = resolveBookmark(record.bookmark) else {
                    deactivateRoot(record.id)
                    roots.append(Self.root(from: record, available: false))
                    continue
                }
                let scope = beginAccessBeforeInspection(resolved.url, id: record.id)
                guard scope.allowed else {
                    deactivateRoot(record.id)
                    roots.append(Self.root(from: record, available: false))
                    continue
                }
                let availableURL: URL
                let identity: RootIdentity
                do {
                    availableURL = try inspectedCanonicalRoot(resolved.url)
                    identity = try Self.rootIdentity(availableURL)
                } catch {
                    deactivateRoot(record.id)
                    roots.append(Self.root(from: record, available: false))
                    continue
                }
                if scope.newlyAcquired { newlyAcquiredScopes.insert(record.id) }
                guard seenResolvedPaths.insert(availableURL.path).inserted else {
                    deactivateRoot(record.id)
                    newlyAcquiredScopes.remove(record.id)
                    throw WorkspaceBrowserFailure.corruptStore("duplicate resolved workspace root path")
                }
                activeURLs[record.id] = availableURL
                activeRootIdentities[record.id] = identity
                if resolved.stale || availableURL.path != record.lastKnownPath {
                    archive.roots[index].bookmark = try Self.bookmark(for: availableURL)
                    archive.roots[index].lastKnownPath = availableURL.path
                    archive.roots[index].displayName = availableURL.lastPathComponent
                    changed = true
                }
                roots.append(Self.root(from: archive.roots[index], available: true))
            }
            if changed { try persist() }
            return Self.sorted(roots)
        } catch let failure as WorkspaceBrowserFailure {
            archive = originalArchive
            for id in newlyAcquiredScopes { deactivateRoot(id) }
            throw failure
        } catch {
            archive = originalArchive
            for id in newlyAcquiredScopes { deactivateRoot(id) }
            throw .io(String(describing: error))
        }
    }

    public func addRoot(_ url: URL) async throws(WorkspaceBrowserFailure) -> WorkspaceRoot {
        try loadIfNeeded()
        guard archive.roots.count < WorkspaceRoot.maximumRootCount else {
            throw .rootLimitExceeded(WorkspaceRoot.maximumRootCount)
        }
        let id = WorkspaceRootID()
        let scope = beginAccessBeforeInspection(url, id: id)
        guard scope.allowed else { throw .permissionDenied(url.path) }
        var accessCommitted = false
        defer {
            if !accessCommitted, scope.newlyAcquired { endAccess(id) }
        }
        let canonical = try inspectedCanonicalRoot(url)
        if let existing = archive.roots.first(where: { $0.lastKnownPath == canonical.path }) {
            throw .duplicateRoot(existing.lastKnownPath)
        }
        let identity = try Self.rootIdentity(canonical)
        let record = StoredRoot(
            id: id,
            bookmark: try Self.bookmark(for: canonical),
            lastKnownPath: canonical.path,
            displayName: canonical.lastPathComponent,
            expandedRelativePaths: [""],
            selectedRelativePath: nil
        )
        archive.roots.append(record)
        do { try persist() }
        catch {
            archive.roots.removeAll { $0.id == record.id }
            throw error
        }
        activeURLs[record.id] = canonical
        activeRootIdentities[record.id] = identity
        accessCommitted = true
        return Self.root(from: record, available: true)
    }

    public func removeRoot(_ id: WorkspaceRootID) async throws(WorkspaceBrowserFailure) {
        try loadIfNeeded()
        guard let index = archive.roots.firstIndex(where: { $0.id == id }) else { throw .unknownRoot(id) }
        let removed = archive.roots.remove(at: index)
        do { try persist() }
        catch {
            archive.roots.insert(removed, at: index)
            throw error
        }
        deactivateRoot(id)
    }

    public func children(
        rootID: WorkspaceRootID,
        relativeDirectory: String
    ) async throws(WorkspaceBrowserFailure) -> [WorkspaceBrowserEntry] {
        try loadIfNeeded()
        guard Self.isValidRelativePath(relativeDirectory) else { throw .invalidPath(relativeDirectory) }
        let access = try availableRoot(rootID)
        let limit = directoryEntryLimit
        let beforeOpeningEntry = beforeOpeningEntry
        let afterReadingDirectoryEntry = afterReadingDirectoryEntry
        let operation = Task.detached(priority: .utility) {
            try Self.childrenBlocking(
                rootID: rootID,
                relativeDirectory: relativeDirectory,
                access: access,
                limit: limit,
                beforeOpeningEntry: beforeOpeningEntry,
                afterReadingDirectoryEntry: afterReadingDirectoryEntry
            )
        }
        return try await Self.value(of: operation)
    }

    public func readFile(_ entry: WorkspaceBrowserEntry) async throws(WorkspaceBrowserFailure) -> WorkspaceFileRead {
        try loadIfNeeded()
        guard entry.kind == .file,
              Self.isValidRelativePath(entry.relativePath),
              entry.name == URL(fileURLWithPath: entry.relativePath).lastPathComponent else {
            throw .invalidPath(entry.relativePath)
        }
        let access = try availableRoot(entry.rootID)
        let beforeOpeningEntry = beforeOpeningEntry
        let operation = Task.detached(priority: .utility) {
            try Self.readFileBlocking(
                entry,
                access: access,
                beforeOpeningEntry: beforeOpeningEntry
            )
        }
        return try await Self.value(of: operation)
    }

    public func updateNavigation(
        rootID: WorkspaceRootID,
        expandedRelativePaths: [String],
        selectedRelativePath: String?
    ) async throws(WorkspaceBrowserFailure) -> WorkspaceRoot {
        try loadIfNeeded()
        guard expandedRelativePaths.count <= WorkspaceRoot.maximumExpandedPathCount,
              expandedRelativePaths.allSatisfy(Self.isValidRelativePath),
              selectedRelativePath.map(Self.isValidRelativePath) ?? true else {
            throw .invalidPath(selectedRelativePath ?? "workspace navigation")
        }
        guard let index = archive.roots.firstIndex(where: { $0.id == rootID }) else { throw .unknownRoot(rootID) }
        let old = archive.roots[index]
        archive.roots[index].expandedRelativePaths = Array(Set(expandedRelativePaths)).sorted()
        archive.roots[index].selectedRelativePath = selectedRelativePath
        do { try persist() }
        catch {
            archive.roots[index] = old
            throw error
        }
        return Self.root(from: archive.roots[index], available: activeURLs[rootID] != nil)
    }

    private static func childrenBlocking(
        rootID: WorkspaceRootID,
        relativeDirectory: String,
        access: RootAccess,
        limit: Int,
        beforeOpeningEntry: (@Sendable (String) -> Void)?,
        afterReadingDirectoryEntry: (@Sendable () -> Void)?
    ) throws -> [WorkspaceBrowserEntry] {
        let descriptor = try openDirectory(relativeDirectory, access: access)
        defer { Darwin.close(descriptor) }
        let copy = Darwin.dup(descriptor)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { Darwin.close(copy) }
            throw mapErrno(path: relativeDirectory)
        }
        defer { closedir(stream) }
        var entries: [WorkspaceBrowserEntry] = []
        entries.reserveCapacity(min(limit, 256))
        var observedEntryCount = 0
        errno = 0
        while let pointer = readdir(stream) {
            if Task.isCancelled { throw WorkspaceBrowserFailure.cancelled }
            var dirent = pointer.pointee
            let name = withUnsafePointer(to: &dirent.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { errno = 0; continue }
            observedEntryCount += 1
            afterReadingDirectoryEntry?()
            guard observedEntryCount <= limit else { throw WorkspaceBrowserFailure.entryLimitExceeded(limit) }
            guard !name.hasPrefix("."), !name.contains("/"), !name.contains("\0") else {
                errno = 0
                continue
            }
            let relative = relativeDirectory.isEmpty ? name : relativeDirectory + "/" + name
            beforeOpeningEntry?(relative)
            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_flags & UInt32(UF_HIDDEN) == 0 else { errno = 0; continue }
            let kind: WorkspaceEntryKind
            switch fileType(info) {
            case S_IFDIR where !isPackageDirectory(name): kind = .directory
            case S_IFREG: kind = .file
            default: errno = 0; continue
            }
            entries.append(.init(rootID: rootID, relativePath: relative, name: name, kind: kind))
            errno = 0
        }
        guard errno == 0 else { throw mapErrno(path: relativeDirectory) }
        return entries.sorted {
            if $0.kind != $1.kind { return $0.kind == .directory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func readFileBlocking(
        _ entry: WorkspaceBrowserEntry,
        access: RootAccess,
        beforeOpeningEntry: (@Sendable (String) -> Void)?
    ) throws -> WorkspaceFileRead {
        let components = entry.relativePath.split(separator: "/").map(String.init)
        guard let name = components.last else { throw WorkspaceBrowserFailure.invalidPath(entry.relativePath) }
        let parent = components.dropLast().joined(separator: "/")
        let directory = try openDirectory(parent, access: access)
        defer { Darwin.close(directory) }
        beforeOpeningEntry?(entry.relativePath)
        let descriptor = Darwin.openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw mapErrno(path: entry.relativePath) }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, fileType(before) == S_IFREG else {
            throw WorkspaceBrowserFailure.invalidPath(entry.relativePath)
        }
        guard before.st_size >= 0 else { throw WorkspaceBrowserFailure.invalidPath(entry.relativePath) }
        let observedSize = UInt64(before.st_size)
        guard observedSize <= maximumOpenFileBytes else {
            throw WorkspaceBrowserFailure.fileTooLarge(actual: observedSize, limit: maximumOpenFileBytes)
        }
        var data = Data()
        data.reserveCapacity(Int(observedSize))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            if Task.isCancelled { throw WorkspaceBrowserFailure.cancelled }
            let permitted = maximumOpenFileBytes - UInt64(data.count)
            guard permitted > 0 else {
                var byte: UInt8 = 0
                let extra = Darwin.read(descriptor, &byte, 1)
                if extra == 0 { break }
                if extra < 0, errno == EINTR { continue }
                throw WorkspaceBrowserFailure.fileTooLarge(
                    actual: maximumOpenFileBytes + 1,
                    limit: maximumOpenFileBytes
                )
            }
            let request = min(buffer.count, Int(permitted))
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, request)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw mapErrno(path: entry.relativePath)
            }
            data.append(buffer, count: count)
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              sameSnapshot(before, after),
              UInt64(after.st_size) == UInt64(data.count) else {
            throw WorkspaceBrowserFailure.io("\(entry.relativePath): file changed while reading")
        }
        let path = joinedPath(root: access.url.path, relative: entry.relativePath)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let nanos = Int64(after.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(after.st_mtimespec.tv_nsec)
        let identity = FileIdentity(
            canonicalPath: path,
            device: UInt64(after.st_dev),
            inode: UInt64(after.st_ino),
            byteCount: UInt64(after.st_size),
            modifiedNanoseconds: nanos,
            contentToken: digest
        )
        return WorkspaceFileRead(
            url: URL(fileURLWithPath: path),
            result: FileReadResult(data: data, identity: identity)
        )
    }

    private static func openDirectory(_ relativePath: String, access: RootAccess) throws -> Int32 {
        var descriptor = Darwin.open(access.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw mapErrno(path: access.url.path) }
        var rootInfo = stat()
        guard fstat(descriptor, &rootInfo) == 0,
              fileType(rootInfo) == S_IFDIR,
              RootIdentity(device: UInt64(rootInfo.st_dev), inode: UInt64(rootInfo.st_ino)) == access.identity else {
            Darwin.close(descriptor)
            throw WorkspaceBrowserFailure.unavailableRoot(access.id)
        }
        do {
            for component in relativePath.split(separator: "/").map(String.init) {
                if Task.isCancelled { throw WorkspaceBrowserFailure.cancelled }
                let next = Darwin.openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw mapErrno(path: relativePath) }
                Darwin.close(descriptor)
                descriptor = next
                var info = stat()
                guard fstat(descriptor, &info) == 0, fileType(info) == S_IFDIR else {
                    throw WorkspaceBrowserFailure.invalidPath(relativePath)
                }
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func value<T: Sendable>(of operation: Task<T, Error>) async throws(WorkspaceBrowserFailure) -> T {
        do {
            return try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: {
                operation.cancel()
            }
        } catch let failure as WorkspaceBrowserFailure {
            throw failure
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .io(String(describing: error))
        }
    }

    private static func rootIdentity(_ url: URL) throws(WorkspaceBrowserFailure) -> RootIdentity {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0, fileType(info) == S_IFDIR else {
            throw mapErrno(path: url.path)
        }
        return RootIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    private static func fileType(_ info: stat) -> mode_t { info.st_mode & S_IFMT }

    private static func isPackageDirectory(_ name: String) -> Bool {
        let packageExtensions: Set<String> = [
            "app", "appex", "bundle", "framework", "kext", "mdimporter", "pkg",
            "plugin", "qlgenerator", "rtfd", "wdgt", "xcodeproj", "xcworkspace", "playground",
        ]
        return packageExtensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased())
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

    private static func joinedPath(root: String, relative: String) -> String {
        root == "/" ? "/" + relative : root + "/" + relative
    }

    private func loadIfNeeded() throws(WorkspaceBrowserFailure) {
        guard !loaded else { return }
        var pathInfo = stat()
        guard Darwin.lstat(archiveURL.path, &pathInfo) == 0 else {
            if errno != ENOENT { throw Self.mapErrno(path: archiveURL.path) }
            loaded = true
            return
        }
        let data: Data
        let decoded: Archive
        do {
            data = try Self.readArchive(archiveURL)
            decoded = try JSONDecoder().decode(Archive.self, from: data)
        } catch let failure as WorkspaceBrowserFailure { throw failure }
        catch { throw .corruptStore(String(describing: error)) }
        guard decoded.schemaVersion == 1,
              Set(decoded.roots.map(\.id)).count == decoded.roots.count else {
            throw .corruptStore("unsupported schema or duplicate root ID")
        }
        archive = decoded
        loaded = true
    }

    private static func readArchive(_ url: URL) throws(WorkspaceBrowserFailure) -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw mapErrno(path: url.path) }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, fileType(before) == S_IFREG,
              before.st_size >= 0 else { throw .corruptStore("workspace archive is not a regular file") }
        guard before.st_size <= maximumArchiveBytes else {
            throw .corruptStore("workspace archive exceeds size limit")
        }
        var data = Data()
        data.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let remaining = maximumArchiveBytes + 1 - data.count
            guard remaining > 0 else { throw .corruptStore("workspace archive exceeds size limit") }
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, min($0.count, remaining))
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw mapErrno(path: url.path)
            }
            data.append(buffer, count: count)
            if data.count > maximumArchiveBytes {
                throw .corruptStore("workspace archive exceeds size limit")
            }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, sameSnapshot(before, after), after.st_size == data.count else {
            throw .corruptStore("workspace archive changed while reading")
        }
        return data
    }

    private func persist() throws(WorkspaceBrowserFailure) {
        do {
            let directory = archiveURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(archive)
            guard data.count <= Self.maximumArchiveBytes else {
                throw WorkspaceBrowserFailure.corruptStore("workspace archive exceeds size limit")
            }
            try data.write(to: archiveURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archiveURL.path)
        } catch let failure as WorkspaceBrowserFailure { throw failure }
        catch { throw .io(String(describing: error)) }
    }

    private func availableRoot(_ id: WorkspaceRootID) throws(WorkspaceBrowserFailure) -> RootAccess {
        guard archive.roots.contains(where: { $0.id == id }) else { throw .unknownRoot(id) }
        guard let root = activeURLs[id], let identity = activeRootIdentities[id] else { throw .unavailableRoot(id) }
        return RootAccess(id: id, url: root, identity: identity)
    }

    private func beginAccessBeforeInspection(_ url: URL, id: WorkspaceRootID) -> ScopeAttempt {
        if let existing = scopedAccessURLs[id] {
            if existing == url { return ScopeAttempt(allowed: true, newlyAcquired: false) }
            endAccess(id)
        }
        if startSecurityScopedAccess(url) {
            scopedAccessURLs[id] = url
            return ScopeAttempt(allowed: true, newlyAcquired: true)
        }
        return ScopeAttempt(allowed: !securityScopedAccessRequired, newlyAcquired: false)
    }

    private func inspectedCanonicalRoot(_ url: URL) throws(WorkspaceBrowserFailure) -> URL {
        do { return try canonicalizeRoot(url) }
        catch let failure as WorkspaceBrowserFailure { throw failure }
        catch { throw .io(String(describing: error)) }
    }

    private func endAccess(_ id: WorkspaceRootID) {
        guard let url = scopedAccessURLs.removeValue(forKey: id) else { return }
        stopSecurityScopedAccess(url)
    }

    private func deactivateRoot(_ id: WorkspaceRootID) {
        endAccess(id)
        activeURLs.removeValue(forKey: id)
        activeRootIdentities.removeValue(forKey: id)
    }

    private func resolveBookmark(_ data: Data) -> (url: URL, stale: Bool)? {
        var stale = false
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) { return (url, stale) }
        stale = false
        return try? (URL(
            resolvingBookmarkData: data,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ), stale)
    }

    private static func bookmark(for url: URL) throws(WorkspaceBrowserFailure) -> Data {
        do {
            return try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            do { return try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil) }
            catch { throw map(error, path: url.path) }
        }
    }

    private static func canonicalRoot(_ url: URL) throws(WorkspaceBrowserFailure) -> URL {
        guard url.isFileURL else { throw .invalidPath(url.absoluteString) }
        let root = url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        var info = stat()
        guard Darwin.lstat(root.path, &info) == 0 else { throw mapErrno(path: root.path) }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw .invalidPath(root.path) }
        return root
    }

    private static func isValidRelativePath(_ path: String) -> Bool {
        guard !path.hasPrefix("/"), path.utf8.count <= 16 * 1_024 else { return false }
        if path.isEmpty { return true }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0")
        }
    }

    private static func root(from record: StoredRoot, available: Bool) -> WorkspaceRoot {
        WorkspaceRoot(
            id: record.id,
            canonicalPath: record.lastKnownPath,
            displayName: record.displayName,
            isAvailable: available,
            expandedRelativePaths: record.expandedRelativePaths,
            selectedRelativePath: record.selectedRelativePath
        )
    }

    private static func sorted(_ roots: [WorkspaceRoot]) -> [WorkspaceRoot] {
        roots.sorted {
            let name = $0.displayName.localizedStandardCompare($1.displayName)
            return name == .orderedSame ? $0.canonicalPath < $1.canonicalPath : name == .orderedAscending
        }
    }

    private static func map(_ error: Error, path: String) -> WorkspaceBrowserFailure {
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain,
           (cocoa.code == NSFileReadNoPermissionError || cocoa.code == NSFileWriteNoPermissionError) {
            return .permissionDenied(path)
        }
        return .io("\(path): \(error)")
    }

    private static func mapErrno(path: String) -> WorkspaceBrowserFailure {
        switch errno {
        case EACCES, EPERM: .permissionDenied(path)
        case ENOENT, ELOOP, ENOTDIR: .invalidPath(path)
        default: .io("\(path): \(String(cString: strerror(errno)))")
        }
    }

    deinit {
        for url in scopedAccessURLs.values { stopSecurityScopedAccess(url) }
    }
}
