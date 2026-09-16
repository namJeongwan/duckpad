import Foundation
import DuckpadDomain
import DuckpadArchiveBridge

/// ZIP entries are decoded into bounded values, never extracted onto disk.
/// Packages may be flat or wrapped in one .duckpad-plugin directory.
public enum ExtensionPackageArchive {
    public static let maximumBytes = 32 * 1_024 * 1_024
    public static func decode(_ data: Data) throws -> [String: Data] {
        let bytes = [UInt8](data)
        func fail() -> ExtensionFailure { .invalidPackagePath }
        func number(_ offset: Int, _ size: Int) throws -> Int {
            guard offset >= 0, offset <= bytes.count - size else { throw fail() }
            return (0..<size).reduce(0) { $0 | (Int(bytes[offset + $1]) << ($1 * 8)) }
        }
        guard bytes.count >= 22, bytes.count <= maximumBytes else { throw fail() }
        let lower = max(0, bytes.count - 65_557)
        guard let end = try stride(from: bytes.count - 22, through: lower, by: -1).first(where: {
            try number($0, 4) == 0x06054b50 && $0 + 22 + number($0 + 20, 2) == bytes.count
        }) else { throw fail() }
        let count = try number(end + 10, 2), directorySize = try number(end + 12, 4), directory = try number(end + 16, 4)
        guard try number(end + 4, 2) == 0, try number(end + 6, 2) == 0, try number(end + 8, 2) == count,
              count > 0, count <= 65, directory + directorySize == end else { throw fail() }
        var offset = directory, total = 0
        var files: [String: Data] = [:]
        var wrapper: String?, usesFlat = false
        var occupied: [Range<Int>] = []
        for _ in 0..<count {
            guard try number(offset, 4) == 0x02014b50 else { throw fail() }
            let flags = try number(offset + 8, 2), method = try number(offset + 10, 2)
            let checksum = try number(offset + 16, 4), compressed = try number(offset + 20, 4), size = try number(offset + 24, 4)
            let nameLength = try number(offset + 28, 2), extra = try number(offset + 30, 2), comment = try number(offset + 32, 2)
            let attributes = try number(offset + 38, 4), local = try number(offset + 42, 4)
            guard flags & ~0x080e == 0, [0, 8].contains(method), size <= 16 * 1_024 * 1_024,
                  nameLength > 0, nameLength <= 512, offset + 46 + nameLength + extra + comment <= end,
                  try number(offset + 34, 2) == 0 else { throw fail() }
            let nameBytes = Array(bytes[(offset + 46)..<(offset + 46 + nameLength)])
            guard let name = String(bytes: nameBytes, encoding: .utf8), !name.contains("\\"), !name.contains("\0"), !name.hasPrefix("/") else { throw fail() }
            let components = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let isDirectory = name.hasSuffix("/")
            let parts = isDirectory ? Array(components.dropLast()) : components
            guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), parts.count <= 2 else { throw fail() }
            let fileType = (attributes >> 16) & 0xf000
            guard fileType == 0 || fileType == (isDirectory ? 0x4000 : 0x8000) else { throw fail() }
            if parts.count == 2 || isDirectory {
                guard parts[0].hasSuffix(".duckpad-plugin"), !usesFlat, wrapper == nil || wrapper == parts[0] else { throw fail() }
                wrapper = parts[0]
            } else { guard wrapper == nil else { throw fail() }; usesFlat = true }
            guard try number(local, 4) == 0x04034b50, try number(local + 6, 2) == flags, try number(local + 8, 2) == method,
                  try number(local + 26, 2) == nameLength else { throw fail() }
            let localExtra = try number(local + 28, 2)
            let start = local + 30 + nameLength + localExtra
            guard start <= directory, compressed <= directory - start,
                  Array(bytes[(local + 30)..<(local + 30 + nameLength)]) == nameBytes else { throw fail() }
            let range = local..<(start + compressed)
            guard occupied.allSatisfy({ !$0.overlaps(range) }) else { throw fail() }
            occupied.append(range)
            offset += 46 + nameLength + extra + comment
            if isDirectory { guard size == 0, parts.count == 1 else { throw fail() }; continue }
            total += size
            guard total <= maximumBytes, files.count < 64, let filename = parts.last, files[filename] == nil else { throw fail() }
            let input = Array(bytes[start..<(start + compressed)])
            var output: [UInt8]
            if method == 0 { guard compressed == size else { throw fail() }; output = input }
            else {
                // One spare byte permits validating an empty deflate stream.
                output = [UInt8](repeating: 0, count: max(1, size))
                let valid = input.withUnsafeBufferPointer { input in output.withUnsafeMutableBufferPointer { output in
                    duckpad_inflate(input.baseAddress, input.count, output.baseAddress, size)
                } }
                guard valid != 0 else { throw fail() }
                if size == 0 { output = [] }
            }
            let crc = output.withUnsafeBufferPointer { duckpad_crc32($0.baseAddress, $0.count) }
            guard Int(crc) == checksum else { throw ExtensionFailure.signatureMismatch }
            files[filename] = Data(output)
        }
        guard offset == end, files["plugin.json"] != nil else { throw fail() }
        return files
    }
}
