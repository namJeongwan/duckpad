import CryptoKit
import Darwin
import DuckpadApplication
@testable import DuckpadInfrastructure
import Foundation
import Testing

@Test(arguments: [false, true], [0o600, 0o444])
func largeAtomicSavePreservesEveryByteAcrossEdits(coordinated: Bool, permissions: Int) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("large.txt")
    var bytes = Data(repeating: 65, count: 3 * 1_024 * 1_024 + 31)
    try bytes.write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
    let store = LocalTextFileStore(bookmarkArchiveURL: root.appendingPathComponent("access.json"),
        testingSecurityScopedAccessRequired: coordinated,
        testingStartSecurityScopedAccess: { _ in true }, testingStopSecurityScopedAccess: { _ in },
        testingCreateSecurityScopedBookmark: { Data($0.path.utf8) },
        testingResolveSecurityScopedBookmark: { (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), false) })
    var identity = try await store.read(from: file).identity
    for action in 0..<4 {
        switch action {
        case 0: bytes.append(Data("한글🦆".utf8))
        case 1: bytes.replaceSubrange(1_024_570..<1_024_590, with: Data("changed in middle".utf8))
        case 2: bytes.removeLast(53)
        default: break
        }
        identity = try await store.writeAtomically(bytes, to: file, expectedIdentity: identity, overwrite: false).identity
        let saved = try Data(contentsOf: file)
        #expect(saved == bytes)
        #expect(identity.contentToken == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }
    // Same inode, size and restored mtime must not bypass content validation.
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    var before = stat()
    #expect(Darwin.lstat(file.path, &before) == 0)
    var external = bytes
    external[17] = 90
    try external.write(to: file)
    let times = [before.st_atimespec, before.st_mtimespec]
    #expect(utimensat(AT_FDCWD, file.path, times, 0) == 0)
    var after = stat()
    #expect(Darwin.lstat(file.path, &after) == 0)
    #expect(before.st_ino == after.st_ino)
    #expect(before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec)
    #expect(before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec)
    do {
        _ = try await store.writeAtomically(bytes, to: file, expectedIdentity: identity, overwrite: false)
        Issue.record("same-size external edit was overwritten")
    } catch {
        guard case .conflict = error else { Issue.record("expected conflict, got \(error)"); return }
    }
    #expect(try Data(contentsOf: file) == external)
}

@Test(arguments: [AtomicWriteFault.fullFileSync, .afterTemporaryFileSync, .directorySync])
func clonedSaveFailurePreservesOriginal(fault: AtomicWriteFault) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("large.txt")
    let original = Data(repeating: 65, count: 2 * 1_024 * 1_024)
    try original.write(to: file)
    let store = LocalTextFileStore(fault: fault)
    let identity = try await store.read(from: file).identity
    var edited = original
    edited.append(66)
    do {
        _ = try await store.writeAtomically(edited, to: file, expectedIdentity: identity, overwrite: false)
        Issue.record("fault did not fail")
    } catch { }
    #expect(try Data(contentsOf: file) == original)
}

@Test func cloneCandidateNeverPatchesSource() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    let candidate = root.appendingPathComponent("candidate")
    let original = Data(repeating: 65, count: 2 * 1_024 * 1_024)
    try original.write(to: source)
    var desired = original
    desired[1_024 * 1_024 - 1] = 66
    desired.append(67)
    // This regression probe intentionally requires the APFS fast path on macOS.
    let fd = try #require(try ClonedTextFile.prepare(source: source, destination: candidate, data: desired))
    Darwin.close(fd)
    #expect(try Data(contentsOf: source) == original)
    #expect(try Data(contentsOf: candidate) == desired)
    #expect(try ClonedTextFile.prepare(source: source, destination: candidate, data: original) == nil)
    #expect(try Data(contentsOf: candidate) == desired)
}
