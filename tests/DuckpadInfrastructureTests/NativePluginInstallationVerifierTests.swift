import Darwin
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import Foundation
import Testing

@Suite struct NativePluginInstallationVerifierTests {
    private struct Fixture {
        let root: URL
        let directory: URL
        let registration: ExtensionServiceRegistration
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
            let digest = String(repeating: "a", count: 64)
            directory = root.appendingPathComponent(digest + ".duckpad-plugin")
            let files = ["module.dylib": Data([1, 2, 3, 4]), "locale-en.strings": Data("resource".utf8)]
            registration = ExtensionServiceRegistration(command: .init(id: .init(rawValue: "com.test.show"), title: "Test", operation: 1, inputScope: .service), extensionID: .init(rawValue: "com.test"), publisherFingerprint: String(repeating: "b", count: 64), packageDigest: digest, capabilities: [.nativeCode], nativeFiles: files)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for (name, bytes) in files { try bytes.write(to: directory.appendingPathComponent(name)) }
        }
    }

    @Test func unchangedInstallationValidatesAndMissingInstallationRequestsInstall() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let verifier = LocalNativePluginInstallationVerifier()
        let verified = try await verifier.open(fixture.registration, root: fixture.root)
        #expect(verified.directory.path == fixture.directory.path)
        try verified.validateForLoading()
        await #expect(throws: NativePluginValidationFailure.installationRequired) {
            _ = try await verifier.open(fixture.registration, root: fixture.root.appendingPathComponent("missing"))
        }
    }

    @Test func sameSizeTamperingCannotReuseVerifiedSnapshot() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let verified = try await LocalNativePluginInstallationVerifier().open(fixture.registration, root: fixture.root)
        let file = fixture.directory.appendingPathComponent("module.dylib")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let writer = try FileHandle(forWritingTo: file)
        try writer.write(contentsOf: Data([4, 3, 2, 1]))
        try writer.close()
        try FileManager.default.setAttributes([.modificationDate: try #require(attributes[.modificationDate])], ofItemAtPath: file.path)
        #expect(throws: NativePluginValidationFailure.changedPackage) { try verified.validateForLoading() }
        await #expect(throws: NativePluginValidationFailure.changedPackage) {
            _ = try await LocalNativePluginInstallationVerifier().open(fixture.registration, root: fixture.root)
        }
    }

    @Test func replacingFileOrDirectoryInvalidatesPinnedSnapshot() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let verifier = LocalNativePluginInstallationVerifier()
        let verified = try await verifier.open(fixture.registration, root: fixture.root)
        let file = fixture.directory.appendingPathComponent("module.dylib")
        try FileManager.default.removeItem(at: file)
        try Data([1, 2, 3, 4]).write(to: file)
        #expect(throws: NativePluginValidationFailure.changedPackage) { try verified.validateForLoading() }
        let second = try await verifier.open(fixture.registration, root: fixture.root)
        try FileManager.default.moveItem(at: fixture.directory, to: fixture.root.appendingPathComponent("moved"))
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: false)
        #expect(throws: NativePluginValidationFailure.changedPackage) { try second.validateForLoading() }
    }

    @Test func rejectsSymlinkAndFIFOAndUnexpectedInventory() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let file = fixture.directory.appendingPathComponent("module.dylib")
        let verifier = LocalNativePluginInstallationVerifier()
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: fixture.directory.appendingPathComponent("locale-en.strings"))
        await #expect(throws: NativePluginValidationFailure.changedPackage) { _ = try await verifier.open(fixture.registration, root: fixture.root) }
        try FileManager.default.removeItem(at: file)
        #expect(mkfifo(file.path, 0o600) == 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            let writer = open(file.path, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
        }
        let start = ContinuousClock.now
        await #expect(throws: NativePluginValidationFailure.changedPackage) { _ = try await verifier.open(fixture.registration, root: fixture.root) }
        #expect(start.duration(to: .now) < .seconds(1))
        try FileManager.default.removeItem(at: file)
        try Data([1, 2, 3, 4]).write(to: file)
        try Data().write(to: fixture.directory.appendingPathComponent("unsigned"))
        await #expect(throws: NativePluginValidationFailure.changedPackage) { _ = try await verifier.open(fixture.registration, root: fixture.root) }
    }
}
