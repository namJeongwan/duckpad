import AppKit
import DuckpadLocalization
import Testing
@testable import DuckpadPresentation

@MainActor private final class SuggestionCommitTarget: NSObject {
    var values = [String]()
    @objc func commit(_ sender: FilteredSuggestionField) { values.append(sender.stringValue) }
}

@Suite(.serialized) @MainActor struct FilteredSuggestionFieldTests {
    private func hosted() -> (NSWindow, FilteredSuggestionField) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 300, y: 300, width: 420, height: 220), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let field = FilteredSuggestionField(symbolName: "server.rack")
        field.frame = .init(x: 20, y: 150, width: 330, height: 28)
        window.contentView!.addSubview(field)
        window.makeKeyAndOrderFront(nil); window.contentView?.layoutSubtreeIfNeeded()
        return (window, field)
    }
    private func type(_ value: String, in field: FilteredSuggestionField) throws -> NSTextView {
        field.focus()
        let editor = try #require(field.input.currentEditor() as? NSTextView)
        editor.insertText(value, replacementRange: .init(location: 0, length: editor.string.utf16.count))
        return editor
    }
    @Test func typingFiltersBySubstringWithoutCompletingOrRejectingCustomHosts() throws {
        let (window, field) = hosted(); defer { field.dismissSuggestions(); window.close() }
        field.stringValue = "stage"
        field.setSuggestions(["prod-api", "stage", "user@prod-db", "prod-api", "DEV-api"])
        field.focus()
        #expect(field.filteredSuggestions.count == 4)
        _ = try type("API", in: field)
        #expect(field.filteredSuggestions == ["prod-api", "DEV-api"])
        #expect(field.stringValue == "API")
        #expect(field.suggestionPanel?.isVisible == true)
        _ = try type("user@custom.example", in: field)
        #expect(field.filteredSuggestions.isEmpty && field.stringValue == "user@custom.example")
        #expect(field.suggestionPanel?.isVisible == true)
        _ = try type("", in: field)
        #expect(field.filteredSuggestions == ["prod-api", "stage", "user@prod-db", "DEV-api"])
    }
    @Test func liveMarkedTextAndLateCatalogUpdatesPreserveCompositionAndSelection() throws {
        let (window, field) = hosted(); defer { field.dismissSuggestions(); window.close() }
        field.setSuggestions(["서울-prod", "서버-dev", "부산"]); field.focus()
        let editor = try #require(field.input.currentEditor() as? NSTextView)
        for text in ["서", "서울", "서", "서버"] {
            editor.setMarkedText(text, selectedRange: .init(location: text.utf16.count, length: 0), replacementRange: .init(location: 0, length: editor.string.utf16.count))
            #expect(editor.hasMarkedText())
            #expect(editor.string == text)
            #expect(field.filteredSuggestions == (text == "서울" ? ["서울-prod"] : text == "서버" ? ["서버-dev"] : ["서울-prod", "서버-dev"]))
        }
        let marked = editor.markedRange(), selected = editor.selectedRange()
        field.setSuggestions(["서울-prod", "서버-dev", "서버-stage", "부산"])
        #expect(field.filteredSuggestions == ["서버-dev", "서버-stage"])
        #expect(editor.hasMarkedText() && editor.markedRange() == marked && editor.selectedRange() == selected)
        #expect(!field.control(field.input, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(editor.string == "서버" && editor.hasMarkedText())
        field.choose(row: 0)
        #expect(field.stringValue == "서버-dev" && !editor.hasMarkedText())
        #expect(window.firstResponder === editor)
    }
    @Test func keyboardSelectionCommitsOnlyOnReturnAndEscapeKeepsTypedValue() throws {
        let (window, field) = hosted(); defer { field.dismissSuggestions(); window.close() }
        let target = SuggestionCommitTarget(); field.target = target; field.action = #selector(SuggestionCommitTarget.commit(_:))
        field.setSuggestions(["prod-api", "prod-db", "stage"])
        let editor = try type("prod", in: field)
        #expect(target.values.isEmpty)
        #expect(field.control(field.input, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        #expect(field.control(field.input, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        #expect(field.control(field.input, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(target.values == ["prod-db"] && field.stringValue == "prod-db")
        #expect(field.suggestionPanel?.isVisible == false)
        _ = try type("custom", in: field)
        #expect(field.control(field.input, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(field.stringValue == "custom" && target.values.count == 1)
        #expect(field.control(field.input, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(target.values == ["prod-db", "custom"])
    }
    @Test func returnPreservesTypedDestinationsUnlessUserExplicitlyChooses() throws {
        let (window, field) = hosted(); defer { field.dismissSuggestions(); window.close() }
        let target = SuggestionCommitTarget(); field.target = target; field.action = #selector(SuggestionCommitTarget.commit(_:))
        for (query, suggestions) in [("prod", ["prod-api", "prod"]), ("prod-", ["prod-api"]), ("/var/log", ["/var/log/app"])] {
            field.setSuggestions(suggestions)
            let editor = try type(query, in: field)
            _ = field.control(field.input, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
            #expect(target.values.last == query)
        }
        field.setSuggestions(["prod-api", "prod-db"])
        let editor = try type("prod", in: field)
        _ = field.control(field.input, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
        field.setSuggestions(["prod-new", "prod-api", "prod-db"])
        _ = field.control(field.input, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(target.values.last == "prod-api")
        _ = try type("prod", in: field)
        _ = field.control(field.input, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
        field.setSuggestions(["prod-db"])
        _ = field.control(field.input, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(target.values.last == "prod")
    }
    @Test func popupStaysAnchoredWithoutTakingFocusAndDismissesWhenDisabled() throws {
        let (window, field) = hosted(); defer { field.dismissSuggestions(); window.close() }
        field.setSuggestions(["prod-api", "prod-db", "stage", "dev"])
        let editor = try type("prod", in: field)
        let popup = try #require(field.suggestionPanel)
        #expect(popup.parent === window && window.firstResponder === editor)
        #expect(!popup.canBecomeKey)
        let anchor = window.convertToScreen(field.convert(field.bounds, to: nil))
        #expect(abs(popup.frame.minX - anchor.minX) < 1)
        #expect(abs(popup.frame.maxY - (anchor.minY - 4)) < 1)
        #expect(field.input.frame.maxX < field.bounds.maxX - 22)
        popup.contentView?.layoutSubtreeIfNeeded(); popup.displayIfNeeded()
        let table = try #require(popup.contentView?.subviews.compactMap { $0 as? NSScrollView }.first?.documentView as? NSTableView)
        #expect(table.visibleRect.contains(table.rect(ofRow: field.filteredSuggestions.count - 1)))
        field.isEnabled = false
        #expect(!popup.isVisible && popup.parent == nil && !field.input.isEnabled)
        field.isEnabled = true
        #expect(field.isEnabled && field.input.isEnabled)
    }
    @Test func nativeFilteredPopupSnapshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["DUCKPAD_REMOTE_FILTER_SNAPSHOTS"] else { return }
        let (window, field) = hosted(); defer { field.dismissSuggestions(); window.close() }
        field.setSuggestions(["prod-api-seoul", "stage-api", "prod-db-tokyo", "dev-local", "user@prod-cache"]
            + (1...12).map { "prod-worker-\($0)" })
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            _ = try type("prod", in: field)
            let popup = try #require(field.suggestionPanel)
            #expect(popup.frame.height >= 300)
            #expect(window.screen!.visibleFrame.contains(popup.frame))
            for (name, view) in [("field", window.contentView!), ("list", try #require(field.suggestionPanel?.contentView))] {
                view.layoutSubtreeIfNeeded()
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let root = URL(fileURLWithPath: directory); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("\(name)-\(appearance.rawValue).png"))
            }
        }
    }
}
