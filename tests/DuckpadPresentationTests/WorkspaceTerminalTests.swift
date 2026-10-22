import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import DuckpadLocalization
import Testing
@testable import DuckpadPresentation

@MainActor private final class FolderTerminalSurface: TerminalSurfaceView {
    override var acceptsFirstResponder: Bool { true }
    var stops = 0
    override func shutdown() { stops += 1 }
}

@Suite(.serialized) @MainActor struct WorkspaceTerminalTests {
    @Test func folderMenuRoutesLiteralPathsAndExcludesFilesAndUnavailableRoots() throws {
        _ = NSApplication.shared
        let sidebar = WorkspaceSidebarView(frame: .init(x: 0, y: 0, width: 260, height: 400))
        let window = NSWindow(contentRect: sidebar.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = sidebar; defer { window.close() }
        let root = WorkspaceRoot(canonicalPath: "/tmp/Project '한글' $(literal)", displayName: "project")
        sidebar.apply(roots: [root])
        sidebar.applyChildren(rootID: root.id, relativeDirectory: "", entries: [
            .init(rootID: root.id, relativePath: "nested folder", name: "nested folder", kind: .directory),
            .init(rootID: root.id, relativePath: "note.txt", name: "note.txt", kind: .file),
            .init(rootID: root.id, relativePath: "../outside", name: "outside", kind: .directory),
        ])
        let outline = try #require(sidebar.subviews.compactMap { $0 as? NSScrollView }.first?.documentView as? NSOutlineView)
        outline.expandItem(outline.item(atRow: 0))
        let menu = try #require(outline.menu)
        var external = [URL](), embedded = [URL]()
        sidebar.onRevealInTerminal = { external.append($0) }
        sidebar.onRevealInEmbeddedTerminal = { embedded.append($0) }
        func select(_ relativePath: String) throws {
            let row = try #require((0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? WorkspaceSidebarNode)?.relativePath == relativePath })
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            sidebar.menuNeedsUpdate(menu)
        }
        func terminalItems() -> [NSMenuItem] {
            menu.items.filter { ["revealContextInTerminal", "revealContextInEmbeddedTerminal"].contains($0.action.map(NSStringFromSelector) ?? "") }
        }
        for path in ["", "nested folder"] {
            try select(path)
            #expect(terminalItems().count == 2 && terminalItems().allSatisfy(\.isEnabled))
            for item in terminalItems() { _ = NSApp.sendAction(item.action!, to: item.target, from: item) }
            let expected = path.isEmpty ? root.canonicalPath : root.canonicalPath + "/" + path
            #expect(external.last?.path == expected && embedded.last?.path == expected)
        }
        try select("note.txt"); #expect(terminalItems().isEmpty)
        try select("../outside"); #expect(terminalItems().allSatisfy { !$0.isEnabled })
        try select("")
        sidebar.setInteractionsEnabled(false); sidebar.menuNeedsUpdate(menu)
        let count = external.count + embedded.count
        for item in terminalItems() { _ = NSApp.sendAction(item.action!, to: item.target, from: item) }
        #expect(external.count + embedded.count == count)
        sidebar.setInteractionsEnabled(true)
        sidebar.apply(roots: [.init(id: root.id, canonicalPath: root.canonicalPath, displayName: root.displayName, isAvailable: false)])
        try select("")
        #expect(terminalItems().count == 2 && terminalItems().allSatisfy { !$0.isEnabled })
        #expect(!menu.autoenablesItems)
        for language in AppLanguage.allCases where language != .system {
            let catalog = LocalizationCatalog(language: language)
            sidebar.refreshLocalization(catalog: catalog); sidebar.menuNeedsUpdate(menu)
            #expect(terminalItems().map(\.title) == [catalog.text("Reveal in Terminal"), catalog.text("Reveal in Embedded Terminal")])
        }
    }

    @Test func embeddedFolderOpensExactlyOneNewSessionWithoutChangingExistingShells() async throws {
        _ = NSApplication.shared
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let controller = DuckpadWindowController(workspace: workspace, previewResourceReader: LocalPreviewResourceReader(),
            markdownImageAccess: TestMarkdownImageAccess(), automaticallyStarts: false)
        defer { controller.close() }
        var configurations = [ShellLaunchConfiguration](), surfaces = [FolderTerminalSurface]()
        controller.terminalSurfaceFactory = { configuration in
            configurations.append(configuration)
            let surface = FolderTerminalSurface(); surface.workingDirectory = configuration.workingDirectory
            surfaces.append(surface); return surface
        }
        controller.start(); await controller.waitForStartup()
        let before = workspace.snapshot().tabs
        let first = URL(fileURLWithPath: "/tmp/first '한글' $(literal)", isDirectory: true)
        let second = URL(fileURLWithPath: "/tmp/second folder", isDirectory: true)
        controller.revealWorkspaceFolderInTerminal(first, embedded: true)
        #expect(controller.isTerminalVisible && configurations.map(\.workingDirectory) == [first])
        let previous = try #require(controller.terminalSessions.selectedSession)
        controller.performToggleTerminal()
        #expect(!controller.isTerminalVisible)
        controller.revealWorkspaceFolderInTerminal(second, embedded: true)
        #expect(controller.isTerminalVisible && configurations.map(\.workingDirectory) == [first, second])
        #expect(controller.terminalSessions.sessions.first == previous && controller.terminalSessions.sessions.count == 2)
        #expect(surfaces.allSatisfy { $0.stops == 0 })
        #expect(workspace.snapshot().tabs == before)
        var external = [URL]()
        controller.externalTerminalOpener = { url, completion in external.append(url); completion(true) }
        controller.revealWorkspaceFolderInTerminal(first, embedded: false)
        #expect(external == [first] && configurations.count == 2)
        controller.close()
        controller.revealWorkspaceFolderInTerminal(second, embedded: false)
        #expect(external == [first])
    }
}
