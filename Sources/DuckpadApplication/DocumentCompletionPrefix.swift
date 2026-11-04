import Foundation
import DuckpadDomain

public struct DocumentCompletionPrefix: Sendable {
    public let text: String
    public let insertRange: SearchUTF8Range
    public let replaceRange: SearchUTF8Range
    public let isMemberAccess: Bool
    public init?(_ capture: DocumentIntelligenceCapture) {
        let bytes = capture.utf8, caret = capture.caretUTF8
        guard caret >= 0, caret <= bytes.count, caret == bytes.count || bytes[caret] & 0xC0 != 0x80 else { return nil }
        var lower = max(0, caret - 256), upper = min(bytes.count, caret + 256)
        while lower < caret && bytes[lower] & 0xC0 == 0x80 { lower += 1 }
        while upper > caret && upper < bytes.count && bytes[upper] & 0xC0 == 0x80 { upper -= 1 }
        let before = String(decoding: bytes[lower..<caret], as: UTF8.self)
        let scalars = before.unicodeScalars.reversed().prefix(while: Self.word)
        let text = String(String.UnicodeScalarView(scalars.reversed()))
        let after = String(decoding: bytes[caret..<upper], as: UTF8.self).unicodeScalars.prefix(while: Self.word)
        let suffixBytes = String(String.UnicodeScalarView(after)).utf8.count
        self.text = text
        insertRange = .init(location: caret - text.utf8.count, length: text.utf8.count)
        replaceRange = .init(location: insertRange.location, length: text.utf8.count + suffixBytes)
        let head = String(String.UnicodeScalarView(before.unicodeScalars.dropLast(text.unicodeScalars.count)))
        if head.hasSuffix("::"), ["rust", "ruby", "cpp", "php", "csharp"].contains(capture.languageID.rawValue) {
            isMemberAccess = true
        } else if head.hasSuffix(".") {
            let receiver = head.dropLast().trimmingCharacters(in: .whitespaces)
            let word = receiver.unicodeScalars.reversed().prefix(while: Self.word)
            isMemberAccess = receiver.last.map { ")]}".contains($0) } == true
                || (!word.isEmpty && word.contains { !CharacterSet.decimalDigits.contains($0) })
        } else { isMemberAccess = false }
    }
    private static func word(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || CharacterSet.alphanumerics.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar)
    }
}
