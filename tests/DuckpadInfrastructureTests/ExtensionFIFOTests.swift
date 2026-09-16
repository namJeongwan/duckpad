import CryptoKit
import Darwin
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import Foundation
import Testing

/// A rescue writer makes the regression fail instead of hanging the test runner.
private final class FIFOProbe: @unchecked Sendable {
    let url: URL
    private let completed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var rescued = false

    init(url: URL) throws {
        self.url = url
        guard mkfifo(url.path, 0o600) == 0 else { throw CocoaError(.fileWriteUnknown) }
        DispatchQueue.global().async { [self] in
            guard completed.wait(timeout: .now() + 2) == .timedOut else { return }
            lock.lock()
            rescued = true
            lock.unlock()
            let writer = open(url.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
            if writer >= 0 { close(writer) }
        }
    }

    func finish() -> Bool {
        completed.signal()
        lock.lock()
        defer { lock.unlock() }
        return !rescued
    }
}

@Suite struct ExtensionFIFOTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func packageDiscoveryRejectsFIFOWithoutWaitingForWriter() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("hostile.duckpad-plugin")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        let probe = try FIFOProbe(url: package.appendingPathComponent("plugin.json"))
        let report = await LocalExtensionPackageLoader(root: root, bundledPackages: []).discover()
        #expect(probe.finish(), "Unsigned package blocked discovery until a writer connected")
        #expect(report.packages.isEmpty)
        #expect(report.failures[package.lastPathComponent] == .invalidPackagePath)
    }

    @Test func policyRejectsFIFOWithoutWaitingForWriter() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = try FIFOProbe(url: root.appendingPathComponent("policy-v1.json"))
        await #expect(throws: (any Error).self) { _ = try await LocalExtensionPreferenceStore(root: root).loadPolicy() }
        #expect(probe.finish(), "Policy loading blocked until a writer connected")
    }

    @Test func serviceStateRejectsFIFOWithoutWaitingForWriter() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = ExtensionServiceRegistration(
            command: .init(id: .init(rawValue: "com.test.show"), title: "Test", operation: 1, inputScope: .service),
            extensionID: .init(rawValue: "com.test"), publisherFingerprint: String(repeating: "a", count: 64),
            packageDigest: "digest", capabilities: [.pluginStorage, .uiList])
        let storage = LocalExtensionServiceStorage(root: root)
        try await storage.save(Data(), for: identity)
        let command = SHA256.hash(data: Data(identity.command.id.rawValue.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = root.appendingPathComponent(identity.extensionID.rawValue)
            .appendingPathComponent(identity.publisherFingerprint).appendingPathComponent(command).appendingPathComponent("state.bin")
        try FileManager.default.removeItem(at: file)
        let probe = try FIFOProbe(url: file)
        await #expect(throws: (any Error).self) { _ = try await storage.load(identity) }
        #expect(probe.finish(), "Plugin state loading blocked until a writer connected")
    }
}
