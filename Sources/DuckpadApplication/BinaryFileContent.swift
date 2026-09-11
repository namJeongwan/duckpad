import DuckpadDomain
import Foundation

/// Binary detection and the read-only fallback for editors without native byte storage.
public enum BinaryFileContent {
    public static let analysisByteCount = 64 * 1_024

    public static func isBinary(_ data: Data, assuming encoding: TextFileEncoding? = nil) -> Bool {
        if encoding == .utf16LittleEndian || encoding == .utf16BigEndian
            || data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return false
        }
        let sample = data.prefix(analysisByteCount)
        if sample.contains(0) { return true }
        let controls = sample.filter { $0 < 0x20 && ![9, 10, 12, 13].contains($0) }.count
        if controls > sample.count / 10 { return true }
        if String(data: sample, encoding: .utf8) != nil { return false }
        // A sample can end in the middle of a valid UTF-8 scalar.
        if data.count > sample.count {
            for tail in 1...3 where String(data: sample.dropLast(tail), encoding: .utf8) != nil {
                return false
            }
        }
        return true
    }

    public static func decode(_ data: Data, decodingText: Bool = true) -> DecodedTextFile {
        let bytes = data
        let hasBOM = bytes.starts(with: [0xEF, 0xBB, 0xBF])
        return DecodedTextFile(
            text: decodingText ? String(decoding: hasBOM ? bytes.dropFirst(3) : bytes, as: UTF8.self) : "",
            encoding: .utf8,
            byteOrderMark: hasBOM ? .present : .absent,
            lineEnding: .none,
            binaryByteCount: bytes.count
        )
    }
}
