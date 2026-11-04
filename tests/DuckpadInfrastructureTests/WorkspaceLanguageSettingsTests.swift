import Foundation
import Testing
import DuckpadApplication
import DuckpadDomain
@testable import DuckpadInfrastructure

@Suite(.serialized)
struct WorkspaceLanguageSettingsTests {
    @Test func folderWorkspaceAndGlobalPrecedenceAreIndependentForTheSamePath() async throws {
        let a = SessionID(), b = SessionID()
        let folder = LanguageServiceFolder(id: UUID().uuidString, path: "/tmp/shared", displayName: "shared")
        var settings = LanguageServiceSettings(serverID: "basedpyright", workspaces: [
            a.rawValue.uuidString: .init(serverID: "ty", folders: [folder.id: .init(serverID: "pyright")]),
            b.rawValue.uuidString: .init(serverID: "disabled")])
        func selected(_ id: SessionID) -> String {
            settings.server(forProject: folder.path, workspaceID: id, folder: folder, default: "basedpyright")
        }
        #expect(selected(a) == "pyright")
        #expect(selected(b) == "disabled")
        settings.workspaces[a.rawValue.uuidString]?.folders[folder.id] = .init()
        #expect(selected(a) == "ty")
        settings.workspaces[a.rawValue.uuidString]?.serverID = nil
        #expect(selected(a) == "basedpyright")
        #expect(selected(b) == "disabled")
        let registration = try await LanguagePluginFixtures.registration("python")
        let packet = LanguageServerLaunchRequest(registration: registration, documentPath: folder.path + "/sample.py", settings: settings, workspaceID: a, folder: folder)
        #expect(packet.isValid)
        #expect(packet.settings.workspaces.keys.sorted() == [a.rawValue.uuidString])
        #expect(packet.settings.projects.isEmpty)
        let decoded = try JSONDecoder().decode(LanguageServerLaunchRequest.self, from: JSONEncoder().encode(packet))
        #expect(decoded.workspaceID == a && decoded.folder == folder)
    }

    @Test func interpreterPriorityIncludesExplicitWorkspaceBeforeAutomaticEnvironment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent(".venv/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let local = bin.appendingPathComponent("python").path
        try FileManager.default.createSymbolicLink(atPath: local, withDestinationPath: "/bin/sh")
        let a = SessionID(), b = SessionID(), folder = LanguageServiceFolder.project(root.path)
        let rule = try await LanguagePluginFixtures.registration("python").service.interpreter
        var settings = LanguageServiceSettings(interpreterPath: "/bin/echo", workspaces: [
            a.rawValue.uuidString: .init(interpreterPath: "/bin/cat", folders: [folder.id: .init(interpreterPath: "/bin/ls")])])
        func resolve(_ id: SessionID) throws -> String? {
            try LanguageInterpreterResolver.resolve(rule: rule, settings: settings, root: root, searchPaths: ["/bin"], workspaceID: id, folder: folder)
        }
        #expect(try resolve(a) == "/bin/ls")
        #expect(try resolve(b) == local)
        settings.workspaces[a.rawValue.uuidString]?.folders[folder.id] = .init()
        #expect(try resolve(a) == "/bin/cat")
        settings.workspaces[a.rawValue.uuidString]?.interpreterPath = ""
        #expect(try resolve(a) == local)
        try FileManager.default.removeItem(atPath: local)
        #expect(try resolve(a) == "/bin/echo")
        settings.workspaces[a.rawValue.uuidString]?.interpreterPath = root.appendingPathComponent("missing").path
        #expect(throws: (any Error).self) { try resolve(a) }
    }

    @Test func legacySeedsBecomeIndependentSnapshotsAndClearingDoesNotReimport() {
        let a = SessionID(), b = SessionID(), folder = LanguageServiceFolder.project("/tmp/shared")
        var settings = LanguageServiceSettings(projects: [folder.path: .init(serverID: "ty")])
        var copy = settings.workspace(a)
        copy.folders[folder.id] = .init()
        settings.workspaces[a.rawValue.uuidString] = copy
        #expect(settings.workspace(a).folderSettings(folder, projectRoot: folder.path).serverID == nil)
        #expect(settings.workspace(b).folderSettings(folder, projectRoot: folder.path).serverID == "ty")
        #expect(settings.isolated(to: a).projects.isEmpty)
        #expect(settings.isolated(to: a).workspace(a) == copy)
    }

    @Test @MainActor func folderAssociationUsesLongestBoundaryAndRetainsIdentityOnRename() {
        let provider = LanguageServerCompletionProvider { _ in nil }
        defer { provider.shutdown() }
        let parent = LanguageServiceFolder(id: UUID().uuidString, path: "/tmp/project", displayName: "project")
        let child = LanguageServiceFolder(id: UUID().uuidString, path: "/tmp/project/nested", displayName: "nested")
        #expect(provider.updateWorkspaceFolders([parent, child]))
        #expect(provider.workspaceFolder(for: URL(fileURLWithPath: child.path + "/a.py")) == child)
        #expect(provider.workspaceFolder(for: URL(fileURLWithPath: "/tmp/project-other/a.py")) == nil)
        let renamed = LanguageServiceFolder(id: child.id, path: child.path, displayName: "renamed")
        #expect(!provider.updateWorkspaceFolders([parent, renamed]))
        #expect(provider.workspaceFolders.contains(renamed))
        let owner = provider.currentWorkspaceID
        #expect(provider.currentWorkspaceID == owner)
    }

    @Test func persistedRecoveryIdentityRejoinsOnlyItsOwnLanguageSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = ScratchSession(), b = ScratchSession()
        let settings = AppSettings(languageServices: ["com.duckpad.python/python": .init(workspaces: [
            a.id.rawValue.uuidString: .init(serverID: "ty", interpreterPath: "/tmp/env-a/bin/python"),
            b.id.rawValue.uuidString: .init(serverID: "pyright", interpreterPath: "/tmp/env-b/bin/python")])])
        let settingsURL = root.appendingPathComponent("settings/settings.json")
        try await LocalAppSettingsStore(archiveURL: settingsURL).save(settings)
        for (name, session) in [("a", a), ("b", b)] {
            _ = try await LocalRecoveryStore(root: root.appendingPathComponent(name)).commit(.init(session: session, buffers: [:]), generation: .init(rawValue: 1))
        }
        let restoredA = try #require(try await LocalRecoveryStore(root: root.appendingPathComponent("a")).loadLatest()).archive.session.id
        let restoredB = try #require(try await LocalRecoveryStore(root: root.appendingPathComponent("b")).loadLatest()).archive.session.id
        let restored = try #require(try await LocalAppSettingsStore(archiveURL: settingsURL).load()).languageServices["com.duckpad.python/python"]
        #expect(restoredA == a.id && restoredB == b.id && restoredA != restoredB)
        #expect(restored?.workspace(restoredA).interpreterPath == "/tmp/env-a/bin/python")
        #expect(restored?.workspace(restoredB).serverID == "pyright")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DUCKPAD_PYTHON_SERVERS_TEST_DIRECTORY"] != nil), arguments: ["basedpyright", "pyright", "ty"])
    @MainActor func realSameFileWorkspacesKeepDifferentEnvironmentsAndOnlyChangedOwnerRestarts(serverID: String) async throws {
        let tools = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["DUCKPAD_PYTHON_SERVERS_TEST_DIRECTORY"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-workspaces-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("pyproject.toml"))
        let envA = root.appendingPathComponent(".venv"), envB = root.appendingPathComponent("other-env")
        try PythonLanguageServerTests.environment(at: envA, python: tools.appendingPathComponent("python"), member: "only_environment_a")
        try PythonLanguageServerTests.environment(at: envB, python: tools.appendingPathComponent("python"), member: "only_environment_b")
        for name in ["basedpyright-langserver", "pyright-langserver", "ty"] {
            try FileManager.default.createSymbolicLink(at: envA.appendingPathComponent("bin/" + name), withDestinationURL: tools.appendingPathComponent(name))
        }
        let url = root.appendingPathComponent("sample.py"), a = SessionID(), b = SessionID()
        let text = "from duckpad_probe import Widget\nwidget = Widget()\nwidget."
        try text.write(to: url, atomically: true, encoding: .utf8)
        let registration = try await LanguagePluginFixtures.registration("python")
        let registry = LanguageServerAdapterRegistry(registrations: [registration])
        var settings = LanguageServiceSettings(serverID: serverID, workspaces: [
            a.rawValue.uuidString: .init(interpreterPath: envA.appendingPathComponent("bin/python").path),
            b.rawValue.uuidString: .init(interpreterPath: envB.appendingPathComponent("bin/python").path)])
        var identityA = a
        let providerA = LanguageServerCompletionProvider(registry: registry, settings: [registration.settingsKey: settings], workspaceID: { identityA }) { _ in url }
        let providerB = LanguageServerCompletionProvider(registry: registry, settings: [registration.settingsKey: settings], workspaceID: { b }) { _ in url }
        defer { providerA.shutdown(); providerB.shutdown() }
        let capture = DocumentIntelligenceCapture(buffer: .init(bufferID: BufferID(), revision: 0), utf8: Data(text.utf8), caretUTF8: text.utf8.count, languageID: .init(rawValue: "python"), contextID: .init())
        let prefix = try #require(DocumentCompletionPrefix(capture))
        func labels(_ provider: LanguageServerCompletionProvider) async throws -> [String] {
            let deadline = ContinuousClock.now.advanced(by: .seconds(12))
            repeat {
                let values = try await provider.completions(in: capture, prefixRange: prefix.insertRange).map(\.label)
                if values.contains(where: { $0.hasPrefix("only_environment_") }) { return values }
                try await Task.sleep(for: .milliseconds(100))
            } while ContinuousClock.now < deadline
            return []
        }
        #expect(try await labels(providerA).contains("only_environment_a"))
        #expect(try await labels(providerB).contains("only_environment_b"))
        let contextA = try #require(providerA.context(for: url))
        #expect(contextA.workspaceID == a)
        #expect(providerB.context(for: url)?.workspaceID == b)
        var invalidations = 0
        providerA.onInvalidation = { invalidations += 1 }
        settings.workspaces[b.rawValue.uuidString]?.interpreterPath = envA.appendingPathComponent("bin/python").path
        #expect(!providerA.update(registrations: [registration], settings: [registration.settingsKey: settings]))
        #expect(providerB.update(registrations: [registration], settings: [registration.settingsKey: settings]))
        #expect(providerA.context(for: url) == contextA && invalidations == 0)
        #expect(providerB.context(for: url) == nil)
        #expect(try await labels(providerB).contains("only_environment_a"))
        // A restored/different workspace identity cannot reuse the previous session.
        identityA = b
        #expect(providerA.context(for: url) == nil)
        #expect(try await labels(providerA).contains("only_environment_a"))
        #expect(providerA.context(for: url)?.workspaceID == b && invalidations == 1)
    }
}
