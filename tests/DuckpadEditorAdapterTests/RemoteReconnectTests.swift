import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
import Testing

@MainActor private final class ReconnectReader: FileObservationReading {
    var failures = 0, calls = 0
    var offsets = [UInt64]()
    var partialStage = 0
    var prefix = Data()
    func read(_ source: FileObservationSource, after cursor: FileObservationCursor?, maximumBytes: Int) async throws -> FileObservationRead {
        calls += 1; offsets.append(cursor?.offset ?? 0)
        if partialStage == 1, let cursor {
            partialStage = 2
            let data = prefix + Data([0xED, 0x95])
            return .init(data: data, cursor: .init(identity: cursor.identity, offset: cursor.offset + UInt64(data.count)), sourceSize: cursor.offset + UInt64(data.count) + 2, reset: false)
        }
        if failures > 0 { failures -= 1; throw FileObservationError.unavailable }
        if partialStage == 2, let cursor {
            partialStage = 3
            return .init(data: Data([0x9C, 10]), cursor: .init(identity: cursor.identity, offset: cursor.offset + 2), sourceSize: cursor.offset + 2, reset: false)
        }
        guard case .ssh(let location) = source else { throw FileObservationError.invalidResponse }
        return try await LocalFileObservationReader().read(.local(location.path), after: cursor, maximumBytes: maximumBytes)
    }
}

@Suite(.serialized) @MainActor struct RemoteReconnectTests {
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(predicate())
    }
    @Test func tailStopsAfterThreeRetriesAndManualRestartKeepsSnapshotAndOffset() async throws {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        try Data("start\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore()), editor = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
        workspace.onChange = { binding.render($0) }; _ = await workspace.start()
        defer { editor.invalidate() }
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
        #expect(reader.calls == 4 && reader.offsets == [6, 6, 6, 6])
        #expect(view.contentUTF8 == Data("start\n".utf8))
        #expect(!workspace.snapshot().tabs.first(where: { $0.id == tab })!.isDirty)
        try Data("start\n한글\n".utf8).write(to: file)
        reader.failures = 0
        #expect(tail.canRetry(tabID: tab))
        tail.retry(tabID: tab)
        try await wait { view.contentUTF8 == Data("start\n한글\n".utf8) }
        #expect(reader.offsets.last == 6 && tail.states[tab] == .following)
    }
    @Test func manualRetryKeepsViewportAndUnreadCountAndRereadsIncompleteUTF8() async throws {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        let original = String(repeating: "before\n", count: 300)
        try Data(original.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore()), editor = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
        workspace.onChange = { binding.render($0) }; _ = await workspace.start()
        defer { editor.invalidate() }
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
        #expect(reader.offsets.last == UInt64(original.utf8.count + 6))
        #expect(tail.unreadLineCounts[tab] == 2 && view.firstVisibleLine == 0)
        #expect(view.anchorUTF8Position == 2 && view.caretUTF8Position == 10)
    }

    @Test func automaticReconnectRetainsIncompleteUTF8AndStopCancelsBackoff() async throws {
        _ = NSApplication.shared
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        try Data("start\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore()), editor = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
        workspace.onChange = { binding.render($0) }; _ = await workspace.start()
        defer { editor.invalidate() }
        let reader = ReconnectReader()
        let tab = try await RemoteFileUseCase(workspace: workspace, editor: editor, reader: reader).open(RemoteFileLocation(host: "fixture", path: file.path)!)
        let view = try #require(editor.activeScintillaView)
        let tail = TailFileUseCase(workspace: workspace, editor: editor, reader: reader,
            retryPolicy: .init(delays: [.milliseconds(5), .milliseconds(5), .milliseconds(5)]))
        defer { tail.cancelAll() }
        reader.calls = 0; reader.offsets = []; reader.partialStage = 1; reader.failures = 3
        try await tail.start(tabID: tab)
        try await wait { reader.partialStage == 3 }
        #expect(reader.calls == 5 && reader.offsets == [6, 8, 8, 8, 8])
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
