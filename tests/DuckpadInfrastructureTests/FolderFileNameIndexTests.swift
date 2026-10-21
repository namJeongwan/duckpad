import DuckpadApplication
@testable import DuckpadInfrastructure
import Foundation
import Darwin
import Testing

struct FolderFileNameIndexTests {
    @Test(arguments: [false, true])
    func queryFindsDeepNamesAfterUnrelatedEntriesExhaustTheInitialIndex(usingRipgrep: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("zz/deep"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<200 { try Data().write(to: root.appendingPathComponent("unrelated-\(i).txt")) }
        try Data().write(to: root.appendingPathComponent("zz/deep/utils.ts"))
        let indexer = LocalFolderFileNameIndex(executable: usingRipgrep ? executable : nil)
        let result = try await indexer.search(in: root, query: "UTILS.ts", maximumEntries: 10, includeHiddenFiles: false)
        #expect(result.relativePaths == ["zz/deep/utils.ts"])
        #expect(!result.isTruncated)
        let literal = try await indexer.search(in: root, query: "[utils]*", maximumEntries: 10, includeHiddenFiles: false)
        #expect(literal.relativePaths.isEmpty)
    }
    @Test func cachedDirectoryMetadataNeverAllowsAReplacedSymlink() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("selected"), child = root.appendingPathComponent("child")
        let outside = base.appendingPathComponent("outside")
        for directory in [child, outside] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: base) }
        for directory in [child, outside] { try Data().write(to: directory.appendingPathComponent("util.ts")) }
        let access = try FolderSearchRoot(path: root.path)
        let first = try #require(access.open("child/util.ts", cacheDirectoryPackages: true))
        Darwin.close(first.descriptor)
        try FileManager.default.removeItem(at: child)
        try FileManager.default.createSymbolicLink(at: child, withDestinationURL: outside)
        let replaced = access.open("child/util.ts", cacheDirectoryPackages: true)
        if let replaced { Darwin.close(replaced.descriptor) }
        #expect(replaced == nil)
    }

    private var executable: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/ripgrep/15.1.0/native/rg")
    }
    @Test(arguments: [false, true]) func namesIncludeBinaryAndLargeFilesWithoutReadingTheirContents(usingRipgrep: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for path in ["Sources", "ignored", "Example.app/Contents"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("ignored/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        for path in ["Sources/한글.swift", "ignored/disk.txt", ".hidden", "Example.app/Contents/private.txt"] { try Data([0, 255, 0]).write(to: root.appendingPathComponent(path)) }
        let large = root.appendingPathComponent("large.bin")
        #expect(FileManager.default.createFile(atPath: large.path, contents: nil))
        let handle = try FileHandle(forWritingTo: large); try handle.truncate(atOffset: 128 * 1_024 * 1_024); try handle.close()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.swift"), withDestinationURL: root.appendingPathComponent("Sources/한글.swift"))
        let indexer = LocalFolderFileNameIndex(executable: usingRipgrep ? executable : nil)
        let result = try await indexer.index(in: root)
        #expect(Set(result.relativePaths) == (usingRipgrep ? ["Sources/한글.swift", "large.bin"] : ["Sources/한글.swift", "large.bin", "ignored/disk.txt"]))
        #expect(!result.isTruncated)
        let bounded = try await indexer.index(in: root, maximumEntries: 1)
        #expect(bounded.isTruncated); #expect(bounded.relativePaths.count <= 1)
        let cancelled = Task { try await indexer.index(in: root) }; cancelled.cancel()
        do { _ = try await cancelled.value; Issue.record("cancelled name index completed") } catch { }
    }
    @Test(arguments: ["root", "directory", "file"])
    func indexedRootAndComponentsCannotBeReplacedWithOutsideLinks(component: String) async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let selected = base.appendingPathComponent("selected"), outside = base.appendingPathComponent("outside")
        for dir in [selected.appendingPathComponent("child"), outside.appendingPathComponent("child")] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("safe".utf8).write(to: selected.appendingPathComponent("child/name.txt"))
        for name in ["name.txt", "child/name.txt"] { try Data("outside secret".utf8).write(to: outside.appendingPathComponent(name)) }
        let indexer = LocalFolderFileNameIndex(executable: nil), index = try await indexer.index(in: selected)
        #expect(index.relativePaths == ["child/name.txt"])
        let read = try await indexer.readFile(in: selected, root: index.root, relativePath: "child/name.txt")
        #expect(read.result.data == Data("safe".utf8))
        let replaced = component == "root" ? selected : component == "directory" ? selected.appendingPathComponent("child") : selected.appendingPathComponent("child/name.txt")
        try FileManager.default.moveItem(at: replaced, to: base.appendingPathComponent("original"))
        let destination = component == "file" ? outside.appendingPathComponent("name.txt") : outside
        try FileManager.default.createSymbolicLink(at: replaced, withDestinationURL: destination)
        do {
            _ = try await indexer.readFile(in: selected, root: index.root, relativePath: "child/name.txt")
            Issue.record("outside link was accepted")
        } catch { }
    }

}
