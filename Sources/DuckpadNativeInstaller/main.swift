import Foundation
import Darwin
import XPC
import DuckpadInfrastructure
import DuckpadPluginSupport

private final class Reply: @unchecked Sendable {
    let send: (String?, String?) -> Void
    init(_ send: @escaping (String?, String?) -> Void) { self.send = send }
}

private final class Installer: NSObject, DuckpadNativeInstallerProtocol {
    let store: ManagedNativePackageStore
    let terminalCommand: TerminalCommandInstaller
    let plantUML: PlantUMLRuntime
    let renderWork = PlantUMLWork()
    init(root: URL, home: URL, app: URL) {
        store = ManagedNativePackageStore(root: root)
        terminalCommand = TerminalCommandInstaller(home: home, app: app)
        plantUML = PlantUMLRuntime(root: home.appendingPathComponent("Library/Application Support/Duckpad/PlantUMLRuntime")) { active in
            // Replies end their automatic transaction. Retain the helper while its reusable JVM is idle.
            if active { xpc_transaction_begin() } else { xpc_transaction_end() }
        }
    }
    init(copying other: Installer) {
        store = other.store; terminalCommand = other.terminalCommand; plantUML = other.plantUML
    }
    func renderPlantUML(_ request: Data, withReply reply: @escaping (Data?, String?) -> Void) {
        guard request.count <= 1024 * 1024 else { reply(nil, "invalidInput"); return }
        let response = PlantUMLReply(reply)
        let runtime = plantUML
        guard renderWork.start({
            do {
                try Task.checkCancellation()
                let input = try JSONDecoder().decode(PlantUMLRequest.self, from: request)
                response.send(try await runtime.perform(input), nil)
            } catch let error as PlantUMLFailure {
                let data = try? JSONSerialization.data(withJSONObject: ["code": error.code, "detail": error.detail])
                response.send(nil, data.flatMap { String(data: $0, encoding: .utf8) } ?? "renderFailed")
            } catch {
                response.send(nil, "renderFailed")
            }
        }) else { reply(nil, "busy"); return }
    }
    func installTerminalCommand(withReply reply: @escaping (String?) -> Void) {
        do { try terminalCommand.install(); reply(nil) }
        catch { reply(String(describing: error)) }
    }
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
        installer = Installer(root: root, home: home, app: app)
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == geteuid() else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: DuckpadNativeInstallerProtocol.self)
        let session = Installer(copying: installer)
        connection.exportedObject = session
        let work = session.renderWork
        connection.invalidationHandler = { work.cancel() }
        connection.interruptionHandler = { work.cancel() }
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
