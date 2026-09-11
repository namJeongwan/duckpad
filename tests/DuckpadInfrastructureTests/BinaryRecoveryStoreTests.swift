import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import Foundation
import Testing

struct BinaryRecoveryStoreTests {
    @Test func fullBinaryPositionsAndEditableScratchSurviveDiskRecovery() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = container.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: container) }
        var session = ScratchSession()
        let scratch = BufferMetadata(revision: 1, isDirty: true)
        _ = try session.addUntitled(buffer: scratch)
        let identity = FileIdentity(canonicalPath: "/tmp/full.bin", device: 1, inode: 2,
            byteCount: 2_097_156, modifiedNanoseconds: 3, contentToken: "full")
        let tab = try session.addFile(binding: FileBinding(canonicalPath: identity.canonicalPath,
            encoding: .utf8, byteOrderMark: .absent, lineEnding: .none,
            observedIdentity: identity, binaryByteCount: 2_097_156), title: "full.bin")
        let binary = try session.buffer(for: tab)
        let state = EditorViewState(anchorUTF8: 1_500_000, caretUTF8: 2_097_156,
            firstVisibleLine: 500, bookmarkedLines: [499])
        let archive = RecoveryArchive(session: session, buffers: [
            scratch.id: EditorRecoverySnapshot(bufferID: scratch.id, revision: scratch.revision,
                utf8: Data("unsaved scratch".utf8), viewState: EditorViewState(caretUTF8: 3)),
            binary.id: EditorRecoverySnapshot(bufferID: binary.id, revision: binary.revision,
                utf8: Data(), viewState: state)
        ])
        let store = LocalRecoveryStore(root: root)
        #expect(try await store.commit(archive, generation: PersistenceGeneration(rawValue: 1)) == .committed)
        #expect(try await store.loadLatest()?.archive == archive)
        let verified = try #require(LocalRecoveryStore.discoverVerifiedRoots(in: container).first)
        let verifiedStore = LocalRecoveryStore(verifiedRoot: verified)
        #expect(try await verifiedStore.loadLatest()?.archive == archive)
        #expect(try await verifiedStore.commit(archive, generation: PersistenceGeneration(rawValue: 2)) == .committed)
        #expect(try await verifiedStore.loadLatest()?.archive == archive)

        var invalidBuffers = archive.buffers
        invalidBuffers[binary.id] = EditorRecoverySnapshot(bufferID: binary.id, revision: binary.revision,
            utf8: Data(), viewState: EditorViewState(caretUTF8: 2_097_157))
        let invalid = RecoveryArchive(session: session, buffers: invalidBuffers)
        do {
            _ = try await store.commit(invalid, generation: PersistenceGeneration(rawValue: 3))
            Issue.record("out-of-range binary positions must be rejected")
        } catch { }
        #expect(try await store.loadLatest()?.archive == archive)
    }
}
