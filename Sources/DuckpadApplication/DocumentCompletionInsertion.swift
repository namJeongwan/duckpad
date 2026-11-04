import Foundation
import DuckpadDomain

extension DocumentCompletionSuggestion {
    /// Expand relative server method stubs without changing their edit ranges or
    /// additional imports. The editor applies the resulting text as one Undo batch.
    public func insertionText(in capture: DocumentIntelligenceCapture, replacing range: SearchUTF8Range) -> String? {
        guard adjustIndentation, insertText.contains("\n") || insertText.contains("\r") else { return insertText }
        let bytes = capture.utf8
        guard insertText.utf8.count <= 65_536, range.location >= 0, range.location <= bytes.count else { return nil }
        var start = range.location
        while start > 0, range.location - start < 2_048, bytes[start - 1] != 10, bytes[start - 1] != 13 { start -= 1 }
        guard start == 0 || bytes[start - 1] == 10 || bytes[start - 1] == 13 else { return nil }
        var end = start
        while end < range.location, bytes[end] == 32 || bytes[end] == 9 { end += 1 }
        let indentation = String(decoding: bytes[start..<end], as: UTF8.self)
        let newline: String
        let first = start > 0 ? start - 1 : bytes.prefix(4_096).firstIndex(where: { $0 == 10 || $0 == 13 })
        if let first, bytes[first] == 13 {
            newline = first + 1 < bytes.count && bytes[first + 1] == 10 ? "\r\n" : "\r"
        } else if let first, first > 0, bytes[first - 1] == 13 { newline = "\r\n" }
        else { newline = "\n" }
        let normalized = insertText.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        let size = normalized.utf8.count + (lines.count - 1) * (indentation.utf8.count + newline.utf8.count - 1)
        guard size <= 65_536 else { return nil }
        return lines[0] + lines.dropFirst().map { newline + indentation + $0 }.joined()
    }
}
