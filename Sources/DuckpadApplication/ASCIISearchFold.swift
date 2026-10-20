import Foundation

/// ASCII case folding keeps byte offsets intact. Non-ASCII input must use ICU's
/// Unicode folding (including expansions such as ß and special letters ſ / K).
enum ASCIISearchFold {
    static func folded(_ data: Data) -> Data? {
        let ascii = data.withUnsafeBytes { bytes in
            var offset = 0
            while offset + 8 <= bytes.count {
                if offset & 0xFFFF == 0, Task.isCancelled { return false }
                if bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self) & 0x8080808080808080 != 0 { return false }
                offset += 8
            }
            while offset < bytes.count {
                if bytes[offset] >= 0x80 { return false }
                offset += 1
            }
            return true
        }
        guard ascii, !Task.isCancelled else { return nil }
        // The standard library's ASCII String path is already optimized; a Swift
        // per-byte mutation loop is substantially slower in debug builds.
        let folded = Data(String(decoding: data, as: UTF8.self).lowercased().utf8)
        return Task.isCancelled ? nil : folded
    }
}
