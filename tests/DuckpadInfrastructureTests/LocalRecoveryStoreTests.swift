import DuckpadApplication
import DuckpadDomain
@testable import DuckpadInfrastructure
import Foundation
import Testing

private func recoveryRoot() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("duckpad-recovery-test-\(UUID().uuidString)", isDirectory: true)
}

private func recoveryArchive(
    text: String,
    revision: UInt64 = 1,
    fileBinding: Bool = false,
    viewState: EditorViewState = EditorViewState()
) throws -> RecoveryArchive {
    var session = ScratchSession()
    let buffer = BufferMetadata(revision: revision, isDirty: revision > 0)
    let tab = try session.addUntitled(buffer: buffer)
    if fileBinding {
        let identity = FileIdentity(
            canonicalPath: "/tmp/recovered.txt",
            device: 1,
            inode: 2,
            byteCount: 8,
            modifiedNanoseconds: 3,
            contentToken: "preserved-conflict-token"
        )
        try session.bindFile(
            tabID: tab,
            binding: FileBinding(
                canonicalPath: identity.canonicalPath,
                encoding: .utf16LittleEndian,
                byteOrderMark: .present,
                lineEnding: .crlf,
                observedIdentity: identity
            ),
            title: "recovered.txt",
            cleanAtRevision: 0
        )
    }
    return RecoveryArchive(
        session: session,
        buffers: [buffer.id: EditorRecoverySnapshot(
            bufferID: buffer.id,
            revision: revision,
            utf8: Data(text.utf8),
            viewState: viewState
        )]
    )
}

private func mutateManifest(
    root: URL,
    generation: UInt64,
    _ mutation: (inout [String: Any]) throws -> Void
) throws {
    let url = root.appendingPathComponent(
        "generations/\(String(format: "%020llu", generation))/manifest.json"
    )
    let data = try Data(contentsOf: url)
    guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CocoaError(.fileReadCorruptFile)
    }
    try mutation(&object)
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
}

@Test func recoveryRoundTripPreservesDirtyFileMetadataTextAndViewState() async throws {
    let root = recoveryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let state = EditorViewState(
        anchorUTF8: 3,
        caretUTF8: 10,
        firstVisibleLine: 14,
        horizontalScrollOffset: 21,
        wordWrapEnabled: false
    )
    let archive = try recoveryArchive(text: "한글🙂\r\nrecovery", revision: 7, fileBinding: true, viewState: state)
    let store = LocalRecoveryStore(root: root)

    #expect(try await store.commit(archive, generation: PersistenceGeneration(rawValue: 1)) == .committed)
    let loaded = try #require(try await store.loadLatest())
    #expect(loaded.generation.rawValue == 1)
    #expect(loaded.archive == archive)
    let tab = try #require(loaded.archive.session.tabs.first)
    #expect(try loaded.archive.session.buffer(for: tab.id).isDirty)
    #expect(try loaded.archive.session.fileBinding(for: tab.id)?.observedIdentity.contentToken == "preserved-conflict-token")
}

@Test func corruptNewestManifestFallsBackToPreviousKnownGoodGeneration() async throws {
    let root = recoveryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try recoveryArchive(text: "known good")
    let second = try recoveryArchive(text: "newest")
    let store = LocalRecoveryStore(root: root)
    _ = try await store.commit(first, generation: PersistenceGeneration(rawValue: 1))
    _ = try await store.commit(second, generation: PersistenceGeneration(rawValue: 2))
    let newestManifest = root.appendingPathComponent("generations/00000000000000000002/manifest.json")
    try Data("{\"truncated\":".utf8).write(to: newestManifest)

    let loaded = try #require(try await store.loadLatest())
    #expect(loaded.generation.rawValue == 1)
    #expect(loaded.archive == first)
    #expect(try await store.commit(second, generation: PersistenceGeneration(rawValue: 2)) == .committed)
    #expect(try await store.loadLatest()?.archive == second)
}

@Test func corruptNewestBlobHashFallsBackToPreviousGeneration() async throws {
    let root = recoveryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try recoveryArchive(text: "old")
    let second = try recoveryArchive(text: "new")
    let store = LocalRecoveryStore(root: root)
    _ = try await store.commit(first, generation: PersistenceGeneration(rawValue: 1))
    _ = try await store.commit(second, generation: PersistenceGeneration(rawValue: 2))
    let blobs = root.appendingPathComponent("generations/00000000000000000002/blobs")
    let blob = try #require(try FileManager.default.contentsOfDirectory(at: blobs, includingPropertiesForKeys: nil).first)
    try Data("tampered".utf8).write(to: blob)

    let loaded = try #require(try await store.loadLatest())
    #expect(loaded.generation.rawValue == 1)
    #expect(loaded.archive == first)
}

@Test(arguments: [RecoveryStoreFault.afterFirstBlob, .syncBlobsDirectory, .beforeManifest, .afterManifest])
func incompleteGenerationNeverReplacesPrevious(_ fault: RecoveryStoreFault) async throws {
    let root = recoveryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try recoveryArchive(text: "durable")
    let interrupted = try recoveryArchive(text: "interrupted")
    _ = try await LocalRecoveryStore(root: root).commit(first, generation: PersistenceGeneration(rawValue: 1))
    do {
        _ = try await LocalRecoveryStore(root: root, fault: fault).commit(
            interrupted,
            generation: PersistenceGeneration(rawValue: 2)
        )
        Issue.record("fault should interrupt commit")
    } catch { }
    let loaded = try #require(try await LocalRecoveryStore(root: root).loadLatest())
    #expect(loaded.generation.rawValue == 1)
    #expect(loaded.archive == first)
    let remaining = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("generations").path)
    #expect(!remaining.contains(where: { $0.hasPrefix(".tmp-") }))
}

@Test func blobsDirectorySyncFailureCannotPublishSuccessfulGeneration() async throws {
    let root = recoveryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalRecoveryStore(root: root, fault: .syncBlobsDirectory)
    do {
        _ = try await store.commit(
            try recoveryArchive(text: "must not publish"),
            generation: PersistenceGeneration(rawValue: 1)
        )
        Issue.record("blob-directory sync failure must fail the commit")
    } catch { }
    #expect(try await LocalRecoveryStore(root: root).loadLatest() == nil)
    #expect(!FileManager.default.fileExists(
        atPath: root.appendingPathComponent("generations/00000000000000000001").path
    ))
}

@Test func invalidRecoveredViewCoordinatesRejectNewestAndFallBack() async throws {
    let cases: [(String, Int)] = [
        ("caretUTF8", -1),
        ("anchorUTF8", 100),
        ("caretUTF8", 1), // continuation byte inside the leading Korean scalar
        ("firstVisibleLine", -1),
        ("horizontalScrollOffset", -1),
    ]
    for (key, value) in cases {
        let root = recoveryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = try recoveryArchive(text: "previous")
        let newest = try recoveryArchive(text: "한🙂")
        let store = LocalRecoveryStore(root: root)
        _ = try await store.commit(previous, generation: PersistenceGeneration(rawValue: 1))
        _ = try await store.commit(newest, generation: PersistenceGeneration(rawValue: 2))
        try mutateManifest(root: root, generation: 2) { manifest in
            var buffers = manifest["buffers"] as! [[String: Any]]
            var viewState = buffers[0]["viewState"] as! [String: Any]
            viewState[key] = value
            buffers[0]["viewState"] = viewState
            manifest["buffers"] = buffers
        }

        let loaded = try #require(try await store.loadLatest())
        #expect(loaded.generation.rawValue == 1)
        #expect(loaded.archive == previous)
    }
}

@Test func outOfRangeRecoveredBookmarkRejectsNewestAndFallsBack() async throws {
    let root = recoveryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let previous = try recoveryArchive(text: "previous")
    let newest = try recoveryArchive(text: "one\ntwo")
    let store = LocalRecoveryStore(root: root)
    _ = try await store.commit(previous, generation: PersistenceGeneration(rawValue: 1))
    _ = try await store.commit(newest, generation: PersistenceGeneration(rawValue: 2))
    try mutateManifest(root: root, generation: 2) { manifest in
        var buffers = manifest["buffers"] as! [[String: Any]]
        var viewState = buffers[0]["viewState"] as! [String: Any]
        viewState["bookmarkedLines"] = [99]
        buffers[0]["viewState"] = viewState
        manifest["buffers"] = buffers
    }

    let loaded = try #require(try await store.loadLatest())
    #expect(loaded.generation.rawValue == 1)
    #expect(loaded.archive == previous)
}

@Test func outOfRangeSecondarySplitCaretRejectsNewestAndFallsBack() async throws {
    let root = recoveryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let previous = try recoveryArchive(text: "previous")
    let splitState = EditorViewState(
        splitOrientation: .sideBySide,
        secondaryViewState: SecondaryEditorViewState(caretUTF8: 1)
    )
    let newest = try recoveryArchive(text: "two", viewState: splitState)
    let store = LocalRecoveryStore(root: root)
    _ = try await store.commit(previous, generation: PersistenceGeneration(rawValue: 1))
    _ = try await store.commit(newest, generation: PersistenceGeneration(rawValue: 2))
    try mutateManifest(root: root, generation: 2) { manifest in
        var buffers = manifest["buffers"] as! [[String: Any]]
        var viewState = buffers[0]["viewState"] as! [String: Any]
        var secondary = viewState["secondaryViewState"] as! [String: Any]
        secondary["caretUTF8"] = 99
        viewState["secondaryViewState"] = secondary
        buffers[0]["viewState"] = viewState
        manifest["buffers"] = buffers
    }

    let loaded = try #require(try await store.loadLatest())
    #expect(loaded.generation.rawValue == 1)
    #expect(loaded.archive == previous)
}

@Test func manifestWithTwoTabsOwningOneDocumentIsRejectedAtLoad() async throws {
    let root = recoveryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var session = ScratchSession()
    let first = session.addUntitled()
    let second = session.addUntitled()
    let firstBuffer = try session.buffer(for: first)
    let secondBuffer = try session.buffer(for: second)
    let archive = RecoveryArchive(session: session, buffers: [
        firstBuffer.id: EditorRecoverySnapshot(bufferID: firstBuffer.id, revision: 0, utf8: Data()),
        secondBuffer.id: EditorRecoverySnapshot(bufferID: secondBuffer.id, revision: 0, utf8: Data()),
    ])
    let store = LocalRecoveryStore(root: root)
    _ = try await store.commit(archive, generation: PersistenceGeneration(rawValue: 1))
    try mutateManifest(root: root, generation: 1) { manifest in
        var encodedSession = manifest["session"] as! [String: Any]
        var tabs = encodedSession["tabs"] as! [[String: Any]]
        tabs[1]["documentID"] = tabs[0]["documentID"]
        encodedSession["tabs"] = tabs
        manifest["session"] = encodedSession
    }

    do {
        _ = try await store.loadLatest()
        Issue.record("duplicate tab document ownership must reject the archive")
    } catch let error {
        guard case .corrupt = error else {
            Issue.record("expected corrupt recovery error")
            return
        }
    }
}

@Test func publishedGenerationIsValidatedAfterInjectedPostPublishInterruption() async throws {
    let root = recoveryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let archive = try recoveryArchive(text: "published")
    do {
        _ = try await LocalRecoveryStore(root: root, fault: .afterPublish).commit(
            archive,
            generation: PersistenceGeneration(rawValue: 1)
        )
        Issue.record("fault should report uncertain publish")
    } catch { }
    let loaded = try #require(try await LocalRecoveryStore(root: root).loadLatest())
    #expect(loaded.archive == archive)
}

@Test func recoveryDirectoriesAndFilesUsePrivatePermissions() async throws {
    let root = recoveryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try await LocalRecoveryStore(root: root).commit(
        try recoveryArchive(text: "private"),
        generation: PersistenceGeneration(rawValue: 1)
    )
    let generation = root.appendingPathComponent("generations/00000000000000000001")
    let blob = try #require(try FileManager.default.contentsOfDirectory(
        at: generation.appendingPathComponent("blobs"),
        includingPropertiesForKeys: nil
    ).first)
    for directory in [root, root.appendingPathComponent("generations"), generation, generation.appendingPathComponent("blobs")] {
        let mode = try #require(FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue & 0o777 == 0o700)
    }
    for file in [generation.appendingPathComponent("manifest.json"), blob] {
        let mode = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue & 0o777 == 0o600)
    }
}

@Test func storeRetainsCurrentAndPreviousGenerationOnly() async throws {
    let root = recoveryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalRecoveryStore(root: root)
    for generation in 1...3 {
        _ = try await store.commit(
            try recoveryArchive(text: "generation \(generation)"),
            generation: PersistenceGeneration(rawValue: UInt64(generation))
        )
    }
    let names = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("generations").path)
        .filter { !$0.hasPrefix(".") }
        .sorted()
    #expect(names == ["00000000000000000002", "00000000000000000003"])
}

@Test func sameGenerationDifferentArchiveFailsAsCollision() async throws {
    let root = recoveryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalRecoveryStore(root: root)
    _ = try await store.commit(
        try recoveryArchive(text: "winner"),
        generation: PersistenceGeneration(rawValue: 1)
    )
    do {
        _ = try await store.commit(
            try recoveryArchive(text: "loser"),
            generation: PersistenceGeneration(rawValue: 1)
        )
        Issue.record("different archive cannot be superseded at the same generation")
    } catch let error as SessionStoreError {
        guard case .corrupt = error else { Issue.record("expected collision error"); return }
    }
}

@Test func resetRemovesRecoveryRoot() async throws {
    let root = recoveryRoot()
    let store = LocalRecoveryStore(root: root)
    _ = try await store.commit(
        try recoveryArchive(text: "reset"),
        generation: PersistenceGeneration(rawValue: 1)
    )
    try await store.reset()
    #expect(!FileManager.default.fileExists(atPath: root.path))
    #expect(try await store.loadLatest() == nil)
}

@Test func largeUTF8ArchiveRoundTripsOffMainStoreBoundary() async throws {
    let root = recoveryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let text = String(repeating: "한글🙂\n", count: 250_000)
    let archive = try recoveryArchive(text: text)
    let store = LocalRecoveryStore(root: root)
    _ = try await store.commit(archive, generation: PersistenceGeneration(rawValue: 1))
    #expect(try await store.loadLatest()?.archive.buffers.values.first?.utf8.count == text.utf8.count)
}
