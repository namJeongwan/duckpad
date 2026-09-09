import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
import DuckpadEditorAdapter
@testable import DuckpadPresentation
import Testing

@Suite(.serialized)
struct FourPaneNativeWindowTests {
    @Test @MainActor func draggingBetweenThreeAndOneTabsProducesTwoAndTwo() async throws {
        _ = NSApplication.shared
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let adapter = ScintillaEditorAdapter()
        let controller = DuckpadWindowController(workspace: workspace, editorAdapter: adapter, editorView: adapter.view,
            secondaryEditorView: adapter.secondaryGroupView, additionalEditorViews: adapter.additionalEditorGroupViews,
            editorGroupRouter: adapter, automaticallyStarts: false)
        defer { controller.close(); adapter.invalidate() }
        controller.start()
        await controller.waitForStartup()
        for value in ["first", "second", "third", "fourth"] {
            if value != "first" { _ = await workspace.addScratch() }
            adapter.activeScintillaView?.insertCommittedText(value)
        }
        let ids = workspace.snapshot().tabs.map(\.id)
        controller.editorGroupWorkspace.onAction?(.splitAdjacent(ids[3], .primary, .primary, .right, .move))
        #expect(controller.editorGroupLayoutSnapshot.primaryTabIDs.count == 3)
        #expect(controller.editorGroupLayoutSnapshot.secondaryTabIDs.count == 1)
        #expect(controller.editorGroupWorkspace.performTabDrop(payload: .init(tabID: ids[1], sourceGroup: .primary),
            destinationGroup: .secondary, insertionIndex: 1, optionPressed: false))
        for _ in 0..<100 { await Task.yield() }
        #expect(controller.editorGroupLayoutSnapshot.primaryTabIDs == [ids[0], ids[2]])
        #expect(controller.editorGroupLayoutSnapshot.secondaryTabIDs == [ids[3], ids[1]])
        #expect(adapter.activeEditorGroup == .secondary)
        #expect(adapter.activeScintillaView?.contentUTF8 == Data("second".utf8))
        #expect(controller.editorGroupWorkspace.performTabDrop(payload: .init(tabID: ids[1], sourceGroup: .secondary),
            destinationGroup: .primary, insertionIndex: 1, optionPressed: false))
        for _ in 0..<100 { await Task.yield() }
        #expect(controller.editorGroupLayoutSnapshot.primaryTabIDs == [ids[0], ids[1], ids[2]])
        #expect(controller.editorGroupLayoutSnapshot.secondaryTabIDs == [ids[3]])
        #expect(adapter.activeEditorGroup == .primary)
        #expect(adapter.activeScintillaView?.contentUTF8 == Data("second".utf8))
    }

    @Test @MainActor func draggingTheLastTabBackUsesTheDropIndexAndKeepsItsNativeDocument() async throws {
        _ = NSApplication.shared
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        let adapter = ScintillaEditorAdapter()
        let controller = DuckpadWindowController(workspace: workspace, editorAdapter: adapter, editorView: adapter.view,
            secondaryEditorView: adapter.secondaryGroupView, additionalEditorViews: adapter.additionalEditorGroupViews,
            editorGroupRouter: adapter, automaticallyStarts: false)
        defer { controller.close(); adapter.invalidate() }
        controller.start()
        await controller.waitForStartup()
        for value in ["first", "second", "third"] {
            if value != "first" { _ = await workspace.addScratch() }
            adapter.activeScintillaView?.insertCommittedText(value)
        }
        let tabs = workspace.snapshot().tabs
        controller.editorGroupWorkspace.onAction?(.splitAdjacent(tabs[2].id, .primary, .primary, .right, .move))
        controller.editorGroupWorkspace.onAction?(.transfer(tabs[2].id, .secondary, .primary, 0, .move))
        for _ in 0..<100 { await Task.yield() }
        #expect(controller.editorGroupLayoutSnapshot.visibleGroups == [.primary])
        #expect(controller.editorGroupLayoutSnapshot.primaryTabIDs == [tabs[2].id, tabs[0].id, tabs[1].id])
        #expect(adapter.activeScintillaView?.contentUTF8 == Data("third".utf8))
        controller.editorGroupWorkspace.onAction?(.splitAdjacent(tabs[2].id, .primary, .primary, .right, .copy))
        controller.editorGroupWorkspace.onAction?(.transfer(tabs[2].id, .secondary, .primary, 2, .move))
        for _ in 0..<100 { await Task.yield() }
        #expect(controller.editorGroupLayoutSnapshot.primaryTabIDs == [tabs[0].id, tabs[2].id, tabs[1].id])
        #expect(controller.editorGroupLayoutSnapshot.visibleGroups == [.primary])
        #expect(adapter.activeScintillaView?.contentUTF8 == Data("third".utf8))
    }

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
            for group in layout.visibleGroups {
                let strip = try #require(controller.editorGroupWorkspace.pane(for: group)?.tabStrip)
                #expect(controller.editorGroupWorkspace.pane(for: group)?.layer?.borderWidth == 0)
                let background = try #require(strip.layer?.backgroundColor)
                let color = try #require(NSColor(cgColor: background)?.usingColorSpace(.deviceRGB))
                #expect(appearance == .aqua ? color.redComponent > 0.8 : color.redComponent < 0.3)
            }
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
