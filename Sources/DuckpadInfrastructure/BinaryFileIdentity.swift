import CryptoKit
import Darwin
import DuckpadApplication
import DuckpadDomain
import Foundation

/// Display-only identity: never an editable document's overwrite precondition.
enum BinaryFileIdentity {
    // ponytail: sampled display tokens rely on filesystem change times; editable content still needs full hashing.
    static func make(path: String, data: Data, info: stat) -> FileIdentity {
        let digest = SHA256.hash(data: data.prefix(BinaryFileContent.analysisByteCount))
            .map { String(format: "%02x", $0) }.joined()
        return FileIdentity(canonicalPath: path, device: UInt64(info.st_dev), inode: UInt64(info.st_ino),
            byteCount: UInt64(info.st_size),
            modifiedNanoseconds: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
            contentToken: "binary-readonly:\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec):\(digest)")
    }

    static func sameSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}
