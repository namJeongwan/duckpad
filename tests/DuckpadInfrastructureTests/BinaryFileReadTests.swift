import Darwin
import DuckpadApplication
import DuckpadInfrastructure
import Foundation
import Testing

struct BinaryFileReadTests {
    @Test func binaryReadIncludesTheFullTailAndPreservesFileSize() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(FileManager.default.createFile(atPath: url.path, contents: Data([0, 0xFF])))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 2 * 1_024 * 1_024)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("tail".utf8))
        try handle.close()
        let store = LocalTextFileStore()
        let read = try await store.readForDisplay(from: url, assuming: nil)
        #expect(read.data.count == 2_097_156)
        #expect(read.identity.byteCount == 2_097_156)
        #expect(read.data.prefix(2) == Data([0, 0xFF]))
        #expect(read.data.suffix(4) == Data("tail".utf8))
        #expect(try await store.readForDisplay(from: url, assuming: nil).identity == read.identity)
        #expect(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == 2_097_156)
    }

    @Test func binaryIdentityDetectsLateByteChangesEvenWhenModificationTimeIsRestored() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0, count: 262_144).write(to: url)
        let store = LocalTextFileStore()
        let first = try await store.readForDisplay(from: url, assuming: nil)
        var original = stat()
        #expect(Darwin.lstat(url.path, &original) == 0)
        #expect(first.identity.contentToken.hasPrefix("binary-readonly:"))
        try await Task.sleep(for: .milliseconds(2))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 200_000)
        try handle.write(contentsOf: Data([0xFF]))
        var times = [original.st_atimespec, original.st_mtimespec]
        #expect(futimens(handle.fileDescriptor, &times) == 0)
        try handle.close()
        let changed = try await store.readForDisplay(from: url, assuming: nil)
        #expect(changed.identity.modifiedNanoseconds == first.identity.modifiedNanoseconds)
        #expect(changed.identity.byteCount == first.identity.byteCount)
        #expect(changed.identity.contentToken != first.identity.contentToken)
        let fullIdentity = try await store.read(from: url).identity
        #expect(!fullIdentity.contentToken.hasPrefix("binary-readonly:"))
        #expect(fullIdentity != changed.identity)
    }

    @Test func largeTextIsReadInFullWithItsNormalIdentity() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data(repeating: 0x41, count: 1_024 * 1_024 + 1)
        try data.write(to: url)
        let store = LocalTextFileStore()
        let display = try await store.readForDisplay(from: url, assuming: nil)
        let raw = try await store.read(from: url)
        #expect(display == raw)
        #expect(display.data == data)
    }
    @Test func sidebarReadsFullBinaryWithTheSameIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("large.bin")
        try Data([0, 0xFF]).write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 2 * 1_024 * 1_024 + 1)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("tail".utf8))
        try handle.close()
        let store = LocalWorkspaceRootStore(archiveURL: directory.appendingPathComponent("roots.json"))
        let root = try await store.addRoot(directory)
        let entry = try #require(try await store.children(rootID: root.id, relativeDirectory: "")
            .first(where: { $0.name == "large.bin" }))
        let read = try await store.readFile(entry)
        #expect(read.result.data.count == 2_097_157)
        #expect(read.result.data.suffix(4) == Data("tail".utf8))
        #expect(read.result.identity.byteCount == 2_097_157)
        #expect(read.result == (try await LocalTextFileStore().readForDisplay(from: file, assuming: nil)))
    }

}
