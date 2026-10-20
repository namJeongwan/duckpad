import DuckpadApplication
import DuckpadInfrastructure
import Foundation
import Testing

@Suite(.serialized) @MainActor
struct WorkspaceFileNameIndexTests {
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
