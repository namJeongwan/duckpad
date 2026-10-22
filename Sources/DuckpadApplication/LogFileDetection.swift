import Foundation

/// Conservative shared log detection; no dependency on the originating logger.
/// Only the first 16 KiB, 64 lines and 512 bytes per line are inspected.
public enum LogFileDetection {
    public static let maximumProbeBytes = 16 * 1_024
    private static let levels: Set<String> = ["TRACE", "VERBOSE", "DEBUG", "DBG", "INFO", "INFORMATION", "NOTICE", "WARN", "WARNING", "WRN", "ERROR", "ERR", "FAIL", "FAILURE", "SEVERE", "FATAL", "CRITICAL", "CRIT", "PANIC", "FTL"]

    public static func isRotatedLogFilename(_ filename: String) -> Bool {
        let name = URL(fileURLWithPath: filename).lastPathComponent.lowercased()
        guard let range = name.range(of: ".log.", options: .backwards) else { return false }
        let suffix = name[range.upperBound...]
        return !suffix.isEmpty && suffix.utf8.allSatisfy { (48...57).contains($0) || $0 == 45 || $0 == 46 }
    }

    public static func matches(_ prefix: Data) -> Bool {
        let bytes = Array(prefix.prefix(maximumProbeBytes))
        var cursor = 0, lines = 0, logLines = 0
        while cursor < bytes.count, lines < 64 {
            let start = cursor
            while cursor < bytes.count, bytes[cursor] != 10, bytes[cursor] != 13 { cursor += 1 }
            let sample = Array(bytes[start..<min(cursor, start + 512)])
            cursor += 1; lines += 1
            if hasSGR(sample) { return true }
            let text = String(decoding: sample, as: UTF8.self)
            // Only severity fields count in structured JSON; message text alone
            // should not turn an ordinary document into a log.
            let lower = text.lowercased()
            let structured = ["\"level\"", "\"severity\"", "\"levelname\""].contains { lower.contains($0 + ":") || lower.contains($0 + " :") }
            let tokens = text.split { !$0.isASCII || !($0.isLetter || $0.isNumber || $0 == "_") }
            let hasLevel = tokens.contains { levels.contains($0.uppercased()) }
            if hasLevel {
                logLines += 1
                let timestamp = sample.prefix(40).filter { $0 == 58 || $0 == 45 || $0 == 47 }.count >= 2
                    && sample.prefix(10).contains { (48...57).contains($0) }
                let pythonLevel = tokens.first.map { levels.contains($0.uppercased()) } == true && text.contains(":")
                if timestamp || structured || pythonLevel || logLines >= 2 { return true }
            }
        }
        return false
    }
    private static func hasSGR(_ bytes: [UInt8]) -> Bool {
        for index in bytes.indices where bytes[index] == 27 && index + 2 < bytes.count && bytes[index + 1] == 91 {
            var count = 0, value = 0, valid = true
            for cursor in (index + 2)..<min(bytes.count, index + 128) {
                let c = bytes[cursor]
                if (48...57).contains(c) { value = value * 10 + Int(c - 48); if value > 999 { valid = false; break } }
                else if c == 59 { count += 1; value = 0; if count >= 32 { valid = false; break } }
                else if c == 109 { return valid }
                else { break }
            }
        }
        return false
    }
}
