import Foundation
import Testing
import DuckpadApplication
import DuckpadDomain
import LanguageServerProtocol
@testable import DuckpadInfrastructure

@Suite(.serialized) struct CompletionInfrastructureTests {
    @Test func codeMirrorMatcherRanksPrefixesWordBoundariesAndUnicode() async {
        let matcher = CodeMirrorCompletionMatcher()
        let candidates = ["user_name", "user_email", "getUserName", "updateName", "résumé", "한글이름"]
        let prefix = await matcher.matches("user_n", candidates: candidates, limit: 20)
        #expect(prefix.first?.index == 0)
        let abbreviation = await matcher.matches("un", candidates: candidates, limit: 20)
        #expect(abbreviation.contains { $0.index == 0 })
        #expect(abbreviation.contains { $0.index == 3 })
        #expect(abbreviation.allSatisfy { !$0.ranges.isEmpty })
        #expect(await matcher.matches("re", candidates: candidates, limit: 20).first?.index == 4)
        #expect(await matcher.matches("한글", candidates: candidates, limit: 20).first?.index == 5)
    }

    @Test func lspPositionsRoundTripEmojiKoreanAndMixedLineEndings() throws {
        let text = "한🙂x\r\né\r끝\n"
        let coordinates = LSPTextCoordinates(Data(text.utf8))
        #expect(coordinates.position(7) == Position(line: 0, character: 3))
        #expect(coordinates.offset(.init(line: 0, character: 3)) == 7)
        #expect(coordinates.offset(.init(line: 0, character: 2)) == nil)
        #expect(coordinates.position(2) == nil)
        #expect(coordinates.offset(.init(line: 1, character: 1)) == 12)
        #expect(coordinates.offset(.init(line: 9, character: 0)) == nil)
        #expect(coordinates.position(text.utf8.count) == Position(line: 3, character: 0))
    }

    @Test @MainActor func completionLabelDetailsPreserveParametersAndOrigin() throws {
        let item = CompletionItem(label: "aggregate", labelDetails: .init(detail: "(func, axis=0)", description: "DataFrame"), kind: .method)
        let value = try #require(LanguageServerCompletionProvider.suggestion(item, coordinates: .init(Data("df.ag".utf8)),
            caret: 5, prefixRange: .init(location: 3, length: 2)))
        #expect(value.detail == "(func, axis=0) · DataFrame")
    }

    @Test @MainActor func wordIndexTracksInsertDeleteAndUndoWithoutLosingOtherOccurrences() async {
        let index = DocumentCompletionWordIndex(), buffer = BufferID()
        var text = "alpha alpha beta\n한글이름"
        func capture(_ revision: UInt64) -> DocumentIntelligenceCapture {
            .init(buffer: .init(bufferID: buffer, revision: revision), utf8: Data(text.utf8),
                  caretUTF8: text.utf8.count, languageID: .plainText, contextID: .init())
        }
        #expect(Set(await index.terms(in: capture(0))) == ["alpha", "beta", "한글이름"])
        index.apply(.init(bufferID: buffer, expectedRevision: 0, range: .init(location: 0, length: 6), replacement: ""))
        text = "alpha beta\n한글이름"
        #expect(Set(await index.terms(in: capture(1))) == ["alpha", "beta", "한글이름"])
        index.apply(.init(bufferID: buffer, expectedRevision: 1, range: .init(location: 0, length: 6), replacement: ""))
        text = "beta\n한글이름"
        #expect(Set(await index.terms(in: capture(2))) == ["beta", "한글이름"])
        index.apply(.init(bufferID: buffer, expectedRevision: 2, range: .init(location: 0, length: 0), replacement: "alpha "))
        text = "alpha beta\n한글이름"
        #expect(Set(await index.terms(in: capture(3))) == ["alpha", "beta", "한글이름"])
    }

    @Test func launchPresetsAreRestrictedAndDetectProjectRoots() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/nested"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Cargo.toml"))
        let request = LanguageServerLaunchRequest(registration: try await LanguagePluginFixtures.registration("rust"), documentPath: root.appendingPathComponent("src/nested/main.rs").path)
        #expect(request.isValid)
        #expect(request.command == ["rust-analyzer"])
        #expect(LanguageServerProcessSession.projectRoot(for: request).path == root.path)
        #expect(!LanguageServerLaunchRequest(registration: try await LanguagePluginFixtures.registration("rust"), documentPath: "/tmp/test", serverID: "shell").isValid)
        #expect(!LanguageServerLaunchRequest(registration: try await LanguagePluginFixtures.registration("python"), documentPath: "relative.py").isValid)
    }

    @Test @MainActor
    func languageClientSynchronizesDocumentsAnswersRequestsAndResolvesImports() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-lsp-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent(".venv/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("pyproject.toml"))
        let script = bin.appendingPathComponent("basedpyright-langserver")
        try Self.serverFixture
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let buffer = BufferID(), context = DocumentIntelligenceContextID()
        let registry = try await LanguagePluginFixtures.registry("python")
        let provider = LanguageServerCompletionProvider(registry: registry) { _ in root.appendingPathComponent("sample.py") }
        defer { provider.shutdown() }
        var text = "#한🙂\r\npri"
        func capture(_ revision: UInt64) -> DocumentIntelligenceCapture {
            .init(buffer: .init(bufferID: buffer, revision: revision), utf8: Data(text.utf8), caretUTF8: text.utf8.count,
                  languageID: .init(rawValue: "python"), contextID: context)
        }
        let first = capture(0), prefix = try #require(DocumentCompletionPrefix(first))
        let suggestions = try await provider.completions(in: first, prefixRange: prefix.insertRange)
        let suggestion = try #require(suggestions.first)
        #expect(suggestion.label == "print")
        #expect(suggestion.insertRange == prefix.insertRange)
        let resolved = try #require(await provider.resolve(suggestion, capture: first))
        #expect(resolved.documentation == "Resolved documentation")
        #expect(resolved.additionalEdits.count == 1)
        #expect(resolved.additionalEdits.first?.range.location == 0)
        text += "n"
        let next = capture(1)
        let updated = try await provider.completions(in: next, prefixRange: try #require(DocumentCompletionPrefix(next)).insertRange)
        #expect(updated.first?.detail == "version 2: prin")
        #expect(updated.first?.insertRange.length == 4)
        provider.update(registrations: [], settings: [:])
        #expect(await provider.resolve(resolved, capture: first) == nil)
        #expect(try await provider.completions(in: next, prefixRange: try #require(DocumentCompletionPrefix(next)).insertRange).isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DUCKPAD_PYRIGHT_TEST_EXECUTABLE"] != nil))
    @MainActor func realPyrightProvidesStringMembersAndDocumentation() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["DUCKPAD_PYRIGHT_TEST_EXECUTABLE"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-pyright-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent(".venv/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("pyright-langserver").path, withDestinationPath: executable)
        try "[project]\nname = \"completion-test\"\nversion = \"0.0.0\"\n".write(to: root.appendingPathComponent("pyproject.toml"), atomically: true, encoding: .utf8)
        let url = root.appendingPathComponent("sample.py")
        var text = "user_name = \"Duckpad\"\nuser_email = \"duck@example.com\"\nus"
        try text.write(to: url, atomically: true, encoding: .utf8)
        let registration = try await LanguagePluginFixtures.registration("python")
        let registry = LanguageServerAdapterRegistry(registrations: [registration])
        let provider = LanguageServerCompletionProvider(registry: registry, settings: [registration.settingsKey: .init(serverID: "pyright")]) { _ in url }
        defer { provider.shutdown() }
        let buffer = BufferID(), context = DocumentIntelligenceContextID()
        func capture(_ revision: UInt64) -> DocumentIntelligenceCapture {
            .init(buffer: .init(bufferID: buffer, revision: revision), utf8: Data(text.utf8), caretUTF8: text.utf8.count,
                  languageID: .init(rawValue: "python"), contextID: context)
        }
        let first = capture(0)
        let names = try await provider.completions(in: first, prefixRange: try #require(DocumentCompletionPrefix(first)).insertRange)
        #expect(names.contains { $0.label == "user_name" })
        text += "er_name."
        let next = capture(1)
        let members = try await provider.completions(in: next, prefixRange: try #require(DocumentCompletionPrefix(next)).insertRange)
        let upper = try #require(members.first { $0.label == "upper" })
        let resolved = try #require(await provider.resolve(upper, capture: next))
        #expect(!resolved.documentation.isEmpty)
        #expect(resolved.source == .languageServer)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DUCKPAD_RUST_ANALYZER_TEST_EXECUTABLE"] != nil))
    @MainActor func realRustAnalyzerCompletesProjectFunctions() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["DUCKPAD_RUST_ANALYZER_TEST_EXECUTABLE"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-rust-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = try await LanguagePluginFixtures.registration("rust")
        let bin = root.appendingPathComponent(try #require(registration.service.projectExecutableDirectories.first))
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("rust-analyzer").path, withDestinationPath: executable)
        try "[package]\nname = \"duckpad_completion_test\"\nversion = \"0.0.0\"\nedition = \"2021\"\n".write(to: root.appendingPathComponent("Cargo.toml"), atomically: true, encoding: .utf8)
        let text = "fn paddle() {}\nfn main() { padd }\n", url = root.appendingPathComponent("src/main.rs")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let end = try #require(text.range(of: "padd", options: .backwards)).upperBound
        let capture = DocumentIntelligenceCapture(buffer: .init(bufferID: BufferID(), revision: 0), utf8: Data(text.utf8),
            caretUTF8: text[..<end].utf8.count, languageID: .init(rawValue: "rust"), contextID: .init())
        let provider = LanguageServerCompletionProvider(registry: try await LanguagePluginFixtures.registry(capture.languageID.rawValue)) { _ in url }
        defer { provider.shutdown() }
        var suggestions: [DocumentCompletionSuggestion] = []
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(12))
        repeat {
            suggestions = try await provider.completions(in: capture, prefixRange: try #require(DocumentCompletionPrefix(capture)).insertRange)
            if suggestions.contains(where: { $0.label.hasPrefix("paddle") }) { break }
            try await Task.sleep(for: .milliseconds(300))
        } while clock.now < deadline
        #expect(suggestions.contains { $0.label.hasPrefix("paddle") })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DUCKPAD_RUBY_LSP_TEST_EXECUTABLE"] != nil))
    @MainActor func realRubyLspCompletesProjectMethods() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["DUCKPAD_RUBY_LSP_TEST_EXECUTABLE"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-ruby-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let registration = try await LanguagePluginFixtures.registration("ruby")
        let bin = root.appendingPathComponent(try #require(registration.service.projectExecutableDirectories.first))
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("ruby-lsp").path, withDestinationPath: executable)
        try "source 'https://rubygems.org'\ngem 'ruby-lsp'\n".write(to: root.appendingPathComponent("Gemfile"), atomically: true, encoding: .utf8)
        let bundler = Process()
        bundler.executableURL = URL(fileURLWithPath: executable).deletingLastPathComponent().appendingPathComponent("bundle")
        bundler.arguments = ["lock", "--local"]
        bundler.currentDirectoryURL = root
        bundler.standardOutput = FileHandle.nullDevice
        try bundler.run(); bundler.waitUntilExit()
        #expect(bundler.terminationStatus == 0)
        let text = "class Duck\n  def paddle; end\nend\nDuck.new.pa", url = root.appendingPathComponent("sample.rb")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let capture = DocumentIntelligenceCapture(buffer: .init(bufferID: BufferID(), revision: 0), utf8: Data(text.utf8),
            caretUTF8: text.utf8.count, languageID: .init(rawValue: "ruby"), contextID: .init())
        let provider = LanguageServerCompletionProvider(registry: try await LanguagePluginFixtures.registry(capture.languageID.rawValue)) { _ in url }
        defer { provider.shutdown() }
        var suggestions: [DocumentCompletionSuggestion] = []
        for _ in 0..<5 {
            suggestions = try await provider.completions(in: capture, prefixRange: try #require(DocumentCompletionPrefix(capture)).insertRange)
            if suggestions.contains(where: { $0.label == "paddle" }) { break }
            try await Task.sleep(for: .milliseconds(300))
        }
        #expect(suggestions.contains { $0.label == "paddle" })
    }

    @Test @MainActor func disablingAPluginRejectsAnInFlightCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-plugin-pending-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent(".venv/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("pyproject.toml"))
        let script = bin.appendingPathComponent("basedpyright-langserver")
        let fixture = Self.serverFixture.replacingOccurrences(of: "import sys, json", with: "import sys, json, time")
            .replacingOccurrences(of: "pending = message", with: "pending = message\n        open(root_path + '/request-started', 'w').close()\n        time.sleep(1)")
        try fixture.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let provider = LanguageServerCompletionProvider(registry: try await LanguagePluginFixtures.registry("python")) { _ in root.appendingPathComponent("sample.py") }
        defer { provider.shutdown() }
        let text = "#한🙂\r\npri"
        let capture = DocumentIntelligenceCapture(buffer: .init(bufferID: BufferID(), revision: 0), utf8: Data(text.utf8),
            caretUTF8: text.utf8.count, languageID: .init(rawValue: "python"), contextID: .init())
        let prefix = try #require(DocumentCompletionPrefix(capture))
        let task = Task { try await provider.completions(in: capture, prefixRange: prefix.insertRange) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("request-started").path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("request-started").path))
        var invalidated = false
        provider.onInvalidation = { invalidated = true }
        provider.update(registrations: [], settings: [:])
        #expect(invalidated)
        #expect(try await task.value.isEmpty)
        #expect(provider.registrations.isEmpty)
    }

    private static let serverFixture = #"""
#!/usr/bin/env python3
import sys, json
text = ""
version = 0
pending = None
root_path = ""
document_uri = ""
def send(value):
    data = json.dumps(value, ensure_ascii=False).encode()
    sys.stdout.buffer.write(b"Content-Length: " + str(len(data)).encode() + b"\r\n\r\n" + data)
    sys.stdout.buffer.flush()
def response(identifier, result):
    send({"jsonrpc":"2.0", "id":identifier, "result":result})
while True:
    length = 0
    while True:
        line = sys.stdin.buffer.readline()
        if not line: sys.exit(0)
        if line == b"\r\n": break
        if line.lower().startswith(b"content-length:"): length = int(line.split(b":")[1])
    message = json.loads(sys.stdin.buffer.read(length))
    method = message.get("method")
    params = message.get("params", {})
    if method == "initialize":
        assert params["capabilities"]["textDocument"]["completion"]["completionItem"]["snippetSupport"] is False
        root_path = params["rootPath"]
        assert params.get("initializationOptions") is None
        response(message["id"], {"capabilities":{"textDocumentSync":2, "completionProvider":{"resolveProvider":True}}})
    elif method == "textDocument/didOpen":
        text = params["textDocument"]["text"]
        version = params["textDocument"]["version"]
        document_uri = params["textDocument"]["uri"]
    elif method == "textDocument/didChange":
        assert params["contentChanges"][0]["range"]["start"] == {"line":0,"character":0}
        text = params["contentChanges"][0]["text"]
        version = params["textDocument"]["version"]
    elif method == "textDocument/completion":
        pending = message
        send({"jsonrpc":"2.0", "id":"configuration", "method":"workspace/configuration", "params":{"items":[{"section":"python", "scopeUri":document_uri}]}})
    elif message.get("id") == "configuration":
        assert isinstance(message["result"][0]["pythonPath"], str)
        position = pending["params"]["position"]
        assert position["line"] == 1
        response(pending["id"], [{"label":"print", "kind":3, "detail":"version %d: %s" % (version, text.splitlines()[-1]),
            "textEdit":{"range":{"start":{"line":1,"character":0},"end":position},"newText":"print"},"data":{"resolve":True}}])
    elif method == "completionItem/resolve":
        params["documentation"] = "Resolved documentation"
        params["additionalTextEdits"] = [{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"newText":"import example\n"}]
        response(message["id"], params)
    elif method == "shutdown": response(message["id"], None)
    elif method == "exit": break
"""#
}
