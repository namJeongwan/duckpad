import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import Foundation
import Testing

struct FileLocationStoreTests {
    @Test func nativeTrashReturnsRecoverableFileWithExactBytes() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-trash-test-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("duckpad-test-\(UUID()).txt")
        let bytes = Data("test-only 한글 🦆".utf8)
        try bytes.write(to: source)
        let store = LocalTextFileStore(bookmarkArchiveURL: folder.appendingPathComponent("access.json"))
        let identity = try await store.read(from: source).identity
        let binding = FileBinding(canonicalPath: source.path, encoding: .utf8, byteOrderMark: .absent,
            lineEnding: .none, observedIdentity: identity)
        let receipt = try await store.changeLocation(of: binding, operation: .trash)
        let trashed = URL(fileURLWithPath: receipt.identity.canonicalPath)
        defer { try? FileManager.default.removeItem(at: trashed) }
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(trashed.path != source.path)
        #expect(try Data(contentsOf: trashed) == bytes)
        #expect(receipt.identity.contentToken == identity.contentToken)
    }

    @Test func symlinkDestinationIsNeverFollowedOrReplaced() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.txt")
        let target = folder.appendingPathComponent("link.txt")
        let outside = folder.appendingPathComponent("other.txt")
        try Data("source".utf8).write(to: source)
        try Data("other".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        let store = LocalTextFileStore()
        let identity = try await store.read(from: source).identity
        let binding = FileBinding(canonicalPath: source.path, encoding: .utf8, byteOrderMark: .absent,
            lineEnding: .none, observedIdentity: identity)
        await #expect(throws: TextFileStoreError.destinationExists(target.path)) {
            try await store.changeLocation(of: binding, operation: .move(target))
        }
        #expect(try Data(contentsOf: source) == Data("source".utf8))
        #expect(try Data(contentsOf: outside) == Data("other".utf8))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == outside.path)
    }
}
