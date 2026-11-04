import Foundation
import DuckpadDomain
import LanguageServerProtocol
import DuckpadApplication

/// LSP defaults to UTF-16; Scintilla offsets are UTF-8 bytes.
struct LSPTextCoordinates {
    let bytes: Data
    private let starts: [Int]
    init(_ bytes: Data) {
        self.bytes = bytes
        var starts = [0], i = 0
        while i < bytes.count {
            if bytes[i] == 13 {
                i += 1
                if i < bytes.count && bytes[i] == 10 { i += 1 }
                starts.append(i)
            } else if bytes[i] == 10 { i += 1; starts.append(i) }
            else { i += 1 }
        }
        self.starts = starts
    }
    func position(_ offset: Int) -> Position? {
        guard offset >= 0, offset <= bytes.count,
              offset == bytes.count || bytes[offset] & 0xC0 != 0x80 else { return nil }
        let line = starts.lastIndex(where: { $0 <= offset }) ?? 0
        guard let prefix = String(data: bytes[starts[line]..<offset], encoding: .utf8),
              !prefix.contains("\r"), !prefix.contains("\n") else { return nil }
        return Position(line: line, character: prefix.utf16.count)
    }
    func offset(_ position: Position) -> Int? {
        guard starts.indices.contains(position.line), position.character >= 0 else { return nil }
        let start = starts[position.line]
        var end = position.line + 1 < starts.count ? starts[position.line + 1] : bytes.count
        while end > start && (bytes[end - 1] == 10 || bytes[end - 1] == 13) { end -= 1 }
        guard let text = String(data: bytes[start..<end], encoding: .utf8), position.character <= text.utf16.count,
              let index = text.utf16.index(text.utf16.startIndex, offsetBy: position.character).samePosition(in: text.utf8) else { return nil }
        return start + text.utf8.distance(from: text.utf8.startIndex, to: index)
    }
    func range(_ range: LSPRange) -> SearchUTF8Range? {
        guard let lower = offset(range.start), let upper = offset(range.end), lower <= upper else { return nil }
        return .init(location: lower, length: upper - lower)
    }
}
