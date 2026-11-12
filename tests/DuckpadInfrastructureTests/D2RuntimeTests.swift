import Foundation
import Testing
@testable import DuckpadInfrastructure
import DuckpadPluginSupport

@Suite(.serialized)
struct D2RuntimeTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("duckpad-d2-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @Test func malformedRequestsAndScriptPathsNeverStartAProcess() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = D2Runtime(root: root.appendingPathComponent("cache"))
        for request in [D2Request(source: ""), .init(source: "a\0b"), .init(source: String(repeating: "x", count: 524_289)),
                        .init(source: "a -> b", executablePath: "bad\npath")] {
            do { _ = try await runtime.perform(request); Issue.record("invalid D2 input accepted") }
            catch let error as D2Failure { #expect(error.code == "invalidInput") }
        }
        let script = root.appendingPathComponent("fake-d2")
        try Data("#!/bin/sh\ntouch should-not-exist".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        do { _ = try await runtime.perform(.init(source: "a -> b", executablePath: script.path)); Issue.record("script accepted as a runtime") }
        catch let error as D2Failure { #expect(error.code == "invalidRuntime") }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("should-not-exist").path))
    }
    @Test func frameBudgetIncludesJSONEscapingForBoundedSource() throws {
        let source = String(repeating: "\\\"\n", count: 174_762)
        #expect(source.utf8.count <= 512 * 1024)
        let bytes = try JSONEncoder().encode(D2Request(source: source))
        #expect(bytes.count <= D2Request.maximumFrameBytes)
    }
    @Test func processTimeoutAndOutputLimitCleanTheirFiles() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try D2Process.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["2"], directory: root, timeout: 0.03)
            Issue.record("timeout not enforced")
        } catch let error as D2Failure { #expect(error.code == "timeout") }
        do {
            _ = try D2Process.run(URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["too much output"], directory: root, outputLimit: 1)
            Issue.record("output limit not enforced")
        } catch let error as D2Failure { #expect(error.code == "outputLimit") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DUCKPAD_D2_TEST_EXECUTABLE"] != nil))
    func realD2RendersKoreanAndReportsSyntaxWithoutRetainingSource() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["DUCKPAD_D2_TEST_EXECUTABLE"])
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = D2Runtime(root: root)
        let svg = try await runtime.perform(.init(source: "client -> server: 안녕하세요", executablePath: executable, dark: true))
        #expect(String(decoding: svg, as: UTF8.self).contains("안녕하세요"))
        #expect(String(decoding: svg, as: UTF8.self).contains("<svg"))
        do { _ = try await runtime.perform(.init(source: "a: {", executablePath: executable)); Issue.record("invalid syntax accepted") }
        catch let error as D2Failure { #expect(error.code == "renderFailed" && !error.detail.isEmpty) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DUCKPAD_D2_TEST_SETUP"] == "1"))
    func automaticSetupVerifiesAndReusesItsPrivateRuntime() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = D2Runtime(root: root)
        let first = try await runtime.perform(.init(source: "a -> b", install: true))
        let executable = root.appendingPathComponent(D2Runtime.runtimeDirectoryName).appendingPathComponent("d2")
        let modified = try executable.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let second = try await runtime.perform(.init(source: "b -> c"))
        #expect(!first.isEmpty && !second.isEmpty)
        #expect(try executable.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
        #expect(FileManager.default.fileExists(atPath: executable.deletingLastPathComponent().appendingPathComponent("LICENSE.txt").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [D2Runtime.runtimeDirectoryName])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DUCKPAD_D2_TEST_EXECUTABLE"] != nil))
    func sourceCannotImportFilesOutsideItsRenderJob() async throws {
        let executable = try #require(ProcessInfo.processInfo.environment["DUCKPAD_D2_TEST_EXECUTABLE"])
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let privateFile = root.appendingPathComponent("private.d2")
        try Data("private: PRIVATE_CANARY".utf8).write(to: privateFile)
        let source = "...@\"" + privateFile.path + "\""
        let control = try D2Process.run(URL(fileURLWithPath: executable), arguments: ["--stdout-format=svg", "-", "-"],
                                        directory: root, input: Data(source.utf8))
        #expect(String(decoding: control, as: UTF8.self).contains("PRIVATE_CANARY"))
        let runtime = D2Runtime(root: root.appendingPathComponent("sandbox"))
        do {
            _ = try await runtime.perform(.init(source: source, executablePath: executable))
            Issue.record("D2 imported a file outside its render job")
        } catch let error as D2Failure {
            #expect(error.code == "renderFailed")
            #expect(!error.detail.contains("PRIVATE_CANARY"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("sandbox").path).isEmpty)
    }
}
