import DuckpadDomain
import Foundation

struct EditorConfigDocument {
    struct Section { let pattern: String; var values: [(String, String)] = [] }
    var isRoot = false
    var sections: [Section] = []

    init(_ text: String) {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                sections.append(Section(pattern: String(line.dropFirst().dropLast())))
            } else if let separator = line.firstIndex(of: "=") {
                let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces).lowercased()
                if sections.isEmpty { if key == "root" { isRoot = value == "true" } }
                else { sections[sections.count - 1].values.append((key, value)) }
            }
        }
    }

    private static func isSupported(_ key: String, _ value: String) -> Bool {
        switch key {
        case "indent_style": return ["tab", "space"].contains(value)
        case "indent_size": return value == "tab" || Int(value).map { (1...16).contains($0) } == true
        case "tab_width": return Int(value).map { (1...16).contains($0) } == true
        case "end_of_line": return ["lf", "crlf", "cr"].contains(value)
        case "charset": return ["utf-8", "utf-8-bom", "utf-16le", "utf-16be"].contains(value)
        case "trim_trailing_whitespace", "insert_final_newline": return ["true", "false"].contains(value)
        default: return false
        }
    }

    func apply(to properties: inout [String: String], relativePath: String) {
        for section in sections where EditorConfigGlob.matches(section.pattern, path: relativePath) {
            for (key, value) in section.values {
                if value == "unset" { properties.removeValue(forKey: key) }
                else if Self.isSupported(key, value) { properties[key] = value }
            }
        }
    }
}
