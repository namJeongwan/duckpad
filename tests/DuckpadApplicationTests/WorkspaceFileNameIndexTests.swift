import DuckpadApplication
import DuckpadInfrastructure
import Foundation
import Testing

@Suite(.serialized) @MainActor
struct WorkspaceFileNameIndexTests {
    @Test func nameQueryRetainsLiteralUnicodeFoldingAndAbsolutePathMatching() {
        #expect(FileNameQuery("UTILS.TS").matches(path: "/project/src/utils.ts"))
        #expect(FileNameQuery("utils.ts").matches(path: "/project/src/ütils.ts"))
        #expect(FileNameQuery("STRASSE").matches(path: "/project/Straße.ts"))
        #expect(FileNameQuery("src utils.ts").matches(path: "/project/src/deep/utils.ts"))
        #expect(FileNameQuery("/project/src").matches(path: "/project/src/utils.ts"))
        #expect(!FileNameQuery("[utils]*").matches(path: "/project/src/utils.ts"))
    }
    @Test func queryFindsUnopenedDeepFilesWithASmallRetainedResultBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/deep"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<30 { try Data().write(to: root.appendingPathComponent("other-\(i).ts")) }
        try Data().write(to: root.appendingPathComponent("src/deep/utils.ts"))
        let browser = WorkspaceBrowserUseCase(store: LocalWorkspaceRootStore(archiveURL: root.appendingPathComponent(".roots.json")))
        _ = await browser.start(); _ = await browser.addRoot(root)
        let result = try await browser.fileNameIndex(maximumEntries: 2, query: "utils.ts")
        #expect(result.files.map(\.relativePath) == ["src/deep/utils.ts"])
        #expect(!result.isTruncated)
    }
    @Test func recursiveNamesSkipHiddenLinksAndRespectBoundedEnumeration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("this is content, not a file name".utf8).write(to: root.appendingPathComponent("Sources/한글.swift"))
        try Data().write(to: root.appendingPathComponent(".hidden"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("Sources"))
        let browser = WorkspaceBrowserUseCase(store: LocalWorkspaceRootStore(archiveURL: root.appendingPathComponent(".roots.json")))
        _ = await browser.start(); _ = await browser.addRoot(root)
        let result = try await browser.fileNameIndex()
        #expect(result.files.map(\.relativePath) == ["Sources/한글.swift"])
        #expect(!result.isTruncated)
        let bounded = try await browser.fileNameIndex(maximumEntries: 1)
        #expect(bounded.isTruncated)
        #expect(bounded.files.isEmpty)
        let cancelled = Task { try await browser.fileNameIndex() }
        cancelled.cancel()
        do { _ = try await cancelled.value; Issue.record("cancelled traversal returned files") } catch { }
    }
}
