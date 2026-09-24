import Foundation

/// Deliberately small grammar: $1, ${1:default}, $0 and escaped $, } or \.
/// Repeated numbered fields are selected together by the editor.
public struct SnippetExpansion: Equatable, Sendable {
    public struct Field: Equatable, Sendable {
        public let number: Int
        public var range: NSRange
    }
    public let text: String
    public let fields: [Field]
    public let isWithinLimits: Bool

    public init(_ template: String, indentation: String = "", lineEnding: String = "\n") {
        guard template.utf8.count <= 65_536, indentation.utf8.count <= 4096, lineEnding.utf8.count <= 2 else {
            text = ""; fields = []; isWithinLimits = false; return
        }
        let source = Array(template.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var output = "", fields: [Field] = [], defaults: [Int: String] = [:]
        var index = 0
        // Collect defaults first so a mirror before its declaration is usable.
        while index < source.count {
            if source[index] == "\\", index + 1 < source.count { index += 2; continue }
            if let token = Self.token(source, at: index) {
                if let value = token.value, defaults[token.number] == nil { defaults[token.number] = value }
                index = token.end
            } else { index += 1 }
        }
        func expanded(_ value: String) -> String? {
            let newlines = value.utf8.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
            guard value.utf8.count + newlines * (lineEnding.utf8.count + indentation.utf8.count) <= 1_048_576 else { return nil }
            return value.replacingOccurrences(of: "\n", with: lineEnding + indentation)
        }
        var valid = true
        index = 0
        var offset = 0
        while index < source.count {
            guard offset <= 1_048_576, fields.count < 256 else { valid = false; break }
            if source[index] == "\\", index + 1 < source.count, ["$", "}", "\\"].contains(source[index + 1]) {
                let value = String(source[index + 1]); output += value; offset += value.utf8.count; index += 2
            } else if let token = Self.token(source, at: index) {
                guard let value = expanded(defaults[token.number] ?? ""), offset + value.utf8.count <= 1_048_576 else { valid = false; break }
                fields.append(Field(number: token.number, range: NSRange(location: offset, length: value.utf8.count)))
                output += value; offset += value.utf8.count; index = token.end
            } else {
                guard let value = expanded(String(source[index])), offset + value.utf8.count <= 1_048_576 else { valid = false; break }
                output += value; offset += value.utf8.count; index += 1
            }
        }
        if !fields.contains(where: { $0.number == 0 }) { fields.append(.init(number: 0, range: NSRange(location: offset, length: 0))) }
        text = valid ? output : ""; self.fields = valid ? fields : []; isWithinLimits = valid
    }

    private static func token(_ source: [Character], at start: Int) -> (number: Int, value: String?, end: Int)? {
        guard source[start] == "$", start + 1 < source.count else { return nil }
        var i = start + 1
        let braced = source[i] == "{"
        if braced { i += 1 }
        let digitStart = i
        while i < source.count, source[i].isASCII, source[i].isNumber { i += 1 }
        guard i > digitStart, let number = Int(String(source[digitStart..<i])), number <= 999 else { return nil }
        if !braced { return (number, nil, i) }
        guard i < source.count else { return nil }
        if source[i] == "}" { return (number, nil, i + 1) }
        guard source[i] == ":" else { return nil }
        i += 1
        var value = ""
        while i < source.count {
            if source[i] == "}" { return (number, value, i + 1) }
            if source[i] == "{" { return nil } // Nested expressions are literal, not partially interpreted.
            if source[i] == "\\", i + 1 < source.count, ["}", "$", "\\"].contains(source[i + 1]) { i += 1 }
            value.append(source[i]); i += 1
        }
        return nil
    }
}
