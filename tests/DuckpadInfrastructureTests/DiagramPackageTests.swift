import Foundation
import Testing
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure

/// Optional artifact check: uses the production loader, never installs or enables a package.
@Test(.enabled(if: ProcessInfo.processInfo.environment["DUCKPAD_D2_PACKAGE"] != nil &&
                      ProcessInfo.processInfo.environment["DUCKPAD_MERMAID_PACKAGE"] != nil))
func nativeDiagramPackagesPassHostSignatureInventoryAndCompatibility() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("diagram-packages-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let loader = LocalExtensionPackageLoader(root: root, bundledPackages: [])
    for (variable, id) in [("DUCKPAD_D2_PACKAGE", "com.duckpad.d2"), ("DUCKPAD_MERMAID_PACKAGE", "com.duckpad.mermaid")] {
        let path = try #require(ProcessInfo.processInfo.environment[variable])
        let (package, files) = try await loader.readPackage(at: URL(fileURLWithPath: path))
        #expect(package.manifest.id.rawValue == id)
        #expect(package.manifest.api.contains(ExtensionWorkspaceUseCase.apiVersion))
        #expect(files["module.dylib"]?.isEmpty == false)
        #expect(!files.keys.contains { $0.hasSuffix(".js") })
        if id == "com.duckpad.d2" {
            #expect(!package.manifest.api.contains(SemanticVersion(major: 1, minor: 5, patch: 0)))
        }
    }
}
