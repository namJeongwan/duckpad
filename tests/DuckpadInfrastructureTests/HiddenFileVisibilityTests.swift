import Darwin
import DuckpadApplication
import DuckpadDomain
import Foundation
import Testing
@testable import DuckpadInfrastructure

@Suite(.serialized)
struct HiddenFileVisibilityTests {
    private var executable: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/ripgrep/15.1.0/native/rg")
    }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for dir in [".config", "flagged-dir", "Hidden.app/Contents"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true) }
        for path in ["visible.txt", ".env", ".config/inside.txt", "flagged.txt", "flagged-dir/inside.txt", "Hidden.app/Contents/private.txt"] {
            try Data("needle".utf8).write(to: root.appendingPathComponent(path))
        }
        #expect(chflags(root.appendingPathComponent("flagged.txt").path, UInt32(UF_HIDDEN)) == 0)
        #expect(chflags(root.appendingPathComponent("flagged-dir").path, UInt32(UF_HIDDEN)) == 0)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".link"), withDestinationURL: root.appendingPathComponent("visible.txt"))
        return root
    }
    @Test(arguments: [false, true])
    func contentSearchIncludesDotAndFlaggedFilesOnlyWhenEnabled(usingRipgrep: Bool) async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let search = FolderSearchUseCase(store: LocalFolderSearchFileStore(), regexEngine: ICURegexEngine(),
            backend: usingRipgrep ? RipgrepFolderSearchBackend(executable: executable) : nil)
        for enabled in [false, true, false] {
            let result = try await search.search(rootPath: root.path, query: .init(pattern: "needle", options: .init(includeHiddenFiles: enabled)))
            #expect(Set(result.documents.map(\.relativePath)) == (enabled ? ["visible.txt", ".env", ".config/inside.txt", "flagged.txt", "flagged-dir/inside.txt"] : ["visible.txt"]))
            #expect(!result.isTruncated)
        }
    }
    @Test(arguments: [false, true])
    func filenameIndexIncludesAndSafelyOpensHiddenFilesWhenEnabled(usingRipgrep: Bool) async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let indexer = LocalFolderFileNameIndex(executable: usingRipgrep ? executable : nil)
        let normal = try await indexer.index(in: root)
        #expect(normal.relativePaths == ["visible.txt"])
        let all = try await indexer.index(in: root, includeHiddenFiles: true)
        #expect(Set(all.relativePaths) == ["visible.txt", ".env", ".config/inside.txt", "flagged.txt", "flagged-dir/inside.txt"])
        let read = try await indexer.readFile(in: root, root: all.root, relativePath: ".env")
        #expect(read.result.data == Data("needle".utf8))
        do { _ = try await indexer.readFile(in: root, root: all.root, relativePath: ".link"); Issue.record("followed hidden link") } catch { }
    }
    @Test func hiddenOptionDoesNotOverrideRipgrepIgnoreRules() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data(".env\n.config/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        let search = FolderSearchUseCase(store: LocalFolderSearchFileStore(), regexEngine: ICURegexEngine(),
            backend: RipgrepFolderSearchBackend(executable: executable))
        let result = try await search.search(rootPath: root.path, query: .init(pattern: "needle", options: .init(includeHiddenFiles: true)))
        #expect(Set(result.documents.map(\.relativePath)) == ["visible.txt", "flagged.txt", "flagged-dir/inside.txt"])
    }
    @Test @MainActor func workspaceTreeAndWorkspaceFilenameIndexFollowTheSamePreference() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: archive) }
        let browser = WorkspaceBrowserUseCase(store: LocalWorkspaceRootStore(archiveURL: archive))
        _ = await browser.start(); _ = await browser.addRoot(root)
        let id = try #require(browser.roots.first?.id)
        for enabled in [false, true, false] {
            browser.showHiddenFiles = enabled
            let children = try await browser.children(rootID: id, relativeDirectory: "")
            #expect(Set(children.map(\.name)) == (enabled ? ["visible.txt", ".env", ".config", "flagged.txt", "flagged-dir"] : ["visible.txt"]))
            let index = try await browser.fileNameIndex()
            #expect(Set(index.files.map(\.relativePath)) == (enabled ? ["visible.txt", ".env", ".config/inside.txt", "flagged.txt", "flagged-dir/inside.txt"] : ["visible.txt"]))
        }
    }
    @Test func visibilityPreferenceRoundTripsAndOlderSettingsKeepTheirDefault() throws {
        #expect(!AppSettings.defaults.showHiddenFiles)
        var settings = AppSettings.defaults; settings.showHiddenFiles = true
        let encoded = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: encoded).showHiddenFiles)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "showHiddenFiles")
        #expect(try !JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: legacy)).showHiddenFiles)
    }
}
