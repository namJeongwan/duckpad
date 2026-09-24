import Foundation

enum EditorConfigGlob {
    static func matches(_ pattern: String, path: String) -> Bool {
        guard pattern.utf8.count <= 4096, !pattern.hasSuffix("/") else { return false }
        var budget = 256
        guard let expanded = expand(pattern, budget: &budget) else { return false }
        return expanded.contains { glob in
            var inClass = false
            var qualified = false
            for char in glob {
                if char == "[" { inClass = true }
                if char == "]" { inClass = false }
                if char == "/", !inClass { qualified = true }
            }
            let candidate = qualified ? path : URL(fileURLWithPath: path).lastPathComponent
            let body = regex(Array(glob.hasPrefix("/") ? glob.dropFirst() : glob[...]))
            guard let regex = try? NSRegularExpression(pattern: "\\A" + body + "\\z") else { return false }
            var matched = false
            let deadline = Date.timeIntervalSinceReferenceDate + 0.02
            regex.enumerateMatches(in: candidate, options: [.reportProgress], range: NSRange(candidate.startIndex..., in: candidate)) { match, _, stop in
                if match != nil { matched = true; stop.pointee = true }
                if Date.timeIntervalSinceReferenceDate > deadline { stop.pointee = true }
            }
            return matched
        }
    }

    private static func expand(_ text: String, budget: inout Int) -> [String]? {
        guard budget > 0 else { return nil }
        budget -= 1
        var escaped = false, level = 0
        var classEnd: String.Index?
        var start: String.Index?
        for index in text.indices {
            let c = text[index]
            if let end = classEnd, index <= end { continue }
            if escaped { escaped = false; continue }
            if c == "\\" { escaped = true; continue }
            if c == "[", let end = text[text.index(after: index)...].firstIndex(of: "]") {
                classEnd = end; continue
            }
            if c == "{" { if level == 0 { start = index }; level += 1 }
            if c == "}", level > 0 {
                level -= 1
                guard level == 0, let start else { continue }
                let inside = String(text[text.index(after: start)..<index])
                var parts: [String] = [], part = "", nested = 0
                var innerEscaped = false
                var innerClassEnd: String.Index?
                for position in inside.indices {
                    let char = inside[position]
                    if let end = innerClassEnd, position <= end { part.append(char); continue }
                    if innerEscaped { innerEscaped = false; part.append(char); continue }
                    if char == "\\" { innerEscaped = true; part.append(char); continue }
                    if char == "[", let end = inside[inside.index(after: position)...].firstIndex(of: "]") {
                        innerClassEnd = end; part.append(char); continue
                    }
                    if char == "{" { nested += 1 }; if char == "}" { nested -= 1 }
                    if char == ",", nested == 0 { parts.append(part); part = "" } else { part.append(char) }
                }
                parts.append(part)
                if parts.count == 1 {
                    let range = inside.components(separatedBy: "..")
                    if range.count == 2, let low = Int(range[0]), let high = Int(range[1]), low < high,
                       high.subtractingReportingOverflow(low).overflow == false,
                       high - low < 128 {
                        parts = (low...high).map(String.init)
                    } else { return [text] }
                }
                var result: [String] = []
                for part in parts {
                    guard let values = expand(String(text[..<start]) + part + text[text.index(after: index)...], budget: &budget) else { return nil }
                    result += values
                }
                return result
            }
        }
        return [text]
    }

    private static func regex(_ chars: [Character]) -> String {
        var result = "", i = 0
        while i < chars.count {
            let c = chars[i]; i += 1
            switch c {
            case "\\":
                if i < chars.count { result += NSRegularExpression.escapedPattern(for: String(chars[i])); i += 1 }
                else { result += "\\\\" }
            case "*":
                if i < chars.count, chars[i] == "*" {
                    i += 1
                    if i < chars.count, chars[i] == "/" { i += 1; result += "(?:.*/)?" }
                    else { result += ".*" }
                } else { result += "[^/]*" }
            case "?": result += "[^/]"
            case "[":
                if let close = chars[i...].firstIndex(of: "]"), close > i {
                    let negative = chars[i] == "!"
                    let content = chars[(i + (negative ? 1 : 0))..<close]
                    result += "[" + (negative ? "^/" : "")
                    for char in content { result += "\\x{" + String(char.unicodeScalars.first!.value, radix: 16) + "}" }
                    result += "]"; i = close + 1
                } else { result += "\\[" }
            default: result += NSRegularExpression.escapedPattern(for: String(c))
            }
        }
        return result
    }
}
