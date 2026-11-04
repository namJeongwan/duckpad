import Foundation
import Testing
import DuckpadApplication
import DuckpadDomain
import LanguageServerProtocol
@testable import DuckpadInfrastructure

struct LanguageServerAdapterTests {
    @Test(arguments: ["python", "ruby", "rust"])
    func signedOptionalLanguagePackagesRegisterAndRoundTrip(language: String) async throws {
        let registration = try await LanguagePluginFixtures.registration(language)
        try await LanguageServerRegistrationVerifier.verify(registration)
        let request = LanguageServerLaunchRequest(registration: registration, documentPath: "/tmp/sample")
        let decoded = try JSONDecoder().decode(LanguageServerLaunchRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded.isValid)
        #expect(decoded.registration == registration)
        #expect(decoded.command == registration.service.servers.first { $0.id == registration.service.defaultServerID }?.command)
        #expect(LanguageServerAdapterRegistry.empty.registration(forLanguageID: language) == nil)
    }
    @Test func ambiguousOwnersAreQuarantined() async throws {
        let python = try await LanguagePluginFixtures.registration("python"), rust = try await LanguagePluginFixtures.registration("rust")
        let registry = LanguageServerAdapterRegistry(registrations: [python, python, rust])
        #expect(registry.conflictingLanguages == ["python"])
        #expect(registry.registration(forLanguageID: "python") == nil)
        #expect(registry.registration(forLanguageID: "rust") == rust)
    }
    @Test func tamperingCannotInjectCommandsOrInterpreterRules() async throws {
        let good = try await LanguagePluginFixtures.registration("python")
        var files = good.packageFiles
        var manifest = try #require(JSONSerialization.jsonObject(with: files["plugin.json"]!) as? [String: Any])
        manifest["name"] = "tampered"
        files["plugin.json"] = try JSONSerialization.data(withJSONObject: manifest)
        let tampered = LanguageServerRegistration(extensionID: good.extensionID, packageDigest: good.packageDigest, service: good.service, packageFiles: files)
        await #expect(throws: (any Error).self) { try await LanguageServerRegistrationVerifier.verify(tampered) }
        let forgedService = LanguageServiceContribution(languageID: "python", displayName: "Python", defaultServerID: "injected",
            servers: [.init(id: "injected", command: ["sh", "-c", "exit"])], projectRootMarkers: [])
        let forged = LanguageServerRegistration(extensionID: good.extensionID, packageDigest: good.packageDigest, service: forgedService, packageFiles: good.packageFiles)
        await #expect(throws: (any Error).self) { try await LanguageServerRegistrationVerifier.verify(forged) }
        #expect(!LanguageServerLaunchRequest(registration: good, documentPath: "/tmp/test.py", serverID: "rust-analyzer").isValid)
    }
    @Test(arguments: ["python", "ruby", "rust"])
    func rootMarkersAreProvidedByTheLanguagePlugin(language: String) async throws {
        let registration = try await LanguagePluginFixtures.registration(language)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/nested"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(try #require(registration.service.projectRootMarkers.first)))
        let request = LanguageServerLaunchRequest(registration: registration, documentPath: root.appendingPathComponent("src/nested/file").path)
        #expect(LanguageServerProcessSession.projectRoot(for: request).path == root.path)
    }
    @Test func invalidManifestPathsAndUnboundedTemplatesAreRejected() throws {
        let server = LanguageServiceServer(id: "sample", command: ["sample-server"])
        #expect(!LanguageServiceContribution(languageID: "sample", displayName: "Sample", defaultServerID: "sample", servers: [server], projectRootMarkers: ["../outside"]).isValid)
        #expect(!LanguageServiceContribution(languageID: "sample", displayName: "Sample", defaultServerID: "missing", servers: [server], projectRootMarkers: []).isValid)
        #expect(!LanguageServiceValue.string("${unrecognized}").isValid())
    }
}
