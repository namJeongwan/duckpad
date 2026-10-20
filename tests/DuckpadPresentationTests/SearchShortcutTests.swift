import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadEditorAdapter
import DuckpadInfrastructure
import Testing
@testable import DuckpadPresentation

@Suite(.serialized) @MainActor
struct SearchShortcutTests {
    private func host() async -> (DuckpadWindowController, ScintillaEditorAdapter) {
        _ = NSApplication.shared
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let editor = ScintillaEditorAdapter()
        let search = SearchWorkspaceUseCase(workspace: workspace, editor: editor, regexEngine: ICURegexEngine())
        let controller = DuckpadWindowController(workspace: workspace, previewResourceReader: LocalPreviewResourceReader(),
            markdownImageAccess: TestMarkdownImageAccess(), editorAdapter: editor, editorView: editor.view,
            searchUseCase: search, automaticallyStarts: false)
        controller.start(); await controller.waitForStartup()
        return (controller, editor)
    }
    @Test func commandRBelongsOnlyToReplaceAndShiftRRemainsProjectReplace() async throws {
        let (controller, editor) = await host()
        defer { controller.close(); editor.invalidate() }
        let registry = ShortcutRegistry(menu: DuckpadMainMenuFactory.make(target: controller), overrides: [:])
        let binding = try #require(MenuShortcut("cmd+r"))
        let owners = registry.entries.filter { $0.identities.contains(binding.identity) }
        #expect(owners.map(\.id) == ["performShowReplace:"])
        let project = try #require(registry.entries.first { $0.id == "performReplaceInFiles:" })
        #expect(project.identities.contains(try #require(MenuShortcut("cmd+shift+r")).identity))
        let remapped = ShortcutRegistry(menu: DuckpadMainMenuFactory.make(target: controller), overrides: ["performShowReplace:": "cmd+alt+r"])
        #expect(!remapped.entries.contains { $0.identities.contains(binding.identity) })
    }
    @Test(arguments: [false, true])
    func nativeMenuCommandROpensReplaceAndPreservesAnActiveFindQuery(fromFind: Bool) async throws {
        let (controller, editor) = await host()
        let oldMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = oldMenu; controller.close(); editor.invalidate() }
        editor.activeScintillaView?.insertCommittedText("source selection")
        editor.selectAndReveal(.init(location: 0, length: 6))
        NSApp.mainMenu = DuckpadMainMenuFactory.make(target: controller)
        var before: SearchQuery?
        if fromFind {
            controller.performShowFind()
            controller.searchPanel.setQuery(.init(pattern: "edited query", replacement: "한글 replacement",
                options: .init(matchCase: true), fileMask: "*.swift"))
            before = controller.searchPanel.currentQuery()
            #expect(controller.searchPanel.window?.isVisible == true)
        }
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: (fromFind ? controller.searchPanel.window : controller.window)?.windowNumber ?? 0,
            context: nil, characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15))
        #expect(NSApp.mainMenu?.performKeyEquivalent(with: event) == true)
        #expect(controller.searchPanel.selectedTab == .replace)
        #expect(!controller.searchPanel.isHidden)
        if let before { #expect(controller.searchPanel.currentQuery() == before) }
        else { #expect(controller.searchPanel.currentQuery().pattern == "source") }
    }
}
