import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadScintillaBridge
import Foundation
import Testing

@Suite(.serialized) @MainActor struct LogHighlightingTests {
    private func hosted() -> (NSWindow, DPScintillaEditorView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 980, height: 380), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = DPScintillaEditorView(frame: window.contentView!.bounds)
        window.contentView = view
        return (window, view)
    }
    private func activate(_ view: DPScintillaEditorView) {
        #expect(view.applyLexerNamed("duckpadlog", keywords: [], tabWidth: 4, useTabs: false, folding: false, braceMatching: false, maximumStyleBytes: 1_024))
    }
    private func waitForStyles(_ view: DPScintillaEditorView) async throws {
        for _ in 0..<2_000 {
            if !view.asynchronousStylingPending { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!view.asynchronousStylingPending)
    }
    private func offset(_ token: String, in text: String) throws -> UInt {
        let range = try #require(text.range(of: token)); return UInt(text[..<range.lowerBound].utf8.count)
    }
    @Test func commonLevelsTimeAndStacksHaveDistinctReadableColorsInAllPalettes() async throws {
        let source = "2026-10-22 10:20:30.101 TRACE raw details\n2026-10-22 10:20:30.102 DEBUG worker state\n2026-10-22 10:20:30.103 INFO 서버 시작 한글 🦆\n2026-10-22 10:20:30.104 WARN slow request\n2026-10-22 10:20:30.105 ERROR connection failed\n2026-10-22 10:20:30.106 FATAL shutting down\n    at example.Service.run(Service.java:42)\n{\"level\":\"error\",\"message\":\"structured event\"}\n\u{1b}[32;1mANSI green\u{1b}[0m  \u{1b}[38;2;160;100;210mRGB purple\u{1b}[0m\n"
        let (window, view) = hosted(); defer { view.invalidate(); window.close() }
        try view.loadUTF8(Data(source.utf8), revision: 0); activate(view)
        for palette: DPScintillaPalette in [.light, .dark, .highContrastLight, .highContrastDark] {
            view.apply(palette); try await waitForStyles(view)
            let levels = try ["TRACE", "DEBUG", "INFO", "WARN", "ERROR"].map { view.style(atUTF8Position: try offset($0, in: source)) }
            let colors = Set(levels.map { view.foregroundColor(forStyle: $0) })
            #expect(colors.count == 5)
            #expect(view.style(atUTF8Position: try offset("2026", in: source)) == 120)
            #expect(view.style(atUTF8Position: try offset("at example", in: source)) == 128)
            #expect(view.style(atUTF8Position: try offset("level", in: source)) == 136)
            #expect(view.contentUTF8 == Data(source.utf8) && !view.canUndo)
            if let directory = ProcessInfo.processInfo.environment["DUCKPAD_LOG_SNAPSHOTS"] {
                window.appearance = NSAppearance(named: palette == .dark || palette == .highContrastDark ? .darkAqua : .aqua)
                window.orderFront(nil); view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: image)
                let url = URL(fileURLWithPath: directory); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try #require(image.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent("logs-\(palette.rawValue).png"))
            }
        }
    }
    @Test func ANSIColorsFontStateAndSplitSequencesPreserveBytesAndResetForPlainText() async throws {
        let source = "\u{1b}[31;1mred\ncontinued\u{1b}[0m plain \u{1b}[38;5;196mindexed\u{1b}[0m \u{1b}[38;2;12;34;56;48;2;80;90;100;3;4mtruecolor\u{1b}[0m \u{1b}[38;2;255"
        let (window, view) = hosted(); defer { view.invalidate(); window.close() }
        try view.loadUTF8(Data(source.utf8), revision: 0); activate(view); try await waitForStyles(view)
        #expect(!view.isStyleVisible(15))
        #expect(view.style(atUTF8Position: 0) == 15)
        #expect(view.style(atUTF8Position: try offset("red", in: source)) == 65)
        #expect(view.ansiForeground(atUTF8Position: try offset("continued", in: source)) != -1)
        #expect(view.ansiForeground(atUTF8Position: try offset("plain", in: source)) == -1)
        #expect(view.ansiForeground(atUTF8Position: try offset("indexed", in: source)) == 0x0000FF)
        #expect(view.ansiForeground(atUTF8Position: try offset("truecolor", in: source)) == 0x38220C)
        #expect(view.ansiBackground(atUTF8Position: try offset("truecolor", in: source)) == 0x645A50)
        #expect(view.style(atUTF8Position: try offset("truecolor", in: source)) == 70)
        let append = ";0;0m한글🦆\u{1b}[0m\n"
        #expect(view.applyObservedUTF8(Data(append.utf8), revision: 1, reset: false))
        try await waitForStyles(view)
        #expect(view.ansiForeground(atUTF8Position: try offset("한글", in: source + append)) == 0x0000FF)
        #expect(view.contentUTF8 == Data((source + append).utf8) && !view.canUndo)
        #expect(view.applyLexerNamed("null", keywords: [], tabWidth: 4, useTabs: false, folding: false, braceMatching: false, maximumStyleBytes: 1_024))
        #expect(view.isStyleVisible(15))
        #expect(view.ansiForeground(atUTF8Position: try offset("red", in: source)) == -1)
        #expect(view.ansiBackground(atUTF8Position: try offset("truecolor", in: source)) == -1)
        #expect(view.contentUTF8 == Data((source + append).utf8))
    }
    @Test func editUndoRotationAndPendingLexerReplacementCannotLeaveStaleANSI() async throws {
        let (window, view) = hosted(); defer { view.invalidate(); window.close() }
        let source = "\u{1b}[31mred\nnext line\n"
        try view.loadUTF8(Data(source.utf8), revision: 0); activate(view); try await waitForStyles(view)
        let before = view.ansiForeground(atUTF8Position: 5)
        try view.replaceUTF8Range(.init(location: 3, length: 1), withReplacement: Data("2".utf8), expectedRevision: 0, resultingRevision: 1)
        try await waitForStyles(view)
        #expect(view.ansiForeground(atUTF8Position: 5) != before)
        view.undo(); try await waitForStyles(view)
        #expect(view.contentUTF8 == Data(source.utf8))
        #expect(view.ansiForeground(atUTF8Position: 5) == before)
        #expect(view.applyObservedUTF8(Data("INFO rotated\n".utf8), revision: view.revision + 1, reset: true))
        try await waitForStyles(view)
        #expect(view.ansiForeground(atUTF8Position: 5) == -1)
        try view.loadUTF8(Data(String(repeating: "INFO initial\n", count: 50_000).utf8), revision: 0); activate(view)
        #expect(view.applyLexerNamed("null", keywords: [], tabWidth: 4, useTabs: false, folding: false, braceMatching: false, maximumStyleBytes: 1_024))
        try await Task.sleep(for: .milliseconds(30))
        #expect(view.foregroundColor(forStyle: 15) == view.foregroundColor(forStyle: 0))
        #expect(!view.asynchronousStylingPending)
    }
    @Test func searchAndOccurrenceRemainVisibleOverANSISolidBackground() async throws {
        let source = "\u{1b}[48;2;60;60;60m                highlightedtoken highlightedtoken\u{1b}[0m\n"
        let (window, view) = hosted(); defer { view.invalidate(); window.close() }
        try view.loadUTF8(Data(source.utf8), revision: 0); activate(view); view.apply(.dark)
        view.isCaretWordHighlightEnabled = false
        try await waitForStyles(view)
        window.orderFront(nil); view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        func pixels() throws -> [UInt8] {
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let scaleX = Double(bitmap.pixelsWide) / view.bounds.width
            let scaleY = Double(bitmap.pixelsHigh) / view.bounds.height
            var result = [UInt8]()
            // Text area only: exclude the caret, gutter/overview markers and
            // scrollers so a pixel change proves the overlay itself is visible.
            for y in 0..<Int(40 * scaleY) { for x in Int(90 * scaleX)..<Int(600 * scaleX) {
                let c = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                result += [UInt8(clamping: Int(c.redComponent * 255)), UInt8(clamping: Int(c.greenComponent * 255)), UInt8(clamping: Int(c.blueComponent * 255))]
            } }
            return result
        }
        let plain = try pixels()
        let first = try offset("highlightedtoken", in: source)
        #expect(view.setSearchHighlights([NSValue(range: .init(location: Int(first), length: 16))], revision: 0))
        window.displayIfNeeded()
        let found = try pixels()
        #expect(zip(plain, found).filter { $0 != $1 }.count > 20)
        view.clearSearchHighlights()
        view.restoreCaretUTF8Position(first + 2, anchorPosition: first + 2, firstVisibleLine: 0, horizontalScrollOffset: 0, wordWrapEnabled: false)
        window.displayIfNeeded()
        let sameCaretBaseline = try pixels()
        view.isCaretWordHighlightEnabled = true
        for _ in 0..<200 where !view.isWordHighlighted(atUTF8Position: first) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(view.isWordHighlighted(atUTF8Position: first))
        window.displayIfNeeded()
        let occurrence = try pixels()
        #expect(zip(sameCaretBaseline, occurrence).filter { $0 != $1 }.count > 20)
    }

    @Test func checkpointBoundaryEditsAndUndoMatchFreshDenseSGRStyling() async throws {
        let source = String(repeating: "\u{1b}[31mred\u{1b}[0m \u{1b}[48;2;40;50;60mblue\u{1b}[0m ", count: 1_000)
        let (window, view) = hosted(), (freshWindow, fresh) = hosted()
        defer { view.invalidate(); fresh.invalidate(); window.close(); freshWindow.close() }
        try view.loadUTF8(Data(source.utf8), revision: 0); activate(view); try await waitForStyles(view)
        let insertion = Data("\u{1b}[38;2;100;50;200mINSERT\u{1b}[0m".utf8), at = 16_384 + 2
        var changed = Data(source.utf8); changed.insert(contentsOf: insertion, at: at)
        try view.replaceUTF8Range(.init(location: at, length: 0), withReplacement: insertion, expectedRevision: 0, resultingRevision: 1)
        try await waitForStyles(view)
        try fresh.loadUTF8(changed, revision: 0); activate(fresh); try await waitForStyles(fresh)
        for index in 0..<changed.count {
            let position = UInt(index)
            #expect(view.style(atUTF8Position: position) == fresh.style(atUTF8Position: position))
            #expect(view.ansiForeground(atUTF8Position: position) == fresh.ansiForeground(atUTF8Position: position))
            #expect(view.ansiBackground(atUTF8Position: position) == fresh.ansiBackground(atUTF8Position: position))
        }
        view.undo(); try await waitForStyles(view)
        try fresh.loadUTF8(Data(source.utf8), revision: 1); activate(fresh); try await waitForStyles(fresh)
        #expect(view.contentUTF8 == Data(source.utf8))
        for index in stride(from: 0, to: source.utf8.count, by: 7) {
            let position = UInt(index)
            #expect(view.style(atUTF8Position: position) == fresh.style(atUTF8Position: position))
            #expect(view.ansiForeground(atUTF8Position: position) == fresh.ansiForeground(atUTF8Position: position))
            #expect(view.ansiBackground(atUTF8Position: position) == fresh.ansiBackground(atUTF8Position: position))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DUCKPAD_LOG_PERFORMANCE"] == "1"))
    func largeLongLineLogAndTailAreBoundedWithoutWholeDocumentRestyling() async throws {
        let (window, view) = hosted(); defer { view.invalidate(); window.close() }
        let source = "\u{1b}[36m" + String(repeating: "long log 한글 🦆 ", count: 900_000)
        try view.loadUTF8(Data(source.utf8), revision: 0)
        window.orderFront(nil)
        let coldStart = ContinuousClock.now
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let coldFrame = milliseconds(coldStart.duration(to: .now))
        let began = ContinuousClock.now; activate(view)
        let initial = milliseconds(began.duration(to: .now)); #expect(initial < 50)
        #expect(!view.languageStylingFallback)
        var maximumFrame = 0.0, maximumMainTurnGap = 0.0
        let deadline = ContinuousClock.now + .seconds(20)
        while view.asynchronousStylingPending && ContinuousClock.now < deadline {
            let frameStart = ContinuousClock.now
            view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            maximumFrame = max(maximumFrame, milliseconds(frameStart.duration(to: .now)))
            let turn = ContinuousClock.now
            try await Task.sleep(for: .milliseconds(1))
            maximumMainTurnGap = max(maximumMainTurnGap, milliseconds(turn.duration(to: .now)))
        }
        #expect(!view.asynchronousStylingPending)
        #expect(maximumFrame < 50)
        #expect(maximumMainTurnGap < 50)
        view.followObservedFileEnd(); view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let before = view.logStyledByteCount, reads = view.snapshotReadCount
        let chunk = Data(String(repeating: "한글 log\n", count: 4_000).utf8)
        let appendStart = ContinuousClock.now
        #expect(view.applyObservedUTF8(chunk, revision: 1, reset: false))
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let append = milliseconds(appendStart.duration(to: .now)); #expect(append < 50)
        try await waitForStyles(view)
        let styled = view.logStyledByteCount - before
        #expect(styled <= chunk.count + 64 * 1_024)
        #expect(view.snapshotReadCount == reads && !view.canUndo)
        #expect(view.maximumLogStyleSliceMicroseconds < 50_000)
        print("DUCKPAD_LOG_PERF bytes=\(source.utf8.count) initial_ms=\(initial) append_ms=\(append) append_bytes=\(chunk.count) styled_bytes=\(styled) max_slice_us=\(view.maximumLogStyleSliceMicroseconds) cold_plain_frame_ms=\(coldFrame) max_frame_ms=\(maximumFrame) max_main_turn_gap_ms=\(maximumMainTurnGap)")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DUCKPAD_LOG_PERFORMANCE"] == "1"))
    func multilineANSISharedWrappedTailStaysWithin50ms() async throws {
        let (window, view) = hosted(), (cloneWindow, clone) = hosted()
        defer { clone.invalidate(); view.invalidate(); cloneWindow.close(); window.close() }
        let line = "2026-10-22 10:20:30 INFO \u{1b}[32;1m서버 시작\u{1b}[0m " + String(repeating: "message ", count: 20) + "\n"
        let source = Data(String(repeating: line, count: 40_000).utf8)
        try view.loadUTF8(source, revision: 0); activate(view)
        clone.shareDocument(with: view); activate(clone)
        view.isInputEnabled = false; clone.isInputEnabled = false
        view.isWordWrapEnabled = true; clone.isWordWrapEnabled = true
        view.isMinimapVisible = true; clone.isMinimapVisible = true
        window.orderFront(nil); cloneWindow.orderFront(nil)
        try await waitForStyles(view)
        view.followObservedFileEnd(); clone.followObservedFileEnd()
        for target in [view, clone] { target.layoutSubtreeIfNeeded() }
        window.displayIfNeeded(); cloneWindow.displayIfNeeded()
        let reads = view.snapshotReadCount, before = view.logStyledByteCount
        let append = Data(String(repeating: line, count: 200).utf8)
        var times = [Double]()
        for revision in 1...6 {
            let start = ContinuousClock.now
            #expect(view.applyObservedUTF8(append, revision: UInt64(revision), reset: false))
            view.layoutSubtreeIfNeeded(); clone.layoutSubtreeIfNeeded()
            window.displayIfNeeded(); cloneWindow.displayIfNeeded()
            times.append(milliseconds(start.duration(to: .now)))
            try await waitForStyles(view)
        }
        #expect(times.allSatisfy { $0 < 50 })
        #expect(clone.documentByteLength == source.count + append.count * 6)
        #expect(view.snapshotReadCount == reads && !view.canUndo)
        #expect(view.logStyledByteCount - before <= (append.count + 64 * 1_024) * 6)
        print("DUCKPAD_LOG_SHARED_PERF bytes=\(source.count) append_bytes=\(append.count) max_ms=\(times.max()!) samples=\(times.count) styled_bytes=\(view.logStyledByteCount - before)")
    }
    private func milliseconds(_ duration: Duration) -> Double {
        let c = duration.components; return Double(c.seconds) * 1_000 + Double(c.attoseconds) / 1e15
    }
}
