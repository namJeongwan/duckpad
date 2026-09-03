import DuckpadApplication
import DuckpadDomain
@testable import DuckpadInfrastructure
import Foundation
import Testing

private func makeFolderSearchRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("duckpad-folder-search-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private final class DirectoryReadGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func block() { entered.signal(); release.wait() }
}

@Test func localFolderEnumerationIsRecursiveDeterministicAndSkipsUnsafeEntries() async throws {
    let root = try makeFolderSearchRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let nested = root.appendingPathComponent("nested", isDirectory: true)
    let package = root.appendingPathComponent("Ignored.app", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try Data("duck root".utf8).write(to: root.appendingPathComponent("a.txt"))
    try Data("duck nested".utf8).write(to: nested.appendingPathComponent("b.swift"))
    try Data("duck hidden".utf8).write(to: root.appendingPathComponent(".secret"))
    try Data("duck package".utf8).write(to: package.appendingPathComponent("inside.txt"))
    try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("linked.txt"),
        withDestinationURL: nested.appendingPathComponent("b.swift")
    )
    let store = LocalFolderSearchFileStore()

    let result = try await store.enumerateTextCandidates(
        rootPath: root.path,
        maximumFiles: 10,
        maximumDocumentBytes: 1_024,
        maximumTotalBytes: 10_240
    )

    #expect(result.files.map(\.relativePath).sorted() == ["a.txt", "nested/b.swift"])
    #expect(result.files.allSatisfy { $0.identity.canonicalPath == $0.path })
    #expect(result.skippedFileCount >= 3)
    #expect(!result.isTruncated)
}

@Test func localFolderEnumerationCapsFileCountAndBytesBeforeUnboundedReads() async throws {
    let root = try makeFolderSearchRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(repeating: 0x61, count: 8).write(to: root.appendingPathComponent("a.txt"))
    try Data(repeating: 0x62, count: 8).write(to: root.appendingPathComponent("b.txt"))
    try Data(repeating: 0x63, count: 64).write(to: root.appendingPathComponent("large.txt"))
    let store = LocalFolderSearchFileStore()

    let result = try await store.enumerateTextCandidates(
        rootPath: root.path,
        maximumFiles: 1,
        maximumDocumentBytes: 16,
        maximumTotalBytes: 16
    )

    #expect(result.files.count == 1)
    #expect(result.totalBytes == 8)
    #expect(result.isTruncated)
    #expect(result.files[0].relativePath == "a.txt")
}

@Test func localFolderEnumerationRejectsNonDirectoryRoot() async throws {
    let root = try makeFolderSearchRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("file.txt")
    try Data("duck".utf8).write(to: file)
    let store = LocalFolderSearchFileStore()
    do {
        _ = try await store.enumerateTextCandidates(
            rootPath: file.path,
            maximumFiles: 10,
            maximumDocumentBytes: 16,
            maximumTotalBytes: 16
        )
        Issue.record("file root was accepted")
    } catch let error {
        #expect(error == .invalidRoot(file.path))
    }
}

@Test func localFolderEnumerationDoesNotFollowFileSwappedToSymlink() async throws {
    let root = try makeFolderSearchRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = try makeFolderSearchRoot()
    defer { try? FileManager.default.removeItem(at: outside) }
    let victim = root.appendingPathComponent("victim.txt")
    let secret = outside.appendingPathComponent("secret.txt")
    try Data("inside".utf8).write(to: victim)
    try Data("outside secret".utf8).write(to: secret)
    let store = LocalFolderSearchFileStore(testingBeforeOpeningEntry: { relativePath in
        guard relativePath == "victim.txt" else { return }
        try? FileManager.default.removeItem(at: victim)
        try? FileManager.default.createSymbolicLink(at: victim, withDestinationURL: secret)
    })

    let result = try await store.enumerateTextCandidates(
        rootPath: root.path,
        maximumFiles: 10,
        maximumDocumentBytes: 1_024,
        maximumTotalBytes: 10_240
    )

    #expect(result.files.isEmpty)
    #expect(result.totalBytes == 0)
    #expect(result.skippedFileCount == 1)
}

@Test func localFolderEnumerationDoesNotFollowDirectorySwappedToSymlink() async throws {
    let root = try makeFolderSearchRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = try makeFolderSearchRoot()
    defer { try? FileManager.default.removeItem(at: outside) }
    let nested = root.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data("inside".utf8).write(to: nested.appendingPathComponent("inside.txt"))
    try Data("outside secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
    let store = LocalFolderSearchFileStore(testingBeforeOpeningEntry: { relativePath in
        guard relativePath == "nested" else { return }
        try? FileManager.default.removeItem(at: nested)
        try? FileManager.default.createSymbolicLink(at: nested, withDestinationURL: outside)
    })

    let result = try await store.enumerateTextCandidates(
        rootPath: root.path,
        maximumFiles: 10,
        maximumDocumentBytes: 1_024,
        maximumTotalBytes: 10_240
    )

    #expect(result.files.isEmpty)
    #expect(result.totalBytes == 0)
    #expect(result.skippedFileCount == 1)
}

@Test func localFolderEnumerationBoundsDirectoryMetadata() async throws {
    let root = try makeFolderSearchRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 0..<4 {
        try Data("duck".utf8).write(to: root.appendingPathComponent("\(index).txt"))
    }
    let store = LocalFolderSearchFileStore(
        maximumDirectoryEntries: 2,
        maximumDirectoryNameBytes: 1_024
    )

    let result = try await store.enumerateTextCandidates(
        rootPath: root.path,
        maximumFiles: 10,
        maximumDocumentBytes: 1_024,
        maximumTotalBytes: 10_240
    )

    #expect(result.files.count == 2)
    #expect(result.isTruncated)
}

@Test func localFolderEnumerationCancellationInterruptsDirectoryListing() async throws {
    let root = try makeFolderSearchRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("duck".utf8).write(to: root.appendingPathComponent("a.txt"))
    try Data("duck".utf8).write(to: root.appendingPathComponent("b.txt"))
    let gate = DirectoryReadGate()
    let store = LocalFolderSearchFileStore(testingAfterReadingDirectoryEntry: { gate.block() })
    let task = Task {
        try await store.enumerateTextCandidates(
            rootPath: root.path,
            maximumFiles: 10,
            maximumDocumentBytes: 1_024,
            maximumTotalBytes: 10_240
        )
    }
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            gate.entered.wait()
            continuation.resume()
        }
    }
    task.cancel()
    gate.release.signal()

    do {
        _ = try await task.value
        Issue.record("cancelled directory listing completed")
    } catch let error as FolderSearchFailure {
        #expect(error == .search(.cancelled))
    } catch {
        Issue.record("unexpected cancellation error: \(error)")
    }
}

@Test func localFolderEnumerationNeverLoadsGrowthPastDocumentCap() async throws {
    let root = try makeFolderSearchRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("growing.txt")
    try Data("x".utf8).write(to: file)
    let store = LocalFolderSearchFileStore(testingBeforeReadingFile: { relativePath in
        guard relativePath == "growing.txt" else { return }
        try? Data(repeating: 0x78, count: 4_096).write(to: file)
    })

    let result = try await store.enumerateTextCandidates(
        rootPath: root.path,
        maximumFiles: 10,
        maximumDocumentBytes: 16,
        maximumTotalBytes: 1_024
    )

    #expect(result.files.isEmpty)
    #expect(result.totalBytes == 0)
    #expect(result.skippedFileCount == 1)
}
