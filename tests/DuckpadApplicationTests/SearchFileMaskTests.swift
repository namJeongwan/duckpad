import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import Foundation
import Testing

struct SearchFileMaskTests {
    @Test func globsHandleListsExclusionsUnicodeAndLiteralStarsInNames() throws {
        let mask = try SearchFileMask("*.swift, *.JSON; 한?.txt; !*.generated.swift")
        #expect(mask.matches("Sources/App.swift")); #expect(mask.matches("CONFIG.json"))
        #expect(mask.matches("한글.txt")); #expect(!mask.matches("a.generated.swift")); #expect(!mask.matches("notes.md"))
        #expect(try SearchFileMask("*a").matches("*xa"))
        #expect(try SearchFileMask("!*.min.js").matches("a.ts"))
        #expect(try !SearchFileMask("!*.min.js").matches("a.min.js"))
        #expect(try SearchFileMask("").matches("anything"))
        #expect(throws: SearchFailure.self) { try SearchFileMask(String(repeating: "a", count: 4097)) }
    }
    @Test func folderMaskFiltersBeforeReadingOrConsumingTheFileBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 65, count: 1024).write(to: root.appendingPathComponent("a.txt"))
        try Data("duck".utf8).write(to: root.appendingPathComponent("b.swift"))
        let store = LocalFolderSearchFileStore()
        let result = try await store.enumerateTextCandidates(rootPath: root.path, maximumFiles: 1, maximumDocumentBytes: 10, maximumTotalBytes: 10, fileMask: SearchFileMask("*.swift"))
        #expect(result.files.map(\.relativePath) == ["b.swift"])
        #expect(!result.isTruncated); #expect(result.totalBytes == 4); #expect(result.skippedFileCount == 0)
        let search = FolderSearchUseCase(store: store, regexEngine: ICURegexEngine())
        let preview = try await search.search(rootPath: root.path, query: .init(pattern: "duck", fileMask: "*.swift"))
        #expect(preview.documents.map(\.relativePath) == ["b.swift"])
    }
}
