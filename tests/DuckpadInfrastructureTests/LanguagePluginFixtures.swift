import Foundation
import DuckpadDomain
import DuckpadApplication
import DuckpadInfrastructure
import Testing

enum LanguagePluginFixtures {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("LanguagePlugins")
    static func package(_ language: String) async throws -> LoadedExtensionPackage {
        let loader = LocalExtensionPackageLoader(root: FileManager.default.temporaryDirectory)
        return try await loader.readPackage(at: root.appendingPathComponent("com.duckpad.\(language).duckpad-plugin")).0
    }
    static func registration(_ language: String) async throws -> LanguageServerRegistration {
        let package = try await package(language)
        return .init(extensionID: package.manifest.id, packageDigest: package.packageDigest,
            service: try #require(package.manifest.contributes.languageServices.first), packageFiles: try #require(package.languageServiceFiles))
    }
    static func registry(_ language: String) async throws -> LanguageServerAdapterRegistry {
        .init(registrations: [try await registration(language)])
    }
}
