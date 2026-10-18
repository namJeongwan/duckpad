import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
@testable import DuckpadPresentation
import Testing

@Suite(.serialized) @MainActor
struct TerminalShortcutTests {
    @Test func splitRatiosSurviveZoomResizeAndHistoryRestore() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var created = 0
        let workspace = TerminalSessionWorkspaceView(configuration: ShellLaunchConfiguration(workingDirectory: URL(fileURLWithPath: "/tmp"))) { _ in
            created += 1
            return RoutingSurface()
        }
        window.contentView = workspace
        workspace.split(.right)
        let initial = try #require(workspace.subviews.first as? NSSplitView)
        initial.setPosition(200, ofDividerAt: 0)
        let saved = try #require(workspace.snapshot)
        workspace.toggleZoom()
        workspace.frame.size.width = 1000
        workspace.toggleZoom()
        let restored = try #require(workspace.subviews.first as? NSSplitView)
        #expect(abs(restored.arrangedSubviews[0].frame.width - 250) < 2)
        workspace.split(.down)
        let nested = try #require(workspace.subviews.first as? NSSplitView)
        #expect(abs(nested.arrangedSubviews[0].frame.width - 250) < 2)
        let horizontal = try #require(nested.arrangedSubviews[1] as? NSSplitView)
        horizontal.setPosition(100, ofDividerAt: 0)
        let nestedSnapshot = try #require(workspace.snapshot)
        workspace.frame.size = NSSize(width: 1200, height: 600)
        workspace.layoutSubtreeIfNeeded()
        #expect(abs(nested.arrangedSubviews[0].frame.width - 300) < 2)
        #expect(abs(horizontal.arrangedSubviews[0].frame.height - 150) < 2)
        workspace.toggleZoom()
        workspace.toggleZoom()
        workspace.restore(nestedSnapshot)
        let restoredNested = try #require(workspace.subviews.first as? NSSplitView)
        let restoredHorizontal = try #require(restoredNested.arrangedSubviews[1] as? NSSplitView)
        #expect(abs(restoredHorizontal.arrangedSubviews[0].frame.height - 150) < 2)
        workspace.frame.size.width = 1000
        workspace.equalize()
        workspace.restore(saved)
        let fromHistory = try #require(workspace.subviews.first as? NSSplitView)
        #expect(abs(fromHistory.arrangedSubviews[0].frame.width - 250) < 2)
        #expect(created == 3)
    }

    @Test func firstSplitKeepsBothPanesVisibleAfterLayout() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var surfaces: [RoutingSurface] = []
        let workspace = TerminalSessionWorkspaceView(configuration: ShellLaunchConfiguration(workingDirectory: URL(fileURLWithPath: "/tmp"))) { _ in
            let surface = RoutingSurface(); surfaces.append(surface); return surface
        }
        window.contentView = workspace
        workspace.frame = NSRect(x: 0, y: 0, width: 800, height: 200)
        workspace.layoutSubtreeIfNeeded()
        workspace.split(.right)
        workspace.layoutSubtreeIfNeeded()
        let split = try #require(workspace.subviews.first as? NSSplitView)
        #expect(split.arrangedSubviews.count == 2)
        for surface in surfaces {
            #expect(surface.frame.width > 390)
            #expect(surface.frame.width < 410)
            #expect(!split.isSubviewCollapsed(surface))
        }
        workspace.frame.size.width = 1000
        workspace.layoutSubtreeIfNeeded()
        for surface in surfaces { #expect(surface.frame.width > 400) }
    }

    @Test func cyclingZoomedSplitFocusesAnAttachedVisiblePane() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var surfaces: [RoutingSurface] = []
        let workspace = TerminalSessionWorkspaceView(configuration: ShellLaunchConfiguration(workingDirectory: URL(fileURLWithPath: "/tmp"))) { _ in
            let surface = RoutingSurface(); surfaces.append(surface); return surface
        }
        window.contentView = workspace
        workspace.split(.right)
        for direction in [TerminalDirection.next, .previous] {
            workspace.toggleZoom()
            let before = workspace.selectedSurface
            workspace.focus(direction)
            let selected = try #require(workspace.selectedSurface)
            #expect(selected !== before)
            #expect(selected.window === window)
            #expect(!selected.isHiddenOrHasHiddenAncestor)
            #expect(window.firstResponder === selected)
        }
    }

    @Test func terminalRouterPrecedesMenusAndLeavesControlWForTheShell() throws {
        _ = NSApplication.shared
        let window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let surface = RoutingSurface()
        window.contentView = surface
        window.makeFirstResponder(surface)
        let router = AuxiliaryCloseKeyRouter()
        let split = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                timestamp: 1, windowNumber: window.windowNumber, context: nil,
                                                characters: "d", charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2))
        #expect(router.handle(split))
        #expect(surface.keys == [2])
        let deleteWord = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
                                                     timestamp: 2, windowNumber: window.windowNumber, context: nil,
                                                     characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        #expect(!router.handle(deleteWord))
        #expect(window.firstResponder === surface)
        let editor = NSTextView()
        window.contentView = editor
        window.makeFirstResponder(editor)
        #expect(!router.handle(split))
        #expect(surface.keys == [2, 13])
    }

    @Test func splitTabNavigationAndTerminalUndoDoNotTouchDocumentHistory() async throws {
        let documents = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let controller = DuckpadWindowController(workspace: documents,
            previewResourceReader: LocalPreviewResourceReader(), markdownImageAccess: TestMarkdownImageAccess(),
            automaticallyStarts: false)
        defer { controller.close() }
        var surfaces: [RoutingSurface] = []
        controller.terminalSurfaceFactory = { _ in
            let surface = RoutingSurface(); surfaces.append(surface); return surface
        }
        controller.start(); await controller.waitForStartup()
        let before = documents.snapshot()
        controller.performToggleTerminal()
        let panel = try #require(controller.terminalPanel)
        let firstSession = try #require(controller.terminalSessions.selectedID)
        panel.handle(.split(.right))
        #expect(surfaces.count == 2)
        #expect(controller.window?.firstResponder === surfaces[1])
        panel.handle(.focusSplit(.previous))
        #expect(controller.window?.firstResponder === surfaces[0])
        panel.handle(.toggleSplitZoom)
        panel.handle(.toggleSplitZoom)
        let firstWindowMoves = surfaces.map(\.windowMoves)
        panel.handle(.newTab)
        #expect(surfaces.count == 3)
        #expect(surfaces[0].windowMoves == firstWindowMoves[0])
        #expect(surfaces[1].windowMoves == firstWindowMoves[1])
        let secondSession = controller.terminalSessions.selectedID
        panel.handle(.selectTab(1))
        #expect(controller.terminalSessions.selectedID == firstSession)
        #expect(surfaces[0].windowMoves == firstWindowMoves[0])
        #expect(surfaces[1].windowMoves == firstWindowMoves[1])
        #expect(!surfaces[0].isHiddenOrHasHiddenAncestor)
        #expect(surfaces[2].isHiddenOrHasHiddenAncestor)
        panel.handle(.selectTab(-2))
        #expect(controller.terminalSessions.selectedID == secondSession)
        panel.handle(.closeSurface)
        #expect(controller.terminalSessions.sessions.count == 1)
        #expect(surfaces[2].stops == 0)
        panel.handle(.undo)
        #expect(controller.terminalSessions.sessions.count == 2)
        #expect(controller.terminalSessions.selectedID == secondSession)
        #expect(surfaces.count == 3)
        panel.handle(.redo)
        #expect(controller.terminalSessions.sessions.count == 1)
        panel.discardHistory()
        #expect(surfaces[2].stops == 1)
        #expect(surfaces[0].stops == 0)
        #expect(surfaces[1].stops == 0)
        #expect(documents.snapshot().tabs == before.tabs)
    }
}

@MainActor private final class RoutingSurface: TerminalSurfaceView {
    var keys: [UInt16] = []
    var stops = 0
    var windowMoves = 0
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); windowMoves += 1 }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { onFocus?(); return true }
    override func handleTerminalKeyEquivalent(_ event: NSEvent) -> Bool {
        keys.append(event.keyCode)
        return event.modifierFlags.contains(.command) && event.keyCode == 2
    }
    override func shutdown() { stops += 1 }
}
