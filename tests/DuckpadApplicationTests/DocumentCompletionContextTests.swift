import Foundation
import Testing
import DuckpadDomain
@testable import DuckpadApplication

struct DocumentCompletionContextTests {
    private func capture(_ text: String, language: String) -> DocumentIntelligenceCapture {
        .init(buffer: .init(bufferID: BufferID(), revision: 0), utf8: Data(text.utf8), caretUTF8: text.utf8.count,
              languageID: .init(rawValue: language), contextID: .init())
    }
    @Test(arguments: [
        ("python", "class Person:", false), ("python", "value:Person", false),
        ("python", "df[::", false), ("python", ".", false), ("python", "1.", false),
        ("python", "...", false), ("python", "df.", true), ("python", "call().", true),
        ("python", "df[\"name\"].", true), ("python", "obj .", true), ("python", "한글.", true),
        ("rust", "Person::", true), ("rust", "::", true), ("ruby", "Name::", true), ("cpp", "Name::", true)
    ])
    func actualMemberOperators(language: String, text: String, expected: Bool) throws {
        let prefix = try #require(DocumentCompletionPrefix(capture(text, language: language)))
        #expect(prefix.isMemberAccess == expected)
    }
    @Test(arguments: [
        ("python", "class P", false), ("python", "\tclass P", false),
        ("python", "async def new", true), ("python", "class Person:\n    def __", true), ("python", "class Name(Base", true),
        ("python", "def new(value:Person", true), ("python", "def new()->Person", true),
        ("python", "result = Person", true), ("python", "value:", false),
        ("ruby", "class Name::P", false), ("ruby", "class New < Person", true),
        ("ruby", "def self.new", true), ("rust", "pub(crate) async fn new", true),
        ("rust", "pub struct P", false), ("rust", "impl Person", true),
        ("rust", "fn new(value:Person", true), ("rust", "value:Person", true)
    ])
    func declarationNamesAndReferences(language: String, text: String, expected: Bool) throws {
        let capture = capture(text, language: language), prefix = try #require(DocumentCompletionPrefix(capture))
        #expect(DocumentCompletionContext.allowsAutomatic(in: capture, prefix: prefix) == expected)
    }
}
