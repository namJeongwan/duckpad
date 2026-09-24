import Foundation

/// Explicit file rules. Missing values leave the editor's defaults intact.
public struct EditorConventions: Equatable, Sendable {
    public var properties: [String: String]
    public init(properties: [String: String] = [:]) { self.properties = properties }

    public var trimTrailingWhitespace: Bool? { boolean("trim_trailing_whitespace") }
    public var insertFinalNewline: Bool? { boolean("insert_final_newline") }
    public var lineEnding: LineEnding? {
        properties["end_of_line"].flatMap(LineEnding.init(rawValue:)).flatMap {
            [.lf, .crlf, .cr].contains($0) ? $0 : nil
        }
    }
    public var charset: (TextFileEncoding, ByteOrderMark)? {
        switch properties["charset"] {
        case "utf-8": (.utf8, .absent)
        case "utf-8-bom": (.utf8, .present)
        case "utf-16le": (.utf16LittleEndian, .present)
        case "utf-16be": (.utf16BigEndian, .present)
        default: nil // Latin-1 is not an encoding supported by Duckpad.
        }
    }
    public func indentation(defaults: LanguageIndentation) -> (indent: LanguageIndentation, tabWidth: Int) {
        let tabs = properties["indent_style"].flatMap { $0 == "tab" ? true : ($0 == "space" ? false : nil) } ?? defaults.useTabs
        let size = positiveWidth("indent_size")
        let tab = positiveWidth("tab_width") ?? size ?? defaults.width
        let width = properties["indent_size"] == "tab" ? tab : (size ?? defaults.width)
        return (.init(width: width, useTabs: tabs), tab)
    }
    private func positiveWidth(_ name: String) -> Int? {
        properties[name].flatMap(Int.init).flatMap { (1...16).contains($0) ? $0 : nil }
    }
    private func boolean(_ name: String) -> Bool? {
        properties[name].flatMap { $0 == "true" ? true : ($0 == "false" ? false : nil) }
    }
}
