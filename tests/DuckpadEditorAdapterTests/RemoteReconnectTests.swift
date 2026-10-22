import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
import Testing

@MainActor private final class ReconnectReader: FileObservationReading {
    var failures = 0, calls = 0
    var offsets = [UInt64]()
    var requests = [(cursor: FileObservationCursor?, limit: Int)]()
    var partialStage = 0
    var prefix = Data()
    var holdMetadata = false, metadataWaiting = false, releaseMetadata = false
    var replacementAfterMetadata: Data?
    func read(_ source: FileObservationSource, after cursor: FileObservationCursor?, maximumBytes: Int) async throws -> FileObservationRead {
        calls += 1; offsets.append(cursor?.offset ?? 0); requests.append((cursor, maximumBytes))
        if partialStage == 1, let cursor {
            partialStage = 2
            let data = prefix + Data([0xED, 0x95])
            return .init(data: data, cursor: .init(identity: cursor.identity, offset: cursor.offset + UInt64(data.count)), sourceSize: cursor.offset + UInt64(data.count) + 2, reset: false)
        }
        if failures > 0 { failures -= 1; throw FileObservationError.unavailable }
        if partialStage == 2, cursor == nil { partialStage = 0 }
        if partialStage == 2, let cursor {
            partialStage = 3
            return .init(data: Data([0x9C, 10]), cursor: .init(identity: cursor.identity, offset: cursor.offset + 2), sourceSize: cursor.offset + 2, reset: false)
        }
        guard case .ssh(let location) = source else { throw FileObservationError.invalidResponse }
        if cursor == nil, holdMetadata {
            metadataWaiting = true
            while !releaseMetadata { await Task.yield() } // deliberately simulate a late, non-cooperative reply
        }
        let read = try await LocalFileObservationReader().read(.local(location.path), after: cursor, maximumBytes: maximumBytes)
        if cursor == nil, let replacementAfterMetadata {
            self.replacementAfterMetadata = nil
            try replacementAfterMetadata.write(to: URL(fileURLWithPath: location.path), options: .atomic)
        }
        return read
    }
}

@Suite(.serialized) @MainActor struct RemoteReconnectTests {
    private func showEditor(_ editor: ScintillaEditorAdapter) -> NSWindow {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1_000, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = editor.view
        window.orderFront(nil); editor.view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        return window
    }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(predicate())
    }
    @Test func tailStopsAfterThreeRetriesAndManualRestartReloadsLatestSnapshot() async throws {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        try Data("start\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore()), editor = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
        workspace.onChange = { binding.render($0) }; _ = await workspace.start()
        let window = showEditor(editor)
        defer { window.contentView = nil; window.close(); editor.invalidate() }
        let reader = ReconnectReader()
        let tab = try await RemoteFileUseCase(workspace: workspace, editor: editor, reader: reader).open(RemoteFileLocation(host: "fixture", path: file.path)!)
        let view = try #require(editor.activeScintillaView)
        let tail = TailFileUseCase(workspace: workspace, editor: editor, reader: reader,
            retryPolicy: .init(delays: [.milliseconds(5), .milliseconds(5), .milliseconds(5)]))
        defer { tail.cancelAll() }
        reader.calls = 0; reader.offsets = []; reader.failures = 10
        try await tail.start(tabID: tab)
        try await wait { tail.states[tab] == .failed(.unavailable) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(reader.calls == 4 && reader.offsets == [6, 0, 0, 0])
        #expect(view.contentUTF8 == Data("start\n".utf8))
        #expect(!workspace.snapshot().tabs.first(where: { $0.id == tab })!.isDirty)
        try Data("start\n한글\n".utf8).write(to: file)
        reader.failures = 0
        #expect(tail.canRetry(tabID: tab))
        tail.retry(tabID: tab)
        try await wait { view.contentUTF8 == Data("start\n한글\n".utf8) }
        #expect(reader.requests.suffix(2).first?.cursor == nil)
        #expect(reader.offsets.last == 0 && tail.states[tab] == .following)
        #expect(editor.isObservedFileFollowingEnd(in: workspace.fileContext(tabID: tab)!.buffer.bufferID))
    }
    @Test func manualRetryFollowsEndClearsUnreadAndReplacesIncompleteUTF8() async throws {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        let original = String(repeating: "before\n", count: 300)
        try Data(original.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore()), editor = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
        workspace.onChange = { binding.render($0) }; _ = await workspace.start()
        let window = showEditor(editor)
        defer { window.contentView = nil; window.close(); editor.invalidate() }
        let reader = ReconnectReader()
        let tab = try await RemoteFileUseCase(workspace: workspace, editor: editor, reader: reader).open(RemoteFileLocation(host: "fixture", path: file.path)!)
        let view = try #require(editor.activeScintillaView)
        let tail = TailFileUseCase(workspace: workspace, editor: editor, reader: reader,
            retryPolicy: .init(delays: [.milliseconds(5), .milliseconds(5), .milliseconds(5)]))
        defer { tail.cancelAll() }
        reader.calls = 0; reader.offsets = []; reader.partialStage = 1; reader.prefix = Data("added\n".utf8); reader.failures = 4
        try await tail.start(tabID: tab)
        view.restoreCaretUTF8Position(10, anchorPosition: 2, firstVisibleLine: 0, horizontalScrollOffset: 0, wordWrapEnabled: false)
        try await wait { tail.states[tab] == .failed(.unavailable) }
        #expect(tail.unreadLineCounts[tab] == 1 && view.firstVisibleLine == 0)
        try Data((original + "added\n한\n").utf8).write(to: file)
        reader.failures = 0; reader.partialStage = 0
        tail.retry(tabID: tab)
        try await wait { view.contentUTF8 == Data((original + "added\n한\n").utf8) }
        #expect(reader.requests.suffix(2).first?.cursor == nil)
        #expect(tail.unreadLineCounts[tab] == nil)
        #expect(view.firstVisibleLine > 0)
        #expect(view.anchorUTF8Position == view.caretUTF8Position)
        #expect(editor.isObservedFileFollowingEnd(in: workspace.fileContext(tabID: tab)!.buffer.bufferID))
        #expect(!view.canUndo && !view.isInputEnabled)
        #expect(workspace.snapshot().tabs.first(where: { $0.id == tab })?.isDirty == false)
    }

    @Test(arguments: [false, true])
    func manualReconnectSkipsLargeBacklogAndHandlesRotationAndSplitUTF8(rotated: Bool) async throws {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        try Data("old snapshot\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore()), editor = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
        workspace.onChange = { binding.render($0) }; _ = await workspace.start()
        let window = showEditor(editor)
        defer { window.contentView = nil; window.close(); editor.invalidate() }
        let reader = ReconnectReader()
        let location = try #require(RemoteFileLocation(host: "fixture", path: file.path))
        let tab = try await RemoteFileUseCase(workspace: workspace, editor: editor, reader: reader).open(location)
        let view = try #require(editor.activeScintillaView)
        let tail = TailFileUseCase(workspace: workspace, editor: editor, reader: reader, retryPolicy: .init(delays: []))
        defer { tail.cancelAll() }
        reader.failures = 1
        try await tail.start(tabID: tab)
        try await wait { tail.states[tab] == .failed(.unavailable) }
        let latest = Data(String(repeating: "2026 INFO 한글 🦆 backlog\n", count: 100_000).utf8)
            + Data("latest line\n".utf8) + Data([0xED, 0x95])
        try latest.write(to: file, options: rotated ? .atomic : [])
        reader.requests = []
        let began = ContinuousClock.now
        tail.retry(tabID: tab)
        try await wait { tail.states[tab] == .following && view.contentUTF8.suffix(12) == Data("latest line\n".utf8) }
        let requests = reader.requests
        let elapsed = began.duration(to: .now).components
        let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        print("DUCKPAD_RECONNECT bytes=\(latest.count) requests=\(requests.count) visible_bytes=\(view.documentByteLength) milliseconds=\(milliseconds) rotated=\(rotated)")
        #expect(requests.count == 2)
        #expect(requests.first?.cursor == nil && requests.first?.limit == 1)
        #expect(requests.last?.cursor?.offset == UInt64(latest.count - (64 * 1_024 - 4)))
        #expect(requests.last?.limit == 64 * 1_024 - 4)
        #expect(view.documentByteLength <= 64 * 1_024)
        #expect(String(data: view.contentUTF8, encoding: .utf8)?.contains("�") == false)
        let context = try #require(workspace.fileContext(tabID: tab))
        #expect(context.binding?.observedIdentity.byteCount == UInt64(latest.count - 2))
        #expect(editor.isObservedFileFollowingEnd(in: context.buffer.bufferID))
        #expect(try editor.recoveryCapture(for: context.buffer.bufferID)?.materializedSnapshot().utf8 == view.contentUTF8)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([0x9C, 10])); try handle.close()
        try await wait { view.contentUTF8.suffix(4) == Data("한\n".utf8) }
        #expect(tail.unreadLineCounts[tab] == nil && !view.canUndo)
        #expect(!workspace.snapshot().tabs.first(where: { $0.id == tab })!.isDirty)
    }

    @Test(arguments: ["empty", "rotation", "cancel"])
    func reconnectPreservesSnapshotUntilSuccessAndRejectsStaleReplies(scenario: String) async throws {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        let original = Data("readable old snapshot\n".utf8)
        try original.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore()), editor = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
        workspace.onChange = { binding.render($0) }; _ = await workspace.start()
        let window = showEditor(editor)
        defer { window.contentView = nil; window.close(); editor.invalidate() }
        let reader = ReconnectReader()
        let location = try #require(RemoteFileLocation(host: "fixture", path: file.path))
        let tab = try await RemoteFileUseCase(workspace: workspace, editor: editor, reader: reader).open(location)
        let view = try #require(editor.activeScintillaView)
        let tail = TailFileUseCase(workspace: workspace, editor: editor, reader: reader, retryPolicy: .init(delays: [.zero]))
        defer { reader.releaseMetadata = true; tail.cancelAll() }
        reader.failures = 2
        try await tail.start(tabID: tab)
        try await wait { tail.states[tab] == .failed(.unavailable) }
        #expect(view.contentUTF8 == original)
        if scenario == "empty" { try Data().write(to: file) }
        if scenario == "rotation" { reader.replacementAfterMetadata = Data("new rotated snapshot\n".utf8) }
        if scenario == "cancel" { reader.holdMetadata = true }
        tail.retry(tabID: tab)
        #expect(tail.states[tab] != .following && !tail.canRetry(tabID: tab))
        if scenario == "cancel" {
            try await wait { reader.metadataWaiting }
            #expect(view.contentUTF8 == original)
            let revision = view.revision
            tail.cancel(tab)
            reader.releaseMetadata = true
            try await Task.sleep(for: .milliseconds(50))
            #expect(view.contentUTF8 == original && view.revision == revision && tail.states[tab] == nil)
        } else {
            let expected = scenario == "empty" ? Data() : Data("new rotated snapshot\n".utf8)
            try await wait { tail.states[tab] == .following && view.contentUTF8 == expected }
            #expect(editor.isObservedFileFollowingEnd(in: workspace.fileContext(tabID: tab)!.buffer.bufferID))
            #expect(!view.canUndo && !view.isInputEnabled)
        }
    }

    @Test func automaticReconnectReloadsLatestAndStopCancelsBackoff() async throws {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        try Data("start\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore()), editor = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
        workspace.onChange = { binding.render($0) }; _ = await workspace.start()
        let window = showEditor(editor)
        defer { window.contentView = nil; window.close(); editor.invalidate() }
        let reader = ReconnectReader()
        let tab = try await RemoteFileUseCase(workspace: workspace, editor: editor, reader: reader).open(RemoteFileLocation(host: "fixture", path: file.path)!)
        let view = try #require(editor.activeScintillaView)
        let tail = TailFileUseCase(workspace: workspace, editor: editor, reader: reader,
            retryPolicy: .init(delays: [.milliseconds(5), .milliseconds(5), .milliseconds(5)]))
        defer { tail.cancelAll() }
        try Data("start\n한\n".utf8).write(to: file)
        reader.calls = 0; reader.offsets = []; reader.partialStage = 1; reader.failures = 3
        try await tail.start(tabID: tab)
        try await wait { view.contentUTF8 == Data("start\n한\n".utf8) && tail.states[tab] == .following }
        #expect(reader.calls == 6 && reader.offsets == [6, 8, 0, 0, 0, 0])
        #expect(view.contentUTF8 == Data("start\n한\n".utf8))
        #expect(tail.states[tab] == .following)
        tail.cancel(tab)
        reader.partialStage = 0; reader.failures = 10
        try await tail.start(tabID: tab)
        try await wait { if case .reconnecting = tail.states[tab] { return true }; return false }
        tail.cancel(tab)
        let stoppedAt = reader.calls
        try await Task.sleep(for: .milliseconds(80))
        #expect(reader.calls == stoppedAt && tail.states[tab] == nil)
    }
}
