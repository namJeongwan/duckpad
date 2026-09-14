import Foundation

/// Bounded forward-only diff. Small edits let Scintilla move selections and
/// bookmarks with the text, without an unbounded shortest-edit search.
enum FormattingEdits {
    static func between(_ old: String, _ new: String) -> [SearchReplacementEdit] {
        // Editor ranges and replacements are already UTF-8. Avoid scalar arrays,
        // offset tables, and per-replacement String conversions. Each cursor
        // stays on a scalar boundary, including lookahead and replacement ends.
        var old = old, new = new
        return old.withUTF8 { a in
            new.withUTF8 { b in diff(a, b) }
        }
    }

    @inline(__always)
    private static func width(_ byte: UInt8) -> Int {
        byte < 0x80 ? 1 : byte < 0xE0 ? 2 : byte < 0xF0 ? 3 : 4
    }

    @inline(__always)
    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9 || byte == 10 || byte == 13
    }

    @inline(__always)
    private static func sameScalar(_ a: UnsafeBufferPointer<UInt8>, _ x: Int,
                                   _ b: UnsafeBufferPointer<UInt8>, _ y: Int) -> Bool {
        guard a[x] == b[y] else { return false }
        for offset in 1..<width(a[x]) where a[x + offset] != b[y + offset] { return false }
        return true
    }

    @inline(__always)
    private static func matches(_ a: UnsafeBufferPointer<UInt8>, _ startA: Int,
                                _ b: UnsafeBufferPointer<UInt8>, _ startB: Int) -> Bool {
        guard startA < a.count, startB < b.count else { return false }
        var x = startA, y = startB
        for _ in 0..<3 {
            guard x < a.count, y < b.count else { return true }
            guard sameScalar(a, x, b, y) else { return false }
            let count = width(a[x])
            x += count; y += count
        }
        return true
    }

    private static func replacement(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) -> Data {
        guard start < end else { return Data() }
        // Copy directly from the contiguous storage rather than feeding the
        // generic Sequence initializer one byte at a time.
        return Data(bytes: bytes.baseAddress!.advanced(by: start), count: end - start)
    }

    private static func diff(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>) -> [SearchReplacementEdit] {
        var i = 0, j = 0
        var start: (Int, Int)?
        var edits: [SearchReplacementEdit] = []
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, sameScalar(a, i, b, j) {
                if let (x, y) = start {
                    edits.append(.init(range: .init(location: x, length: i - x), replacementUTF8: replacement(b, from: y, to: j)))
                    start = nil
                }
                let count = width(a[i])
                i += count; j += count; continue
            }
            if start == nil { start = (i, j) }
            if edits.count >= 10_000 || i == a.count || j == b.count {
                i = a.count; j = b.count; break
            }
            // Formatting often changes every gap around short tokens. Requiring
            // three unchanged scalars there loses alignment (e.g. [1,2] versus
            // [ 1, 2 ]) and repeatedly scans unrelated text. Consume changed
            // whitespace runs before searching for the next token. Scan each run
            // only once, even if the following tokens also differ.
            var gapI = i, gapJ = j
            while gapI < a.count, isWhitespace(a[gapI]) { gapI += 1 }
            while gapJ < b.count, isWhitespace(b[gapJ]) { gapJ += 1 }
            if gapI != i || gapJ != j {
                i = gapI; j = gapJ; continue
            }
            var aligned = false
            var nextI = i, nextJ = j
            for _ in 1...64 {
                if nextI < a.count { nextI += width(a[nextI]) }
                if nextJ < b.count { nextJ += width(b[nextJ]) }
                if matches(a, i, b, nextJ) { j = nextJ; aligned = true; break }
                if matches(a, nextI, b, j) { i = nextI; aligned = true; break }
                if nextI == a.count, nextJ == b.count { break }
            }
            if !aligned { i += width(a[i]); j += width(b[j]) }
        }
        if let (x, y) = start {
            edits.append(.init(range: .init(location: x, length: i - x), replacementUTF8: replacement(b, from: y, to: j)))
        }
        return edits.reversed()
    }
}
