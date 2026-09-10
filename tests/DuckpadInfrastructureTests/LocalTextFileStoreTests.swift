import DuckpadApplication
import DuckpadDomain
@testable import DuckpadInfrastructure
import Foundation
import Testing

private final class SecurityScopeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0

    func start(_ url: URL) -> Bool {
        lock.lock(); starts += 1; lock.unlock()
        return true
    }

    func stop(_ url: URL) {
        lock.lock(); stops += 1; lock.unlock()
    }

    var values: (starts: Int, stops: Int) {
        lock.lock(); defer { lock.unlock() }
        return (starts, stops)
    }
}

@Test func documentSecurityScopesAreOwnerBalancedAndBookmarksRestoreAcrossStores() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("scope.txt")
    try Data("duck".utf8).write(to: file)
    let archive = directory.appendingPathComponent("bookmarks.json")
    let counter = SecurityScopeCounter()
    let makeStore = {
        LocalTextFileStore(
            bookmarkArchiveURL: archive,
            testingSecurityScopedAccessRequired: true,
            testingStartSecurityScopedAccess: { counter.start($0) },
            testingStopSecurityScopedAccess: { counter.stop($0) },
            testingCreateSecurityScopedBookmark: { Data($0.path.utf8) },
            testingResolveSecurityScopedBookmark: {
                (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), false)
            }
        )
    }
    let first = makeStore()
    let firstOwner = UUID()
    let secondOwner = UUID()
    let access = try await first.prepareSecurityScopedAccess(to: file, ownerID: firstOwner)
    _ = try await first.prepareSecurityScopedAccess(to: file, ownerID: firstOwner)
    _ = try await first.prepareSecurityScopedAccess(to: file, ownerID: secondOwner)
    #expect(counter.values == (1, 0))
    await first.releaseSecurityScopedAccess(forCanonicalPath: file.path, ownerID: firstOwner)
    #expect(counter.values == (1, 0))
    await first.releaseSecurityScopedAccess(forCanonicalPath: file.path, ownerID: secondOwner)
    #expect(counter.values == (1, 1))

    let identity = try await first.read(from: file).identity
    let binding = FileBinding(
        canonicalPath: file.path,
        encoding: .utf8,
        byteOrderMark: .absent,
        lineEnding: .none,
        observedIdentity: identity,
        securityScopedBookmark: access.bookmark
    )
    let relaunched = makeStore()
    let relaunchOwner = UUID()
    #expect(try await relaunched.restoreSecurityScopedAccess(
        for: binding,
        ownerID: relaunchOwner
    ).securityScopedBookmark == Data(file.path.utf8))
    await relaunched.releaseAllSecurityScopedAccess(ownerID: relaunchOwner)
    #expect(counter.values == (2, 2))
}

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

@Test func renewedSecurityScopeReplacesCachedGrantAndRetainsOtherOwners() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("scope.note")
    try Data("original".utf8).write(to: file)
    let counter = SecurityScopeCounter()
    let store = LocalTextFileStore(bookmarkArchiveURL: directory.appendingPathComponent("bookmarks.json"),
        testingSecurityScopedAccessRequired: true,
        testingStartSecurityScopedAccess: { counter.start($0) },
        testingStopSecurityScopedAccess: { counter.stop($0) },
        testingCreateSecurityScopedBookmark: { _ in Data("grant-\(counter.values.starts)".utf8) },
        testingResolveSecurityScopedBookmark: { _ in (file, false) })
    let first = UUID(), second = UUID()
    let original = try await store.prepareSecurityScopedAccess(to: file, ownerID: first)
    _ = try await store.prepareSecurityScopedAccess(to: file, ownerID: second)
    let renewed = try await store.renewSecurityScopedAccess(to: file, ownerID: first)
    #expect(renewed.bookmark != original.bookmark)
    #expect(counter.values == (2, 1))
    #expect(try await store.prepareSecurityScopedAccess(to: file, ownerID: second).bookmark == renewed.bookmark)
    await store.releaseAllSecurityScopedAccess(ownerID: first)
    #expect(counter.values == (2, 1))
    await store.releaseAllSecurityScopedAccess(ownerID: second)
    #expect(counter.values == (2, 2))
}

@Test func failedRenewalPreservesTheExistingOwnersAndGrant() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("scope.note")
    try Data("original".utf8).write(to: file)
    let counter = SecurityScopeCounter()
    let store = LocalTextFileStore(bookmarkArchiveURL: directory.appendingPathComponent("bookmarks.json"),
        testingSecurityScopedAccessRequired: true,
        testingStartSecurityScopedAccess: { counter.start($0) },
        testingStopSecurityScopedAccess: { counter.stop($0) },
        testingCreateSecurityScopedBookmark: { _ in
            if counter.values.starts > 1 { throw TextFileStoreError.io("bookmark failure") }
            return Data("original-grant".utf8)
        }, testingResolveSecurityScopedBookmark: { _ in (file, false) })
    let owner = UUID()
    let original = try await store.prepareSecurityScopedAccess(to: file, ownerID: owner)
    do {
        _ = try await store.renewSecurityScopedAccess(to: file, ownerID: owner)
        Issue.record("renewal unexpectedly succeeded")
    } catch { #expect(error == .io("bookmark failure")) }
    #expect(counter.values == (2, 1))
    #expect(try await store.prepareSecurityScopedAccess(to: file, ownerID: owner).bookmark == original.bookmark)
    await store.releaseAllSecurityScopedAccess(ownerID: owner)
    #expect(counter.values == (2, 2))
}

@Test func newSaveDestinationPersistsBookmarkOnlyAfterFileExists() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("new.note")
    let store = LocalTextFileStore(bookmarkArchiveURL: directory.appendingPathComponent("bookmarks.json"),
        testingSecurityScopedAccessRequired: true, testingStartSecurityScopedAccess: { _ in true },
        testingStopSecurityScopedAccess: { _ in }, testingCreateSecurityScopedBookmark: { url in
            guard FileManager.default.fileExists(atPath: url.path) else { throw TextFileStoreError.notFound(url.path) }
            return Data("durable-new-file-grant".utf8)
        }, testingResolveSecurityScopedBookmark: { _ in (file, false) })
    let owner = UUID()
    #expect(try await store.renewSecurityScopedAccess(to: file, ownerID: owner).bookmark == nil)
    // A conflict/Overwrite retry can prepare the same grant before creation.
    #expect(try await store.prepareSecurityScopedAccess(to: file, ownerID: owner).bookmark == nil)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    _ = try await store.writeAtomically(Data("preserved edits".utf8), to: file, expectedIdentity: nil, overwrite: false)
    #expect(try await store.prepareSecurityScopedAccess(to: file, ownerID: owner).bookmark == Data("durable-new-file-grant".utf8))
    #expect(try String(contentsOf: file, encoding: .utf8) == "preserved edits")
    await store.releaseAllSecurityScopedAccess(ownerID: owner)
}
