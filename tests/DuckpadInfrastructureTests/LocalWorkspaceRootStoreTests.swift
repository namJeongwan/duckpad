import DuckpadApplication
import DuckpadDomain
@testable import DuckpadInfrastructure
import Dispatch
import Foundation
import Testing

private final class ScopeEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(String, URL)] = []

    func record(_ event: String, url: URL) {
        lock.withLock { storage.append((event, url)) }
    }

    var events: [(String, URL)] {
        lock.withLock { storage }
    }
}

@Suite(.serialized)
struct LocalWorkspaceRootStoreTests {
    @Test
    func rootsChildrenAndNavigationRoundTripWithoutFollowingSymlinks() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("Sources", isDirectory: true)
        let package = fixture.root.appendingPathComponent("Skip.app", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: fixture.root.appendingPathComponent("note.txt"))
        try Data("swift".utf8).write(to: source.appendingPathComponent("main.swift"))
        try Data("hidden".utf8).write(to: fixture.root.appendingPathComponent(".secret"))
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("link.txt"),
            withDestinationURL: fixture.root.appendingPathComponent("note.txt")
        )
        let store = LocalWorkspaceRootStore(archiveURL: fixture.archive)

        let added = try await store.addRoot(fixture.root)
        let top = try await store.children(rootID: added.id, relativeDirectory: "")
        #expect(top.map(\.name) == ["Sources", "note.txt"])
        #expect(top.map(\.kind) == [.directory, .file])
        let note = try #require(top.last)
        let read = try await store.readFile(note)
        #expect(read.url == fixture.root.appendingPathComponent("note.txt"))
        #expect(read.result.data == Data("hello".utf8))
        _ = try await store.updateNavigation(
            rootID: added.id,
            expandedRelativePaths: ["", "Sources", "Sources"],
            selectedRelativePath: "Sources/main.swift"
        )

        let restoredStore = LocalWorkspaceRootStore(archiveURL: fixture.archive)
        let restored = try #require(try await restoredStore.loadRoots().first)
        #expect(restored.id == added.id)
        #expect(restored.canonicalPath == fixture.root.path)
        #expect(restored.expandedRelativePaths == ["", "Sources"])
        #expect(restored.selectedRelativePath == "Sources/main.swift")
        #expect(try await restoredStore.children(rootID: added.id, relativeDirectory: "Sources").map(\.name) == ["main.swift"])
    }

    @Test
    func traversalAndForgedEntryKindsFailClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outside = fixture.base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("escape", isDirectory: true),
            withDestinationURL: outside
        )
        let store = LocalWorkspaceRootStore(archiveURL: fixture.archive)
        let root = try await store.addRoot(fixture.root)
        await #expect(throws: WorkspaceBrowserFailure.invalidPath("../outside")) {
            _ = try await store.children(rootID: root.id, relativeDirectory: "../outside")
        }
        let forged = WorkspaceBrowserEntry(rootID: root.id, relativePath: "../outside", name: "outside", kind: .file)
        await #expect(throws: WorkspaceBrowserFailure.invalidPath("../outside")) {
            _ = try await store.readFile(forged)
        }
        let throughSymlink = WorkspaceBrowserEntry(
            rootID: root.id,
            relativePath: "escape/secret.txt",
            name: "secret.txt",
            kind: .file
        )
        await #expect(throws: WorkspaceBrowserFailure.self) {
            _ = try await store.readFile(throughSymlink)
        }
    }

    @Test
    func corruptArchiveFailsOnEveryRetryInsteadOfBecomingEmptyState() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("not-json".utf8).write(to: fixture.archive)
        let store = LocalWorkspaceRootStore(archiveURL: fixture.archive)

        for _ in 0..<2 {
            do {
                _ = try await store.loadRoots()
                Issue.record("corrupt workspace archive must fail")
            } catch let failure {
                guard case .corruptStore = failure else {
                    Issue.record("unexpected failure: \(failure)")
                    continue
                }
            }
        }
    }

    @Test
    func descriptorReadRejectsFileSwappedToOutsideSymlink() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let safe = fixture.root.appendingPathComponent("note.txt")
        let outside = fixture.base.appendingPathComponent("outside.txt")
        try Data("safe".utf8).write(to: safe)
        try Data("secret".utf8).write(to: outside)
        let store = LocalWorkspaceRootStore(
            archiveURL: fixture.archive,
            testingBeforeOpeningEntry: { relativePath in
                guard relativePath == "note.txt" else { return }
                try? FileManager.default.removeItem(at: safe)
                try? FileManager.default.createSymbolicLink(at: safe, withDestinationURL: outside)
            }
        )
        let root = try await store.addRoot(fixture.root)
        let entry = WorkspaceBrowserEntry(
            rootID: root.id,
            relativePath: "note.txt",
            name: "note.txt",
            kind: .file
        )
        await #expect(throws: WorkspaceBrowserFailure.invalidPath("note.txt")) {
            _ = try await store.readFile(entry)
        }
    }

    @Test
    func rawDirectoryLimitAndCancellationApplyBeforeMaterialization() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for name in ["one", "two", "three"] {
            try Data().write(to: fixture.root.appendingPathComponent(name))
        }
        let capped = LocalWorkspaceRootStore(archiveURL: fixture.archive, directoryEntryLimit: 2)
        let root = try await capped.addRoot(fixture.root)
        await #expect(throws: WorkspaceBrowserFailure.entryLimitExceeded(2)) {
            _ = try await capped.children(rootID: root.id, relativeDirectory: "")
        }

        let cancellationFixture = try Fixture()
        defer { cancellationFixture.remove() }
        try Data().write(to: cancellationFixture.root.appendingPathComponent("one"))
        try Data().write(to: cancellationFixture.root.appendingPathComponent("two"))
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let cancellable = LocalWorkspaceRootStore(
            archiveURL: cancellationFixture.archive,
            testingAfterReadingDirectoryEntry: {
                entered.signal()
                release.wait()
            }
        )
        let cancellationRoot = try await cancellable.addRoot(cancellationFixture.root)
        let task = Task {
            try await cancellable.children(rootID: cancellationRoot.id, relativeDirectory: "")
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                entered.wait()
                continuation.resume()
            }
        }
        task.cancel()
        release.signal()
        await #expect(throws: WorkspaceBrowserFailure.cancelled) { _ = try await task.value }
    }

    @Test
    func restoredSecurityScopeStartsBeforeInspectionAndStopsTheExactURL() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let seed = LocalWorkspaceRootStore(archiveURL: fixture.archive)
        let seeded = try await seed.addRoot(fixture.root)
        let recorder = ScopeEventRecorder()
        let restoredStore = LocalWorkspaceRootStore(
            archiveURL: fixture.archive,
            testingSecurityScopedAccessRequired: true,
            testingStartSecurityScopedAccess: { url in
                recorder.record("start", url: url)
                return true
            },
            testingStopSecurityScopedAccess: { recorder.record("stop", url: $0) },
            testingCanonicalizeRoot: { url in
                recorder.record("inspect", url: url)
                return url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
            }
        )

        let restored = try #require(try await restoredStore.loadRoots().first)
        #expect(restored.isAvailable)
        try await restoredStore.removeRoot(seeded.id)

        let events = recorder.events
        #expect(events.map(\.0) == ["start", "inspect", "stop"])
        #expect(events.first?.1 == events.last?.1)
    }

    @Test
    func requiredSecurityScopeFailureDoesNotInspectOrPublishAvailableRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let seed = LocalWorkspaceRootStore(archiveURL: fixture.archive)
        _ = try await seed.addRoot(fixture.root)
        let recorder = ScopeEventRecorder()
        let restoredStore = LocalWorkspaceRootStore(
            archiveURL: fixture.archive,
            testingSecurityScopedAccessRequired: true,
            testingStartSecurityScopedAccess: { url in
                recorder.record("start", url: url)
                return false
            },
            testingStopSecurityScopedAccess: { recorder.record("stop", url: $0) },
            testingCanonicalizeRoot: { url in
                recorder.record("inspect", url: url)
                return url
            }
        )

        let restored = try #require(try await restoredStore.loadRoots().first)
        #expect(!restored.isAvailable)
        #expect(recorder.events.map(\.0) == ["start"])
    }

    private struct Fixture {
        let base: URL
        let root: URL
        let archive: URL

        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-workspace-\(UUID().uuidString)", isDirectory: true)
            root = base.appendingPathComponent("root", isDirectory: true)
            archive = base.appendingPathComponent("preferences/workspace-roots.json")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: base) }
    }
}
