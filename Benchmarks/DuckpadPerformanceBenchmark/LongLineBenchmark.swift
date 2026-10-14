import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
import Foundation
import QuartzCore

/// Reads the fixture into an isolated in-memory document. Never saves it or
/// touches the user's application session. Includes Cocoa input-manager queries,
/// status calculation, and synchronous drawing in each latency sample.
@MainActor
enum LongLineBenchmark {
    enum Failure: Error { case invariant(String) }

    static func run(path: String, lexer: String = "json") async throws {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        setbuf(stdout, nil)
        let quick = ProcessInfo.processInfo.environment["DUCKPAD_LONG_LINE_QUICK"] == "1"
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let text = String(data: original, encoding: .utf8) else {
            throw Failure.invariant("UTF-8 fixture required")
        }
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
        let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
        workspace.onChange = { binding.render($0) }
        _ = await workspace.start()
        guard let buffer = workspace.snapshot().activeBuffer else { throw Failure.invariant("buffer") }
        editor.install(.init(bufferID: buffer.bufferID, revision: buffer.revision, text: text))
        editor.display(buffer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor.view
        defer { window.close(); editor.invalidate() }
        guard let view = editor.activeScintillaView else { throw Failure.invariant("view") }
        view.isWordWrapEnabled = true
        guard view.applyLexerNamed(lexer, keywords: lexer == "json" ? ["false null true"] : [], tabWidth: 4,
            useTabs: false, folding: true, braceMatching: true, maximumStyleBytes: UInt(max(original.count + 1024, 16 * 1024 * 1024))) else {
            throw Failure.invariant("Unavailable lexer: \(lexer)")
        }
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
        CATransaction.flush()
        view.focusEditor()
        guard let input = window.firstResponder as? any NSTextInputClient else { throw Failure.invariant("input") }
        @discardableResult func finishInput() -> [Double] {
            let start = ContinuousClock.now
            let range = input.selectedRange()
            let selected = ContinuousClock.now
            var actual = NSRange()
            let surrounding = NSRange(location: max(0, range.location - 16), length: min(16, range.location))
            _ = input.attributedSubstring(forProposedRange: surrounding, actualRange: &actual)
            let substring = ContinuousClock.now
            _ = input.firstRect(forCharacterRange: range, actualRange: &actual)
            let rect = ContinuousClock.now
            _ = editor.editorStatus
            let status = ContinuousClock.now
            window.contentView?.displayIfNeeded()
            // Layer-backed views may defer drawRect until the transaction commits.
            // Include that work instead of attributing it to the next run-loop turn.
            CATransaction.flush()
            let draw = ContinuousClock.now
            return [(start, selected), (selected, substring), (substring, rect), (rect, status), (status, draw)]
                .map { FormattingBenchmark.milliseconds($0.0.duration(to: $0.1)) }
        }
        func percentile(_ values: [Double], _ fraction: Double) -> Double {
            values.sorted()[min(values.count - 1, Int(ceil(Double(values.count) * fraction)) - 1)]
        }
        var failed = false
        func report(_ label: String, _ operation: String, _ values: [Double]) {
            let maximum = values.max()!
            print("LONG_LINE position=\(label) operation=\(operation) samples=\(values.count) p50_ms=\(percentile(values, 0.5)) p95_ms=\(percentile(values, 0.95)) max_ms=\(maximum) budget_ms=50 pass=\(maximum <= 50)")
            failed = failed || maximum > 50
        }
        func measure(_ action: () -> Void) -> Double {
            let start = ContinuousClock.now
            _ = input.selectedRange()
            action()
            finishInput()
            return FormattingBenchmark.milliseconds(start.duration(to: .now))
        }
        // Include the longest JSON string, where restarting at a structural
        // token needs to cross substantially more text than at an arbitrary byte.
        var stringStart: Int?, longestStart = 0, longestLength = 0, escaped = false
        for (index, byte) in original.enumerated() {
            if let start = stringStart {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 {
                    if index - start > longestLength { longestStart = start; longestLength = index - start }
                    stringStart = nil
                }
            } else if byte == 34 { stringStart = index + 1 }
        }
        var positions = [("start", 0), ("quarter", original.count / 4), ("middle", original.count / 2),
            ("three-quarters", original.count * 3 / 4), ("long-string", longestStart + longestLength / 2),
            ("end", original.count)]
        // Run separate processes with different first positions to exercise cold
        // editing there as well, without a preceding insert/delete warm-up.
        if let first = ProcessInfo.processInfo.environment["DUCKPAD_LONG_LINE_FIRST_POSITION"],
           let index = positions.firstIndex(where: { $0.0 == first }) {
            positions.insert(positions.remove(at: index), at: 0)
        }
        for (label, proposed) in positions {
            var offset = proposed
            while offset < original.count && original[offset] & 0xC0 == 0x80 { offset += 1 }
            view.setPrimarySelectionUTF8Range(.init(location: offset, length: 0))
            finishInput()
            var insertion: [Double] = [], deletion: [Double] = []
            for _ in 0..<(quick ? 8 : 40) {
                view.beginGroupedUndo()
                let start = ContinuousClock.now
                _ = input.selectedRange()
                input.insertText("a", replacementRange: .init(location: NSNotFound, length: 0))
                let insertedAt = ContinuousClock.now
                let phases = finishInput()
                let displayedAt = ContinuousClock.now
                insertion.append(FormattingBenchmark.milliseconds(start.duration(to: displayedAt)))
                if insertion.count == 1 {
                    print("LONG_LINE_FIRST position=\(label) input_ms=\(FormattingBenchmark.milliseconds(start.duration(to: insertedAt))) selected_substring_rect_status_draw_ms=\(phases)")
                }
                view.endGroupedUndo()
                view.beginGroupedUndo()
                let deleting = ContinuousClock.now
                _ = input.selectedRange()
                window.firstResponder?.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
                finishInput()
                deletion.append(FormattingBenchmark.milliseconds(deleting.duration(to: .now)))
                view.endGroupedUndo()
                // Process pending layout/idle work between key events.
                await Task.yield()
            }
            guard view.contentUTF8 == original else { throw Failure.invariant("edit bytes at \(label)") }
            view.undo() // Undo deletion: restores the inserted character.
            var inserted = original
            inserted.insert(contentsOf: Data("a".utf8), at: offset)
            guard view.contentUTF8 == inserted else { throw Failure.invariant("delete undo at \(label)") }
            view.undo()
            guard view.contentUTF8 == original else { throw Failure.invariant("insert undo at \(label)") }
            view.redo(); view.redo()
            guard view.contentUTF8 == original else { throw Failure.invariant("redo at \(label)") }
            for (operation, values) in [("insert", insertion), ("backspace", deletion)] {
                report(label, operation, values)
            }
            var burst: [Double] = [], eraseBurst: [Double] = []
            for _ in 0..<(quick ? 4 : 16) {
                burst.append(measure {
                    input.insertText("a", replacementRange: .init(location: NSNotFound, length: 0))
                })
            }
            for _ in 0..<(quick ? 4 : 16) {
                eraseBurst.append(measure {
                    window.firstResponder?.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
                })
            }
            report(label, "burst-insert", burst)
            report(label, "burst-backspace", eraseBurst)
            guard view.contentUTF8 == original else { throw Failure.invariant("burst bytes at \(label)") }

            // Selection replacement, Undo/Redo, and punctuation can invalidate
            // different lexical regions than typing the same ordinary character.
            var replace: [Double] = [], undo: [Double] = [], redo: [Double] = []
            for replacement in ["\"", "\\", "{}", String(repeating: "a", count: 256)] {
                var end = min(offset + 32, original.count)
                while end < original.count && original[end] & 0xC0 == 0x80 { end += 1 }
                view.setPrimarySelectionUTF8Range(.init(location: offset, length: end - offset))
                finishInput()
                view.beginGroupedUndo()
                replace.append(measure {
                    input.insertText(replacement, replacementRange: .init(location: NSNotFound, length: 0))
                })
                view.endGroupedUndo()
                var expected = original
                if lexer != "null" && replacement == "\"" && end > offset {
                    // Smart editing surrounds an existing selection with quotes.
                    expected.insert(34, at: end)
                    expected.insert(34, at: offset)
                } else {
                    expected.replaceSubrange(offset..<end, with: replacement.utf8)
                }
                guard view.contentUTF8 == expected else { throw Failure.invariant("replacement at \(label)") }
                undo.append(measure { view.undo() })
                guard view.contentUTF8 == original else { throw Failure.invariant("replacement undo at \(label)") }
                redo.append(measure { view.redo() })
                guard view.contentUTF8 == expected else { throw Failure.invariant("replacement redo at \(label)") }
                undo.append(measure { view.undo() })
                guard view.contentUTF8 == original else { throw Failure.invariant("restored bytes at \(label)") }
            }
            report(label, "replace", replace)
            report(label, "undo", undo)
            report(label, "redo", redo)
        }
        print("LONG_LINE bytes=\(original.count) lines=\(view.lineCount) wrap=true lexer=\(lexer) undo_redo_exact=true")
        if failed { throw Failure.invariant("50 ms maximum budget exceeded") }
    }
}
