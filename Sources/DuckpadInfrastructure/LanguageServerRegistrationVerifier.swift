import Foundation
import DuckpadApplication
import DuckpadDomain

public enum LanguageServerRegistrationVerifier {
    public static func verify(_ registration: LanguageServerRegistration) async throws {
        // No filesystem path or manifest supplied outside the signed inventory
        // can choose a command, settings template, or environment search rule.
        let loader = LocalExtensionPackageLoader(root: FileManager.default.temporaryDirectory, bundledPackages: [])
        let package = try await loader.verify(files: registration.packageFiles)
        guard package.manifest.runtime.kind == "language-provider", package.manifest.id == registration.extensionID,
              package.packageDigest == registration.packageDigest,
              package.manifest.api.contains(ExtensionWorkspaceUseCase.apiVersion),
              package.manifest.contributes.languageServices.contains(registration.service) else { throw ExtensionFailure.signatureMismatch }
    }
}
