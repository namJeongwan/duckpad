import Darwin
import Foundation

/// Prepares a private copy-on-write candidate. Only the candidate is patched;
/// callers retain their existing atomic publication and durability protocol.
enum ClonedTextFile {
    static let minimumByteCount = 1_024 * 1_024

    /// Returns an open descriptor owned by the caller, or nil when cloning is
    /// unavailable. The destination must be a fresh, private temporary name.
    static func prepare(source: URL, destination: URL, data: Data) throws -> Int32? {
        guard data.count >= minimumByteCount else { return nil }
        guard clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) == 0 else { return nil }
        // clonefile preserves a read-only source mode. Make only our private
        // candidate writable before opening it; never follow a substituted link.
        guard fchmodat(AT_FDCWD, destination.path, S_IRUSR | S_IWUSR, AT_SYMLINK_NOFOLLOW) == 0 else {
            let error = failure()
            Darwin.unlink(destination.path)
            throw error
        }
        let descriptor = Darwin.open(destination.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            let error = failure()
            Darwin.unlink(destination.path)
            throw error
        }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw failure() }
            let chunkSize = 1_024 * 1_024
            let scratch = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
            defer { scratch.deallocate() }
            try data.withUnsafeBytes { (desired: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < desired.count {
                    let length = min(chunkSize, desired.count - offset)
                    let available = Int(min(Int64(length), max(0, info.st_size - Int64(offset))))
                    var read = 0
                    while read < available {
                        let count = pread(descriptor, scratch.advanced(by: read), available - read, off_t(offset + read))
                        if count < 0, errno == EINTR { continue }
                        guard count > 0 else { throw failure() }
                        read += count
                    }
                    let bytes = desired.baseAddress!.advanced(by: offset)
                    if available != length || memcmp(scratch, bytes, length) != 0 {
                        var written = 0
                        while written < length {
                            let count = pwrite(descriptor, bytes.advanced(by: written), length - written, off_t(offset + written))
                            if count < 0, errno == EINTR { continue }
                            guard count > 0 else { throw failure() }
                            written += count
                        }
                    }
                    offset += length
                }
            }
            if info.st_size != data.count {
                guard ftruncate(descriptor, off_t(data.count)) == 0 else { throw failure() }
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            Darwin.unlink(destination.path)
            throw error
        }
    }

    private static func failure() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno == 0 ? EIO : errno))
    }
}
