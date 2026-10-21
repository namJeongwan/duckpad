import AppKit
import DuckpadScintillaBridge
import Testing

/// Run alone in Release: DUCKPAD_OCCURRENCE_PERFORMANCE=1 swift test -c release --filter WordOccurrencePerformanceTests
@Suite(.serialized) @MainActor
struct WordOccurrencePerformanceTests {
    private func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DUCKPAD_OCCURRENCE_PERFORMANCE"] == "1"),
          arguments: ["sparse-64MiB", "dense-100k-limit", "wrapped-clone"])
    func visibleEditorStaysResponsiveDuringScanAndPublication(fixture: String) async throws {
        _ = NSApplication.shared
        let source: String
        let expected: Int
        switch fixture {
        case "sparse-64MiB":
            let padding = String(repeating: String(repeating: ".", count: 1023) + "\n", count: 32_768)
            source = "ap\n" + padding + "ap\n" + padding + "ap"
            expected = 3
        case "dense-100k-limit":
            source = String(repeating: "ap x\n", count: 100_001)
            expected = 100_000
        default:
            source = String(repeating: "ap text ", count: 2_000)
            expected = 2_000
        }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1_000, height: 340),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let primary = DPScintillaEditorView(frame: .init(x: 0, y: 0, width: 500, height: 340))
        let clone = DPScintillaEditorView(frame: primary.frame)
        primary.isWordWrapEnabled = fixture == "wrapped-clone"
        clone.isWordWrapEnabled = primary.isWordWrapEnabled
        primary.isMinimapVisible = true
        clone.isMinimapVisible = true
        try primary.loadUTF8(Data(source.utf8), revision: 1)
        clone.shareDocument(with: primary)
        let root = NSStackView(views: [primary, clone])
        root.orientation = .horizontal; root.distribution = .fillEqually; root.spacing = 1
        window.contentView = root
        window.orderFront(nil)
        defer { clone.invalidate(); primary.invalidate(); window.contentView = nil; window.close() }
        root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        var interactions: [Double] = [], turns: [Double] = [], totals: [Double] = []
        func measureInteraction(_ action: () -> Void) {
            let start = ContinuousClock.now
            action()
            root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            interactions.append(milliseconds(start.duration(to: .now)))
        }
        for iteration in 0..<3 {
            primary.setPrimarySelectionUTF8Range(.init(location: source.utf8.count, length: 0))
            try await Task.sleep(for: .milliseconds(150))
            #expect(primary.searchOverviewPositions.isEmpty)
            let start = ContinuousClock.now
            measureInteraction { primary.setPrimarySelectionUTF8Range(.init(location: 0, length: 2)) }
            let deadline = start + .seconds(15)
            var edited = false
            while ContinuousClock.now < deadline {
                let turn = ContinuousClock.now
                try await Task.sleep(for: .milliseconds(2))
                root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                turns.append(milliseconds(turn.duration(to: .now)))
                for pane in [primary, clone] {
                    let count = pane.searchOverviewPositions.count
                    #expect(count == 0 || count == expected, "Partial scrollbar result: \(count)")
                }
                if !edited, iteration == 0, primary.isWordHighlighted(atUTF8Position: 0),
                   primary.searchOverviewPositions.isEmpty {
                    edited = true
                    measureInteraction {
                        primary.setPrimarySelectionUTF8Range(.init(location: source.utf8.count, length: 0))
                        primary.insertCommittedText("!")
                    }
                    measureInteraction { primary.undo() }
                    #expect(primary.documentByteLength == source.utf8.count)
                    #expect(primary.searchOverviewPositions.isEmpty)
                    primary.setPrimarySelectionUTF8Range(.init(location: 0, length: 2))
                }
                if primary.searchOverviewPositions.count == expected && clone.searchOverviewPositions.count == expected { break }
            }
            totals.append(milliseconds(start.duration(to: .now)))
            #expect(primary.searchOverviewPositions.count == expected)
            #expect(clone.searchOverviewPositions.count == expected)
            #expect(primary.wordHighlightInspectedByteCount <= 64 * 1024 + 256)
            #expect(!primary.canUndo)
            // The cap deliberately leaves the 100,001st match undecorated.
            if fixture == "dense-100k-limit" { #expect(!primary.isWordHighlighted(atUTF8Position: 500_000)) }
            if fixture == "sparse-64MiB" && iteration == 0 { #expect(edited) }
        }
        let sorted = turns.sorted()
        let p95 = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
        print("DUCKPAD_OCCURRENCE_PERF fixture=\(fixture) interaction_max_ms=\(interactions.max()!) main_turn_p95_ms=\(p95) main_turn_max_ms=\(turns.max()!) scan_total_ms=\(totals) samples=\(turns.count)")
        #expect(interactions.allSatisfy { $0 < 50 }, "Input plus display exceeded 50ms")
        #expect(turns.allSatisfy { $0 < 50 }, "Scan/publication plus display blocked a main-actor turn over 50ms")
    }
}
