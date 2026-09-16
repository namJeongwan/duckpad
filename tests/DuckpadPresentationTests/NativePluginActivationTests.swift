import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import CryptoKit
import Darwin
import Foundation
@testable import DuckpadPresentation
import Testing

private final class RejectedInstallation: VerifiedNativePluginInstallation, @unchecked Sendable {
    let directory = URL(fileURLWithPath: "/unused-native-test")
    private let lock = NSLock()
    private var validations = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return validations }
    func validateForLoading() throws {
        lock.lock(); validations += 1; lock.unlock()
        throw NativePluginValidationFailure.changedPackage
    }
}

private actor DeferredNativeVerifier: NativePluginInstallationVerifying {
    private var requests: [CheckedContinuation<any VerifiedNativePluginInstallation, any Error>?] = []
    var count: Int { requests.count }
    func open(_ registration: ExtensionServiceRegistration, root: URL) async throws -> any VerifiedNativePluginInstallation {
        try await withCheckedThrowingContinuation { requests.append($0) }
    }
    func finish(_ index: Int, installation: RejectedInstallation) {
        requests[index]?.resume(returning: installation)
        requests[index] = nil
    }
}

private actor FailingNativeVerifier: NativePluginInstallationVerifying {
    private(set) var count = 0
    func open(_ registration: ExtensionServiceRegistration, root: URL) async throws -> any VerifiedNativePluginInstallation {
        count += 1
        throw NativePluginValidationFailure.changedPackage
    }
}

@Suite(.serialized) struct NativePluginActivationTests {
    @Test @MainActor func synchronizationRetriesFailedActivation() async throws {
        let registration = ExtensionServiceRegistration(command: .init(id: .init(rawValue: "com.test.retry"), title: "Test", operation: 1, inputScope: .service), extensionID: .init(rawValue: "com.test"), publisherFingerprint: String(repeating: "b", count: 64), packageDigest: String(repeating: "a", count: 64), capabilities: [.nativeCode], nativeFiles: ["module.dylib": Data()])
        let verifier = FailingNativeVerifier()
        let host = NativePluginServiceHost(storageRoot: URL(fileURLWithPath: "/unused-storage"), verifier: verifier)
        defer { host.synchronize([]) }
        host.synchronize([registration])
        await #expect(throws: NativePluginValidationFailure.self) {
            try await host.prepareInstallation(command: registration.command.id)
        }
        #expect(await verifier.count == 1)
        // Reconciliation, without a user command, previously retried failures.
        host.synchronize([registration])
        for _ in 0..<100 {
            if await verifier.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await verifier.count == 2)
    }

    @Test @MainActor func verifiedModuleActivatesAllCommandsAndStopsEveryInstance() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.c")
        let module = root.appendingPathComponent("module.dylib")
        // A self-contained ABI fixture: no clipboard, documents, UI or network.
        try Data("""
        #include <stdint.h>
        #include <stdlib.h>
        static uint32_t created, stopped, destroyed;
        uint32_t duckpad_native_abi_version(void) { return 1; }
        void *duckpad_native_create(const void *host, const uint8_t *config, size_t length) { ++created; return malloc(1); }
        void *duckpad_native_view(void *instance) { return 0; }
        void duckpad_native_set_language(void *instance, const char *language) {}
        void duckpad_native_deactivate(void *instance) { ++stopped; }
        void duckpad_native_destroy(void *instance) { ++destroyed; free(instance); }
        uint32_t duckpad_test_counts(void) { return created | (stopped << 8) | (destroyed << 16); }
        """.utf8).write(to: source)
        let exitCode = try await Task.detached {
            let compiler = Process()
            compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
            compiler.arguments = ["-dynamiclib", source.path, "-o", module.path]
            try compiler.run()
            compiler.waitUntilExit()
            return compiler.terminationStatus
        }.value
        try #require(exitCode == 0)
        let bytes = try Data(contentsOf: module)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let directory = root.appendingPathComponent(digest + ".duckpad-plugin")
        let registrations = ["one", "two"].map {
            ExtensionServiceRegistration(command: .init(id: .init(rawValue: "com.test." + $0), title: "Test", operation: 1, inputScope: .service), extensionID: .init(rawValue: "com.test"), publisherFingerprint: String(repeating: "b", count: 64), packageDigest: digest, capabilities: [.nativeCode], nativeFiles: ["module.dylib": bytes])
        }
        let host = NativePluginServiceHost(storageRoot: root.appendingPathComponent("state"), packageRoot: root, verifier: LocalNativePluginInstallationVerifier(), preparePackage: { files in
            // A second installer call would fail: reopening must use the
            // existing verified execution copy, just as the app does.
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            for (name, data) in files { try data.write(to: directory.appendingPathComponent(name)) }
        })
        defer { host.synchronize([]) }
        host.synchronize(Array(registrations.prefix(1)))
        try await host.prepareInstallation(for: .init(rawValue: "com.test"))
        host.synchronize(registrations)
        try await host.prepareInstallation(for: .init(rawValue: "com.test"))
        let handle = try #require(dlopen(directory.appendingPathComponent("module.dylib").path, RTLD_NOW | RTLD_LOCAL))
        defer { dlclose(handle) }
        let symbol = try #require(dlsym(handle, "duckpad_test_counts"))
        let counts = unsafeBitCast(symbol, to: (@convention(c) () -> UInt32).self)
        #expect(counts() == 2)
        host.synchronize(registrations)
        try await host.prepareInstallation(for: .init(rawValue: "com.test"))
        #expect(counts() == 2, "Already active commands must not be recreated")
        host.synchronize([])
        #expect(counts() == 2 | (2 << 8) | (2 << 16))
    }

    @Test @MainActor func revokedActivationCannotLoadOrClearItsReplacement() async throws {
        let registration = ExtensionServiceRegistration(command: .init(id: .init(rawValue: "com.test.show"), title: "Test", operation: 1, inputScope: .service), extensionID: .init(rawValue: "com.test"), publisherFingerprint: String(repeating: "b", count: 64), packageDigest: String(repeating: "a", count: 64), capabilities: [.nativeCode], nativeFiles: ["module.dylib": Data()])
        let verifier = DeferredNativeVerifier()
        let host = NativePluginServiceHost(storageRoot: URL(fileURLWithPath: "/unused-storage"), verifier: verifier)
        host.synchronize([registration])
        for _ in 0..<100 {
            if await verifier.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await verifier.count == 1)
        #expect(host.contains(registration.command.id))
        host.synchronize([])
        #expect(!host.contains(registration.command.id))
        host.synchronize([registration])
        for _ in 0..<100 {
            if await verifier.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let stale = RejectedInstallation()
        let current = RejectedInstallation()
        await verifier.finish(0, installation: stale)
        try await Task.sleep(for: .milliseconds(30))
        host.synchronize([registration])
        #expect(await verifier.count == 2, "A stale task must not clear a newer activation")
        await verifier.finish(1, installation: current)
        for _ in 0..<100 {
            if current.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(stale.count == 0, "Revoked code must not reach the native loading boundary")
        #expect(current.count == 1)
        host.synchronize([])
    }
}
