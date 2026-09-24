import DuckpadDomain
import DuckpadApplication
@testable import DuckpadInfrastructure
import Foundation
import Testing

struct EditorConfigTests {
    @Test func restoresAuthorizedConfigAfterRestartForExtensionlessFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-config-access-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent(".editorconfig")
        try "root=true\n[*]\nindent_style=space\nindent_size=2".write(to: config, atomically: true, encoding: .utf8)
        let scoped = try #require(URL(string: config.absoluteString + "?scope"))
        let probe = ConfigScopeProbe()
        func makeStore() -> LocalTextFileStore {
            LocalTextFileStore(bookmarkArchiveURL: root.appendingPathComponent("bookmarks.json"),
                testingSecurityScopedAccessRequired: true,
                testingStartSecurityScopedAccess: { probe.start($0) },
                testingStopSecurityScopedAccess: { _ in probe.stop() },
                testingCreateSecurityScopedBookmark: { url in
                    guard probe.selected || url.query == "scope" else { throw TextFileStoreError.permissionDenied(url.path) }
                    return Data("config-grant".utf8)
                }, testingResolveSecurityScopedBookmark: { _ in (scoped, false) })
        }
        let initial = makeStore(), owner = UUID()
        _ = try await initial.prepareSecurityScopedAccess(to: config, ownerID: owner)
        await initial.releaseAllSecurityScopedAccess(ownerID: owner)
        probe.selected = false
        let before = probe.counts
        let reader = LocalEditorConfigReader(accessStore: makeStore())
        let rules = await reader.conventions(for: root.appendingPathComponent("new 51"))
        #expect(rules.properties["indent_size"] == "2")
        #expect(probe.counts.0 == before.0 + 1)
        #expect(probe.counts.1 == before.1 + 1)
    }
    @Test func matching() {
        for (pattern, path) in [("*.swift", "nested/main.swift"), ("src/**/a?.{swift,c}", "src/a1.swift"), ("file{1..3}.txt", "file2.txt"), ("[!x].txt", "a.txt"), ("/src/*", "src/a"), ("\\[name\\].txt", "[name].txt")] {
            #expect(EditorConfigGlob.matches(pattern, path: path), "\(pattern): \(path)")
        }
        #expect(!EditorConfigGlob.matches("src/*", path: "src/nested/a"))
        #expect(!EditorConfigGlob.matches("*.SWIFT", path: "a.swift"))
        #expect(!EditorConfigGlob.matches("folder/", path: "folder/a"))
        #expect(!EditorConfigGlob.matches("[!x].txt", path: "x.txt"))
    }
    @Test func bracesAndCommasInsideCharacterListsAreLiteral() {
        for name in ["{.txt", "}.txt", "1.txt", "..txt"] {
            #expect(EditorConfigGlob.matches("[ab{1..2}].txt", path: name))
        }
        #expect(EditorConfigGlob.matches("{[a,b],x}.txt", path: ",.txt"))
        #expect(EditorConfigGlob.matches("{[a,b],x}.txt", path: "x.txt"))
        #expect(EditorConfigGlob.matches("{[a{b],x}.txt", path: "{.txt"))
    }
    @Test func pathologicalGlobsHaveABudget() {
        let start = Date()
        #expect(!EditorConfigGlob.matches(String(repeating: "a*", count: 60) + "b", path: String(repeating: "a", count: 250)))
        #expect(Date().timeIntervalSince(start) < 2)
    }
    @Test func invalidValuesDoNotEraseInheritedRules() {
        var properties = ["indent_size": "2"]
        EditorConfigDocument("[*]\nindent_size=not-a-number").apply(to: &properties, relativePath: "a.txt")
        #expect(properties["indent_size"] == "2")
    }
    @Test func hierarchyRootUnsetAndLastSectionWin() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-config-\(UUID())")
        let child = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "root = TRUE\n[*]\nindent_style=space\nindent_size=4\ntrim_trailing_whitespace=true\n[*.swift]\nindent_size=2\n".write(to: root.appendingPathComponent(".editorconfig"), atomically: true, encoding: .utf8)
        try "[*]\nindent_size=8\ntrim_trailing_whitespace=unset\n[main.swift]\nindent_size=3\n".write(to: child.appendingPathComponent(".editorconfig"), atomically: true, encoding: .utf8)
        let rules = await LocalEditorConfigReader().conventions(for: child.appendingPathComponent("main.swift"))
        #expect(rules.properties["indent_size"] == "3")
        #expect(rules.properties["indent_style"] == "space")
        #expect(rules.trimTrailingWhitespace == nil)
        try "root=true\n[*]\nindent_size=6".write(to: child.appendingPathComponent(".editorconfig"), atomically: true, encoding: .utf8)
        let isolated = await LocalEditorConfigReader().conventions(for: child.appendingPathComponent("main.swift"))
        #expect(isolated.properties["indent_style"] == nil)
    }
}

private final class ConfigScopeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var userSelected = true
    private var starts = 0
    private var stops = 0
    var selected: Bool {
        get { lock.withLock { userSelected } }
        set { lock.withLock { userSelected = newValue } }
    }
    var counts: (Int, Int) { lock.withLock { (starts, stops) } }
    func start(_ url: URL) -> Bool {
        lock.withLock {
            guard userSelected || url.query == "scope" else { return false }
            starts += 1
            return true
        }
    }
    func stop() { lock.withLock { stops += 1 } }
}
