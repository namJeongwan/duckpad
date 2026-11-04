import AppKit
import DuckpadApplication
import DuckpadEditorAdapter
import DuckpadInfrastructure
import DuckpadPresentation

/// Runs only against an explicitly selected isolated Python completion fixture.
@MainActor enum MagicMethodCompletionSmoke {
    static func run(controller: DuckpadWindowController, editor: ScintillaEditorAdapter,
                    intelligence: DocumentIntelligenceUseCase, provider: LanguageServerCompletionProvider,
                    url: URL, expectedServer: String) async {
        precondition(url.path.contains("/SecurityScopeSmoke/"), "magic method smoke requires an isolated fixture")
        guard let view = editor.activeScintillaView, let window = controller.window,
              let client = window.firstResponder as? any NSTextInputClient else { preconditionFailure("magic method editor missing") }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func wait(_ condition: () -> Bool) async {
            for _ in 0..<600 {
                if condition() { return }
                try? await Task.sleep(for: .milliseconds(20))
            }
            preconditionFailure("magic method completion timed out")
        }
        let head = view.contentUTF8
        client.insertText("__", replacementRange: .init(location: NSNotFound, length: 0))
        await wait { editor.isCompletionSuggestionVisible }
        precondition(provider.context(for: url)?.serverID == expectedServer, "wrong Python server")
        let table = window.childWindows?.compactMap { $0.contentView }.flatMap(descendants).compactMap { $0 as? NSTableView }.first
        guard let table else { preconditionFailure("magic method candidate table missing") }
        var labels: [String: Int] = [:]
        for row in 0..<table.numberOfRows {
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true),
               let name = descendants(cell).compactMap({ $0 as? NSTextField }).first?.stringValue { labels[name] = row }
        }
        guard let index = labels["__init__"], labels["__repr__"] != nil else { preconditionFailure("magic methods not returned") }
        precondition(!labels.keys.contains(where: { !$0.hasPrefix("__") }) && labels["__document_noise"] == nil,
            "method list contains unrelated words")
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        guard let tab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48) else {
            preconditionFailure("magic method Tab event missing")
        }
        NSApplication.shared.postEvent(tab, atStart: false)
        let expected = head + Data("__init__(self) -> None:\n        pass".utf8)
        await wait { view.contentUTF8 == expected }
        precondition(view.caretUTF8Position == UInt(expected.count), "method caret offset is wrong")
        view.undo()
        let typed = head + Data("__".utf8)
        precondition(view.contentUTF8 == typed, "method insertion was not one Undo step")
        view.redo()
        precondition(view.contentUTF8 == expected, "method Redo lost the stub")
        view.undo()
        _ = await intelligence.complete()
        precondition(editor.isCompletionSuggestionVisible, "method suggestions did not reopen")
        print("Duckpad magic method smoke ready: __init__ + __repr__ + real Tab + indentation + caret + single Undo/Redo; " + expectedServer)
        fflush(stdout)
    }
}
