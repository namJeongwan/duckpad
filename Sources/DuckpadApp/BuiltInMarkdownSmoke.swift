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
            let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
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
            let source = "# Packaged preview\n\n```rust\nfn main() {}\n```\n\n$x^2$\n\n```mermaid\ngraph TD; A[Start]-->B[Finish]\n```"
            view.insertCommittedText(source)
            let revision = workspace.activeFileContext()?.buffer.revision
            for _ in 0..<3 {
                controller.performToggleMarkdownPreview()
                guard let content = controller.window?.contentView,
                      let web = descendants(content).compactMap({ $0 as? WKWebView }).first else {
                    throw FormattingFailure.unavailable
                }
                let deadline = ContinuousClock.now + .seconds(20)
                var rendered = false
                while ContinuousClock.now < deadline {
                    rendered = (try? await web.evaluateJavaScript("document.querySelector('h1')?.textContent === 'Packaged preview' && !!document.querySelector('.hljs-keyword') && !!document.querySelector('.katex') && Array.from(document.querySelectorAll('.mermaid-diagram svg text')).some(t => t.textContent === 'Start')")) as? Bool == true
                    if rendered { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard rendered else { throw FormattingFailure.timedOut }
                _ = try await web.callAsyncJavaScript("await document.fonts.ready; return true;", arguments: [:], in: nil, contentWorld: .page)
                guard try await web.evaluateJavaScript("Array.from(document.fonts).some(f => f.family === 'KaTeX_Main' && f.status === 'loaded')") as? Bool == true else { throw FormattingFailure.unavailable }
                controller.performToggleMarkdownPreview()
            }
            guard view.contentUTF8 == Data(source.utf8), workspace.activeFileContext()?.buffer.revision == revision else {
                throw FormattingFailure.staleDocument
            }
            controller.close()
            editor.invalidate()
            print("PASS: packaged Markdown preview opened/closed three times; Rust, math fonts and Mermaid rendered; source and revision preserved")
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
