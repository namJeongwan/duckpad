import CryptoKit
import Darwin
import DuckpadApplication
import DuckpadDomain
import Foundation

public actor LocalFolderSearchFileStore: FolderSearchFileStore {
    private let beforeOpeningEntry: (@Sendable (String) -> Void)?
    private let afterReadingDirectoryEntry: (@Sendable () -> Void)?
    private let beforeReadingFile: (@Sendable (String) -> Void)?
    private let maximumDirectoryEntries: Int
    private let maximumDirectoryNameBytes: Int

    public init() {
        beforeOpeningEntry = nil
        afterReadingDirectoryEntry = nil
        beforeReadingFile = nil
        maximumDirectoryEntries = 1_000_000
        maximumDirectoryNameBytes = 32 * 1_024 * 1_024
    }

    init(
        testingBeforeOpeningEntry: (@Sendable (String) -> Void)? = nil,
        testingAfterReadingDirectoryEntry: (@Sendable () -> Void)? = nil,
        testingBeforeReadingFile: (@Sendable (String) -> Void)? = nil,
        maximumDirectoryEntries: Int = 1_000_000,
        maximumDirectoryNameBytes: Int = 32 * 1_024 * 1_024
    ) {
        beforeOpeningEntry = testingBeforeOpeningEntry
        afterReadingDirectoryEntry = testingAfterReadingDirectoryEntry
        beforeReadingFile = testingBeforeReadingFile
        self.maximumDirectoryEntries = maximumDirectoryEntries
        self.maximumDirectoryNameBytes = maximumDirectoryNameBytes
    }

    public func enumerateTextCandidates(
        rootPath: String,
        maximumFiles: Int,
        maximumDocumentBytes: Int,
        maximumTotalBytes: Int
    ) async throws(FolderSearchFailure) -> FolderSearchEnumeration {
        let beforeOpeningEntry = beforeOpeningEntry
        let afterReadingDirectoryEntry = afterReadingDirectoryEntry
        let beforeReadingFile = beforeReadingFile
        let maximumDirectoryEntries = maximumDirectoryEntries
        let maximumDirectoryNameBytes = maximumDirectoryNameBytes
        let task = Task.detached(priority: .utility) {
            try Self.enumerateBlocking(
                rootPath: rootPath,
                maximumFiles: maximumFiles,
                maximumDocumentBytes: maximumDocumentBytes,
                maximumTotalBytes: maximumTotalBytes,
                beforeOpeningEntry: beforeOpeningEntry,
                afterReadingDirectoryEntry: afterReadingDirectoryEntry,
                beforeReadingFile: beforeReadingFile,
                maximumDirectoryEntries: maximumDirectoryEntries,
                maximumDirectoryNameBytes: maximumDirectoryNameBytes
            )
        }
        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch let error as FolderSearchFailure {
            throw error
        } catch is CancellationError {
            throw .search(.cancelled)
        } catch {
            throw .enumerationFailed(String(describing: error))
        }
    }

    private static func enumerateBlocking(
        rootPath: String,
        maximumFiles: Int,
        maximumDocumentBytes: Int,
        maximumTotalBytes: Int,
        beforeOpeningEntry: (@Sendable (String) -> Void)?,
        afterReadingDirectoryEntry: (@Sendable () -> Void)?,
        beforeReadingFile: (@Sendable (String) -> Void)?,
        maximumDirectoryEntries: Int,
        maximumDirectoryNameBytes: Int
    ) throws(FolderSearchFailure) -> FolderSearchEnumeration {
        guard maximumFiles > 0, maximumDocumentBytes > 0, maximumTotalBytes > 0,
              maximumDirectoryEntries > 0, maximumDirectoryNameBytes > 0 else {
            throw .invalidLimits
        }
        let requested = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let accessed = requested.startAccessingSecurityScopedResource()
        defer { if accessed { requested.stopAccessingSecurityScopedResource() } }
        let root = requested.resolvingSymlinksInPath().standardizedFileURL
        let rootDescriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDescriptor >= 0 else {
            if errno == EACCES || errno == EPERM { throw .accessDenied(root.path) }
            throw .invalidRoot(rootPath)
        }
        defer { Darwin.close(rootDescriptor) }
        var rootInfo = stat()
        guard fstat(rootDescriptor, &rootInfo) == 0, fileType(rootInfo) == S_IFDIR else {
            throw .invalidRoot(rootPath)
        }

        var files: [FolderSearchFile] = []
        var skipped = 0
        var totalBytes = 0
        var truncated = false
        var observedEntries = 0
        var observedNameBytes = 0

        func walk(directoryDescriptor: Int32, relativeDirectory: String, depth: Int) throws(FolderSearchFailure) {
            if Task.isCancelled { throw .search(.cancelled) }
            guard depth <= 256 else { skipped += 1; return }
            let listing: DirectoryListing
            do {
                listing = try directoryNames(
                    descriptor: directoryDescriptor,
                    maximumEntries: maximumDirectoryEntries - observedEntries,
                    maximumNameBytes: maximumDirectoryNameBytes - observedNameBytes,
                    afterReadingEntry: afterReadingDirectoryEntry
                )
            } catch let failure as FolderSearchFailure {
                throw failure
            }
            catch {
                if depth == 0 { throw .enumerationFailed("\(root.path): \(error.localizedDescription)") }
                skipped += 1
                return
            }
            observedEntries += listing.names.count
            observedNameBytes += listing.nameBytes
            if listing.isTruncated { truncated = true }

            for name in listing.names {
                if Task.isCancelled { throw .search(.cancelled) }
                guard !name.hasPrefix("."), !name.contains("/") else { skipped += 1; continue }
                let relativePath = relativeDirectory.isEmpty ? name : "\(relativeDirectory)/\(name)"
                beforeOpeningEntry?(relativePath)
                let descriptor = Darwin.openat(
                    directoryDescriptor,
                    name,
                    O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
                )
                guard descriptor >= 0 else { skipped += 1; continue }
                defer { Darwin.close(descriptor) }
                var before = stat()
                guard fstat(descriptor, &before) == 0 else { skipped += 1; continue }
                guard before.st_flags & UInt32(UF_HIDDEN) == 0 else { skipped += 1; continue }

                switch fileType(before) {
                case S_IFDIR:
                    let displayPath = joinedPath(root: root.path, relative: relativePath)
                    guard !isPackageDirectory(name: name, displayPath: displayPath) else { skipped += 1; continue }
                    try walk(directoryDescriptor: descriptor, relativeDirectory: relativePath, depth: depth + 1)
                    if truncated { return }
                case S_IFREG:
                    guard files.count < maximumFiles else { truncated = true; return }
                    guard before.st_size >= 0, before.st_size <= maximumDocumentBytes else {
                        skipped += 1
                        continue
                    }
                    let remainingTotal = maximumTotalBytes - totalBytes
                    guard before.st_size <= remainingTotal else { truncated = true; return }
                    beforeReadingFile?(relativePath)
                    let data: Data
                    do {
                        data = try boundedRead(
                            descriptor: descriptor,
                            documentLimit: maximumDocumentBytes,
                            aggregateLimit: remainingTotal
                        )
                    } catch ReadFailure.documentLimit {
                        skipped += 1
                        continue
                    } catch ReadFailure.aggregateLimit {
                        truncated = true
                        return
                    } catch let failure as FolderSearchFailure {
                        throw failure
                    } catch {
                        skipped += 1
                        continue
                    }
                    var after = stat()
                    guard fstat(descriptor, &after) == 0,
                          sameSnapshot(before, after),
                          after.st_size == data.count else {
                        skipped += 1
                        continue
                    }
                    let canonicalPath = joinedPath(root: root.path, relative: relativePath)
                    files.append(FolderSearchFile(
                        path: canonicalPath,
                        relativePath: relativePath,
                        data: data,
                        identity: identity(path: canonicalPath, info: after, data: data)
                    ))
                    totalBytes += data.count
                default:
                    skipped += 1
                }
            }
            if listing.isTruncated { return }
        }

        try walk(directoryDescriptor: rootDescriptor, relativeDirectory: "", depth: 0)
        var rootPathInfo = stat()
        var rootAfter = stat()
        guard Darwin.lstat(root.path, &rootPathInfo) == 0,
              fstat(rootDescriptor, &rootAfter) == 0,
              fileType(rootPathInfo) == S_IFDIR,
              rootPathInfo.st_dev == rootInfo.st_dev,
              rootPathInfo.st_ino == rootInfo.st_ino,
              rootAfter.st_dev == rootInfo.st_dev,
              rootAfter.st_ino == rootInfo.st_ino else {
            throw .enumerationFailed("selected folder changed during search")
        }
        return FolderSearchEnumeration(
            rootPath: root.path,
            files: files,
            isTruncated: truncated,
            skippedFileCount: skipped,
            totalBytes: totalBytes
        )
    }

    private enum ReadFailure: Error {
        case documentLimit
        case aggregateLimit
        case input
    }

    private static func boundedRead(
        descriptor: Int32,
        documentLimit: Int,
        aggregateLimit: Int
    ) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            if Task.isCancelled { throw FolderSearchFailure.search(.cancelled) }
            let permitted = min(documentLimit, aggregateLimit)
            if result.count == permitted {
                var probe: UInt8 = 0
                let count = Darwin.read(descriptor, &probe, 1)
                if count == 0 { return result }
                guard count > 0 else {
                    if errno == EINTR { continue }
                    throw ReadFailure.input
                }
                if aggregateLimit < documentLimit { throw ReadFailure.aggregateLimit }
                throw ReadFailure.documentLimit
            }
            let request = min(buffer.count, permitted - result.count)
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(descriptor, raw.baseAddress, request)
            }
            if count == 0 { return result }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw ReadFailure.input
            }
            result.append(buffer, count: count)
        }
    }

    private struct DirectoryListing {
        let names: [String]
        let nameBytes: Int
        let isTruncated: Bool
    }

    private static func directoryNames(
        descriptor: Int32,
        maximumEntries: Int,
        maximumNameBytes: Int,
        afterReadingEntry: (@Sendable () -> Void)?
    ) throws -> DirectoryListing {
        guard maximumEntries > 0, maximumNameBytes > 0 else {
            return DirectoryListing(names: [], nameBytes: 0, isTruncated: true)
        }
        let copy = Darwin.dup(descriptor)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { Darwin.close(copy) }
            throw CocoaError(.fileReadUnknown)
        }
        defer { closedir(stream) }
        var names: [String] = []
        var nameBytes = 0
        var truncated = false
        errno = 0
        while let pointer = readdir(stream) {
            if Task.isCancelled { throw FolderSearchFailure.search(.cancelled) }
            var entry = pointer.pointee
            let name = withUnsafePointer(to: &entry.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." {
                afterReadingEntry?()
                let bytes = name.utf8.count
                guard names.count < maximumEntries, bytes <= maximumNameBytes - nameBytes else {
                    truncated = true
                    break
                }
                names.append(name)
                nameBytes += bytes
            }
            errno = 0
        }
        guard errno == 0 else { throw CocoaError(.fileReadUnknown) }
        return DirectoryListing(
            names: names.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
            nameBytes: nameBytes,
            isTruncated: truncated
        )
    }

    private static func fileType(_ info: stat) -> mode_t {
        info.st_mode & S_IFMT
    }

    private static func isPackageDirectory(name: String, displayPath: String) -> Bool {
        let packageExtensions: Set<String> = [
            "app", "appex", "bundle", "framework", "kext", "mdimporter", "pkg",
            "plugin", "qlgenerator", "rtfd", "wdgt", "xcodeproj", "xcworkspace", "playground",
        ]
        if packageExtensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased()) { return true }
        return (try? URL(fileURLWithPath: displayPath, isDirectory: true)
            .resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }

    private static func joinedPath(root: String, relative: String) -> String {
        root == "/" ? "/" + relative : root + "/" + relative
    }

    private static func sameSnapshot(_ before: stat, _ after: stat) -> Bool {
        before.st_dev == after.st_dev
            && before.st_ino == after.st_ino
            && before.st_size == after.st_size
            && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
            && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
            && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
            && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    }

    private static func identity(path: String, info: stat, data: Data) -> FileIdentity {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let nanos = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return FileIdentity(
            canonicalPath: path,
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            byteCount: UInt64(info.st_size),
            modifiedNanoseconds: nanos,
            contentToken: digest
        )
    }
}
