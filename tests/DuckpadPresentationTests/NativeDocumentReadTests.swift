import CryptoKit
import Darwin
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import Foundation
@testable import DuckpadPresentation
import Testing

@Suite(.serialized) struct NativeDocumentReadTests {
    @Test @MainActor func readsAreBoundedAuthorizedAndDetached() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.c")
        let module = root.appendingPathComponent("module.dylib")
        let sdk = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("SDK/DuckpadNative/include")
        try Data("""
        #include "DuckpadNative.h"
        #include <stdlib.h>
        static DuckpadHostV1 api;
        uint32_t duckpad_native_abi_version(void) { return 1; }
        void *duckpad_native_create(const DuckpadHostV1 *host, const uint8_t *config, size_t length) { api = *host; return malloc(1); }
        void *duckpad_native_view(void *instance) { return 0; }
        void duckpad_native_set_language(void *instance, const char *language) {}
        void duckpad_native_deactivate(void *instance) {}
        void duckpad_native_destroy(void *instance) { free(instance); }
        int64_t duckpad_test_read(uint8_t *buffer, size_t capacity) { return api.read_document(api.context, buffer, capacity); }
        """.utf8).write(to: source)
        let status = try await Task.detached {
            let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
            compiler.arguments = ["-dynamiclib", "-I", sdk.path, source.path, "-o", module.path]
            try compiler.run(); compiler.waitUntilExit(); return compiler.terminationStatus
        }.value
        try #require(status == 0)
        let bytes = try Data(contentsOf: module)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let directory = root.appendingPathComponent(digest + ".duckpad-plugin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try bytes.write(to: directory.appendingPathComponent("module.dylib"))
        let handle = try #require(dlopen(directory.appendingPathComponent("module.dylib").path, RTLD_NOW | RTLD_LOCAL))
        // NativePluginImage intentionally retains its own module handle.
        defer { dlclose(handle) }
        let read = unsafeBitCast(try #require(dlsym(handle, "duckpad_test_read")), to: (@convention(c) (UnsafeMutablePointer<UInt8>?, Int) -> Int64).self)
        for granted in [false, true] {
            let registration = ExtensionServiceRegistration(command: .init(id: .init(rawValue: "com.test.read"), title: "Test", operation: 1, inputScope: .service), extensionID: .init(rawValue: "com.test"), publisherFingerprint: String(repeating: "b", count: 64), packageDigest: digest, capabilities: granted ? [.nativeCode, .documentsRead] : [.nativeCode], nativeFiles: ["module.dylib": bytes])
            let installation = try await LocalNativePluginInstallationVerifier().open(registration, root: root)
            let instance = try NativePluginInstance(registration, root: root, installation: installation, language: "en")
            defer { instance.stop() }
            var text = "한글 🦆"; var liveGrant = true; var captures = 0
            instance.readDocument = { guard liveGrant else { return nil }; captures += 1; return text }
            let size = read(nil, 0)
            if !granted { #expect(size == -1); #expect(captures == 0); continue }
            #expect(size == text.utf8.count)
            var buffer = [UInt8](repeating: 0, count: Int(size))
            #expect(buffer.withUnsafeMutableBufferPointer { read($0.baseAddress, $0.count) } == size)
            #expect(String(bytes: buffer, encoding: .utf8) == text)
            #expect(buffer.withUnsafeMutableBufferPointer { read($0.baseAddress, 1) } == -1)
            liveGrant = false; let prior = captures
            #expect(read(nil, 0) == -1); #expect(captures == prior)
            liveGrant = true; text = String(repeating: "x", count: 512 * 1024 + 1)
            #expect(read(nil, 0) == -1)
            instance.detach(); #expect(read(nil, 0) == -1)
        }
    }
}
