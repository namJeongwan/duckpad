import DuckpadApplication
import DuckpadInfrastructure
import Foundation
import Testing

@Suite(.serialized) struct WorkspaceDeclarationSearchTests {
    @Test func referenceLimitMarksPartialResults() async throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let rootURL = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data(String(repeating: "swim()\n", count: 205).utf8).write(to: rootURL.appendingPathComponent("calls.swift"))
        let store = LocalWorkspaceRootStore(archiveURL: base.appendingPathComponent("roots.json"))
        let root = try await store.addRoot(rootURL)
        let result = await WorkspaceDeclarationSearch(store: store).find(name: "swim", language: "swift", kind: .references, roots: [root], excludingPaths: [])
        #expect(!result.isComplete)
        #expect(result.matches.count == 200)
    }
    @Test func referencesSearchProjectAndExcludeOpenDiskCopies() async throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let rootURL = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data("message AudioFormat {}\nmessage Frame { AudioFormat format = 1; }\n// AudioFormat".utf8).write(to: rootURL.appendingPathComponent("audio.proto"))
        let openURL = rootURL.appendingPathComponent("open.proto")
        try Data("message Frame { AudioFormat format = 1; }".utf8).write(to: openURL)
        let store = LocalWorkspaceRootStore(archiveURL: base.appendingPathComponent("roots.json"))
        let root = try await store.addRoot(rootURL)
        let result = await WorkspaceDeclarationSearch(store: store).find(name: "AudioFormat", language: "protobuf", kind: .references, roots: [root], excludingPaths: [openURL.path])
        #expect(result.isComplete)
        #expect(result.matches.map { $0.url.lastPathComponent } == ["audio.proto"])
        #expect(result.matches.map(\.match.line) == [2])
    }
    @Test func protobufFilesParticipateInProjectLookup() async throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let rootURL = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data("message AudioFormat { uint32 channels = 1; }".utf8).write(to: rootURL.appendingPathComponent("audio.proto"))
        try Data("struct AudioFormat {}".utf8).write(to: rootURL.appendingPathComponent("audio.swift"))
        let store = LocalWorkspaceRootStore(archiveURL: base.appendingPathComponent("roots.json"))
        let root = try await store.addRoot(rootURL)
        let result = await WorkspaceDeclarationSearch(store: store).find(name: "AudioFormat", language: "protobuf", roots: [root], excludingPaths: [])
        #expect(result.isComplete)
        #expect(result.matches.map { $0.url.lastPathComponent } == ["audio.proto"])
    }
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @Test func filtersLanguageOpenBuffersDependenciesAndSymlinks() async throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let rootURL = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: rootURL.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        for path in ["one.swift", "open.swift", "node_modules/hidden.swift"] {
            try Data("func swim() {}".utf8).write(to: rootURL.appendingPathComponent(path))
        }
        try Data("function swim() {}".utf8).write(to: rootURL.appendingPathComponent("other.js"))
        let outside = base.appendingPathComponent("outside.swift")
        try Data("func swim() {}".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: rootURL.appendingPathComponent("link.swift"), withDestinationURL: outside)
        let store = LocalWorkspaceRootStore(archiveURL: base.appendingPathComponent("roots.json"))
        let root = try await store.addRoot(rootURL)
        let result = await WorkspaceDeclarationSearch(store: store).find(name: "swim", language: "swift", roots: [root, root], excludingPaths: [rootURL.appendingPathComponent("open.swift").path])
        #expect(result.isComplete)
        #expect(result.matches.map { $0.url.lastPathComponent } == ["one.swift"])
    }
    @Test func directoryLimitMarksPartialResults() async throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let rootURL = base.appendingPathComponent("project")
        for n in 0..<260 { try FileManager.default.createDirectory(at: rootURL.appendingPathComponent("dir\(n)"), withIntermediateDirectories: true) }
        let store = LocalWorkspaceRootStore(archiveURL: base.appendingPathComponent("roots.json"))
        let root = try await store.addRoot(rootURL)
        let result = await WorkspaceDeclarationSearch(store: store).find(name: "swim", language: "swift", roots: [root], excludingPaths: [])
        #expect(!result.isComplete)
    }
    @Test func boundedReadRejectsLargeFilesBeforeReading() async throws {
        let base = try fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let rootURL = base.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try Data(repeating: 97, count: 1025).write(to: rootURL.appendingPathComponent("large.swift"))
        let store = LocalWorkspaceRootStore(archiveURL: base.appendingPathComponent("roots.json"))
        let root = try await store.addRoot(rootURL)
        let entry = try #require(try await store.children(rootID: root.id, relativeDirectory: "").first)
        await #expect(throws: WorkspaceBrowserFailure.self) { _ = try await store.readFile(entry, maximumBytes: 1024) }
        #expect(try await store.readFile(entry).result.data.count == 1025)
    }
}
