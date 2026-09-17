import CryptoKit
import Foundation

/// Retains one owned byte snapshot and SHA-256 prefix states. Reuse requires
/// byte-for-byte equality, never just matching filesystem timestamps. Appends
/// and edits near EOF therefore hash only the changed suffix while producing
/// the same ordinary SHA-256 token used by older versions.
final class TextFileContentHasher: @unchecked Sendable {
    private struct Boundary {
        let end: Int
        let state: SHA256
    }
    private struct Snapshot {
        let bytes: Data
        let boundaries: [Boundary]
        let digest: String
    }
    private let lock = NSLock()
    private var snapshot: Snapshot?
    private var workByteCount = 0
    private let chunkSize: Int
    private let maximumCachedBytes: Int

    init(chunkSize: Int = 4 * 1_024 * 1_024, maximumCachedBytes: Int = 2 * 1_024 * 1_024 * 1_024) {
        precondition(chunkSize > 0 && maximumCachedBytes >= 0)
        self.chunkSize = chunkSize
        self.maximumCachedBytes = maximumCachedBytes
    }

    func clear() { lock.withLock { snapshot = nil; workByteCount = 0 } }

    var lastHashedByteCount: Int { lock.withLock { workByteCount } }

    /// Input must be an owned immutable read buffer, not a mapping of a file
    /// another process can overwrite. LocalTextFileStore enforces this.
    func digest(_ data: Data) -> String {
        let previous = lock.withLock { snapshot }
        var hasher = SHA256()
        var boundaries: [Boundary] = []
        var offset = 0
        if let previous {
            data.withUnsafeBytes { (current: UnsafeRawBufferPointer) in
                previous.bytes.withUnsafeBytes { (old: UnsafeRawBufferPointer) in
                    for boundary in previous.boundaries {
                        guard boundary.end <= current.count,
                              (current.baseAddress == old.baseAddress ||
                               memcmp(current.baseAddress!.advanced(by: offset),
                                      old.baseAddress!.advanced(by: offset), boundary.end - offset) == 0) else { break }
                        if boundary.end.isMultiple(of: chunkSize) || boundary.end == data.count {
                            boundaries.append(boundary)
                        }
                        offset = boundary.end
                        hasher = boundary.state
                    }
                }
            }
            if offset == data.count, data.count == previous.bytes.count {
                lock.withLock { workByteCount = 0 }
                return previous.digest
            }
        }
        let hashedBytes = data.count - offset
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            while offset < bytes.count {
                let end = offset + min(chunkSize - offset % chunkSize, bytes.count - offset)
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes[offset..<end]))
                if data.count <= maximumCachedBytes { boundaries.append(Boundary(end: end, state: hasher)) }
                offset = end
            }
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        lock.withLock {
            snapshot = data.count <= maximumCachedBytes
                ? Snapshot(bytes: data, boundaries: boundaries, digest: digest) : nil
            workByteCount = hashedBytes
        }
        return digest
    }
}
