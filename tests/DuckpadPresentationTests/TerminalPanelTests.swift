import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import DuckpadLocalization
@testable import DuckpadPresentation
import Testing

@Suite(.serialized) @MainActor
struct TerminalPanelTests {
    private func makeController(workspace: ScratchWorkspaceUseCase? = nil) -> DuckpadWindowController {
        _ = NSApplication.shared
        return DuckpadWindowController(
            workspace: workspace ?? ScratchWorkspaceUseCase(store: InMemorySessionStore()),
            previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: TestMarkdownImageAccess(),
            automaticallyStarts: false
        )
    }

    @Test func surfaceFactoryIsLazyAndSessionsOwnTheirProcesses() throws {
        let controller = makeController()
        defer { controller.close() }
        var created: [FakeTerminalSurface] = []
        controller.terminalSurfaceFactory = { _ in
            let view = FakeTerminalSurface()
            created.append(view)
            return view
        }
        #expect(created.isEmpty)
        controller.performToggleTerminal()
        let panel = try #require(controller.terminalPanel)
        #expect(created.count == 1)
        #expect(controller.window?.makeFirstResponder(created[0]) == true)
        controller.performPaste()
        #expect(created[0].commands == [.paste])
        controller.performToggleTerminal()
        #expect(created[0].stops == 0)
        controller.performToggleTerminal()
        #expect(created.count == 1)
        panel.handle(.newTab)
        #expect(created.count == 2)
        let firstTab = try #require(panel.sessionTabs.tabs.first)
        let secondTab = try #require(panel.sessionTabs.tabs.last)
        firstTab.activateButton.performClick(nil)
        #expect(controller.terminalSessions.selectedID == firstTab.id)
        #expect(controller.window?.firstResponder === created[0])
        secondTab.activateButton.performClick(nil)
        #expect(controller.terminalSessions.selectedID == secondTab.id)
        #expect(controller.window?.firstResponder === created[1])
        #expect(created.count == 2)
        // Closing an inactive tab must not close or restart the selected shell.
        firstTab.onClose?()
        panel.discardHistory()
        #expect(created[0].stops == 1)
        #expect(created[1].stops == 0)
        #expect(controller.terminalSessions.selectedID == secondTab.id)
        controller.close()
        #expect(created[0].stops == 1)
        #expect(created[1].stops == 1)
    }

    @Test func openingIsLazyHidingPreservesSessionsAndClosingWindowClearsThem() throws {
        let controller = makeController()
        defer { controller.close() }
        #expect(controller.terminalPanel == nil)
        #expect(controller.terminalSessions.sessions.isEmpty)
        controller.statusBar.terminalButton.performClick(nil)
        #expect(controller.statusBar.terminalButton.state == .on)
        let panel = try #require(controller.terminalPanel)
        #expect(controller.isTerminalVisible)
        #expect(controller.terminalSessions.sessions.count == 1)
        panel.handle(.newTab)
        #expect(controller.terminalSessions.sessions.count == 2)
        let sessions = controller.terminalSessions.sessions
        let selected = controller.terminalSessions.selectedID
        controller.statusBar.terminalButton.performClick(nil)
        #expect(controller.statusBar.terminalButton.state == .off)
        #expect(!controller.isTerminalVisible)
        #expect(controller.terminalSessions.sessions == sessions)
        controller.performToggleTerminal()
        #expect(controller.terminalPanel === panel)
        #expect(controller.terminalSessions.selectedID == selected)
        controller.close()
        #expect(controller.terminalSessions.sessions.isEmpty)
        #expect(controller.terminalPanel == nil)
        controller.performToggleTerminal()
        #expect(controller.terminalPanel == nil)
    }

    @Test func focusedCloseClosesTerminalWithoutClosingDocument() async throws {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let controller = makeController(workspace: workspace)
        defer { controller.close() }
        controller.start()
        await controller.waitForStartup()
        let before = workspace.snapshot()
        controller.performToggleTerminal()
        let panel = try #require(controller.terminalPanel)
        controller.window?.makeFirstResponder(panel.sessionTabs.tabs.first?.activateButton)
        #expect(PluginPanelFocus.ownsKeyboardFocus(panel, in: controller.terminalWorkspaceSplit))
        controller.performCloseActiveTab()
        #expect(controller.isTerminalVisible)
        #expect(workspace.snapshot().tabs == before.tabs)
        #expect(controller.terminalSessions.sessions.isEmpty)
    }

    @Test func closingLastSessionShowsEmptyStateAndReopeningDoesNotRecreateIt() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.performToggleTerminal()
        let panel = try #require(controller.terminalPanel)
        try #require(panel.sessionTabs.tabs.last).closeButton.performClick(nil)
        #expect(controller.terminalSessions.sessions.isEmpty)
        #expect(panel.sessionTabs.tabs.isEmpty)
        #expect(controller.window?.firstResponder === panel)
        controller.performToggleTerminal()
        controller.performToggleTerminal()
        #expect(controller.terminalSessions.sessions.isEmpty)
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 1, windowNumber: controller.window!.windowNumber, context: nil,
            characters: "t", charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17))
        #expect((controller.window as? EditorWindow)?.routeTerminalShortcut(key) == true)
        #expect(controller.terminalSessions.sessions.count == 1)
    }

    @Test func panelResizesBelowWorkspaceAndRestoresEditorArea() throws {
        let split = TerminalWorkspaceSplitView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
        let editor = NSView()
        let panel = NSView()
        split.addArrangedSubview(editor)
        split.show(panel)
        #expect(panel.frame.height == 220)
        #expect(panel.frame.minY > editor.frame.maxY)
        split.setFrameSize(NSSize(width: 900, height: 800))
        #expect(panel.frame.height == 220)
        #expect(editor.frame.width == 900)
        split.setPosition(500, ofDividerAt: 0)
        let resized = panel.frame.height
        split.hide(panel)
        #expect(editor.frame.size == split.bounds.size)
        split.show(panel)
        #expect(abs(panel.frame.height - resized) < 1)
        split.setFrameSize(NSSize(width: 420, height: 200))
        #expect(editor.frame.height > 90)
        #expect(panel.frame.height > 90)
        #expect(panel.frame.maxY <= split.bounds.height)
    }

    @Test func menuExposesTerminalShortcutAndCheckedVisibility() throws {
        let controller = makeController()
        defer { controller.close() }
        let menu = DuckpadMainMenuFactory.make(target: controller)
        let item = try #require(menu.items.compactMap(\.submenu).flatMap(\.items).first {
            $0.action == #selector(DuckpadWindowController.performToggleTerminal(_:))
        })
        #expect(item.keyEquivalent == "`")
        #expect(item.keyEquivalentModifierMask == [.control])
        #expect(controller.validateMenuItem(item))
        #expect(item.state == .off)
        controller.performToggleTerminal()
        #expect(controller.validateMenuItem(item))
        #expect(item.state == .on)
    }

    @Test func integratedWindowKeepsEditorAbovePanelAtMinimumSize() throws {
        let controller = makeController()
        defer { controller.close() }
        let window = try #require(controller.window)
        controller.performToggleTerminal()
        let panel = try #require(controller.terminalPanel)
        for size in [NSSize(width: 900, height: 620), NSSize(width: 420, height: 280)] {
            window.setContentSize(size)
            window.contentView?.layoutSubtreeIfNeeded()
            let split = controller.terminalWorkspaceSplit
            let editor = try #require(split.arrangedSubviews.first)
            #expect(editor.frame.height > 90)
            #expect(panel.frame.height > 90)
            #expect(panel.frame.maxY <= split.bounds.height + 1)
            #expect(panel.frame.minY >= editor.frame.maxY)
            #expect(panel.frame.width == split.bounds.width)
        }
        controller.performToggleTerminal()
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(controller.terminalWorkspaceSplit.arrangedSubviews.count == 1)
        #expect(controller.terminalWorkspaceSplit.arrangedSubviews[0].frame.size == controller.terminalWorkspaceSplit.bounds.size)
    }

    @Test func allLocalesPreserveSessionAndRenderAtCompactWidths() throws {
        _ = NSApplication.shared
        let store = TerminalSessionStore()
        let session = try #require(store.create(configuration: .init(workingDirectory: URL(fileURLWithPath: "/tmp/한글/project with spaces"))))
        for _ in 1..<12 {
            store.create(configuration: session.configuration)
        }
        store.select(session.id)
        let panel = TerminalPanelView(sessions: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = panel
        for language in AppLanguage.allCases where language != .system {
            let catalog = LocalizationCatalog(language: language)
            panel.refreshLocalization(catalog: catalog)
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(store.selectedID == session.id)
            #expect(Set(panel.sessionTabs.tabs.map { $0.frame.minY }).count > 1)
            #expect(panel.sessionTabs.tabs.allSatisfy { $0.frame.maxX <= panel.sessionTabs.bounds.width + 1 })
            #expect(panel.sessionTabs.frame.height > 27)
            #expect(panel.sessionTabs.frame.height <= panel.bounds.height - 96)
            #expect(panel.sessionTabs.tabs[0].activateButton.title == catalog.text("Session %1$@", arguments: [1.formatted(.number.locale(catalog.locale))]))
            #expect(panel.heading.stringValue == catalog.text("Unable to start terminal."))
            #expect(panel.directory.stringValue.contains("한글/project with spaces"))
            #expect(panel.sessionTabs.bounds.width == panel.bounds.width)
            var settings = AppSettings.defaults
            settings.multilineTabsEnabled = false
            panel.applyPreferences(settings)
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(Set(panel.sessionTabs.tabs.map { $0.frame.minY }).count == 1)
            #expect(panel.sessionTabs.frame.height == 27)
            panel.applyPreferences(.defaults)
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            if let path = ProcessInfo.processInfo.environment["DUCKPAD_TERMINAL_SNAPSHOTS"] {
                let output = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let bitmap = try #require(panel.bitmapImageRepForCachingDisplay(in: panel.bounds))
                panel.cacheDisplay(in: panel.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: output.appendingPathComponent(language.rawValue + ".png"))
            }
        }
    }
}

@MainActor private final class FakeTerminalSurface: TerminalSurfaceView {
    var stops = 0
    var commands: [EditorCommand] = []
    override var acceptsFirstResponder: Bool { true }
    override func perform(_ command: EditorCommand) { commands.append(command) }
    override func shutdown() { stops += 1 }
}
