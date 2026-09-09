import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import DuckpadEditorAdapter
@testable import DuckpadPresentation
import Testing

@Suite(.serialized)
struct FourPaneNativeWindowTests {
    @Test @MainActor func movingTheLastPrimaryCloneActivatesThePromotedVisiblePane() async throws {
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let adapter = ScintillaEditorAdapter()
        let controller = DuckpadWindowController(
            workspace: workspace, editorAdapter: adapter, editorView: adapter.view,
            secondaryEditorView: adapter.secondaryGroupView,
            additionalEditorViews: adapter.additionalEditorGroupViews,
            editorGroupRouter: adapter, automaticallyStarts: false
        )
        defer { controller.close(); adapter.invalidate() }
        controller.start()
        await controller.waitForStartup()
        adapter.activeScintillaView?.insertCommittedText("shared")
        _ = await workspace.addScratch()
        adapter.activeScintillaView?.insertCommittedText("other")
        let tabs = workspace.snapshot().tabs
        controller.editorGroupWorkspace.onAction?(.splitAdjacent(tabs[0].id, .primary, .primary, .right, .copy))
        controller.editorGroupWorkspace.onAction?(.splitAdjacent(tabs[1].id, .primary, .secondary, .down, .move))
        controller.editorGroupWorkspace.onAction?(.move(tabs[0].id, .primary, .secondary))
        for _ in 0..<10 { await Task.yield() }
        let layout = controller.editorGroupLayoutSnapshot
        #expect(layout.visibleGroups == [.primary, .tertiary])
        #expect(adapter.activeEditorGroup == .primary)
        let native = try #require(adapter.activeScintillaView)
        #expect(native.isDescendant(of: controller.editorGroupWorkspace.primaryPane.editorHostView))
        #expect(native.contentUTF8 == Data("shared".utf8))
        #expect(controller.editorGroupWorkspace.secondaryPane == nil)
    }

    @Test @MainActor func nativeFourPaneWindowKeepsEditorsAndStatusInSync() async throws {
        _ = NSApplication.shared
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let adapter = ScintillaEditorAdapter()
        let controller = DuckpadWindowController(
            workspace: workspace, editorAdapter: adapter, editorView: adapter.view,
            secondaryEditorView: adapter.secondaryGroupView,
            additionalEditorViews: adapter.additionalEditorGroupViews,
            editorGroupRouter: adapter, automaticallyStarts: false
        )
        defer { controller.close(); adapter.invalidate() }
        controller.start()
        await controller.waitForStartup()
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 1200, height: 760))
        for index in 0..<4 {
            if index > 0 { _ = await workspace.addScratch() }
            adapter.activeScintillaView?.insertCommittedText("Panel \(index + 1)\nNative editor 🦆")
        }
        let tabs = workspace.snapshot().tabs
        controller.editorGroupWorkspace.onAction?(.splitAdjacent(tabs[1].id, .primary, .primary, .right, .move))
        controller.editorGroupWorkspace.onAction?(.splitAdjacent(tabs[2].id, .primary, .primary, .down, .move))
        controller.editorGroupWorkspace.onAction?(.splitAdjacent(tabs[3].id, .primary, .secondary, .down, .move))
        for _ in 0..<10 { await Task.yield() }
        let layout = controller.editorGroupLayoutSnapshot
        #expect(layout.visibleGroups.count == 4)
        for group in layout.visibleGroups {
            adapter.activateEditorGroup(group)
            let view = try #require(adapter.activeScintillaView)
            let pane = try #require(controller.editorGroupWorkspace.pane(for: group))
            #expect(view.isDescendant(of: pane.editorHostView))
            #expect(view.documentByteLength > 0)
            #expect(controller.statusBar.lengthLabel.stringValue.contains("Length: \(view.documentByteLength)"))
        }
        controller.commandBar.apply(mainMenu: DuckpadMainMenuFactory.make(target: controller))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            adapter.applyTheme(appearance == .aqua ? .light : .dark)
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            window.contentView?.display()
            if let directory = ProcessInfo.processInfo.environment["DUCKPAD_CHROME_TEST_IMAGES"] {
                let root = try #require(window.contentView)
                let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                root.cacheDisplay(in: root.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                let destination = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try png.write(to: destination.appendingPathComponent("four-panels-\(appearance == .aqua ? "light" : "dark").png"))
            }
        }
        let closingGroup = layout.focusedGroup
        let movedID = try #require(layout.selectedTabID(in: closingGroup))
        controller.performCloseEditorGroup()
        let after = controller.editorGroupLayoutSnapshot
        #expect(after.visibleGroups.count == 3)
        let destination = try #require(after.visibleGroups.first { after.tabIDs(in: $0).contains(movedID) })
        controller.editorGroupWorkspace.onAction?(.select(movedID, destination))
        for _ in 0..<10 { await Task.yield() }
        let movedView = try #require(adapter.activeScintillaView)
        movedView.setPrimarySelectionUTF8Range(NSRange(location: 3, length: 0))
        let buffer = try #require(workspace.snapshot().tabs.first { $0.id == movedID }?.buffer)
        #expect(adapter.recoverySnapshot(for: buffer.bufferID)?.viewState.caretUTF8 == 3)
    }
}
