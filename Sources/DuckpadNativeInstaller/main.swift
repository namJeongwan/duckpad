import Foundation
import Darwin
import DuckpadInfrastructure
import DuckpadPluginSupport

private final class Reply: @unchecked Sendable {
    let send: (String?, String?) -> Void
    init(_ send: @escaping (String?, String?) -> Void) { self.send = send }
}

private final class Installer: NSObject, DuckpadNativeInstallerProtocol {
    let store: ManagedNativePackageStore
    init(root: URL) { store = ManagedNativePackageStore(root: root) }
    func install(_ signedFiles: Data, withReply reply: @escaping (String?, String?) -> Void) {
        guard signedFiles.count <= NativeInstallerXPC.maximumFrameBytes else { reply(nil, "package exceeds limit"); return }
        let reply = Reply(reply)
        let store = store
        Task {
            do {
                let files = try JSONDecoder().decode([String: Data].self, from: signedFiles)
                let digest = try await store.install(files: files)
                reply.send(digest, nil)
            } catch { reply.send(nil, String(describing: error)) }
        }
    }
}

private final class Listener: NSObject, NSXPCListenerDelegate {
    let requirement: String
    let installer: Installer
    init(configure: Void) throws {
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard Bundle(url: app)?.bundleIdentifier == "com.namjeongwan.duckpad", getuid() == geteuid(), getuid() != 0 else { throw CocoaError(.executableNotLoadable) }
        requirement = try NativeInstallerXPC.requirement(for: app, matchingSignerOf: Bundle.main.bundleURL)
        guard let account = getpwuid(getuid()) else { throw CocoaError(.fileNoSuchFile) }
        let home = URL(fileURLWithPath: String(cString: account.pointee.pw_dir), isDirectory: true)
        let root = home.appendingPathComponent("Library/Containers/com.namjeongwan.duckpad/Data/Library/Application Support/Duckpad/NativePluginModules", isDirectory: true)
        installer = Installer(root: root)
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == geteuid() else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: DuckpadNativeInstallerProtocol.self)
        connection.exportedObject = installer
        connection.resume()
        return true
    }
}

do {
    let delegate = try Listener(configure: ())
    let listener = NSXPCListener.service()
    listener.delegate = delegate
    withExtendedLifetime(delegate) { listener.resume() }
} catch {
    fputs("Native installer could not initialize.\n", stderr)
    exit(1)
}
