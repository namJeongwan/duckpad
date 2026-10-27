import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
import DuckpadPresentation
import WebKit

/// Exercises the installed app's resource layout and sandbox before opening any
/// user settings, recovery store, or documents.
@MainActor
enum BuiltInMarkdownSmoke {
    static func run() async {
        do {
            var session = ScratchSession()
            let tab = session.addUntitled()
            try session.changeFileLocation(tabID: tab, binding: nil, title: "packaged-preview.md")
            let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore(session: session))
            let editor = ScintillaEditorAdapter()
            let controller = DuckpadWindowController(workspace: workspace, previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: LocalMarkdownImageAccess(), editorAdapter: editor,
                editorView: editor.view)
            await controller.waitForStartup()
            controller.showAndFocus()
            guard let view = editor.activeScintillaView else { throw FormattingFailure.unavailable }
            guard let content = controller.window?.contentView,
                  let pin = descendants(content).compactMap({ $0 as? NSButton }).first(where: {
                      $0.accessibilityIdentifier().hasPrefix("duckpad.tab.pin.")
                  }), let image = pin.image, image.isTemplate, image.tiffRepresentation != nil else {
                throw FormattingFailure.unavailable
            }
            let source = "# Packaged preview\n\nA **bold** word, `inline code`, and [link](https://example.com).\n\n```rust\nfn main() {}\n```\n\n$x^2$\n\n```mermaid\ngraph TD; A[Start]-->B[Finish]\n```\n\n| A | B |\n| --- | --- |\n| one | two |"
            view.insertCommittedText(source)
            let revision = workspace.activeFileContext()?.buffer.revision
            guard editor.applyLanguage(.init(languageID: .init(rawValue: "markdown"), lexerName: "markdown",
                                             indentation: .init(), folding: false, braceMatching: false)) else {
                throw FormattingFailure.unavailable
            }
            view.setPrimarySelectionUTF8Range(.init(location: source.utf8.count, length: 0))
            guard let codeEditor = descendants(editor.view).compactMap({ $0 as? WKWebView }).first(where: {
                $0.accessibilityIdentifier() == "duckpad.markdown.editor.content"
            }) else { throw FormattingFailure.unavailable }
            let editorDeadline = ContinuousClock.now + .seconds(20)
            var editorRendered = false
            while ContinuousClock.now < editorDeadline {
                editorRendered = (try? await codeEditor.evaluateJavaScript("!!document.querySelector('.md-h1') && !!document.querySelector('.md-bold') && !!document.querySelector('.md-code') && Array.from(document.querySelectorAll('.md-diagram svg text')).some(t=>t.textContent==='Start')")) as? Bool == true
                if editorRendered { break }
                try await Task.sleep(for: .milliseconds(30))
            }
            guard editorRendered, await editor.synchronizePendingInput(), editor.isMarkdownLiveEditingEnabled else {
                throw FormattingFailure.timedOut
            }
            editor.applyTheme(.dark)
            guard await editor.synchronizePendingInput(),
                  try await codeEditor.evaluateJavaScript("getComputedStyle(document.querySelector('.cm-editor')).backgroundColor === 'rgb(40, 44, 51)' && getComputedStyle(document.querySelector('.cm-scroller')).backgroundColor === 'rgb(40, 44, 51)'") as? Bool == true else { throw FormattingFailure.unavailable }
            var followedLink: URL?
            editor.onOpenMarkdownLink = { followedLink = $0 }
            _ = try await codeEditor.evaluateJavaScript("document.querySelector('.md-link-label').dispatchEvent(new MouseEvent('click',{metaKey:true,bubbles:true,cancelable:true}))")
            guard await editor.synchronizePendingInput(), followedLink?.host == "example.com" else { throw FormattingFailure.unavailable }
            let stableTable = try await codeEditor.evaluateJavaScript("JSON.stringify(Array.from(document.querySelectorAll('.md-table :is(th,td)')).map(e=>e.getBoundingClientRect().width))") as? String
            _ = try await codeEditor.evaluateJavaScript("document.querySelectorAll('.md-table-cell-preview')[2].dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true}));document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',bubbles:true,cancelable:true}));")
            guard try await codeEditor.evaluateJavaScript("document.activeElement.value === 'two' && document.querySelectorAll('.md-table table').length === 1") as? Bool == true else { throw FormattingFailure.unavailable }
            _ = try await codeEditor.evaluateJavaScript("document.activeElement.setSelectionRange(0,0);document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowLeft',code:'ArrowLeft',keyCode:37,bubbles:true,cancelable:true}));")
            guard try await codeEditor.evaluateJavaScript("document.activeElement.value === 'one' && getComputedStyle(document.activeElement).boxShadow === 'none'") as? Bool == true else { throw FormattingFailure.unavailable }
            guard try await codeEditor.evaluateJavaScript("JSON.stringify(Array.from(document.querySelectorAll('.md-table :is(th,td)')).map(e=>e.getBoundingClientRect().width))") as? String == stableTable else { throw FormattingFailure.unavailable }
            controller.performToggleMarkdownLiveEditing()
            guard await editor.synchronizePendingInput(), !editor.isMarkdownLiveEditingEnabled,
                  try await codeEditor.evaluateJavaScript("document.querySelector('.cm-editor').classList.contains('md-source')") as? Bool == true else {
                throw FormattingFailure.unavailable
            }
            controller.performToggleMarkdownLiveEditing()
            guard await editor.synchronizePendingInput(), editor.isMarkdownLiveEditingEnabled else { throw FormattingFailure.unavailable }
            guard try await codeEditor.evaluateJavaScript("!!document.querySelector('.md-math .katex')") as? Bool == true else { throw FormattingFailure.unavailable }
            _ = try await codeEditor.callAsyncJavaScript("await document.fonts.ready; return true;", arguments: [:], in: nil, contentWorld: .page)
            guard try await codeEditor.evaluateJavaScript("Array.from(document.fonts).some(f => f.family === 'KaTeX_Main' && f.status === 'loaded')") as? Bool == true else { throw FormattingFailure.unavailable }
            guard view.contentUTF8 == Data(source.utf8), workspace.activeFileContext()?.buffer.revision == revision else {
                throw FormattingFailure.staleDocument
            }
            controller.close()
            editor.invalidate()
            print("PASS: packaged CodeMirror Source/Live editor, inline Mermaid, workspace theme colors, Command-click links, contextual table controls, stable table columns, plain cell caret and arrow navigation; Live math fonts and Mermaid rendered; separate preview removed; source and revision preserved")
            fflush(stdout)
            Darwin._exit(0)
        } catch {
            print("FAIL: packaged Markdown preview: \(error)")
            fflush(stdout)
            Darwin._exit(1)
        }
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
