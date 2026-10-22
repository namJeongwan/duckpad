import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import Foundation
import Testing

/// Counts publication bytes without allocating a 64 MiB native document.
@MainActor private final class TailBudgetEditor: ObservedFileEditorPort {
    var onEdit: ((EditorIncrementalEdit) -> EditorEditOutcome)?
    var bytes = 0, followRequests = 0
    func display(_ buffer: EditorBufferDescriptor) { }
    func install(_ snapshot: EditorTextSnapshot) { bytes = snapshot.text.utf8.count }
    func snapshot(for id: BufferID) -> EditorTextSnapshot? { nil }
    func retire(bufferID: BufferID) { }
    func setInputEnabled(_ enabled: Bool) { }
    func focus() { }
    func applyObservedUTF8(_ data: Data, to buffer: EditorBufferDescriptor, reset: Bool) -> Bool {
        bytes = reset ? data.count : bytes + data.count; return true
    }
    func observedByteCount(for id: BufferID) -> Int? { bytes }
    func isObservedFileFollowingEnd(in id: BufferID) -> Bool { false }
    func followObservedFileEnd(in id: BufferID) { followRequests += 1 }
}
@MainActor private final class TailBudgetReader: FileObservationReading {
    var remaining = 0, calls = 0, failures = 0, injectedFailure = false
    func read(_ source: FileObservationSource, after cursor: FileObservationCursor?, maximumBytes: Int) async throws -> FileObservationRead {
        calls += 1
        guard let cursor else { return .init(data: Data(), cursor: .init(identity: "1:2", offset: 0), sourceSize: 0, reset: false) }
        if !injectedFailure, cursor.offset >= UInt64(TailFileUseCase.maximumGrowthBytes - 64 * 1_024) {
            injectedFailure = true; failures = 4
        }
        if failures > 0 { failures -= 1; throw FileObservationError.unavailable }
        let count = min(maximumBytes, remaining); remaining -= count
        return .init(data: Data(repeating: 65, count: count), cursor: .init(identity: "1:2", offset: cursor.offset + UInt64(count)),
            sourceSize: cursor.offset + UInt64(count + remaining), reset: false)
    }
}
@MainActor struct RemoteRetryBudgetTests {
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<2_000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(predicate())
    }
    @Test func manualRetryCannotResetObservationGrowthLimit() async throws {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        _ = await workspace.start()
        let editor = TailBudgetEditor(), reader = TailBudgetReader()
        let tab = try await RemoteFileUseCase(workspace: workspace, editor: editor, reader: reader).open(RemoteFileLocation(host: "fixture", path: "/log")!)
        reader.remaining = TailFileUseCase.maximumGrowthBytes + 1_024
        let tail = TailFileUseCase(workspace: workspace, editor: editor, reader: reader,
            retryPolicy: .init(delays: [.zero, .zero, .zero]))
        defer { tail.cancelAll() }
        try await tail.start(tabID: tab)
        try await wait { tail.states[tab] == .failed(.unavailable) }
        #expect(editor.bytes > TailFileUseCase.maximumGrowthBytes - 128 * 1_024)
        tail.retry(tabID: tab)
        try await wait { tail.states[tab] == .failed(.tooLarge) }
        #expect(editor.bytes <= TailFileUseCase.maximumGrowthBytes)
        #expect(editor.followRequests == 1 && !tail.canRetry(tabID: tab))
        let calls = reader.calls
        tail.retry(tabID: tab)
        try await Task.sleep(for: .milliseconds(30))
        #expect(reader.calls == calls)
    }
}
