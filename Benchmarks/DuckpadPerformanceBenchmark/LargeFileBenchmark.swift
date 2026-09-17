import AppKit
import CryptoKit
import Darwin
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

    static func run(path: String, liveAutosave: Bool = false) async throws {
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
            debounce: liveAutosave ? .milliseconds(250) : .seconds(60))
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
        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        var stageCPU = cpuSeconds()
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
            print("LARGE_FILE cpu_seconds=\(cpuSeconds() - stageCPU)")
            stageCPU = cpuSeconds()
            maxGap = 0
        }
        var start = ContinuousClock.now
        let openingStarted = start
        var firstPreviewMilliseconds: Double?
        var progressUpdates = 0
        files.onLoadingProgress = {
            guard let progress = files.loadingProgress,
                  let total = progress.totalByteCount, progress.loadedByteCount < total else { return }
            progressUpdates += 1
            let hasPreview = editor.openingPreviewByteCount != nil
                || (progress.loadedByteCount > 0 && editor.activeScintillaView?.documentByteLength ?? 0 > 0)
            if firstPreviewMilliseconds == nil, hasPreview {
                window.contentView?.layoutSubtreeIfNeeded()
                window.contentView?.displayIfNeeded()
                firstPreviewMilliseconds = FormattingBenchmark.milliseconds(openingStarted.duration(to: .now))
            }
        }
        window.makeKeyAndOrderFront(nil)
        guard case .opened = await files.open(fixture), let view = editor.activeScintillaView else {
            throw Failure.invariant("open")
        }
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
        await report(start)
        print("LARGE_FILE first_preview_ms=\(firstPreviewMilliseconds ?? -1) progress_updates=\(progressUpdates)")
        print("LARGE_FILE bytes=\(view.documentByteLength) lines=\(view.lineCount) wrap=\(view.isWordWrapEnabled)")
        // Keep the first probe bounded; --large-file navigates to EOF as a
        // separate measured stage so an unexpected stall is visible in logs.
        stage = "navigate_end"
        print("LARGE_FILE begin=\(stage)")
        start = .now
        view.setPrimarySelectionUTF8Range(NSRange(location: Int(view.documentByteLength), length: 0))
        await report(start)
        view.focusEditor()
        guard let inputClient = window.firstResponder as? any NSTextInputClient else {
            throw Failure.invariant("native input client")
        }
        stage = "input_manager_eof_queries"
        start = .now
        let eofRange = inputClient.selectedRange()
        for _ in 0..<32 {
            guard inputClient.selectedRange() == eofRange else { throw Failure.invariant("input range") }
            var actual = NSRange(location: NSNotFound, length: 0)
            guard inputClient.attributedSubstring(forProposedRange: eofRange, actualRange: &actual)?.string == "" else {
                throw Failure.invariant("input surrounding text")
            }
        }
        await report(start)
        if liveAutosave {
            stage = "initial_autosave"
            start = .now
            await recovery.waitForPendingAutosave()
            await report(start)
            print("LARGE_FILE begin=live_typing")
            for burst in 0..<3 {
                stage = "live_typing_autosave_\(burst)"
                start = .now
                view.beginGroupedUndo()
                for character in "asdasd" {
                    _ = inputClient.selectedRange()
                    inputClient.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
                    _ = inputClient.selectedRange()
                    try await Task.sleep(for: .milliseconds(80))
                }
                view.endGroupedUndo()
                await recovery.waitForPendingAutosave()
                await report(start)
            }
            for _ in 0..<3 { view.undo() }
            await recovery.waitForPendingAutosave()
        }
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
        if liveAutosave, let tab = workspace.snapshot().tabs.first(where: \.isActive) {
            stage = "close_dirty_tab"
            start = .now
            guard case .closed = await workspace.close(tabID: tab.id, decision: .discard) else {
                throw Failure.invariant("close tab")
            }
            await report(start)
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
