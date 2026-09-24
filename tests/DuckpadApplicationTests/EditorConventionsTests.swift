import DuckpadApplication
import DuckpadDomain
import Foundation
import Testing

struct EditorConventionsTests {
    @Test func detectionIsConservativeAndBounded() {
        #expect(IndentationDetector.detect(Data("a\n  b\n    c\n  d\n".utf8)) == .init(width: 2))
        #expect(IndentationDetector.detect(Data("a\n\tb\n\t\tc\n".utf8))?.useTabs == true)
        #expect(IndentationDetector.detect(Data("single\n  aligned".utf8)) == nil)
        #expect(IndentationDetector.detect(Data("a\n    b\nc\n    d\n".utf8)) == .init(width: 4))
        #expect(IndentationDetector.detect(Data((String(repeating: "a", count: 65_536) + "\n  b\n    c\n  d").utf8)) == nil)
    }
    @Test func rulesResolveWidthsAndCharset() {
        let rules = EditorConventions(properties: ["indent_style":"tab", "indent_size":"4", "tab_width":"3", "charset":"utf-8-bom"])
        #expect(rules.indentation(defaults: .init()).indent == .init(width: 4, useTabs: true))
        #expect(rules.indentation(defaults: .init()).tabWidth == 3)
        #expect(rules.charset?.1 == .present)
        #expect(EditorConventions(properties: ["indent_size":"tab", "tab_width":"8"]).indentation(defaults: .init()).indent.width == 8)
        #expect(EditorConventions(properties: ["indent_style":"invalid"]).indentation(defaults: .init(useTabs: true)).indent.useTabs)
    }
    private func cleaned(_ text: String, trim: Bool = true, newline: Bool? = nil, ending: LineEnding = .lf) throws -> String {
        var data = Data(text.utf8)
        let edits = try SaveCleanupEdits.make(utf8: data, trim: trim, finalNewline: newline, lineEnding: ending)
        for edit in edits { data.replaceSubrange(edit.range.location..<(edit.range.location + edit.range.length), with: edit.replacementUTF8) }
        return String(decoding: data, as: UTF8.self)
    }
    @Test func cleanupPreservesUnicodeAndUndoableRanges() throws {
        #expect(try cleaned("한글 🦆  \r\n\t text\t\r\nlast  ", newline: true, ending: .crlf) == "한글 🦆\r\n\t text\r\nlast\r\n")
        #expect(try cleaned("a\n\n", newline: true) == "a\n\n")
        #expect(try cleaned("a  \n  \n\t", newline: false) == "a")
        #expect(try cleaned("", newline: true) == "")
        #expect(try cleaned("\t ", newline: true) == "")
        #expect(try cleaned("a  \n", trim: false) == "a  \n")
    }
    @Test func snippetExpansionAndByteOffsets() {
        let expansion = SnippetExpansion("${1:한글} = $1\n  ${2:value}$0", indentation: "  ", lineEnding: "\r\n")
        #expect(expansion.text == "한글 = 한글\r\n    value")
        #expect(expansion.fields[0].range == NSRange(location: 0, length: 6))
        #expect(expansion.fields[1].range == NSRange(location: 9, length: 6))
        var session = SnippetSession(expansion: expansion, offset: 2)
        #expect(session.ranges.count == 2)
        let applied = session.apply(range: NSRange(location: 2, length: 6), replacementBytes: 3)
        #expect(applied)
        #expect(session.ranges[1].location == 8)
        let moved = session.move(backwards: false)
        #expect(moved)
        #expect(session.ranges[0].location == 20)
        let finished = session.move(backwards: false)
        #expect(finished)
        #expect(session.isFinal)
        #expect(SnippetExpansion("\\$1 ${1:a} \\}").text == "$1 a }")
    }
    @Test func snippetExpansionIsBoundedBeforeAllocation() {
        #expect(!SnippetExpansion(String(repeating: "$1", count: 300)).isWithinLimits)
        #expect(!SnippetExpansion("${1:" + String(repeating: "a", count: 50_000) + "}" + String(repeating: "$1", count: 30)).isWithinLimits)
        #expect(!SnippetExpansion(String(repeating: "\n", count: 1024), indentation: String(repeating: " ", count: 4096)).isWithinLimits)
    }
    @Test func newSettingsRoundTripAndOldDefaults() throws {
        var settings = AppSettings()
        settings.snippets = [.init(name: "hello", body: "${1:world}")]
        settings.trimWhitespaceOnSave = true
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data) == settings)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["snippets", "trimWhitespaceOnSave", "finalNewlineOnSave", "detectIndentation", "editorConfigEnabled"] { json.removeValue(forKey: key) }
        let old = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.snippets.isEmpty && !old.trimWhitespaceOnSave && !old.finalNewlineOnSave)
    }
}
