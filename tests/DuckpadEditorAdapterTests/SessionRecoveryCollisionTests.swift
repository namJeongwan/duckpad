import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
import Foundation
import Testing

@Suite @MainActor
struct SessionRecoveryCollisionTests {
    private func writer(root: URL) -> (ScratchWorkspaceUseCase, ScintillaEditorAdapter, SessionRecoveryUseCase) {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
        let recovery = SessionRecoveryUseCase(
            workspace: workspace, editor: editor, store: LocalRecoveryStore(root: root),
            debounce: .seconds(3_600)
        )
        workspace.onChange = { change in
            binding.render(change)
            recovery.workspaceDidChange(change)
        }
        return (workspace, editor, recovery)
    }

    @Test(arguments: [1, 2])
    func anotherWriterCannotPermanentlyBlockQuitOrAcknowledgeUnsavedText(writes: Int) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, firstEditor, first) = writer(root: root)
        #expect(await first.start() == .saved)
        #expect(await first.flush() == .saved(.init(rawValue: 1)))
        let (workspace, secondEditor, second) = writer(root: root)
        #expect(await second.start() == .saved)
        for _ in 0..<writes {
            try #require(firstEditor.activeScintillaView).insertCommittedText("other writer 한글\n")
            guard case .saved = await first.flush() else { Issue.record("first writer failed"); return }
        }
        try #require(secondEditor.activeScintillaView).insertCommittedText("current unsaved 🙂")
        let active = try #require(workspace.snapshot().activeBuffer)
        let expected = try #require(secondEditor.recoverySnapshot(for: active.bufferID))
        guard case .saved = await second.flushForTermination() else {
            Issue.record("a valid external generation must not permanently block quitting")
            return
        }
        let loaded = try #require(try await LocalRecoveryStore(root: root).loadLatest())
        #expect(loaded.generation.rawValue == UInt64(writes + 2))
        #expect(loaded.archive.buffers[expected.bufferID]?.utf8 == expected.utf8)
        let previous = root.appendingPathComponent(String(format: "generations/%020llu/manifest.json", writes + 1))
        #expect(FileManager.default.fileExists(atPath: previous.path))
    }

    @Test(arguments: [false, true])
    func unchangedTerminationVerifiesThatItsArchiveIsStillDurable(reset: Bool) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (workspace, firstEditor, first) = writer(root: root)
        #expect(await first.start() == .saved)
        try #require(firstEditor.activeScintillaView).insertCommittedText("keep this session 한글")
        #expect(await first.flush() == .saved(.init(rawValue: 1)))
        let active = try #require(workspace.snapshot().activeBuffer)
        let expected = try #require(firstEditor.recoverySnapshot(for: active.bufferID))
        if reset { try await LocalRecoveryStore(root: root).reset() }
        let (_, secondEditor, second) = writer(root: root)
        #expect(await second.start() == .saved)
        for _ in 0..<(reset ? 1 : 2) {
            try #require(secondEditor.activeScintillaView).insertCommittedText("another session\n")
            guard case .saved = await second.flush() else { Issue.record("second writer failed"); return }
        }
        #expect(await first.flushForTermination() == .saved(.init(rawValue: reset ? 2 : 4)))
        let loaded = try #require(try await LocalRecoveryStore(root: root).loadLatest())
        #expect(loaded.archive.buffers[expected.bufferID]?.utf8 == expected.utf8)
    }
}
