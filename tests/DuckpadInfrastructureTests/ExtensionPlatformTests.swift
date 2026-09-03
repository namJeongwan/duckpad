import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import DuckpadPluginRuntimeCore
import DuckpadPluginSupport
import DuckpadWAMRBridge
import Foundation
import Testing

private func temporaryDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private final class ExtensionInfrastructureTestBundleSentinel: NSObject {}

private func currentPluginHostExecutable() throws -> URL {
    let bundleURLs = [Bundle(for: ExtensionInfrastructureTestBundleSentinel.self).bundleURL]
        + Bundle.allBundles.map(\.bundleURL) + [Bundle.main.bundleURL]
    for bundleURL in bundleURLs where bundleURL.pathExtension == "xctest" {
        let candidate = bundleURL.deletingLastPathComponent().appendingPathComponent("DuckpadPluginHost")
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.resolvingSymlinksInPath() }
    }
    throw ExtensionFailure.hostUnavailable("DuckpadPluginHost is absent from the current test build products")
}

@Test func bundledExtensionPassesSignatureInventoryAndWasmPolicy() async throws {
    let root = try temporaryDirectory("extensions-empty")
    defer { try? FileManager.default.removeItem(at: root) }
    let report = await LocalExtensionPackageLoader(root: root).discover()
    #expect(report.failures.isEmpty, "\(report.failures)")
    let package = try #require(report.packages.first)
    #expect(package.manifest.id == ExtensionID(rawValue: "com.duckpad.text-tools"))
    #expect(package.trustSource == .bundled)
    #expect(package.packageDigest == "ce54eed65c4707a705fb246a2bcf304be77366376147a5a17d4f1be3ad984390")
    let metadata = try WasmModulePolicy.validate(package.module, limits: ExtensionHostLimits())
    #expect(metadata.memoryMaximumPages == 128)
}

@Test func hiddenUnsignedPayloadAndSymlinkPackageFailClosed() async throws {
    let root = try temporaryDirectory("extensions-invalid")
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let bundled = repository.appendingPathComponent("Sources/DuckpadInfrastructure/Resources/BundledExtensions/com.duckpad.text-tools.duckpad-plugin")
    let copied = root.appendingPathComponent("copy.duckpad-plugin")
    try FileManager.default.copyItem(at: bundled, to: copied)
    try Data("hidden".utf8).write(to: copied.appendingPathComponent(".payload"))
    let report = await LocalExtensionPackageLoader(root: root, bundledPackages: []).discover()
    #expect(report.packages.isEmpty)
    #expect(report.failures["copy.duckpad-plugin"] == .signatureMismatch)

    let linked = root.appendingPathComponent("linked.duckpad-plugin")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: copied)
    let linkedReport = await LocalExtensionPackageLoader(root: root, bundledPackages: []).discover()
    #expect(linkedReport.failures["linked.duckpad-plugin"] == .invalidPackagePath)
}

@Test func copiedBundledSignatureIsUserImportedAndEverySignedArtifactTamperIsRejected() async throws {
    let root = try temporaryDirectory("extensions-trust")
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let bundled = repository.appendingPathComponent("Sources/DuckpadInfrastructure/Resources/BundledExtensions/com.duckpad.text-tools.duckpad-plugin")
    let clean = root.appendingPathComponent("clean.duckpad-plugin"); try FileManager.default.copyItem(at: bundled, to: clean)
    var report = await LocalExtensionPackageLoader(root: root, bundledPackages: []).discover()
    #expect(report.packages.first?.trustSource == .userImported)

    try FileManager.default.removeItem(at: clean)
    for (name, mutate) in [
        ("module.wasm", { (data: inout Data) in data[data.startIndex] ^= 0xff }),
        ("SHA256SUMS", { (data: inout Data) in data[data.startIndex] = 0x30 }),
        ("SIGNATURE.ed25519", { (data: inout Data) in data[data.startIndex] = data[data.startIndex] == 0x41 ? 0x42 : 0x41 }),
    ] {
        let target = root.appendingPathComponent("tamper.duckpad-plugin")
        try FileManager.default.copyItem(at: bundled, to: target)
        let file = target.appendingPathComponent(name); var bytes = try Data(contentsOf: file); mutate(&bytes); try bytes.write(to: file)
        report = await LocalExtensionPackageLoader(root: root, bundledPackages: []).discover()
        #expect(report.packages.isEmpty, "tampered \(name) was accepted")
        #expect(report.failures["tamper.duckpad-plugin"] != nil)
        try FileManager.default.removeItem(at: target)
    }
}

@Test func frameCodecRejectsTrailingAndOversizedFrames() throws {
    let response = ExtensionHostResponse(result: ExtensionCommandResult(edits: []))
    let frame = try PluginFrameCodec.encode(response)
    #expect(throws: Never.self) { _ = try PluginFrameCodec.decode(ExtensionHostResponse.self, from: frame) }
    var trailing = frame; trailing.append(0)
    #expect(throws: (any Error).self) { _ = try PluginFrameCodec.decode(ExtensionHostResponse.self, from: trailing) }
    var oversized = Data([0x01, 0x00, 0x00, 0x01])
    oversized.append(0)
    #expect(throws: (any Error).self) { _ = try PluginFrameCodec.decode(ExtensionHostResponse.self, from: oversized) }
}

@Test func sharedRuntimeExecutorKeepsDevelopmentAndXPCFramesEquivalent() async throws {
    let root = try temporaryDirectory("runtime-core")
    defer { try? FileManager.default.removeItem(at: root) }
    let package = try #require((await LocalExtensionPackageLoader(root: root).discover()).packages.first)
    let input = Data("z\na".utf8)
    let context = ExtensionInvocationContext(
        extensionID: package.manifest.id,
        commandID: .init(rawValue: "com.duckpad.text-tools.sortSelectedLines"),
        operation: 1,
        inputScope: .selection,
        tabID: TabID(),
        bufferID: BufferID(),
        revision: 7,
        selection: .init(location: 11, length: input.count),
        utf8: input
    )
    let request = ExtensionHostRequest(module: package.module, context: context, limits: .init())
    let responseFrame = try PluginRuntimeExecutor.responseFrame(for: PluginFrameCodec.encode(request))
    let response = try PluginFrameCodec.decode(ExtensionHostResponse.self, from: responseFrame)
    #expect(response.failure == nil)
    #expect(response.result?.edits == [
        ExtensionTextEdit(range: .init(location: 11, length: input.count), replacementUTF8: Data("a\nz".utf8)),
    ])

    var trailing = try PluginFrameCodec.encode(request)
    trailing.append(0xff)
    #expect(throws: (any Error).self) {
        _ = try PluginRuntimeExecutor.responseFrame(for: trailing)
    }
}

@Test func wasmPolicyRejectsImportsStartUnboundedMemoryOversizedTableWrongABIAndLEBOverflow() async throws {
    let header = Data([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00])
    let limits = ExtensionHostLimits()
    let importModule = header + Data([0x01, 0x01, 0x00, 0x02, 0x01, 0x01])
    #expect(throws: ExtensionFailure.invalidModule("imports are forbidden")) { _ = try WasmModulePolicy.validate(importModule, limits: limits) }
    #expect(throws: ExtensionFailure.invalidModule("start functions are forbidden")) { _ = try WasmModulePolicy.validate(header + Data([0x08, 0x00]), limits: limits) }
    #expect(throws: (any Error).self) { _ = try WasmModulePolicy.validate(header + Data([0x05, 0x03, 0x01, 0x00, 0x01]), limits: limits) }
    #expect(throws: ExtensionFailure.limitExceeded("table maximum")) {
        _ = try WasmModulePolicy.validate(header + Data([0x04, 0x06, 0x01, 0x70, 0x01, 0x01, 0x88, 0x27]), limits: limits)
    }
    #expect(throws: ExtensionFailure.invalidModule("LEB128 overflow")) {
        _ = try WasmModulePolicy.validate(header + Data([0x01, 0xff, 0xff, 0xff, 0xff, 0xff]), limits: limits)
    }
    let root = try temporaryDirectory("wasm-policy"); defer { try? FileManager.default.removeItem(at: root) }
    let report = await LocalExtensionPackageLoader(root: root).discover()
    var wrong = try #require(report.packages.first).module
    let needle = Data("duckpad_invoke".utf8)
    let range = try #require(wrong.range(of: needle)); wrong[range.lowerBound] = 0x78
    #expect(throws: ExtensionFailure.invalidModule("missing or invalid ABI export duckpad_invoke")) { _ = try WasmModulePolicy.validate(wrong, limits: limits) }
    var duplicateSection = try #require(report.packages.first).module; duplicateSection.append(contentsOf: [0x01, 0x01, 0x00])
    #expect(throws: (any Error).self) { _ = try WasmModulePolicy.validate(duplicateSection, limits: limits) }
}

@Test func persistedPolicyIsGenerationCheckedAndPrivate() async throws {
    let root = try temporaryDirectory("extension-policy")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalExtensionPreferenceStore(root: root)
    let first = ExtensionPolicySnapshot(generation: 1, enabled: [ExtensionID(rawValue: "com.example.safe")])
    #expect(try await store.savePolicy(first) == .committed)
    #expect(try await store.loadPolicy() == first)
    await #expect(throws: (any Error).self) { try await store.savePolicy(first) }
    let directoryMode = (try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue
    let fileMode = (try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("policy-v1.json").path)[.posixPermissions] as? NSNumber)?.intValue
    #expect(directoryMode == 0o700)
    #expect(fileMode == 0o600)
}

@Test func renamedPolicyGenerationCannotBeRetriedAfterDirectorySyncUncertainty() async throws {
    let root = try temporaryDirectory("extension-policy-uncertain")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalExtensionPreferenceStore(root: root, syncDirectory: { _ in -1 })
    let policy = ExtensionPolicySnapshot(generation: 1, enabled: [ExtensionID(rawValue: "com.example.safe")])

    #expect(try await store.savePolicy(policy) == .durabilityUncertain)
    await #expect(throws: (any Error).self) { _ = try await store.savePolicy(policy) }
    #expect(try await store.loadPolicy() == policy)
}

@Test func manifestDuplicateAndNestedUnknownKeysFailBeforeSignatureTrust() async throws {
    let root = try temporaryDirectory("extensions-json")
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let bundled = repository.appendingPathComponent("Sources/DuckpadInfrastructure/Resources/BundledExtensions/com.duckpad.text-tools.duckpad-plugin")
    let duplicate = root.appendingPathComponent("duplicate.duckpad-plugin")
    try FileManager.default.copyItem(at: bundled, to: duplicate)
    var text = try String(contentsOf: duplicate.appendingPathComponent("plugin.json"), encoding: .utf8)
    text = text.replacingOccurrences(of: "\"schemaVersion\": 1,", with: "\"schemaVersion\": 1, \"schemaVersion\": 1,")
    try Data(text.utf8).write(to: duplicate.appendingPathComponent("plugin.json"))
    var report = await LocalExtensionPackageLoader(root: root, bundledPackages: []).discover()
    #expect(report.packages.isEmpty)
    guard case .malformedManifest(let issue)? = report.failures["duplicate.duckpad-plugin"] else { Issue.record("duplicate key was not typed malformed"); return }
    #expect(issue.contains("duplicate JSON key"))

    try FileManager.default.removeItem(at: duplicate)
    let nested = root.appendingPathComponent("nested.duckpad-plugin")
    try FileManager.default.copyItem(at: bundled, to: nested)
    text = try String(contentsOf: nested.appendingPathComponent("plugin.json"), encoding: .utf8)
    text = text.replacingOccurrences(of: "\"keyID\": \"release-sample-1\"", with: "\"keyID\": \"release-sample-1\", \"secret\": true")
    try Data(text.utf8).write(to: nested.appendingPathComponent("plugin.json"))
    report = await LocalExtensionPackageLoader(root: root, bundledPackages: []).discover()
    guard case .malformedManifest? = report.failures["nested.duckpad-plugin"] else { Issue.record("nested unknown key was accepted"); return }
}

@Test func packageAggregateBytesAndPreferenceRootSymlinkFailClosed() async throws {
    let root = try temporaryDirectory("extensions-caps")
    defer { try? FileManager.default.removeItem(at: root) }
    let package = root.appendingPathComponent("large.duckpad-plugin")
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
    let chunk = Data(repeating: 0x61, count: 1_024 * 1_024)
    for index in 0..<17 { try chunk.write(to: package.appendingPathComponent("asset\(index).txt")) }
    let report = await LocalExtensionPackageLoader(root: root, bundledPackages: []).discover()
    #expect(report.failures["large.duckpad-plugin"] == .limitExceeded("package aggregate bytes"))

    let actual = root.appendingPathComponent("actual-policy"); try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false)
    let linked = root.appendingPathComponent("linked-policy"); try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: actual)
    let store = LocalExtensionPreferenceStore(root: linked)
    await #expect(throws: (any Error).self) { _ = try await store.savePolicy(.init(generation: 1)) }
}

@Test func packageDirectorySwapDuringDescriptorSnapshotFailsIdentityCheck() async throws {
    let root = try temporaryDirectory("extension-race"); defer { try? FileManager.default.removeItem(at: root) }
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let bundled = repository.appendingPathComponent("Sources/DuckpadInfrastructure/Resources/BundledExtensions/com.duckpad.text-tools.duckpad-plugin")
    let package = root.appendingPathComponent("race.duckpad-plugin")
    let moved = root.appendingPathComponent("original-away.duckpad-plugin")
    try FileManager.default.copyItem(at: bundled, to: package)
    let loader = LocalExtensionPackageLoader(root: root, bundledPackages: [], snapshotInterposition: { opened in
        try? FileManager.default.moveItem(at: opened, to: moved)
        try? FileManager.default.copyItem(at: bundled, to: opened)
    })
    let report = await loader.discover()
    #expect(report.packages.isEmpty)
    #expect(report.failures["race.duckpad-plugin"] == .invalidPackagePath)
}

@Test func directWAMRBridgeRejectsNonzeroNullInputWithoutLoadingModule() {
    var outputLength: UInt32 = 8
    var output = [UInt8](repeating: 0, count: 8)
    var error = [CChar](repeating: 0, count: 128)
    let limits = DPWAMRLimits(module_bytes: 8, stack_bytes: 4_096, heap_bytes: 4_096, output_bytes: 8)
    let module: [UInt8] = [0, 97, 115, 109, 1, 0, 0, 0]
    let result = module.withUnsafeBufferPointer { module in
        output.withUnsafeMutableBufferPointer { output in
            dp_wamr_invoke(module.baseAddress, module.count, 1, nil, 1, limits, output.baseAddress, &outputLength, &error, UInt32(error.count))
        }
    }
    #expect(!result)
    let end = error.firstIndex(of: 0) ?? error.endIndex
    #expect(String(decoding: error[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self).contains("invalid invocation"))
}

@Test func processTransportTimeoutAndExplicitCancelReapHelpers() async throws {
    let root = try temporaryDirectory("extension-helper")
    defer { try? FileManager.default.removeItem(at: root) }
    let pidFile = root.appendingPathComponent("pid")
    let helper = root.appendingPathComponent("helper")
    let source = root.appendingPathComponent("helper.c")
    let program = "#include <stdio.h>\n#include <unistd.h>\nint main(void){FILE *f=fopen(\"\(pidFile.path)\",\"w\");fprintf(f,\"%d\",getpid());fclose(f);char b[4096];while(read(0,b,sizeof(b))>0){}sleep(30);return 0;}\n"
    try Data(program.utf8).write(to: source)
    let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    compiler.arguments = ["clang", source.path, "-o", helper.path]
    try compiler.run(); compiler.waitUntilExit(); #expect(compiler.terminationStatus == 0)
    func request(id: UUID, timeout: UInt32) -> ExtensionHostRequest {
        ExtensionHostRequest(requestID: id, module: Data([0]), context: .init(
            extensionID: .init(rawValue: "com.example.x"), commandID: .init(rawValue: "com.example.x.run"), operation: 1,
            inputScope: .document, tabID: TabID(), bufferID: BufferID(), revision: 0,
            selection: .init(location: 0, length: 0), utf8: Data()
        ), limits: .init(timeoutMilliseconds: timeout))
    }
    func waitForPID(until deadline: ContinuousClock.Instant) async -> Int32? {
        while ContinuousClock.now < deadline {
            if let value = try? String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
               let pid = Int32(value) {
                return pid
            }
            await Task.yield()
        }
        return nil
    }
    let timed = ProcessPluginHostTransport(executableURL: helper, permitsInjectedDevelopmentHelper: true)
    let timedTask = Task { try await timed.invoke(request(id: UUID(), timeout: 10_000)) }
    let firstPID = await waitForPID(until: ContinuousClock.now + .seconds(8))
    #expect(firstPID != nil, "timeout helper did not publish PID before readiness deadline")
    await #expect(throws: ExtensionFailure.timedOut) { _ = try await timedTask.value }
    guard let firstPID else { return }
    #expect(kill(firstPID, 0) != 0 && errno == ESRCH)

    try? FileManager.default.removeItem(at: pidFile)
    let cancelled = ProcessPluginHostTransport(executableURL: helper, permitsInjectedDevelopmentHelper: true)
    let id = UUID(); let task = Task { try await cancelled.invoke(request(id: id, timeout: 10_000)) }
    let secondPID = await waitForPID(until: ContinuousClock.now + .seconds(8))
    #expect(secondPID != nil, "helper did not publish PID before readiness deadline")
    guard let secondPID else { return }
    await cancelled.cancel(requestID: id)
    await #expect(throws: ExtensionFailure.cancelled) { _ = try await task.value }
    #expect(kill(secondPID, 0) != 0 && errno == ESRCH)
}

@Test func bundledSamplePreservesFinalAndMixedEOLAndUTF8ThroughRealHost() async throws {
    let root = try temporaryDirectory("sample-host"); defer { try? FileManager.default.removeItem(at: root) }
    let package = try #require((await LocalExtensionPackageLoader(root: root).discover()).packages.first)
    let host = ProcessPluginHostTransport(executableURL: try currentPluginHostExecutable(), permitsInjectedDevelopmentHelper: true)
    let cases: [(String, String)] = [
        ("a\nz", "a\nz"),
        ("z\na", "a\nz"),
        ("z\r\na\r\n", "a\r\nz\r\n"),
        ("z\r\na\rb\n", "a\r\nb\rz\n"),
        ("🙂z\n한글a", "한글a\n🙂z"),
    ]
    for (input, expected) in cases {
        let bytes = Data(input.utf8); let absolute = 17
        let context = ExtensionInvocationContext(extensionID: package.manifest.id,
            commandID: .init(rawValue: "com.duckpad.text-tools.sortSelectedLines"), operation: 1, inputScope: .selection,
            tabID: TabID(), bufferID: BufferID(), revision: 0,
            selection: .init(location: absolute, length: bytes.count), utf8: bytes)
        let response = try await host.invoke(.init(module: package.module, context: context, limits: .init()))
        if input == expected {
            #expect(response.result?.edits.isEmpty == true)
            continue
        }
        let edit = try #require(response.result?.edits.first)
        #expect(edit.range == .init(location: absolute, length: bytes.count))
        #expect(String(decoding: edit.replacementUTF8, as: UTF8.self) == expected)
    }
    let empty = ExtensionInvocationContext(extensionID: package.manifest.id,
        commandID: .init(rawValue: "com.duckpad.text-tools.trimTrailingWhitespace"), operation: 2, inputScope: .document,
        tabID: TabID(), bufferID: BufferID(), revision: 0, selection: .init(location: 0, length: 0), utf8: Data())
    #expect(try await host.invoke(.init(module: package.module, context: empty, limits: .init())).result?.edits.isEmpty == true)
}

@Test func realHostRejectsTrailingRequestFrameBeforeModuleExecution() throws {
    let process = Process(); let input = Pipe(); let output = Pipe()
    process.executableURL = try currentPluginHostExecutable()
    process.standardInput = input; process.standardOutput = output; process.standardError = Pipe(); process.environment = [:]
    let context = ExtensionInvocationContext(extensionID: .init(rawValue: "com.example.x"), commandID: .init(rawValue: "com.example.x.run"), operation: 1, inputScope: .document,
        tabID: TabID(), bufferID: BufferID(), revision: 0, selection: .init(location: 0, length: 0), utf8: Data())
    var frame = try PluginFrameCodec.encode(ExtensionHostRequest(module: Data([0]), context: context, limits: .init())); frame.append(0xff)
    try process.run(); try input.fileHandleForWriting.write(contentsOf: frame); try input.fileHandleForWriting.close()
    let prefix = try #require(try output.fileHandleForReading.read(upToCount: 4)); #expect(prefix.count == 4)
    let count = prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    let body = try #require(try output.fileHandleForReading.read(upToCount: Int(count)))
    var responseFrame = prefix; responseFrame.append(body)
    let response = try PluginFrameCodec.decode(ExtensionHostResponse.self, from: responseFrame)
    #expect(response.failure?.contains("trailing bytes") == true)
    process.waitUntilExit(); #expect(process.terminationStatus == 0)
}
