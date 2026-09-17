import AppKit
import CryptoKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
import Foundation

/// Opt-in end-to-end probe. The supplied file is only read; all writes and
/// recovery generations live in a new temporary directory.
@MainActor
enum LargeFileBenchmark {
    enum Failure: Error { case invariant(String) }

    static func run(path: String) async throws {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-large-file-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("fixture.txt")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: fixture)
        let originalDigest = try await digest(fixture)
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
        let recoveryStore = LocalRecoveryStore(root: root.appendingPathComponent("Recovery"))
        let recovery = SessionRecoveryUseCase(workspace: workspace, editor: editor, store: recoveryStore,
            debounce: .seconds(60))
        workspace.onChange = { change in
            binding.render(change)
            recovery.workspaceDidChange(change)
        }
        let files = FileDocumentUseCase(workspace: workspace, editor: editor,
            store: LocalTextFileStore(bookmarkArchiveURL: root.appendingPathComponent("access.json")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.view
        defer { window.close(); editor.invalidate() }
        _ = await recovery.start()
        var stage = "open"
        var maxGap = 0.0
        let heartbeat = Task { @MainActor in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
                let now = ContinuousClock.now
                maxGap = max(maxGap, FormattingBenchmark.milliseconds(last.duration(to: now)))
                last = now
            }
        }
        defer { heartbeat.cancel() }
        func report(_ start: ContinuousClock.Instant) async {
            await Task.yield()
            print("LARGE_FILE stage=\(stage) ms=\(FormattingBenchmark.milliseconds(start.duration(to: .now))) max_main_gap_ms=\(maxGap)")
            maxGap = 0
        }
        var start = ContinuousClock.now
        guard case .opened = await files.open(fixture), let view = editor.activeScintillaView else {
            throw Failure.invariant("open")
        }
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
        await report(start)
        print("LARGE_FILE bytes=\(view.documentByteLength) lines=\(view.lineCount) wrap=\(view.isWordWrapEnabled)")
        // Keep the first probe bounded; --large-file navigates to EOF as a
        // separate measured stage so an unexpected stall is visible in logs.
        stage = "navigate_end"
        print("LARGE_FILE begin=\(stage)")
        start = .now
        view.setPrimarySelectionUTF8Range(NSRange(location: Int(view.documentByteLength), length: 0))
        await report(start)
        stage = "type_undo"
        let reads = view.snapshotReadCount
        start = .now
        let byteCount = view.documentByteLength
        view.beginGroupedUndo()
        view.insertCommittedText("한글🦆\n")
        view.endGroupedUndo()
        print("LARGE_FILE after_insert_bytes=\(view.documentByteLength) revision=\(view.revision)")
        view.undo()
        print("LARGE_FILE after_undo_bytes=\(view.documentByteLength) expected_bytes=\(byteCount) revision=\(view.revision)")
        window.contentView?.displayIfNeeded()
        await report(start)
        guard view.snapshotReadCount == reads else { throw Failure.invariant("typing read full snapshot") }
        stage = "warm_typing_20"
        start = .now
        view.beginGroupedUndo()
        for _ in 0..<20 { view.insertCommittedText("x") }
        view.endGroupedUndo()
        view.undo()
        await report(start)
        stage = "save_after_undo"
        start = .now
        guard case .saved = await files.saveActive() else { throw Failure.invariant("save") }
        await report(start)
        guard try await digest(fixture) == originalDigest else { throw Failure.invariant("save changed bytes") }
        let suffix = Data("저장 성능🦆\n".utf8)
        let appendedDigest = try await digest(fixture, appending: suffix)
        view.beginGroupedUndo()
        view.insertCommittedText(String(decoding: suffix, as: UTF8.self))
        view.endGroupedUndo()
        stage = "save_append"
        start = .now
        guard case .saved = await files.saveActive() else { throw Failure.invariant("append save") }
        await report(start)
        guard try await digest(fixture) == appendedDigest else { throw Failure.invariant("append save bytes") }
        view.undo()
        stage = "save_truncate"
        start = .now
        guard case .saved = await files.saveActive() else { throw Failure.invariant("truncate save") }
        await report(start)
        guard try await digest(fixture) == originalDigest else { throw Failure.invariant("truncate save bytes") }
        stage = "recovery"
        start = .now
        guard case .saved = await recovery.flush() else { throw Failure.invariant("recovery") }
        await report(start)
        stage = "termination_unchanged"
        start = .now
        guard case .saved = await recovery.flushForTermination() else { throw Failure.invariant("termination") }
        await report(start)
        stage = "termination_dirty"
        view.insertCommittedText("미저장🦆")
        start = .now
        guard case .saved = await recovery.flushForTermination() else { throw Failure.invariant("dirty termination") }
        await report(start)
        guard let stored = try await recoveryStore.loadLatest(),
              let buffer = workspace.snapshot().activeBuffer,
              let recovered = stored.archive.buffers[buffer.bufferID],
              recovered.revision == buffer.revision,
              recovered.utf8.suffix(Data("미저장🦆".utf8).count) == Data("미저장🦆".utf8) else {
            throw Failure.invariant("durable recovery lost final edit")
        }
        print("LARGE_FILE verified save_exact=true unsaved_recovery=true snapshot_reads_during_typing=0")
    }

    private static func digest(_ url: URL, appending suffix: Data = Data()) async throws -> SHA256.Digest {
        try await Task.detached {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var hash = SHA256()
            while let bytes = try file.read(upToCount: 8 * 1_024 * 1_024), !bytes.isEmpty { hash.update(data: bytes) }
            hash.update(data: suffix)
            return hash.finalize()
        }.value
    }
}
