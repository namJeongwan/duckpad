import Foundation
import Testing
import DuckpadApplication
import DuckpadDomain
import LanguageServerProtocol
@testable import DuckpadInfrastructure

@Suite(.serialized)
struct PythonLanguageServerTests {
    @Test func settingsRoundTripAndLegacyArchiveMigration() throws {
        let original = AppSettings(languageServices: ["com.duckpad.python/python": .init(serverID: "ty", interpreterPath: "/opt/python/bin/python",
            projects: ["/tmp/a": .init(serverID: "pyright", interpreterPath: "/tmp/a/.venv/bin/python")])])
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(original)) == original)
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as? [String: Any])
        old.removeValue(forKey: "languageServices")
        old["python"] = ["server": "ty", "interpreterPath": "/tmp/env/bin/python", "projects": ["/tmp/project": ["server": "pyright", "interpreterPath": ""]]]
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(restored.languageServices["com.duckpad.python/python"]?.serverID == "ty")
        #expect(restored.languageServices["com.duckpad.python/python"]?.projects["/tmp/project"]?.serverID == "pyright")
        #expect(!LanguageServiceSettings(interpreterPath: "relative/python").isValid)
        #expect(!LanguageServiceSettings(projects: ["/tmp/a": .init(interpreterPath: "/tmp/a\0python")]).isValid)
    }

    @Test func resolverHonorsProjectThenVenvThenDefaultAndPreservesSymlinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent(".venv/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let local = bin.appendingPathComponent("python").path
        try FileManager.default.createSymbolicLink(atPath: local, withDestinationPath: "/bin/sh")
        let rule = try await LanguagePluginFixtures.registration("python").service.interpreter
        var settings = LanguageServiceSettings(interpreterPath: "/bin/echo")
        #expect(try LanguageInterpreterResolver.resolve(rule: rule, settings: settings, root: root, searchPaths: []) == local)
        settings.projects[root.path] = .init(interpreterPath: "/bin/cat")
        #expect(try LanguageInterpreterResolver.resolve(rule: rule, settings: settings, root: root, searchPaths: []) == "/bin/cat")
        settings.projects[root.path] = .init(interpreterPath: root.appendingPathComponent("missing").path)
        #expect(throws: (any Error).self) { try LanguageInterpreterResolver.resolve(rule: rule, settings: settings, root: root, searchPaths: []) }
        settings.projects.removeAll()
        try FileManager.default.removeItem(atPath: local)
        #expect(try LanguageInterpreterResolver.resolve(rule: rule, settings: settings, root: root, searchPaths: []) == "/bin/echo")
        #expect(try LanguageInterpreterResolver.resolve(rule: rule, settings: .init(), root: root, searchPaths: []) == nil)
    }

    @Test(arguments: ["basedpyright", "pyright", "ty"])
    func pluginTemplatesUseTheServersActualInterpreterSetting(server: String) async throws {
        let registration = try await LanguagePluginFixtures.registration("python")
        let definition = try #require(registration.definition(serverID: server))
        let adapter = PluginLanguageServerAdapter(definition: definition, server: try #require(registration.service.servers.first { $0.id == server }),
            interpreterPath: "/tmp/probe/.venv/bin/python")
        let section = server == "ty" ? "ty.configuration.environment.python" : "python.pythonPath"
        #expect(adapter.configuration(section: section, scopeURI: nil, projectRoot: URL(fileURLWithPath: "/tmp/probe")) == .string("/tmp/probe/.venv/bin/python"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DUCKPAD_PYTHON_SERVERS_TEST_DIRECTORY"] != nil),
          arguments: ["basedpyright", "pyright", "ty"])
    @MainActor func realServersUseProjectEnvironmentAndReplaceItWhenSettingsChange(serverID: String) async throws {
        let tools = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["DUCKPAD_PYTHON_SERVERS_TEST_DIRECTORY"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-python-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "[project]\nname = \"probe\"\nversion = \"0.0.0\"\n".write(to: root.appendingPathComponent("pyproject.toml"), atomically: true, encoding: .utf8)
        let venv = root.appendingPathComponent(".venv"), other = root.appendingPathComponent("other-env")
        try Self.environment(at: venv, python: tools.appendingPathComponent("python"), member: "only_environment_a")
        try Self.environment(at: other, python: tools.appendingPathComponent("python"), member: "only_environment_b")
        for server in ["basedpyright-langserver", "pyright-langserver", "ty"] {
            try FileManager.default.createSymbolicLink(at: venv.appendingPathComponent("bin/" + server), withDestinationURL: tools.appendingPathComponent(server))
        }
        var url = root.appendingPathComponent("sample.py")
        let text = "from duckpad_probe import Widget\nwidget = Widget()\nwidget."
        try text.write(to: url, atomically: true, encoding: .utf8)
        let registration = try await LanguagePluginFixtures.registration("python")
        let registry = LanguageServerAdapterRegistry(registrations: [registration])
        var settings = LanguageServiceSettings(serverID: serverID, interpreterPath: other.appendingPathComponent("bin/python").path)
        let provider = LanguageServerCompletionProvider(registry: registry, settings: [registration.settingsKey: settings]) { _ in url }
        defer { provider.shutdown() }
        let capture = DocumentIntelligenceCapture(buffer: .init(bufferID: BufferID(), revision: 0),
            utf8: Data(text.utf8), caretUTF8: text.utf8.count, languageID: .init(rawValue: "python"), contextID: .init())
        let prefix = try #require(DocumentCompletionPrefix(capture))
        func labels() async throws -> [String] {
            let deadline = ContinuousClock.now.advanced(by: .seconds(12))
            while ContinuousClock.now < deadline {
                let values = try await provider.completions(in: capture, prefixRange: prefix.insertRange).map(\.label)
                if values.contains(where: { $0.hasPrefix("only_environment_") }) { return values }
                try await Task.sleep(for: .milliseconds(100))
            }
            return []
        }
        let initial = try await labels()
        #expect(initial.contains("only_environment_a"))
        #expect(!initial.contains("only_environment_b"))
        #expect(provider.context(for: url)?.serverID == serverID)
        #expect(provider.context(for: url)?.interpreterPath == venv.appendingPathComponent("bin/python").path)
        provider.update(registrations: [], settings: [registration.settingsKey: settings])
        #expect(provider.context(for: url) == nil)
        #expect(try await provider.completions(in: capture, prefixRange: prefix.insertRange).isEmpty)
        provider.update(registrations: [registration], settings: [registration.settingsKey: settings])
        #expect(try await labels().contains("only_environment_a"))
        let alternate = serverID == "ty" ? "basedpyright" : "ty"
        settings.projects[root.path] = .init(serverID: alternate, interpreterPath: other.appendingPathComponent("bin/python").path)
        #expect(provider.update(registrations: [registration], settings: [registration.settingsKey: settings]))
        #expect(provider.context(for: url) == nil)
        let changed = try await labels()
        #expect(changed.contains("only_environment_b"))
        #expect(!changed.contains("only_environment_a"))
        #expect(provider.context(for: url)?.serverID == alternate)
        // A nested Python project must not reuse its parent's interpreter/session.
        if serverID == "ty" {
            let nested = root.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try Data().write(to: nested.appendingPathComponent("pyproject.toml"))
            try FileManager.default.createSymbolicLink(at: nested.appendingPathComponent(".venv"), withDestinationURL: other)
            try FileManager.default.createSymbolicLink(at: other.appendingPathComponent("bin/ty"), withDestinationURL: tools.appendingPathComponent("ty"))
            url = nested.appendingPathComponent("sample.py")
            try text.write(to: url, atomically: true, encoding: .utf8)
            #expect(try await labels().contains("only_environment_b"))
            #expect(provider.context(for: url)?.rootPath == nested.path)
            url = root.appendingPathComponent("sample.py")
        }
        settings.projects[root.path]?.serverID = "disabled"
        provider.update(registrations: [registration], settings: [registration.settingsKey: settings])
        #expect(try await provider.completions(in: capture, prefixRange: prefix.insertRange).isEmpty)
        #expect(provider.context(for: url) == nil)
        #expect(!provider.failedServices.contains(registration.settingsKey))
        settings.projects[root.path] = .init(serverID: alternate, interpreterPath: root.appendingPathComponent("missing-python").path)
        provider.update(registrations: [registration], settings: [registration.settingsKey: settings])
        #expect(try await provider.completions(in: capture, prefixRange: prefix.insertRange).isEmpty)
        #expect(provider.failedServices.contains(registration.settingsKey))
        #expect(provider.update(registrations: [registration], settings: [registration.settingsKey: settings])) // Applying again retries after the user repairs installation.
    }

    static func environment(at root: URL, python: URL, member: String) throws {
        _ = try run(python, ["-m", "venv", "--without-pip", root.path])
        let purelib = try run(root.appendingPathComponent("bin/python"), ["-c", "import sysconfig; print(sysconfig.get_paths()['purelib'])"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let module = URL(fileURLWithPath: purelib).appendingPathComponent("duckpad_probe")
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        try "class Widget:\n    def \(member)(self) -> str: ...\n".write(to: module.appendingPathComponent("__init__.pyi"), atomically: true, encoding: .utf8)
    }
    private static func run(_ executable: URL, _ arguments: [String]) throws -> String {
        let task = Process(), output = Pipe()
        task.executableURL = executable; task.arguments = arguments; task.standardOutput = output
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        return String(decoding: data, as: UTF8.self)
    }
}
