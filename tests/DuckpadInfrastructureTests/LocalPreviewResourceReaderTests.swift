import DuckpadInfrastructure
import Foundation
import Testing

@Suite struct LocalPreviewResourceReaderTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func largeRegularResourcesRemainReadableAndDirectoriesAreRejected() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large.png")
        let bytes = Data(repeating: 1, count: 32 * 1_024 * 1_024 + 1)
        try bytes.write(to: file)
        let reader = LocalPreviewResourceReader()
        let stream = try await reader.open(file)
        var count = 0
        while true {
            let chunk = try await stream.read()
            guard !chunk.isEmpty else { break }
            #expect(chunk.allSatisfy { $0 == 1 })
            count += chunk.count
        }
        await stream.close()
        #expect(count == bytes.count)
        await #expect(throws: (any Error).self) { _ = try await reader.open(root) }
    }

    @Test func appendedBytesRemainReadableUntilEOF() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("image.png")
        try Data([1, 2, 3, 4]).write(to: file)
        let stream = try await LocalPreviewResourceReader().open(file)
        #expect(try await stream.read() == Data([1, 2, 3, 4]))
        let writer = try FileHandle(forWritingTo: file)
        try writer.seekToEnd()
        try writer.write(contentsOf: Data([5]))
        try writer.close()
        #expect(try await stream.read() == Data([5]))
        #expect(try await stream.read().isEmpty)
        await stream.close()
    }

    @Test func symlinkReadsPinnedFileEvenWhenPathIsReplaced() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("image.png")
        let link = root.appendingPathComponent("link.png")
        try Data([1, 2]).write(to: original)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let stream = try await LocalPreviewResourceReader().open(link)
        try FileManager.default.moveItem(at: original, to: root.appendingPathComponent("moved.png"))
        try Data([9, 9]).write(to: original)
        #expect(try await stream.read() == Data([1, 2]))
        #expect(try await stream.read().isEmpty)
        await stream.close()
    }

    @Test @MainActor func imageBookmarksPersistWithoutChangingOtherPreferences() throws {
        let suite = "duckpad-preview-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        defaults.set("preserved", forKey: "unrelated")
        LocalMarkdownImageAccess(defaults: defaults).remember([root, root])
        let bookmarks = try #require(defaults.array(forKey: "markdownPreview.imageFolders") as? [Data])
        #expect(bookmarks.count == 1)
        var stale = false
        let restored = try URL(resolvingBookmarkData: #require(bookmarks.first), options: [.withSecurityScope], bookmarkDataIsStale: &stale)
        #expect(restored.resolvingSymlinksInPath() == root.resolvingSymlinksInPath())
        #expect(defaults.string(forKey: "unrelated") == "preserved")
    }
}
