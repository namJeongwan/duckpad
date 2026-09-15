import CryptoKit
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import DuckpadPluginRuntimeCore
import Foundation
import Testing

@Suite(.serialized) struct ExtensionServiceIntegrationTests {
    @Test func actualClipboardGuestPreservesStateAndReturnsNoDocumentEdits() throws {
        guard let path = ProcessInfo.processInfo.environment["DUCKPAD_CLIPBOARD_PLUGIN_MODULE"] else {
            print("SKIP: build the separate clipboard plugin and set DUCKPAD_CLIPBOARD_PLUGIN_MODULE")
            return
        }
        let module = try Data(contentsOf: URL(fileURLWithPath: path))
        func run(state: Data, event: String, payload: String = "", query: String = "", now: Date = Date()) throws -> ExtensionListProtocol.Response {
            let input = try ExtensionListProtocol.request(state: state, event: event, payload: payload, query: query, now: now)
            let request = ExtensionHostRequest(module: module, context: .init(
                extensionID: .init(rawValue: "com.duckpad.clipboard-history"), commandID: .init(rawValue: "com.duckpad.clipboard-history.show"),
                operation: 1, inputScope: .service, tabID: TabID(), bufferID: BufferID(), revision: 0,
                selection: .init(location: 0, length: 0), utf8: input), limits: .init())
            let originalModule = [UInt8](module)
            let response = PluginRuntimeExecutor.response(for: request)
            #expect([UInt8](module) == originalModule)
            #expect(response.result == nil)
            #expect(response.failure == nil)
            return try ExtensionListProtocol.response(#require(response.serviceOutput))
        }
        let original = "  한글\n    Rust text\n"
        let captured = try run(state: Data(), event: "capture", payload: original)
        #expect(captured.rows.count == 1)
        let pinned = try run(state: captured.state, event: "pin", payload: captured.rows[0].id)
        #expect(pinned.rows[0].pinned)
        let restored = try run(state: pinned.state, event: "query", query: "RUST")
        #expect(restored.rows.count == 1)
        let selected = try run(state: restored.state, event: "select", payload: restored.rows[0].id)
        #expect(selected.selectedText == original)
        let preview = try run(state: restored.state, event: "preview", payload: restored.rows[0].id)
        #expect(preview.selectedText == original)
        #expect(preview.state == restored.state)
        #expect(try run(state: selected.state, event: "clear").rows.isEmpty)
        let start = Date(timeIntervalSince1970: 10_000_000)
        let timed = try run(state: Data(), event: "capture", payload: "expires", now: start)
        let period = try run(state: timed.state, event: "retention", payload: "1", now: start)
        #expect(period.retentionDays == 1)
        let expired = try run(state: period.state, event: "select", payload: timed.rows[0].id, now: start.addingTimeInterval(86_400))
        #expect(expired.rows.isEmpty && expired.selectedText.isEmpty)
        #expect(expired.retentionDays == 1)
    }
    @Test func signedClipboardPackageInstallsAndCannotReplaceExistingVersion() async throws {
        guard let path = ProcessInfo.processInfo.environment["DUCKPAD_CLIPBOARD_PLUGIN_MODULE"] else { return }
        let source = URL(fileURLWithPath: path).deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("input.duckpad-plugin")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        for name in ["module.wasm", "plugin.json", "SHA256SUMS"] {
            try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: package.appendingPathComponent(name))
        }
        let key = Curve25519.Signing.PrivateKey()
        var signed = Data("duckpad-extension-signature-v1\n".utf8)
        signed.append(try Data(contentsOf: package.appendingPathComponent("SHA256SUMS")))
        try Data(key.signature(for: signed).base64EncodedString().utf8).write(to: package.appendingPathComponent("SIGNATURE.ed25519"))
        let destination = root.appendingPathComponent("Extensions")
        let loader = LocalExtensionPackageLoader(root: destination, bundledPackages: [], trustedKeys: [
            .init(publisherID: "com.duckpad", keyID: "clipboard-release-1", publicKey: key.publicKey.rawRepresentation, source: .userImported)
        ])
        try await loader.install(from: package)
        let installed = await loader.discover()
        #expect(installed.failures.isEmpty)
        #expect(installed.packages.count == 1)
        #expect(installed.packages.first?.manifest.contributes.commands.first?.inputScope == .service)
        await #expect(throws: (any Error).self) { try await loader.install(from: package) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).count == 1)
        try Data("tampered".utf8).write(to: package.appendingPathComponent("module.wasm"))
        await #expect(throws: (any Error).self) { try await loader.install(from: package) }
        #expect((await loader.discover()).packages.count == 1)
    }
    @Test func locallySignedClipboardPackageUsesProductionTrust() async throws {
        guard let path = ProcessInfo.processInfo.environment["DUCKPAD_SIGNED_CLIPBOARD_PACKAGE"] else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = LocalExtensionPackageLoader(root: root, bundledPackages: [])
        try await loader.install(from: URL(fileURLWithPath: path))
        let report = await loader.discover()
        #expect(report.failures.isEmpty)
        #expect(report.packages.count == 1)
        #expect(report.packages.first?.trustSource == .userImported)
        #expect(report.packages.first?.manifest.publisher.keyID == "clipboard-release-1")
    }
    @Test func privateStatePersistsAndRejectsSymlinksAndOversize() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = ExtensionServiceRegistration(command: .init(id: .init(rawValue: "com.test.show"), title: "Test", operation: 1, inputScope: .service),
            extensionID: .init(rawValue: "com.test"), publisherFingerprint: String(repeating: "a", count: 64), packageDigest: "digest", capabilities: [.pluginStorage, .uiList])
        let storage = LocalExtensionServiceStorage(root: root)
        let data = Data([0, 255, 10])
        try await storage.save(data, for: identity)
        #expect(try await LocalExtensionServiceStorage(root: root).load(identity) == data)
        let sibling = ExtensionServiceRegistration(command: .init(id: .init(rawValue: "com.test.other"), title: "Other", operation: 2, inputScope: .service), extensionID: identity.extensionID, publisherFingerprint: identity.publisherFingerprint, packageDigest: identity.packageDigest, capabilities: identity.capabilities)
        try await storage.save(Data([42]), for: sibling)
        #expect(try await storage.load(identity) == data)
        #expect(try await storage.load(sibling) == Data([42]))
        let commandHash = SHA256.hash(data: Data(identity.command.id.rawValue.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = root.appendingPathComponent("com.test").appendingPathComponent(identity.publisherFingerprint).appendingPathComponent(commandHash).appendingPathComponent("state.bin")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        await #expect(throws: (any Error).self) { try await storage.save(Data(count: ExtensionListProtocol.maximumStateBytes + 1), for: identity) }
        #expect(try await storage.load(identity) == data)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("missing"))
        await #expect(throws: (any Error).self) { _ = try await storage.load(identity) }
    }
    @Test func listProtocolRejectsFieldsThatWouldExhaustNextRequest() throws {
        #expect(throws: (any Error).self) { _ = try ExtensionListProtocol.request(state: Data(count: ExtensionListProtocol.maximumStateBytes+1), event: "query") }
        #expect(throws: (any Error).self) { _ = try ExtensionListProtocol.request(state: Data(), event: "capture", payload: String(repeating:"x", count:ExtensionListProtocol.maximumPayloadBytes+1)) }
        #expect(throws: (any Error).self) { _ = try ExtensionListProtocol.response(Data([1, 0, 0, 0, 255, 255, 255, 255])) }
    }
}
