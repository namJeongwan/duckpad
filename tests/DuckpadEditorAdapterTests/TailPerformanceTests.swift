import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import Foundation
import Testing

@Suite(.serialized) @MainActor struct TailPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DUCKPAD_TAIL_PERFORMANCE"] == "1"))
    func appendAndDisplayOnLargeSharedDocumentStaysWithin50ms() throws {
        _ = NSApplication.shared
        let editor = ScintillaEditorAdapter()
        defer { editor.invalidate() }
        let id = BufferID()
        let source = String(repeating: "2026-10-21 INFO example log output\n", count: 500_000)
        editor.install(.init(bufferID: id, revision: 0, text: source))
        editor.display(.init(bufferID: id, revision: 0))
        editor.setWordWrapEnabled(false)
        editor.setReadOnly(true, for: id)
        editor.split(orientation: .sideBySide)
        let view = try #require(editor.activeScintillaView)
        let clone = try #require(editor.secondaryScintillaView)
        view.isMinimapVisible = true; clone.isMinimapVisible = true
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1_000, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = editor.view
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        editor.followObservedFileEnd(in: id)
        editor.view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let reads = view.snapshotReadCount
        var metrics = [Double](), reportedUserEdits = 0
        editor.onAcceptedEditLanguage = { _ in reportedUserEdits += 1 }
        let chunk = Data(String(repeating: "line 한글\n", count: 4_000).utf8)
        for revision in 1...12 {
            let start = ContinuousClock.now
            #expect(editor.applyObservedUTF8(chunk, to: .init(bufferID: id, revision: UInt64(revision)), reset: false))
            editor.view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let elapsed = start.duration(to: .now).components
            metrics.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
        }
        print("DUCKPAD_TAIL_PERF bytes=\(source.utf8.count) append_bytes=\(chunk.count) first_ms=\(metrics[0]) max_ms=\(metrics.max()!) samples=\(metrics.count)")
        #expect(metrics.allSatisfy { $0 < 50 })
        #expect(view.snapshotReadCount == reads)
        #expect(!view.canUndo)
        #expect(reportedUserEdits == 0)
        #expect(clone.documentByteLength == source.utf8.count + 12 * chunk.count)
    }
}
