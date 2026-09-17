import Darwin
import Foundation

/// Each generation owns an independent file. APFS shares unchanged extents,
/// while a complete byte comparison repairs even an externally damaged source.
/// No hard links or metadata-only integrity shortcuts are used.
enum RecoveryBlobWriter {
    static func openPreviousBlobs(in generations: Int32, generation: UInt64?) -> Int32 {
        guard let generation else { return -1 }
        let directory = openat(generations, String(format: "%020llu", generation),
                               O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return -1 }
        defer { Darwin.close(directory) }
        return openat(directory, "blobs", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }

    static func writeClone(_ data: Data, name: String, previousBlobs: Int32,
                           destination: Int32) throws -> Bool {
        guard previousBlobs >= 0, data.count >= ClonedTextFile.minimumByteCount else { return false }
        let source = openat(previousBlobs, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { return false }
        defer { Darwin.close(source) }
        var info = stat()
        guard fstat(source, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
        guard let candidate = try ClonedTextFile.prepare(sourceDescriptor: source,
                destinationDirectory: destination, name: name, data: data) else { return false }
        defer { Darwin.close(candidate) }
        guard fsync(candidate) == 0, fcntl(candidate, F_FULLFSYNC) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return true
    }
}
