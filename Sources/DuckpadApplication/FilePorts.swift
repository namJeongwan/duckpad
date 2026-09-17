import DuckpadDomain
import Foundation

public struct FileReadResult: Equatable, Sendable {
    public let data: Data
    public let identity: FileIdentity

    public init(data: Data, identity: FileIdentity) {
        self.data = data
        self.identity = identity
    }
}

public enum TextFileStoreError: Error, Equatable, Sendable {
    case destinationExists(String)
    case notFound(String)
    case permissionDenied(String)
    case invalidPath(String)
    case conflict(current: FileIdentity?)
    case atomicWriteFailed(String)
    case durabilityFailure(
        state: FileCommitFailureState,
        current: FileIdentity?,
        recoveryPath: String?,
        detail: String
    )
    case io(String)
}

public enum FileCommitFailureState: String, Equatable, Sendable {
    case originalRestored
    case replacementVisibleDurabilityUncertain
    case filesystemStateUncertain
}

public enum FileDurability: String, Equatable, Sendable { case durable }

public struct FileWriteReceipt: Equatable, Sendable {
    public let identity: FileIdentity
    public let durability: FileDurability

    public init(identity: FileIdentity, durability: FileDurability = .durable) {
        self.identity = identity
        self.durability = durability
    }
}

public struct SecurityScopedFileAccess: Equatable, Sendable {
    public let url: URL
    public let bookmark: Data?

    public init(url: URL, bookmark: Data? = nil) {
        self.url = url
        self.bookmark = bookmark
    }
}

public protocol TextFileStore: Sendable {
    func changeLocation(of binding: FileBinding, operation: FileLocationOperation) async throws(TextFileStoreError) -> FileLocationReceipt
    /// Refresh access from a URL explicitly selected in a native file panel.
    func renewSecurityScopedAccess(to url: URL, ownerID: UUID) async throws(TextFileStoreError) -> SecurityScopedFileAccess
    func prepareSecurityScopedAccess(
        to url: URL,
        ownerID: UUID
    ) async throws(TextFileStoreError) -> SecurityScopedFileAccess
    func restoreSecurityScopedAccess(
        for binding: FileBinding,
        ownerID: UUID
    ) async throws(TextFileStoreError) -> FileBinding
    func releaseSecurityScopedAccess(forCanonicalPath path: String, ownerID: UUID) async
    func reconcileSecurityScopedAccess(retainingCanonicalPaths paths: Set<String>, ownerID: UUID) async
    func releaseAllSecurityScopedAccess(ownerID: UUID) async
    func clearPersistedSecurityScopedBookmarks() async throws(TextFileStoreError)
    func canonicalURL(for url: URL) async throws(TextFileStoreError) -> URL
    func read(from url: URL) async throws(TextFileStoreError) -> FileReadResult
    func openingPreview(from url: URL, assuming encoding: TextFileEncoding?) async -> FileOpeningPreview?
    /// Returns the complete bytes for text or read-only binary display.
    func readForDisplay(from url: URL, assuming encoding: TextFileEncoding?) async throws(TextFileStoreError) -> FileReadResult
    func currentIdentity(for url: URL) async throws(TextFileStoreError) -> FileIdentity?
    func writeAtomically(
        _ data: Data,
        to url: URL,
        expectedIdentity: FileIdentity?,
        overwrite: Bool
    ) async throws(TextFileStoreError) -> FileWriteReceipt
}

public extension TextFileStore {
    func openingPreview(from url: URL, assuming encoding: TextFileEncoding?) async -> FileOpeningPreview? { nil }
    func changeLocation(of binding: FileBinding, operation: FileLocationOperation) async throws(TextFileStoreError) -> FileLocationReceipt {
        throw .io("File location operations are unavailable")
    }
    func readForDisplay(from url: URL, assuming encoding: TextFileEncoding?) async throws(TextFileStoreError) -> FileReadResult {
        try await read(from: url)
    }

    func renewSecurityScopedAccess(to url: URL, ownerID: UUID) async throws(TextFileStoreError) -> SecurityScopedFileAccess {
        try await prepareSecurityScopedAccess(to: url, ownerID: ownerID)
    }
    func prepareSecurityScopedAccess(
        to url: URL,
        ownerID: UUID
    ) async throws(TextFileStoreError) -> SecurityScopedFileAccess {
        SecurityScopedFileAccess(url: url)
    }

    func restoreSecurityScopedAccess(
        for binding: FileBinding,
        ownerID: UUID
    ) async throws(TextFileStoreError) -> FileBinding { binding }

    func releaseSecurityScopedAccess(forCanonicalPath path: String, ownerID: UUID) async {}
    func reconcileSecurityScopedAccess(retainingCanonicalPaths paths: Set<String>, ownerID: UUID) async {}
    func releaseAllSecurityScopedAccess(ownerID: UUID) async {}
    func clearPersistedSecurityScopedBookmarks() async throws(TextFileStoreError) {}

    func currentIdentity(for url: URL) async throws(TextFileStoreError) -> FileIdentity? {
        do { return try await read(from: url).identity }
        catch .notFound { return nil }
        catch let error { throw error }
    }
}

public struct DecodedTextFile: Equatable, Sendable {
    public let text: String
    public let encoding: TextFileEncoding
    public let byteOrderMark: ByteOrderMark
    public let lineEnding: LineEnding
    public let binaryByteCount: Int?

    public init(text: String, encoding: TextFileEncoding, byteOrderMark: ByteOrderMark, lineEnding: LineEnding, binaryByteCount: Int? = nil) {
        self.text = text
        self.encoding = encoding
        self.byteOrderMark = byteOrderMark
        self.lineEnding = lineEnding
        self.binaryByteCount = binaryByteCount
    }
}

public enum TextFileCodecError: Error, Equatable, Sendable {
    case invalidUTF8
    case truncatedUTF16
    case invalidUTF16
}

public struct TextFileConversion: Equatable, Sendable {
    public let encoding: TextFileEncoding
    public let byteOrderMark: ByteOrderMark
    public let lineEnding: LineEnding

    public init(encoding: TextFileEncoding, byteOrderMark: ByteOrderMark, lineEnding: LineEnding) {
        self.encoding = encoding
        self.byteOrderMark = byteOrderMark
        self.lineEnding = lineEnding
    }
}

public enum TextFileCodec {
    private static let utf8BOM = Data([0xEF, 0xBB, 0xBF])

    /// Opening arbitrary files is permissive; strict decoding remains available
    /// to callers that need to validate an encoding or guarantee a round trip.
    public static func decodeForDisplay(
        _ data: Data,
        assuming explicitEncoding: TextFileEncoding? = nil
    ) -> DecodedTextFile {
        if !BinaryFileContent.isBinary(data, assuming: explicitEncoding),
           let decoded = try? decode(data, assuming: explicitEncoding) { return decoded }
        return BinaryFileContent.decode(data)
    }

    public static func decode(
        _ data: Data,
        assuming explicitEncoding: TextFileEncoding? = nil
    ) throws(TextFileCodecError) -> DecodedTextFile {
        let text: String
        let encoding: TextFileEncoding
        let bom: ByteOrderMark
        if let explicitEncoding {
            switch explicitEncoding {
            case .utf8:
                let hasBOM = data.starts(with: utf8BOM)
                guard let decoded = String(data: hasBOM ? data.dropFirst(3) : data[...], encoding: .utf8) else { throw .invalidUTF8 }
                text = decoded
                encoding = .utf8
                bom = hasBOM ? .present : .absent
            case .utf16LittleEndian:
                let hasBOM = data.starts(with: Data([0xFF, 0xFE]))
                text = try decodeUTF16(hasBOM ? data.dropFirst(2) : data[...], littleEndian: true)
                encoding = .utf16LittleEndian
                bom = hasBOM ? .present : .absent
            case .utf16BigEndian:
                let hasBOM = data.starts(with: Data([0xFE, 0xFF]))
                text = try decodeUTF16(hasBOM ? data.dropFirst(2) : data[...], littleEndian: false)
                encoding = .utf16BigEndian
                bom = hasBOM ? .present : .absent
            }
        } else if data.starts(with: utf8BOM) {
            guard let decoded = String(data: data.dropFirst(3), encoding: .utf8) else { throw .invalidUTF8 }
            text = decoded
            encoding = .utf8
            bom = .present
        } else if data.starts(with: Data([0xFF, 0xFE])) {
            text = try decodeUTF16(data.dropFirst(2), littleEndian: true)
            encoding = .utf16LittleEndian
            bom = .present
        } else if data.starts(with: Data([0xFE, 0xFF])) {
            text = try decodeUTF16(data.dropFirst(2), littleEndian: false)
            encoding = .utf16BigEndian
            bom = .present
        } else {
            guard let decoded = String(data: data, encoding: .utf8) else { throw .invalidUTF8 }
            text = decoded
            encoding = .utf8
            bom = .absent
        }
        return DecodedTextFile(text: text, encoding: encoding, byteOrderMark: bom, lineEnding: detectLineEnding(text))
    }

    public static func encode(
        _ text: String,
        encoding: TextFileEncoding,
        byteOrderMark: ByteOrderMark
    ) -> Data {
        var result = Data()
        switch encoding {
        case .utf8:
            if byteOrderMark == .present { result.append(utf8BOM) }
            result.append(contentsOf: text.utf8)
        case .utf16LittleEndian, .utf16BigEndian:
            if byteOrderMark == .present {
                result.append(contentsOf: encoding == .utf16LittleEndian ? [0xFF, 0xFE] : [0xFE, 0xFF])
            }
            for unit in text.utf16 {
                let high = UInt8(truncatingIfNeeded: unit >> 8)
                let low = UInt8(truncatingIfNeeded: unit)
                result.append(contentsOf: encoding == .utf16LittleEndian ? [low, high] : [high, low])
            }
        }
        return result
    }

    /// Encode an immutable editor checkpoint without making a String/UTF-8
    /// round trip for ordinary UTF-8 saves. Callers validate the checkpoint
    /// while materializing editor deltas before invoking this method.
    public static func encodeUTF8(
        _ utf8: Data,
        encoding: TextFileEncoding,
        byteOrderMark: ByteOrderMark,
        lineEnding: LineEnding
    ) -> Data {
        let normalized = convertUTF8(utf8, to: lineEnding)
        if encoding == .utf8 {
            guard byteOrderMark == .present else { return normalized }
            var result = utf8BOM
            result.append(normalized)
            return result
        }
        return encode(String(decoding: normalized, as: UTF8.self),
                      encoding: encoding, byteOrderMark: byteOrderMark)
    }

    public static func convert(_ text: String, to lineEnding: LineEnding) -> String {
        guard lineEnding != .mixed, lineEnding != .none else { return text }
        return String(decoding: convertUTF8(Data(text.utf8), to: lineEnding), as: UTF8.self)
    }

    private static func convertUTF8(_ utf8: Data, to lineEnding: LineEnding) -> Data {
        guard lineEnding != .mixed, lineEnding != .none else { return utf8 }
        return utf8.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            // libc scans use vectorized loads; LF-only documents are the common
            // large-file case and need no scalar pass or allocation.
            guard let base = bytes.baseAddress, !bytes.isEmpty else { return utf8 }
            if lineEnding == .lf, memchr(base, 13, bytes.count) == nil { return utf8 }
            if lineEnding == .cr, memchr(base, 10, bytes.count) == nil { return utf8 }
            // An already-normalized file needs neither allocation nor copying.
            let existing = detectLineEnding(inUTF8: utf8)
            guard existing != .none, existing != lineEnding else { return utf8 }
            var result = Data()
            result.reserveCapacity(bytes.count)
            var start = 0
            var index = 0
            while index < bytes.count {
                let byte = bytes[index]
                guard byte == 13 || byte == 10 else { index += 1; continue }
                result.append(contentsOf: bytes[start..<index])
                if lineEnding != .lf { result.append(13) }
                if lineEnding != .cr { result.append(10) }
                if byte == 13, index + 1 < bytes.count, bytes[index + 1] == 10 { index += 1 }
                index += 1
                start = index
            }
            result.append(contentsOf: bytes[start..<bytes.count])
            return result
        }
    }

    private static func decodeUTF16(_ bytes: Data.SubSequence, littleEndian: Bool) throws(TextFileCodecError) -> String {
        guard bytes.count.isMultiple(of: 2) else { throw .truncatedUTF16 }
        let raw = Array(bytes)
        var units: [UInt16] = []
        units.reserveCapacity(raw.count / 2)
        for index in stride(from: 0, to: raw.count, by: 2) {
            let unit = littleEndian
                ? UInt16(raw[index]) | UInt16(raw[index + 1]) << 8
                : UInt16(raw[index]) << 8 | UInt16(raw[index + 1])
            units.append(unit)
        }
        var index = 0
        while index < units.count {
            let unit = units[index]
            if (0xD800...0xDBFF).contains(unit) {
                guard index + 1 < units.count, (0xDC00...0xDFFF).contains(units[index + 1]) else { throw .invalidUTF16 }
                index += 2
            } else if (0xDC00...0xDFFF).contains(unit) {
                throw .invalidUTF16
            } else {
                index += 1
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    private static func detectLineEnding(_ text: String) -> LineEnding {
        detectLineEnding(inUTF8: Data(text.utf8))
    }

    public static func detectLineEnding(inUTF8 utf8: Data) -> LineEnding {
        utf8.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var kinds: UInt8 = 0
            var index = 0
            while index < bytes.count {
                if bytes[index] == 13 {
                    if index + 1 < bytes.count, bytes[index + 1] == 10 {
                        kinds |= 2
                        index += 1
                    } else { kinds |= 4 }
                } else if bytes[index] == 10 { kinds |= 1 }
                if kinds.nonzeroBitCount > 1 { return .mixed }
                index += 1
            }
            switch kinds {
            case 1: return .lf
            case 2: return .crlf
            case 4: return .cr
            default: return .none
            }
        }
    }
}
