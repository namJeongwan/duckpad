@testable import DuckpadApplication
import DuckpadDomain
import Foundation
import Testing

struct FormattingEditsTests {
    @Test func whitespaceFormattingPreservesExistingTokens() {
        let old = "[1,2,3,{\"a\":1,\"b\":2}]"
        let new = "[\n  1,\n  2,\n  3,\n  { \"a\": 1, \"b\": 2 }\n]\n"
        var bytes = Data(old.utf8)
        let whitespace: Set<UInt8> = [9, 10, 13, 32]
        for edit in FormattingEdits.between(old, new) {
            #expect(bytes[edit.range.location..<edit.range.upperBound].allSatisfy { whitespace.contains($0) })
            #expect(edit.replacementUTF8.allSatisfy { whitespace.contains($0) })
            bytes.replaceSubrange(edit.range.location..<edit.range.upperBound, with: edit.replacementUTF8)
        }
        #expect(bytes == Data(new.utf8))
    }

    @Test func editLimitFallsBackWithoutSplittingOrChangingUnicodeBytes() {
        let old = String(repeating: "한글 🦆:1;", count: 11_000)
        let new = String(repeating: "한글 🦆: 1;", count: 11_000)
        let edits = FormattingEdits.between(old, new)
        #expect(edits.count <= 10_001)
        var bytes = Data(old.utf8)
        var previousLocation = bytes.count
        for edit in edits {
            #expect(edit.range.upperBound <= previousLocation)
            #expect(String(data: bytes.subdata(in: edit.range.location..<edit.range.upperBound), encoding: .utf8) != nil)
            #expect(String(data: edit.replacementUTF8, encoding: .utf8) != nil)
            bytes.replaceSubrange(edit.range.location..<edit.range.upperBound, with: edit.replacementUTF8)
            previousLocation = edit.range.location
        }
        #expect(bytes == Data(new.utf8))
    }

    @Test func editsReconstructOutputWithoutSplittingUnicode() {
        let samples = ["", "a", "한글 🦆", "é", "e\u{301}", "ê 🦅", "\u{7F}\u{80}\u{7FF}\u{800}\u{FFFF}\u{10000}", "const a={b:1};", "\r\n\t", String(repeating: "x ", count: 100), String(repeating: " ", count: 10_000) + "a", String(repeating: "\t", count: 10_000) + "b"]
        for old in samples {
            for new in samples {
                var bytes = Data(old.utf8)
                for edit in FormattingEdits.between(old, new) {
                    #expect(String(data: bytes.subdata(in: edit.range.location..<edit.range.upperBound), encoding: .utf8) != nil)
                    #expect(String(data: edit.replacementUTF8, encoding: .utf8) != nil)
                    bytes.replaceSubrange(edit.range.location..<edit.range.upperBound, with: edit.replacementUTF8)
                }
                #expect(bytes == Data(new.utf8))
            }
        }
        #expect(FormattingEdits.between("한글", "한글").isEmpty)
    }

    @Test func filenameAndManualLanguageSelectionChooseTheRightParser() {
        #expect(FormattingLanguage.parser(languageID: "text", filename: "new.json", usesLanguageOverride: false) == "json")
        #expect(FormattingLanguage.parser(languageID: "text", filename: "old.json", usesLanguageOverride: true) == nil)
        #expect(FormattingLanguage.parser(languageID: "xml", filename: "old.json", usesLanguageOverride: true) == "xml")
        #expect(FormattingLanguage.parser(languageID: "json", filename: "config.jsonc", usesLanguageOverride: false) == "jsonc")
        #expect(FormattingLanguage.parser(languageID: "rust", filename: "main.rs", usesLanguageOverride: false) == nil)
    }

    @Test func legacySettingsKeepAutomaticFormattingOffAndNewSettingsRoundTrip() throws {
        let legacy = Data(#"{"schemaVersion":1,"appearanceMode":"system","defaultWordWrapEnabled":true,"defaultWrapMarkerVisible":false}"#.utf8)
        #expect(try JSONDecoder().decode(AppSettings.self, from: legacy).formatting.formatOnSave == false)
        var settings = AppSettings()
        settings.formatting.formatOnSave = true
        settings.formatting.tabWidth = 4
        settings.formatting.sqlDialect = .postgresql
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }
}
