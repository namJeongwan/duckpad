import DuckpadDomain
import Foundation

public enum SaveCleanupEdits {
    public static func make(utf8: Data, trim: Bool, finalNewline: Bool?, lineEnding: LineEnding) throws -> [SearchReplacementEdit] {
        guard !utf8.isEmpty else { return [] }
        return try utf8.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var edits: [SearchReplacementEdit] = []
            var i = 0, whitespaceStart: Int?
            while i < bytes.count {
                if i % 65_536 == 0 { try Task.checkCancellation() }
                let byte = bytes[i]
                if byte == 32 || byte == 9 { if whitespaceStart == nil { whitespaceStart = i } }
                else {
                    if trim, (byte == 10 || byte == 13), let start = whitespaceStart {
                        edits.append(.init(range: .init(location: start, length: i - start), replacementUTF8: Data()))
                    }
                    whitespaceStart = nil
                }
                i += 1
            }
            let contentEnd = trim ? whitespaceStart ?? bytes.count : bytes.count
            var endingStart = contentEnd
            if finalNewline == false {
                while endingStart > 0 {
                    let byte = bytes[endingStart - 1]
                    if byte == 10 || byte == 13 || (trim && (byte == 32 || byte == 9)) { endingStart -= 1 }
                    else { break }
                }
            }
            let suffixStart = finalNewline == false ? endingStart : contentEnd
            // Suffix edits subsume trailing whitespace ranges in empty last lines.
            edits.removeAll { $0.range.location >= suffixStart }
            let ending: [UInt8] = lineEnding == .crlf ? [13, 10] : (lineEnding == .cr ? [13] : [10])
            let append = finalNewline == true && suffixStart > 0 && bytes[suffixStart - 1] != 10 && bytes[suffixStart - 1] != 13
            if suffixStart < bytes.count || append {
                edits.append(.init(range: .init(location: suffixStart, length: bytes.count - suffixStart),
                                   replacementUTF8: Data(append ? ending : [])))
            }
            return edits.reversed()
        }
    }
}
