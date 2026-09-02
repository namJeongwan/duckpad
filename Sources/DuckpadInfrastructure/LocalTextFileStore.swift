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
    private let fault: AtomicWriteFault

    public init(fault: AtomicWriteFault = .none) { self.fault = fault }

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
        do {
            return try await Task.detached(priority: .utility) {
                try Self.writeBlocking(data, to: url, expectedIdentity: expectedIdentity, overwrite: overwrite, fault: fault)
            }.value
        } catch let error as TextFileStoreError { throw error }
        catch { throw .io(String(describing: error)) }
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
