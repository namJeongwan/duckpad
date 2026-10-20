import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import Foundation
import Testing

struct SearchMatchPreviewTests {
    @Test func previewIncludesAdjacentLinesAndKeepsUnicodeMatchOffsets() throws {
        for ending in ["\n", "\r\n", "\r"] {
            let lines = (1...30).map { "line \($0) 한글 🦆" }
            let text = lines.joined(separator: ending)
            let prefix = lines.prefix(14).joined(separator: ending) + ending
            let range = SearchUTF8Range(location: prefix.utf8.count + "line 15 ".utf8.count, length: "한글".utf8.count)
            let preview = try #require(SearchMatchPreview.extract(utf8: Data(text.utf8), range: range, line: 15))
            #expect(preview.firstLine == 9)
            #expect(preview.text.hasPrefix("line 9"))
            #expect(preview.text.contains("line 16"))
            let data = Data(preview.text.utf8)
            #expect(String(decoding: data.subdata(in: preview.highlight.location..<preview.highlight.upperBound), as: UTF8.self) == "한글")
        }
    }
    @Test func previewIsBoundedForSingleHugeLinesAndRejectsInvalidOffsets() throws {
        let bytes = Data(String(repeating: "한글", count: 30_000).utf8)
        let preview = try #require(SearchMatchPreview.extract(utf8: bytes, range: .init(location: 90_000, length: 3), line: 1))
        #expect(preview.text.utf8.count <= 32 * 1_024)
        #expect(!preview.text.contains("�"))
        #expect(SearchMatchPreview.extract(utf8: bytes, range: .init(location: -1, length: 3), line: 1) == nil)
        #expect(SearchMatchPreview.extract(utf8: bytes, range: .init(location: bytes.count, length: 1), line: 1) == nil)
    }
    @Test func folderPreviewChecksIdentityAndSizeBeforeDisplayingContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("test.swift")
        try Data("let before = 1\nlet duck = 2\nlet after = 3\n".utf8).write(to: url)
        let store = LocalFolderSearchFileStore()
        let search = FolderSearchUseCase(store: store, regexEngine: ICURegexEngine())
        let results = try await search.search(rootPath: root.path, query: .init(pattern: "duck"))
        let document = try #require(results.documents.first), match = try #require(document.matches.first)
        let preview = try #require(await search.preview(document: document, match: match))
        #expect(preview.text.contains("before")); #expect(preview.text.contains("after"))
        #expect(await store.previewFile(document, maximumBytes: 1) == nil)
        try Data("different content\n".utf8).write(to: url)
        #expect(await search.preview(document: document, match: match) == nil)
    }
}
