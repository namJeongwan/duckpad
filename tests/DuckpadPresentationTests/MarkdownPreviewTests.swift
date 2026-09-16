import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadLocalization
@testable import DuckpadPresentation
import Testing
import WebKit

@Suite(.serialized)
struct MarkdownPreviewTests {
    @Test @MainActor func headerButtonsShowHoverAndPressAndClosePreview() throws {
        _ = NSApplication.shared
        let panel = MarkdownPreviewPanel(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        defer { panel.invalidate() }
        let header = try #require(panel.subviews.compactMap { $0 as? NSStackView }.first)
        panel.layoutSubtreeIfNeeded()
        let buttons = header.arrangedSubviews.compactMap { $0 as? NSButton }
        #expect(buttons.count == 2)
        let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0))
        for button in buttons {
            #expect(button.frame.width >= 26 && button.frame.height >= 26)
            button.mouseExited(with: event)
            let resting = button.layer?.backgroundColor
            button.mouseEntered(with: event)
            let hovered = button.layer?.backgroundColor
            #expect(hovered != resting)
            button.highlight(true)
            #expect(button.layer?.backgroundColor != hovered)
            button.highlight(false)
            button.mouseExited(with: event)
            #expect(button.layer?.backgroundColor == resting)
        }
        var didClose = false
        panel.onClose = { didClose = true }
        let close = try #require(buttons.first { $0.accessibilityIdentifier() == "duckpad.markdown.preview.close" })
        close.performClick(nil)
        #expect(didClose)
    }

    @Test @MainActor func rendersFullMarkdownOfflineAndSanitizesHTML() async throws {
        _ = NSApplication.shared
        let panel = MarkdownPreviewPanel(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        defer { panel.invalidate() }
        let previewWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 850), styleMask: [.titled], backing: .buffered, defer: false)
        previewWindow.contentView = panel
        previewWindow.contentView?.layoutSubtreeIfNeeded()
        previewWindow.orderFront(nil)
        defer { previewWindow.orderOut(nil) }
        let web = try #require(panel.subviews.compactMap { $0 as? WKWebView }.first)
        panel.update(source: """
        # 제목 **한글**

        - first
        - *second*

        | A | B |
        |---|---|
        | 1 | 2 |

        ```rust
        fn main() {
            let n = 1;
        }
        ```

        $x_1 + x_2$

        ```mermaid
        graph TD; A[Start]-->B[Finish]
        ```

        <script>window.__duckpadUntrustedExecutionSentinel = true</script>
        <img src="invalid" onerror="window.__duckpadUntrustedExecutionSentinel = true">
        <b>HTML works</b>
        """)
        try await wait(web, expression: "!!document.querySelector('.mermaid-diagram svg')")
        _ = try await web.callAsyncJavaScript("await document.fonts.ready; return true;", arguments: [:], in: nil, contentWorld: .page)
        #expect(try await web.evaluateJavaScript("Array.from(document.fonts).some(f => f.family === 'KaTeX_Main' && f.status === 'loaded')") as? Bool == true)
        #expect(try await web.evaluateJavaScript("document.querySelector('h1').textContent") as? String == "제목 한글")
        #expect(try await web.evaluateJavaScript("Array.from(document.querySelectorAll('.mermaid-diagram svg text')).map(t => t.textContent).join(' ').includes('Start')") as? Bool == true)
        #expect(try await web.evaluateJavaScript("!!document.querySelector('.hljs-keyword')") as? Bool == true)
        #expect(try await web.evaluateJavaScript("!!document.querySelector('.katex')") as? Bool == true)
        #expect(try await web.evaluateJavaScript("!!document.querySelector('table')") as? Bool == true)
        #expect(try await web.evaluateJavaScript("document.querySelector('b').textContent") as? String == "HTML works")
        let securityState = try await web.evaluateJavaScript("JSON.stringify({injected:typeof window.__duckpadUntrustedExecutionSentinel,scripts:document.querySelectorAll('#content script').length,handlers:document.querySelectorAll('[onerror]').length})") as? String
        #expect(securityState == "{\"injected\":\"undefined\",\"scripts\":0,\"handlers\":0}")
        if let path = ProcessInfo.processInfo.environment["DUCKPAD_MARKDOWN_FULL_SNAPSHOT"] {
            let bitmap = try await web.takeSnapshot(configuration: nil)
            let data = try #require(bitmap.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
                .representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: path))
        }
    }

    @Test @MainActor func largeDocumentAndRelativeLocalImageRender() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=")!
        try png.write(to: root.appendingPathComponent("duck image.png"))
        let panel = MarkdownPreviewPanel(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        defer { panel.invalidate() }
        let web = try #require(panel.subviews.compactMap { $0 as? WKWebView }.first)
        panel.update(source: "![duck](duck%20image.png)\n\n" + String(repeating: "text ", count: 500_000) + "\n\n# End", documentURL: root.appendingPathComponent("test.md"))
        try await wait(web, expression: "document.querySelector('h1')?.textContent === 'End' && document.querySelector('img')?.naturalWidth === 1")
        #expect(try await web.evaluateJavaScript("document.querySelector('img').src.startsWith('duckpad-preview://local/')") as? Bool == true)
    }

    @MainActor private func wait(_ web: WKWebView, expression: String) async throws {
        for _ in 0..<400 {
            if (try? await web.evaluateJavaScript(expression)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        Issue.record("Preview did not satisfy: \(expression)")
    }

    @Test @MainActor func closingDuringSlowRenderReleasesRuntimeBeforeReopening() async throws {
        // A finite render stays pending for 10 seconds. Each runtime must disappear
        // before the next panel opens, without waiting for JavaScript completion.
        for _ in 0..<3 {
            var panel: MarkdownPreviewPanel? = autoreleasepool { MarkdownPreviewPanel(frame: .zero) }
            weak var releasedPanel = panel
            var web: WKWebView? = try #require(panel?.subviews.compactMap { $0 as? WKWebView }.first)
            weak var releasedWeb = web
            try await wait(try #require(web), expression: "typeof window.duckpadRender === 'function'")
            _ = try await #require(web).evaluateJavaScript("""
                window.duckpadRender = async () => {
                    window.renderStarted = true;
                    await new Promise(resolve => setTimeout(resolve, 10000));
                    window.renderCompleted = true;
                }; true;
                """)
            panel?.update(source: "# Slow")
            try await wait(try #require(web), expression: "window.renderStarted === true")
            #expect(try await #require(web).evaluateJavaScript("window.renderCompleted === true") as? Bool == false)
            panel?.invalidate()
            panel = nil
            // Release the test's own reference as well as production ownership.
            web = nil
            for _ in 0..<50 {
                if releasedPanel == nil && releasedWeb == nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(releasedPanel == nil)
            #expect(releasedWeb == nil)
        }
    }

    @Test @MainActor func latestPreviewRendersInWebKitAndCanBeInvalidated() async throws {
        let panel = MarkdownPreviewPanel(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        defer { panel.invalidate() }
        let web = try #require(panel.subviews.compactMap { $0 as? WKWebView }.first)
        #expect(web.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        panel.update(source: "# Obsolete")
        panel.update(source: "# Latest 한글")
        var heading: String?
        for _ in 0..<150 {
            heading = try? await web.evaluateJavaScript("document.querySelector('h1')?.textContent") as? String
            if heading == "Latest 한글" { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(heading == "Latest 한글")
        panel.invalidate()
        #expect(web.navigationDelegate == nil)
    }

    @Test @MainActor func tabPreviewActivatesMarkdownAndViewMenuFollowsActiveTab() async throws {
        var session = ScratchSession()
        let markdown = session.addUntitled()
        try session.changeFileLocation(tabID: markdown, binding: nil, title: "notes.md")
        let plain = session.addUntitled()
        let workspace = ScratchWorkspaceUseCase(store: MarkdownSessionStore(session))
        let controller = DuckpadWindowController(workspace: workspace, automaticallyStarts: false)
        defer { controller.close() }
        controller.start()
        await controller.waitForStartup()
        let main = DuckpadMainMenuFactory.make(target: controller)
        let viewMenu = try #require(main.items.compactMap(\.submenu).first { menu in
            menu.items.contains { $0.action == #selector(DuckpadWindowController.performToggleMarkdownPreview(_:)) }
        })
        let item = try #require(viewMenu.items.first { $0.action == #selector(DuckpadWindowController.performToggleMarkdownPreview(_:)) })
        #expect(item.isHidden)
        #expect(item.keyEquivalent == "V")
        #expect(item.keyEquivalentModifierMask == [.command, .shift])
        let conflicts = main.items.compactMap(\.submenu).flatMap(\.items).filter {
            $0.keyEquivalent.lowercased() == "v" && $0.keyEquivalentModifierMask == [.command, .shift]
        }
        #expect(conflicts.count == 1)
        controller.tabStrip.onContextAction?(markdown, .previewMarkdown)
        for _ in 0..<100 {
            if controller.isMarkdownPreviewVisible { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(workspace.activeFileContext()?.tabID == markdown)
        #expect(controller.isMarkdownPreviewVisible)
        viewMenu.delegate?.menuNeedsUpdate?(viewMenu)
        #expect(!item.isHidden)
        controller.tabStrip.onContextAction?(markdown, .previewMarkdown)
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.isMarkdownPreviewVisible)
        let tabsBeforeClose = workspace.snapshot().tabs.map(\.id)
        let closeEvent = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.control], timestamp: 0, windowNumber: controller.window!.windowNumber,
            context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        #expect(main.performKeyEquivalent(with: closeEvent))
        #expect(!controller.isMarkdownPreviewVisible)
        #expect(workspace.snapshot().tabs.map(\.id) == tabsBeforeClose)
        controller.performToggleMarkdownPreview()
        #expect(controller.isMarkdownPreviewVisible)
        _ = await workspace.activate(tabID: plain)
        #expect(!controller.isMarkdownPreviewVisible)
        viewMenu.delegate?.menuNeedsUpdate?(viewMenu)
        #expect(item.isHidden)
        _ = await workspace.activate(tabID: markdown)
        // Switching tabs refreshes the shortcut without opening the View menu.
        #expect(!item.isHidden)
        let openEvent = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .shift], timestamp: 0, windowNumber: controller.window!.windowNumber,
            context: nil, characters: "V", charactersIgnoringModifiers: "V", isARepeat: false, keyCode: 9))
        #expect(main.performKeyEquivalent(with: openEvent))
        #expect(controller.isMarkdownPreviewVisible)
        viewMenu.delegate?.menuNeedsUpdate?(viewMenu)
        #expect(!item.isHidden)
    }

    @Test @MainActor func standardCloseCommandDismissesPreviewBeforeClosingDocument() async throws {
        let workspace = ScratchWorkspaceUseCase(store: MarkdownSessionStore())
        let controller = DuckpadWindowController(workspace: workspace, automaticallyStarts: false)
        defer { controller.close() }
        controller.start()
        await controller.waitForStartup()
        let main = DuckpadMainMenuFactory.make(target: controller)
        controller.editor.textView.insertText("# Keep this document", replacementRange: NSRange(location: NSNotFound, length: 0))
        let before = workspace.snapshot()
        controller.performToggleMarkdownPreview()
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command], timestamp: 0, windowNumber: controller.window!.windowNumber,
            context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        #expect(main.performKeyEquivalent(with: event))
        try await Task.sleep(for: .milliseconds(100))
        #expect(!controller.isMarkdownPreviewVisible)
        #expect(workspace.snapshot().tabs == before.tabs)
        #expect(workspace.snapshot().activeBuffer == before.activeBuffer)
        #expect(controller.editor.textView.string == "# Keep this document")
        #expect(controller.window?.attachedSheet == nil)
    }

    @Test @MainActor func previewMenuTogglesWithoutChangingDocumentOrRevision() async throws {
        _ = NSApplication.shared
        var session = ScratchSession()
        let markdown = session.addUntitled()
        try session.changeFileLocation(tabID: markdown, binding: nil, title: "notes.md")
        let workspace = ScratchWorkspaceUseCase(store: MarkdownSessionStore(session))
        let controller = DuckpadWindowController(workspace: workspace, automaticallyStarts: false)
        defer { controller.close() }
        controller.start()
        await controller.waitForStartup()
        controller.editor.textView.insertText("# Hello", replacementRange: NSRange(location: NSNotFound, length: 0))
        let before = workspace.snapshot().activeBuffer
        let text = controller.editor.textView.string
        let menu = DuckpadMainMenuFactory.make(target: controller)
        let item = try #require(menu.items.compactMap(\.submenu).flatMap(\.items).first {
            $0.action == #selector(DuckpadWindowController.performToggleMarkdownPreview(_:))
        })
        #expect(controller.validateMenuItem(item))
        #expect(item.state == .off)
        controller.performToggleMarkdownPreview()
        #expect(controller.isMarkdownPreviewVisible)
        #expect(controller.validateMenuItem(item))
        #expect(item.state == .on)
        controller.performToggleMarkdownPreview()
        #expect(!controller.isMarkdownPreviewVisible)
        #expect(workspace.snapshot().activeBuffer == before)
        #expect(controller.editor.textView.string == text)
        #expect(LocalizationCatalog(language: .korean).text("Markdown Preview") == "Markdown 미리보기")
        #expect(LocalizationCatalog(language: .english).text("Close Preview") == "Close Preview")
    }
}

private actor MarkdownSessionStore: SessionStore {
    private var session: StoredSession?
    init(_ value: ScratchSession? = nil) {
        session = value.map { StoredSession(session: $0, generation: PersistenceGeneration(rawValue: 0)) }
    }
    func loadSession() async throws(SessionStoreError) -> StoredSession? { session }
    func commitSession(_ value: ScratchSession, generation: PersistenceGeneration) async throws(SessionStoreError) -> SessionCommitResult {
        session = StoredSession(session: value, generation: generation)
        return .committed
    }
}
