import CryptoKit
import Darwin
import DuckpadApplication
import DuckpadDomain
import Foundation

extension LocalTextFileStore {
    public func changeLocation(of binding: FileBinding, operation: FileLocationOperation) async throws(TextFileStoreError) -> FileLocationReceipt {
        do {
            return try await Task.detached(priority: .utility) {
                try LocalFileLocationOperations.perform(binding, operation: operation)
            }.value
        } catch let error as TextFileStoreError { throw error }
        catch { throw .io(String(describing: error)) }
    }
}

private enum LocalFileLocationOperations {
    static func perform(_ binding: FileBinding, operation: FileLocationOperation) throws -> FileLocationReceipt {
        let source = URL(fileURLWithPath: binding.canonicalPath)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<FileLocationReceipt, Error>?
        let apply: (URL, URL?) -> Void = { source, destination in
            result = Result {
                let current = try identity(source, binary: binding.isReadOnly)
                guard current == binding.observedIdentity else { throw TextFileStoreError.conflict(current: current) }
                let target: URL
                if let destination {
                    var existing = stat()
                    if lstat(destination.path, &existing) == 0 {
                        let isCaseAlias = UInt64(existing.st_dev) == current.device
                            && UInt64(existing.st_ino) == current.inode
                            && destination.path != source.path
                            && destination.resolvingSymlinksInPath().path == source.path
                        guard isCaseAlias else { throw TextFileStoreError.destinationExists(destination.path) }
                    } else if errno != ENOENT { throw TextFileStoreError.permissionDenied(destination.path) }
                    // RENAME_EXCL provides atomic no-overwrite semantics on the
                    // same volume. Foundation handles a cross-volume move.
                    if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) != 0 {
                        guard errno == EXDEV else {
                            if errno == EEXIST { throw TextFileStoreError.destinationExists(destination.path) }
                            throw TextFileStoreError.io(String(cString: strerror(errno)))
                        }
                        try FileManager.default.moveItem(at: source, to: destination)
                    }
                    target = destination
                    coordinator.item(at: source, didMoveTo: target)
                } else {
                    var trashed: NSURL?
                    try FileManager.default.trashItem(at: source, resultingItemURL: &trashed)
                    // Foundation supplies the resulting URL for a successful trash.
                    guard let trashed else { throw TextFileStoreError.io("Trash location unavailable") }
                    target = trashed as URL
                }
                // The operation has committed: never report an ordinary failure
                // just because a subsequent metadata read lost access.
                let observed = (try? identity(target, binary: binding.isReadOnly)) ?? FileIdentity(
                    canonicalPath: target.path, device: current.device, inode: current.inode,
                    byteCount: current.byteCount, modifiedNanoseconds: current.modifiedNanoseconds,
                    contentToken: current.contentToken)
                return FileLocationReceipt(identity: observed)
            }
        }
        switch operation {
        case .move(let destination):
            guard destination.isFileURL else { throw TextFileStoreError.invalidPath(destination.absoluteString) }
            coordinator.coordinate(writingItemAt: source, options: .forMoving,
                writingItemAt: destination, options: [], error: &coordinationError) { apply($0, $1) }
        case .trash:
            coordinator.coordinate(writingItemAt: source, options: .forDeleting, error: &coordinationError) { apply($0, nil) }
        }
        if let result { return try result.get() }
        throw TextFileStoreError.io(coordinationError?.localizedDescription ?? "File coordination failed")
    }

    private static func identity(_ url: URL, binary: Bool) throws -> FileIdentity {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw TextFileStoreError.notFound(url.path) }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw TextFileStoreError.invalidPath(url.path) }
        var hash = SHA256()
        var sample = Data()
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &bytes, bytes.count)
            if count < 0 { if errno == EINTR { continue }; throw TextFileStoreError.io(url.path) }
            if count == 0 { break }
            let chunk = Data(bytes.prefix(count))
            if binary {
                sample.append(chunk.prefix(max(0, BinaryFileContent.analysisByteCount - sample.count)))
                if sample.count >= BinaryFileContent.analysisByteCount { break }
            } else { hash.update(data: chunk) }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, BinaryFileIdentity.sameSnapshot(before, after) else { throw TextFileStoreError.conflict(current: nil) }
        if binary { return BinaryFileIdentity.make(path: url.path, data: sample, info: after) }
        return FileIdentity(canonicalPath: url.path, device: UInt64(after.st_dev), inode: UInt64(after.st_ino),
            byteCount: UInt64(after.st_size), modifiedNanoseconds: Int64(after.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(after.st_mtimespec.tv_nsec),
            contentToken: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
