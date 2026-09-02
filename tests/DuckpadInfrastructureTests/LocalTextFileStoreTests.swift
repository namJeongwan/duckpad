import DuckpadApplication
import DuckpadInfrastructure
import Foundation
import Testing

@Test func atomicFailurePreservesOriginalBytes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("sample.txt")
    let original = Data("original".utf8)
    try original.write(to: file)
    let failing = LocalTextFileStore(fault: .afterTemporaryFileSync)
    do {
        _ = try await failing.writeAtomically(Data("replacement".utf8), to: file, expectedIdentity: nil, overwrite: true)
        Issue.record("injected write unexpectedly succeeded")
    } catch {
        #expect(error == .atomicWriteFailed("injected failure after temporary fsync"))
    }
    #expect(try Data(contentsOf: file) == original)
}

@Test func staleIdentityCannotOverwriteExternalModification() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("sample.txt")
    try Data("first".utf8).write(to: file)
    let store = LocalTextFileStore()
    let observed = try await store.read(from: file).identity
    try Data("external".utf8).write(to: file)
    do {
        _ = try await store.writeAtomically(Data("duckpad".utf8), to: file, expectedIdentity: observed, overwrite: false)
        Issue.record("stale write unexpectedly succeeded")
    } catch {
        guard case .conflict(let current) = error else {
            Issue.record("expected conflict, got \(error)")
            return
        }
        #expect(current?.contentToken != observed.contentToken)
    }
    #expect(try String(contentsOf: file, encoding: .utf8) == "external")
}

@Test func existingTargetRaceAfterTemporarySyncIsRestoredAndReportedAsConflict() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("race.txt")
    try Data("original".utf8).write(to: file)
    let observer = LocalTextFileStore()
    let expected = try await observer.read(from: file).identity
    let external = Data("external-after-check".utf8)
    let racing = LocalTextFileStore(fault: .replaceDestinationBeforeCommit(external))
    do {
        _ = try await racing.writeAtomically(Data("candidate".utf8), to: file, expectedIdentity: expected, overwrite: false)
        Issue.record("raced replacement unexpectedly succeeded")
    } catch {
        guard case .conflict(let current) = error else { Issue.record("expected conflict, got \(error)"); return }
        #expect(current?.contentToken != expected.contentToken)
    }
    #expect(try Data(contentsOf: file) == external)
}

@Test func absentTargetRaceUsesNoReplaceAndNeverOverwritesNewFile() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("new-race.txt")
    let external = Data("created-by-other-process".utf8)
    let racing = LocalTextFileStore(fault: .replaceDestinationBeforeCommit(external))
    do {
        _ = try await racing.writeAtomically(Data("candidate".utf8), to: file, expectedIdentity: nil, overwrite: false)
        Issue.record("exclusive commit unexpectedly overwrote raced file")
    } catch {
        guard case .conflict = error else { Issue.record("expected conflict, got \(error)"); return }
    }
    #expect(try Data(contentsOf: file) == external)
}

@Test(arguments: [AtomicWriteFault.directoryOpen, .directorySync, .directoryClose])
func directoryDurabilityFailuresRestoreOriginal(fault: AtomicWriteFault) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("durability.txt")
    let original = Data("durable-original".utf8)
    try original.write(to: file)
    let observer = LocalTextFileStore()
    let expected = try await observer.read(from: file).identity
    let failing = LocalTextFileStore(fault: fault)
    do {
        _ = try await failing.writeAtomically(Data("candidate".utf8), to: file, expectedIdentity: expected, overwrite: false)
        Issue.record("durability fault unexpectedly succeeded")
    } catch {
        guard case .durabilityFailure(let state, _, let recoveryPath, _) = error else {
            Issue.record("expected typed durability failure, got \(error)")
            return
        }
        #expect(state == .originalRestored)
        #expect(recoveryPath == nil)
    }
    #expect(try Data(contentsOf: file) == original)
}

@Test func uncertainPostRenameFailureReportsRecoveryPathAndRetainsOriginal() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("uncertain.txt")
    try Data("original".utf8).write(to: file)
    let observer = LocalTextFileStore()
    let expected = try await observer.read(from: file).identity
    let failing = LocalTextFileStore(fault: .directorySyncAndRollbackFailure)
    do {
        _ = try await failing.writeAtomically(Data("candidate".utf8), to: file, expectedIdentity: expected, overwrite: false)
        Issue.record("uncertain fault unexpectedly succeeded")
    } catch {
        guard case .durabilityFailure(let state, _, let recoveryPath, _) = error else {
            Issue.record("expected typed uncertain durability failure, got \(error)")
            return
        }
        #expect(state == .filesystemStateUncertain)
        #expect(recoveryPath != nil)
        #expect(recoveryPath.map { FileManager.default.fileExists(atPath: $0) } == true)
    }
}

@Test func fullFileSyncFailureHappensBeforeCommitAndPreservesOriginal() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("full-sync.txt")
    let original = Data("original".utf8)
    try original.write(to: file)
    let failing = LocalTextFileStore(fault: .fullFileSync)
    do {
        _ = try await failing.writeAtomically(Data("candidate".utf8), to: file, expectedIdentity: nil, overwrite: true)
        Issue.record("F_FULLFSYNC fault unexpectedly succeeded")
    } catch {
        #expect(error == .atomicWriteFailed("injected F_FULLFSYNC failure"))
    }
    #expect(try Data(contentsOf: file) == original)
}
