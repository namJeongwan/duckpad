import Foundation
import DuckpadApplication
import DuckpadPluginSupport

/// Resolves project scopes even when only the current document has sandbox access.
@MainActor public enum LanguageServerProjectRootResolver {
    public static func resolve(_ document: URL, registration: LanguageServerRegistration) async -> URL? {
        let request = LanguageServerLaunchRequest(registration: registration, documentPath: document.path)
        guard request.isValid else { return nil }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            guard (try? await LanguageServerRegistrationVerifier.verify(registration)) != nil else { return nil }
            return LanguageServerProcessSession.projectRoot(for: request)
        }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/DuckpadTerminalHost.xpc")
        guard let requirement = try? NativeInstallerXPC.requirement(for: helper, matchingSignerOf: Bundle.main.bundleURL),
              let data = try? JSONEncoder().encode(request) else { return nil }
        let connection = NSXPCConnection(serviceName: TerminalHostXPC.identifier)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: DuckpadTerminalHostProtocol.self)
        connection.resume()
        defer { connection.invalidate() }
        return await withCheckedContinuation { continuation in
            var completed = false
            let finish: @MainActor (String?) -> Void = { path in
                guard !completed else { return }; completed = true
                continuation.resume(returning: path.map { URL(fileURLWithPath: $0) })
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable _ in Task { @MainActor in finish(nil) } } as? DuckpadTerminalHostProtocol
            proxy?.languageServerProjectRoot(data) { path in Task { @MainActor in finish(path) } }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                finish(nil)
            }
        }
    }
}
