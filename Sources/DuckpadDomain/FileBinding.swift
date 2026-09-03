import Foundation

public enum TextFileEncoding: String, CaseIterable, Codable, Equatable, Sendable {
    case utf8
    case utf16LittleEndian
    case utf16BigEndian
}

public enum ByteOrderMark: String, Codable, Equatable, Sendable {
    case absent
    case present
}

public enum LineEnding: String, Codable, Equatable, Sendable {
    case none
    case lf
    case crlf
    case cr
    case mixed
}

/// Stable, adapter-produced identity of the bytes that were last read or saved.
/// The opaque content token prevents timestamp-only conflict checks.
public struct FileIdentity: Codable, Equatable, Sendable {
    public let canonicalPath: String
    public let device: UInt64
    public let inode: UInt64
    public let byteCount: UInt64
    public let modifiedNanoseconds: Int64
    public let contentToken: String

    public init(
        canonicalPath: String,
        device: UInt64,
        inode: UInt64,
        byteCount: UInt64,
        modifiedNanoseconds: Int64,
        contentToken: String
    ) {
        self.canonicalPath = canonicalPath
        self.device = device
        self.inode = inode
        self.byteCount = byteCount
        self.modifiedNanoseconds = modifiedNanoseconds
        self.contentToken = contentToken
    }
}

/// File metadata is deliberately separate from ScratchDocument/BufferMetadata.
/// A document remains stable while Save As replaces this binding.
public struct FileBinding: Codable, Equatable, Sendable {
    public let canonicalPath: String
    public var encoding: TextFileEncoding
    public var byteOrderMark: ByteOrderMark
    public var lineEnding: LineEnding
    public var observedIdentity: FileIdentity
    /// App-scoped security bookmark used only to regain the user's file
    /// authority after a sandboxed relaunch. Nil remains valid for legacy
    /// recovery archives and unsandboxed development builds.
    public var securityScopedBookmark: Data?

    public init(
        canonicalPath: String,
        encoding: TextFileEncoding,
        byteOrderMark: ByteOrderMark,
        lineEnding: LineEnding,
        observedIdentity: FileIdentity,
        securityScopedBookmark: Data? = nil
    ) {
        self.canonicalPath = canonicalPath
        self.encoding = encoding
        self.byteOrderMark = byteOrderMark
        self.lineEnding = lineEnding
        self.observedIdentity = observedIdentity
        self.securityScopedBookmark = securityScopedBookmark
    }
}
