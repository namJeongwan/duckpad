import Foundation

/// Bounded lexical checks for automatic popup triggers, before local or server work.
/// Declaration names introduce a symbol; expressions inside a header still refer
/// to existing symbols and remain eligible for completion.
enum DocumentCompletionContext {
    static func allowsAutomatic(in capture: DocumentIntelligenceCapture, prefix: DocumentCompletionPrefix) -> Bool {
        guard !prefix.text.isEmpty || prefix.isMemberAccess else { return false }
        return declarationNameKeyword(in: capture, prefix: prefix) == nil || isFunctionName(in: capture, prefix: prefix)
    }

    /// Servers can suggest inherited overrides or special methods in this slot.
    /// Current-document words and language keywords cannot make that distinction.
    static func isFunctionName(in capture: DocumentIntelligenceCapture, prefix: DocumentCompletionPrefix) -> Bool {
        declarationNameKeyword(in: capture, prefix: prefix).map { ["def", "fn", "function"].contains($0) } ?? false
    }

    private static func declarationNameKeyword(in capture: DocumentIntelligenceCapture, prefix: DocumentCompletionPrefix) -> String? {
        let keywords: Set<String>
        switch capture.languageID.rawValue {
        case "python": keywords = ["class", "def"]
        case "ruby": keywords = ["class", "module", "def"]
        case "rust": keywords = ["struct", "enum", "trait", "type", "fn", "mod", "union"]
        case "cpp", "c": keywords = ["class", "struct", "enum", "union", "namespace"]
        case "javascript", "typescript": keywords = ["class", "function", "interface", "type"]
        default: return nil
        }
        let bytes = capture.utf8, end = prefix.insertRange.location
        var start = end
        while start > 0, end - start < 2_048, bytes[start - 1] != 10, bytes[start - 1] != 13 { start -= 1 }
        guard start == 0 || bytes[start - 1] == 10 || bytes[start - 1] == 13 else { return nil }
        var header = String(decoding: bytes[start..<end], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        if capture.languageID.rawValue == "python", header.hasPrefix("async ") || header.hasPrefix("async\t") {
            header = String(header.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }
        if capture.languageID.rawValue == "rust" {
            if header.hasPrefix("pub("), let end = header.firstIndex(of: ")") {
                header = String(header[header.index(after: end)...]).trimmingCharacters(in: .whitespaces)
            }
            while let modifier = header.split(whereSeparator: { $0.isWhitespace }).first,
                  ["pub", "async", "unsafe", "const"].contains(String(modifier)), header.count > modifier.count {
                header = String(header.dropFirst(modifier.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        let keyword = String(header.unicodeScalars.prefix(while: word))
        guard keywords.contains(keyword) else { return nil }
        let remainder = header.dropFirst(keyword.count)
        guard remainder.isEmpty || remainder.first?.isWhitespace == true else { return nil }
        let path = remainder.trimmingCharacters(in: .whitespaces)
        if path.isEmpty { return keyword }
        // Ruby methods and C++/Ruby namespace-qualified declarations can contain
        // an existing receiver. A '(', '<', '=' or single ':' ends the name slot.
        let qualified = capture.languageID.rawValue == "ruby" || capture.languageID.rawValue == "cpp"
        return qualified && path.replacingOccurrences(of: "::", with: ".").unicodeScalars.allSatisfy { word($0) || $0 == "." } ? keyword : nil
    }
    private static func word(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || CharacterSet.alphanumerics.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar)
    }
}
