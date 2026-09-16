import Foundation
import CryptoKit
import Testing
import DuckpadApplication
import DuckpadDomain
@testable import DuckpadInfrastructure

@Suite struct ExtensionUpdateInstallerTests {
    private let key = Curve25519.Signing.PrivateKey()
    private var fingerprint: String { SHA256.hash(data: key.publicKey.rawRepresentation).map { String(format: "%02x", $0) }.joined() }
    private func files(_ minor: UInt16) throws -> [String: Data] {
        let manifest = ExtensionManifest(id: .init(rawValue: "com.example.update"), name: "Update Fixture", version: .init(major: 1, minor: minor, patch: 0),
            api: .init(minimum: .init(major: 1, minor: 3, patch: 0), maximumExclusive: .init(major: 2, minor: 0, patch: 0)),
            publisher: .init(id: "com.example", keyID: "fixture"), runtime: .init(kind: "native", module: "module.dylib", abi: "duckpad-native-1"),
            capabilities: [.nativeCode, .pluginStorage, .uiList].map { .init(id: $0, scope: .application) },
            contributes: .init(commands: [.init(id: .init(rawValue: "com.example.update.show"), title: "Show", operation: 1, inputScope: .service)]))
        #if arch(arm64)
        let cpu: UInt8 = 12
        #else
        let cpu: UInt8 = 7
        #endif
        var files = ["plugin.json": try JSONEncoder().encode(manifest), "module.dylib": Data([0xcf, 0xfa, 0xed, 0xfe, cpu, 0, 0, 1])]
        let sums = files.keys.sorted().map { name in SHA256.hash(data: files[name]!).map { String(format: "%02x", $0) }.joined() + "  " + name + "\n" }.joined()
        files["SHA256SUMS"] = Data(sums.utf8)
        files["SIGNATURE.ed25519"] = Data(try key.signature(for: Data(("duckpad-extension-signature-v1\n" + sums).utf8)).base64EncodedString().utf8)
        return files
    }
    private func release(_ minor: UInt16) -> ExtensionUpdate {
        .init(extensionID: .init(rawValue: "com.example.update"), version: .init(major: 1, minor: minor, patch: 0), downloadURL: URL(string: "https://github.com/example/update/releases/download/v1.\(minor).0/plugin.zip")!, sha256: String(repeating: "0", count: 64), publisherID: "com.example", keyID: "fixture")
    }
    private func loader(_ root: URL) -> LocalExtensionPackageLoader {
        .init(root: root, bundledPackages: [], trustedKeys: [.init(publisherID: "com.example", keyID: "fixture", publicKey: key.publicKey.rawRepresentation, source: .userImported)])
    }
    @Test func installationKeepsOldVersionAndIsIdempotent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = loader(root)
        _ = try await loader.install(files: files(0))
        let service = ExtensionUpdateInstaller(loader: loader, nativeInstaller: { _ in })
        let prepared = try await service.prepare(release(1), files: files(1), publisherFingerprint: fingerprint)
        try await service.install(prepared)
        try await service.install(prepared)
        #expect((await loader.discover()).packages.map(\.manifest.version).sorted() == [release(0).version, release(1).version])
    }
    @Test func failedHelperLeavesOnlyOldRegistryVersion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = loader(root)
        let original = try await loader.install(files: files(0))
        let service = ExtensionUpdateInstaller(loader: loader, nativeInstaller: { _ in throw CocoaError(.fileWriteNoPermission) })
        let prepared = try await service.prepare(release(1), files: files(1), publisherFingerprint: fingerprint)
        await #expect(throws: (any Error).self) { try await service.install(prepared) }
        #expect((await loader.discover()).packages == [original])
    }
    @Test func rejectsTamperingPublisherAndReleaseMismatchBeforeInstallation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ExtensionUpdateInstaller(loader: loader(root), nativeInstaller: { _ in Issue.record("invalid package reached installer") })
        var invalid = try files(1); invalid["module.dylib"] = Data([0xcf, 0xfa, 0xed, 0xfe, 1])
        await #expect(throws: (any Error).self) { try await service.prepare(release(1), files: invalid, publisherFingerprint: fingerprint) }
        await #expect(throws: (any Error).self) { try await service.prepare(release(0), files: files(1), publisherFingerprint: fingerprint) }
        await #expect(throws: (any Error).self) { try await service.prepare(release(1), files: files(1), publisherFingerprint: "wrong") }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
