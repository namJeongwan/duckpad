import Foundation
import DuckpadApplication
import Testing

struct MarkdownLinkDestinationTests {
    @Test func resolvesFilesAgainstTheMarkdownDocumentAndKeepsWebQueries() {
        let base = URL(fileURLWithPath: "/tmp/docs/note.md")
        #expect(MarkdownLinkDestination.resolve("../source/a%20b.md#heading", relativeTo: base)?.path == "/tmp/source/a b.md")
        #expect(MarkdownLinkDestination.resolve("file:///tmp/%ED%95%9C%EA%B8%80.md", relativeTo: nil)?.path == "/tmp/한글.md")
        #expect(MarkdownLinkDestination.resolve("/tmp/a%20b.txt", relativeTo: nil)?.path == "/tmp/a b.txt")
        #expect(MarkdownLinkDestination.resolve("https://example.com/a?q=1#heading", relativeTo: base)?.absoluteString == "https://example.com/a?q=1#heading")
        #expect(MarkdownLinkDestination.resolve("file:///tmp/a%23b.md?query#heading", relativeTo: nil)?.path == "/tmp/a#b.md")
        #expect(MarkdownLinkDestination.resolve("relative.md", relativeTo: nil) == nil)
    }

    @Test func ignoresUnsupportedSchemesAndMalformedTargets() {
        for href in ["javascript:alert(1)", "data:text/html,test", "duckpad-editor://assets/editor.js", "file://remote-server/path", "https:", "x\n.md", ""] {
            #expect(MarkdownLinkDestination.resolve(href, relativeTo: URL(fileURLWithPath: "/tmp/note.md")) == nil)
        }
    }
}
