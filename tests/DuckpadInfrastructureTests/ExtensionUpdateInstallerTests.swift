import Foundation
import CryptoKit
import Testing
@testable import DuckpadApplication
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
    private func item(_ package: LoadedExtensionPackage) -> ExtensionRegistryItem {
        .init(manifest: package.manifest, publisherFingerprint: package.publisherFingerprint,
            packageDigest: package.packageDigest, capabilitySchemaDigest: package.capabilitySchemaDigest,
            enabled: false, granted: [], issue: nil)
    }
    @Test func uninstallRemovesAllVersionsAndNativeCopiesButKeepsPluginData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = loader(root.appendingPathComponent("Extensions"))
        let old = try await loader.install(files: files(0))
        let new = try await loader.install(files: files(1))
        let native = root.appendingPathComponent("NativePluginModules")
        for package in [old, new] {
            let dir = native.appendingPathComponent(package.packageDigest + ".duckpad-plugin")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try package.module.write(to: dir.appendingPathComponent("module.dylib"))
        }
        let data = root.appendingPathComponent("PluginData")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: data.appendingPathComponent("history"))
        let installer = ExtensionUpdateInstaller(loader: loader, nativeStore: .init(root: native), nativeInstaller: { _ in })
        let prepared = try await installer.prepare(release(1), files: files(1), publisherFingerprint: fingerprint)
        try await installer.uninstall(item(new), stop: {})
        #expect((await loader.discover()).packages.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: native.path).isEmpty)
        #expect(try Data(contentsOf: data.appendingPathComponent("history")) == Data("keep".utf8))
        // A previously prepared update must not resurrect the uninstalled plugin.
        await #expect(throws: ExtensionFailure.self) { try await installer.install(prepared) }
        // An intentional new install still works after the removal completes.
        let fresh = try await installer.prepare(release(1), files: files(1), publisherFingerprint: fingerprint)
        try await installer.install(fresh)
        #expect((await loader.discover()).packages.count == 1)
    }
    @Test func uninstallFindsManuallyNamedPackagesByManifest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = loader(root)
        let package = try await loader.install(files: files(0))
        try FileManager.default.moveItem(at: root.appendingPathComponent("com.example.update@1.0.0.duckpad-plugin"),
            to: root.appendingPathComponent("Clipboard.duckpad-plugin"))
        let unrelated = root.appendingPathComponent("Broken.duckpad-plugin")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        let installer = ExtensionUpdateInstaller(loader: loader, nativeStore: .init(root: root.appendingPathComponent("Native")), nativeInstaller: { _ in })
        try await installer.uninstall(item(package), stop: {})
        #expect((await loader.discover()).packages.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Clipboard.duckpad-plugin").path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }
    @Test func stopFailureLeavesInstallationIntactAndReleasesRemovalGate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = loader(root)
        let package = try await loader.install(files: files(0))
        let installer = ExtensionUpdateInstaller(loader: loader, nativeInstaller: { _ in })
        await #expect(throws: (any Error).self) {
            try await installer.uninstall(item(package), stop: { throw CocoaError(.fileWriteNoPermission) })
        }
        #expect((await loader.discover()).packages == [package])
        _ = try await loader.installationGeneration(for: package.manifest.id)
    }
    @Test func rejectsUninstallingBundledPluginOrFollowingPackageSymlink() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = LocalExtensionPackageLoader(root: root)
        let package = try #require(await bundled.discover().packages.first)
        try await bundled.beginRemoval(package.manifest.id)
        await #expect(throws: ExtensionFailure.self) {
            try await bundled.uninstall(package.manifest.id, publisherFingerprint: package.publisherFingerprint)
        }
        await bundled.endRemoval(package.manifest.id)
        #expect((await bundled.discover()).packages.contains(package))
        let custom = loader(root)
        let installed = try await custom.install(files: files(0))
        let target = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: target.appendingPathComponent("data"))
        let path = root.appendingPathComponent("com.example.update@1.0.0.duckpad-plugin")
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
        try await custom.beginRemoval(installed.manifest.id)
        await #expect(throws: ExtensionFailure.self) { try await custom.uninstall(installed.manifest.id, publisherFingerprint: fingerprint) }
        #expect(try Data(contentsOf: target.appendingPathComponent("data")) == Data("keep".utf8))
    }

}
