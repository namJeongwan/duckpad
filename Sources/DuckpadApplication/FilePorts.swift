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

public protocol TextFileStore: Sendable {
    func canonicalURL(for url: URL) async throws(TextFileStoreError) -> URL
    func read(from url: URL) async throws(TextFileStoreError) -> FileReadResult
    func currentIdentity(for url: URL) async throws(TextFileStoreError) -> FileIdentity?
    func writeAtomically(
        _ data: Data,
        to url: URL,
        expectedIdentity: FileIdentity?,
        overwrite: Bool
    ) async throws(TextFileStoreError) -> FileWriteReceipt
}

public extension TextFileStore {
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

    public init(text: String, encoding: TextFileEncoding, byteOrderMark: ByteOrderMark, lineEnding: LineEnding) {
        self.text = text
        self.encoding = encoding
        self.byteOrderMark = byteOrderMark
        self.lineEnding = lineEnding
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

    public static func convert(_ text: String, to lineEnding: LineEnding) -> String {
        guard lineEnding != .mixed, lineEnding != .none else { return text }
        let separator: String
        switch lineEnding {
        case .lf: separator = "\n"
        case .crlf: separator = "\r\n"
        case .cr: separator = "\r"
        case .mixed, .none: return text
        }
        let scalars = text.unicodeScalars
        var result = ""
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar.value == 13 {
                let next = scalars.index(after: index)
                index = next < scalars.endIndex && scalars[next].value == 10 ? scalars.index(after: next) : next
                result += separator
            } else if scalar.value == 10 {
                index = scalars.index(after: index)
                result += separator
            } else {
                result.unicodeScalars.append(scalar)
                index = scalars.index(after: index)
            }
        }
        return result
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
        var lf = 0
        var crlf = 0
        var cr = 0
        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex {
            if scalars[index].value == 13 {
                let next = scalars.index(after: index)
                if next < scalars.endIndex, scalars[next].value == 10 {
                    crlf += 1
                    index = scalars.index(after: next)
                } else {
                    cr += 1
                    index = next
                }
            } else if scalars[index].value == 10 {
                lf += 1
                index = scalars.index(after: index)
            } else {
                index = scalars.index(after: index)
            }
        }
        let kinds = [lf, crlf, cr].filter { $0 > 0 }.count
        if kinds == 0 { return .none }
        if kinds > 1 { return .mixed }
        if crlf > 0 { return .crlf }
        if cr > 0 { return .cr }
        return .lf
    }
}
