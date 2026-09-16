import Foundation

public enum NativePluginValidationFailure: Error, Sendable {
    case installationRequired, changedPackage
}

/// Pins the verified filesystem snapshot until the native adapter loads it.
/// The final check inspects metadata only; expensive byte comparisons happen
/// in the verifier before this value reaches the UI actor.
public protocol VerifiedNativePluginInstallation: Sendable {
    var directory: URL { get }
    func validateForLoading() throws
}

public protocol NativePluginInstallationVerifying: Sendable {
    func open(_ registration: ExtensionServiceRegistration, root: URL) async throws -> any VerifiedNativePluginInstallation
}
