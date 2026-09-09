import AppKit
import DuckpadApplication
import DuckpadDomain
@testable import DuckpadPresentation
import Testing

@Suite(.serialized)
struct EditorGroupWorkspaceViewTests {
    @Test @MainActor func tabStripCorrectsNativeDropProposalAndClearsItsMarker() throws {
        let fixture = makeFixture()
        let window = hostInWindow(fixture.view)
        defer { fixture.view.tearDown(); window.contentView = nil; window.close() }
        fixture.view.apply(workspace: workspace(tabs: fixture.tabs), layout: layout(
            primary: [fixture.tabs[0].id, fixture.tabs[1].id], secondary: [fixture.tabs[2].id],
            primarySelection: fixture.tabs[0].id, secondarySelection: fixture.tabs[2].id,
            orientation: .sideBySide))
        let strip = fixture.view.primaryPane.tabStrip
        let collection = strip.hostedCollectionView
        let first = try #require(strip.flowLayout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))).frame
        let sender = DraggingInfoStub(window: window,
            pasteboard: pasteboard(.init(tabID: fixture.tabs[2].id, sourceGroup: .secondary)),
            location: collection.convert(NSPoint(x: first.minX + 3, y: first.midY), to: nil),
            sourceOperationMask: .move)
        var proposed = NSIndexPath(forItem: 99, inSection: 0)
        var operation = NSCollectionView.DropOperation.on
        #expect(strip.collectionView(collection, validateDrop: sender, proposedIndexPath: &proposed,
                                     dropOperation: &operation) == .move)
        #expect(proposed.item == 0)
        #expect(operation == .before)
        let marker = try #require(collection.layer?.sublayers?.first { $0.name == "duckpad.tab.drop-insertion" })
        #expect(!marker.isHidden)
        #expect(marker.frame.midY == first.midY)
        strip.setInteractionsEnabled(false)
        #expect(marker.isHidden)
    }

    @Test @MainActor func unsplitWorkspaceHostsOnePaneAndFiltersItsTabs() {
        let fixture = makeFixture()
        let view = fixture.view
        view.apply(
            workspace: workspace(tabs: fixture.tabs),
            layout: layout(
                primary: [fixture.tabs[2].id, fixture.tabs[0].id],
                primarySelection: fixture.tabs[2].id
            )
        )

        #expect(view.splitView.arrangedSubviews == [view.primaryPane])
        #expect(view.secondaryPane == nil)
        #expect(view.primaryPane.editorHostView === fixture.primaryEditor)
        #expect(view.primaryPane.tabStrip.tabIDs == [fixture.tabs[2].id, fixture.tabs[0].id])
        #expect(view.primaryPane.tabStrip.activeTabID == fixture.tabs[2].id)
    }

    @Test @MainActor func splitWorkspaceUsesRequestedOrientationAndIndependentSelections() throws {
        let fixture = makeFixture()
        let view = fixture.view
        view.apply(
            workspace: workspace(tabs: fixture.tabs),
            layout: layout(
                primary: [fixture.tabs[0].id, fixture.tabs[2].id],
                secondary: [fixture.tabs[1].id],
                primarySelection: fixture.tabs[2].id,
                secondarySelection: fixture.tabs[1].id,
                focused: .secondary,
                orientation: .sideBySide
            )
        )

        let secondary = try #require(view.secondaryPane)
        #expect(view.splitView.isVertical)
        #expect(view.splitView.arrangedSubviews == [view.primaryPane, secondary])
        #expect(secondary.editorHostView === fixture.secondaryEditor)
        #expect(view.primaryPane.tabStrip.activeTabID == fixture.tabs[2].id)
        #expect(secondary.tabStrip.tabIDs == [fixture.tabs[1].id])
        #expect(secondary.tabStrip.activeTabID == fixture.tabs[1].id)
        #expect(secondary.isFocused)
        #expect(!view.primaryPane.isFocused)

        view.apply(
            workspace: workspace(tabs: fixture.tabs),
            layout: layout(
                primary: [fixture.tabs[0].id],
                secondary: [fixture.tabs[1].id, fixture.tabs[2].id],
                primarySelection: fixture.tabs[0].id,
                secondarySelection: fixture.tabs[2].id,
                orientation: .stacked
            )
        )
        #expect(!view.splitView.isVertical)
    }

    @Test @MainActor func overlayHitTestingUsesTheNearestOfFourEdges() {
        let overlay = EditorGroupDropOverlay(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        overlay.layoutSubtreeIfNeeded()

        #expect(overlay.zone(at: NSPoint(x: 590, y: 300)) == .right)
        #expect(overlay.zone(at: NSPoint(x: 300, y: 10)) == .down)
        #expect(overlay.zone(at: NSPoint(x: 590, y: 10)) == .right)
        #expect(overlay.zone(at: NSPoint(x: 10, y: 200)) == .left)
        #expect(overlay.zone(at: NSPoint(x: 300, y: 390)) == .up)
        #expect(overlay.zone(at: NSPoint(x: 300, y: 200)) == nil)
        #expect(overlay.zone(at: NSPoint(x: 210, y: 200)) == .left)
    }

    @Test @MainActor func dropZoneDividerAxisComesFromZoneIdentityNotAspectRatio() throws {
        let right = EditorGroupDropZoneView(zone: .right)
        right.frame = NSRect(x: 0, y: 0, width: 400, height: 20)
        right.layoutSubtreeIfNeeded()
        let rightDivider = try #require(right.layer?.sublayers?.first?.frame)
        #expect(rightDivider.width < rightDivider.height)
        #expect(rightDivider.height == 20)

        let down = EditorGroupDropZoneView(zone: .down)
        down.frame = NSRect(x: 0, y: 0, width: 20, height: 400)
        down.layoutSubtreeIfNeeded()
        let downDivider = try #require(down.layer?.sublayers?.first?.frame)
        #expect(downDivider.width == 20)
        #expect(downDivider.height < downDivider.width)
    }

    @Test @MainActor func edgeDropRejectsLastTabMoveButAllowsOptionClone() {
        let fixture = makeFixture(tabCount: 1)
        fixture.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        fixture.view.layoutSubtreeIfNeeded()
        fixture.view.apply(
            workspace: workspace(tabs: fixture.tabs),
            layout: layout(primary: [fixture.tabs[0].id], primarySelection: fixture.tabs[0].id)
        )
        let payload = EditorGroupDragPayload(tabID: fixture.tabs[0].id, sourceGroup: .primary)
        let right = NSPoint(x: fixture.view.dropOverlay.bounds.maxX - 2, y: fixture.view.dropOverlay.bounds.midY)

        #expect(fixture.view.validateEdgeDrop(payload: payload, location: right, optionPressed: false) == nil)
        #expect(fixture.view.validateEdgeDrop(payload: payload, location: right, optionPressed: true) == .copy)
    }

    @Test @MainActor func edgeDropEmitsTypedSplitAndAlwaysCleansUpOverlay() {
        let fixture = makeFixture()
        fixture.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        fixture.view.layoutSubtreeIfNeeded()
        fixture.view.apply(
            workspace: workspace(tabs: fixture.tabs),
            layout: layout(primary: fixture.tabs.map(\.id), primarySelection: fixture.tabs[0].id)
        )
        let payload = EditorGroupDragPayload(tabID: fixture.tabs[1].id, sourceGroup: .primary)
        let down = NSPoint(x: fixture.view.dropOverlay.bounds.midX, y: 2)
        var actions: [EditorGroupWorkspaceView.Action] = []
        fixture.view.onAction = { actions.append($0) }

        #expect(fixture.view.updateEdgeDrop(payload: payload, location: down, optionPressed: false) == .move)
        #expect(fixture.view.dropOverlay.isPresenting)
        #expect(fixture.view.dropOverlay.highlightedZone == .down)
        #expect(fixture.view.performEdgeDrop(payload: payload, location: down, optionPressed: false))
        #expect(actions == [.split(fixture.tabs[1].id, .primary, .stacked, .move)])
        #expect(!fixture.view.dropOverlay.isPresenting)
        #expect(fixture.view.dropOverlay.highlightedZone == nil)

        _ = fixture.view.updateEdgeDrop(payload: payload, location: down, optionPressed: true)
        fixture.view.cancelDrop()
        #expect(!fixture.view.dropOverlay.isPresenting)
        #expect(fixture.view.dropOverlay.highlightedZone == nil)
    }

    @Test @MainActor func groupDropsDistinguishReorderMoveAndOptionClone() {
        let fixture = makeFixture()
        fixture.view.apply(
            workspace: workspace(tabs: fixture.tabs),
            layout: layout(
                primary: [fixture.tabs[0].id, fixture.tabs[1].id],
                secondary: [fixture.tabs[2].id],
                primarySelection: fixture.tabs[0].id,
                secondarySelection: fixture.tabs[2].id,
                orientation: .sideBySide
            )
        )
        var actions: [EditorGroupWorkspaceView.Action] = []
        fixture.view.onAction = { actions.append($0) }

        #expect(fixture.view.performTabDrop(
            payload: .init(tabID: fixture.tabs[0].id, sourceGroup: .primary),
            destinationGroup: .primary,
            insertionIndex: 2,
            optionPressed: true
        ))
        #expect(fixture.view.performTabDrop(
            payload: .init(tabID: fixture.tabs[1].id, sourceGroup: .primary),
            destinationGroup: .secondary,
            insertionIndex: 1,
            optionPressed: false
        ))
        #expect(fixture.view.performTabDrop(
            payload: .init(tabID: fixture.tabs[0].id, sourceGroup: .primary),
            destinationGroup: .secondary,
            insertionIndex: 0,
            optionPressed: true
        ))

        #expect(actions == [
            .reorder(fixture.tabs[0].id, .primary, 1),
            .transfer(fixture.tabs[1].id, .primary, .secondary, 1, .move),
            .transfer(fixture.tabs[0].id, .primary, .secondary, 0, .copy),
        ])
    }

    @Test @MainActor func groupDropsRejectMissingSourcesAndDuplicateClones() {
        let fixture = makeFixture()
        fixture.view.apply(
            workspace: workspace(tabs: fixture.tabs),
            layout: layout(
                primary: [fixture.tabs[0].id, fixture.tabs[1].id],
                secondary: [fixture.tabs[0].id, fixture.tabs[2].id],
                primarySelection: fixture.tabs[0].id,
                secondarySelection: fixture.tabs[2].id,
                orientation: .stacked
            )
        )

        #expect(!fixture.view.performTabDrop(
            payload: .init(tabID: TabID(), sourceGroup: .primary),
            destinationGroup: .secondary,
            insertionIndex: 0,
            optionPressed: false
        ))
        #expect(!fixture.view.performTabDrop(
            payload: .init(tabID: fixture.tabs[0].id, sourceGroup: .primary),
            destinationGroup: .secondary,
            insertionIndex: 0,
            optionPressed: true
        ))
    }

    @Test @MainActor func paneCallbacksEmitSelectFocusCloseAndContextActions() throws {
        let fixture = makeFixture()
        fixture.view.apply(
            workspace: workspace(tabs: fixture.tabs),
            layout: layout(primary: fixture.tabs.map(\.id), primarySelection: fixture.tabs[0].id)
        )
        var actions: [EditorGroupWorkspaceView.Action] = []
        fixture.view.onAction = { actions.append($0) }

        fixture.view.primaryPane.tabStrip.onActivate?(fixture.tabs[1].id)
        fixture.view.requestFocus(.primary)
        fixture.view.primaryPane.tabStrip.onClose?(fixture.tabs[1].id)
        fixture.view.primaryPane.tabStrip.onContextAction?(fixture.tabs[1].id, .setPinned(true))

        #expect(actions == [
            .select(fixture.tabs[1].id, .primary),
            .focus(.primary),
            .close(fixture.tabs[1].id, .primary),
            .context(fixture.tabs[1].id, .primary, .setPinned(true)),
        ])
    }

    @Test @MainActor func groupsAndTransientDropZonesHaveExplicitAccessibilityNames() throws {
        let fixture = makeFixture()
        fixture.view.apply(
            workspace: workspace(tabs: fixture.tabs),
            layout: layout(primary: fixture.tabs.map(\.id), primarySelection: fixture.tabs[0].id)
        )
        fixture.view.dropOverlay.present(highlighting: .right)

        #expect(fixture.view.primaryPane.accessibilityLabel() == "Primary editor group")
        #expect(fixture.view.primaryPane.tabStrip.hostedCollectionView.accessibilityLabel() == "Primary editor group tabs")
        let children = fixture.view.dropOverlay.accessibilityChildren() as? [NSView]
        let labels = try #require(children?.compactMap { $0.accessibilityLabel() })
        #expect(Set(labels) == ["Split editor to the right"])
    }

    @Test @MainActor func tabCollectionsKeepUniqueGroupIdentifiersAcrossCollapseAndReopen() throws {
        let fixture = makeFixture()
        let splitLayout = layout(
            primary: [fixture.tabs[0].id, fixture.tabs[1].id],
            secondary: [fixture.tabs[2].id],
            primarySelection: fixture.tabs[0].id,
            secondarySelection: fixture.tabs[2].id,
            orientation: .sideBySide
        )
        fixture.view.apply(workspace: workspace(tabs: fixture.tabs), layout: splitLayout)

        #expect(fixture.view.primaryPane.tabStrip.hostedCollectionView.accessibilityIdentifier()
            == "duckpad.editor-group.primary.tabs")
        #expect(try #require(fixture.view.secondaryPane).tabStrip.hostedCollectionView.accessibilityIdentifier()
            == "duckpad.editor-group.secondary.tabs")

        fixture.view.apply(
            workspace: workspace(tabs: fixture.tabs),
            layout: layout(primary: fixture.tabs.map(\.id), primarySelection: fixture.tabs[0].id)
        )
        fixture.view.apply(workspace: workspace(tabs: fixture.tabs), layout: splitLayout)

        #expect(fixture.view.primaryPane.tabStrip.hostedCollectionView.accessibilityIdentifier()
            == "duckpad.editor-group.primary.tabs")
        #expect(try #require(fixture.view.secondaryPane).tabStrip.hostedCollectionView.accessibilityIdentifier()
            == "duckpad.editor-group.secondary.tabs")
    }

    @Test @MainActor func nativeDraggingPathConvertsWindowPointAndDerivesCopyFromOptionModifier() {
        let fixture = makeFixture(modifierFlagsProvider: { [.option] })
        let window = hostInWindow(fixture.view)
        defer {
            fixture.view.tearDown()
            window.contentView = nil
            window.close()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        fixture.view.apply(
            workspace: workspace(tabs: fixture.tabs),
            layout: layout(primary: fixture.tabs.map(\.id), primarySelection: fixture.tabs[0].id)
        )
        let payload = EditorGroupDragPayload(tabID: fixture.tabs[1].id, sourceGroup: .primary)
        let localRight = NSPoint(
            x: fixture.view.dropOverlay.bounds.maxX - 2,
            y: fixture.view.dropOverlay.bounds.midY
        )
        let windowRight = fixture.view.dropOverlay.convert(localRight, to: nil)
        let sender = DraggingInfoStub(
            window: window,
            pasteboard: pasteboard(payload),
            location: windowRight,
            sourceOperationMask: [.move, .copy]
        )
        var actions: [EditorGroupWorkspaceView.Action] = []
        fixture.view.onAction = { actions.append($0) }

        #expect(windowRight != localRight)
        #expect(fixture.view.draggingEntered(sender) == .copy)
        #expect(fixture.view.dropOverlay.highlightedZone == .right)
        #expect(fixture.view.prepareForDragOperation(sender))
        #expect(fixture.view.performDragOperation(sender))
        #expect(actions == [.split(fixture.tabs[1].id, .primary, .sideBySide, .copy)])
        #expect(!fixture.view.dropOverlay.isPresenting)
    }

    @Test @MainActor func nativeBodyDropMovesIntoTheTargetOutsideTheNarrowCenter() {
        let fixture = makeFixture()
        let window = hostInWindow(fixture.view)
        defer { fixture.view.tearDown(); window.contentView = nil; window.close() }
        fixture.view.apply(workspace: workspace(tabs: fixture.tabs), layout: layout(
            primary: [fixture.tabs[0].id, fixture.tabs[1].id], secondary: [fixture.tabs[2].id],
            primarySelection: fixture.tabs[0].id, secondarySelection: fixture.tabs[2].id,
            orientation: .sideBySide))
        let host = fixture.view.primaryPane.editorHostView
        let sender = DraggingInfoStub(window: window,
            pasteboard: pasteboard(.init(tabID: fixture.tabs[2].id, sourceGroup: .secondary)),
            location: host.convert(NSPoint(x: host.bounds.width * 0.25, y: host.bounds.midY), to: nil),
            sourceOperationMask: .move)
        var action: EditorGroupWorkspaceView.Action?
        fixture.view.onAction = { action = $0 }
        #expect(fixture.view.draggingEntered(sender) == .move)
        #expect(fixture.view.dropOverlay.isPresenting)
        #expect(fixture.view.dropOverlay.highlightedZone == nil)
        #expect(fixture.view.prepareForDragOperation(sender))
        #expect(fixture.view.performDragOperation(sender))
        #expect(action == .transfer(fixture.tabs[2].id, .secondary, .primary, 2, .move))
        #expect(!fixture.view.dropOverlay.isPresenting)
    }

    @Test @MainActor func nativeEdgeDragCanCreateAThirdGroup() {
        let fixture = makeFixture()
        let window = hostInWindow(fixture.view)
        defer {
            fixture.view.tearDown()
            window.contentView = nil
            window.close()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        fixture.view.apply(
            workspace: workspace(tabs: fixture.tabs),
            layout: layout(
                primary: [fixture.tabs[0].id, fixture.tabs[1].id],
                secondary: [fixture.tabs[2].id],
                primarySelection: fixture.tabs[0].id,
                secondarySelection: fixture.tabs[2].id,
                orientation: .sideBySide
            )
        )
        let sender = DraggingInfoStub(
            window: window,
            pasteboard: pasteboard(.init(tabID: fixture.tabs[1].id, sourceGroup: .primary)),
            location: fixture.view.dropOverlay.convert(
                NSPoint(x: fixture.view.dropOverlay.bounds.maxX - 2, y: fixture.view.dropOverlay.bounds.midY),
                to: nil
            ),
            sourceOperationMask: .move
        )

        var action: EditorGroupWorkspaceView.Action?
        fixture.view.onAction = { action = $0 }
        #expect(fixture.view.draggingEntered(sender) == .move)
        #expect(fixture.view.prepareForDragOperation(sender))
        #expect(fixture.view.performDragOperation(sender))
        #expect(action == .splitAdjacent(fixture.tabs[1].id, .primary, .primary, .right, .move))
        #expect(!fixture.view.dropOverlay.isPresenting)
    }

    @Test @MainActor func nativeOverlayCleansUpOnExitApplyAndTeardown() {
        let fixture = makeFixture()
        let window = hostInWindow(fixture.view)
        defer {
            window.contentView = nil
            window.close()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let workspaceSnapshot = workspace(tabs: fixture.tabs)
        let unsplit = layout(primary: fixture.tabs.map(\.id), primarySelection: fixture.tabs[0].id)
        fixture.view.apply(workspace: workspaceSnapshot, layout: unsplit)
        let sender = DraggingInfoStub(
            window: window,
            pasteboard: pasteboard(.init(tabID: fixture.tabs[1].id, sourceGroup: .primary)),
            location: fixture.view.dropOverlay.convert(
                NSPoint(x: fixture.view.dropOverlay.bounds.maxX - 2, y: fixture.view.dropOverlay.bounds.midY),
                to: nil
            ),
            sourceOperationMask: .move
        )

        #expect(fixture.view.draggingEntered(sender) == .move)
        fixture.view.draggingExited(sender)
        #expect(!fixture.view.dropOverlay.isPresenting)

        #expect(fixture.view.draggingEntered(sender) == .move)
        fixture.view.apply(workspace: workspaceSnapshot, layout: unsplit)
        #expect(!fixture.view.dropOverlay.isPresenting)

        #expect(fixture.view.draggingEntered(sender) == .move)
        fixture.view.tearDown()
        #expect(!fixture.view.dropOverlay.isPresenting)
        #expect(fixture.view.registeredDraggedTypes.isEmpty)
        #expect(fixture.view.primaryPane.tabStrip.hostedCollectionView.registeredDraggedTypes.isEmpty)
    }

    @Test @MainActor func crossGroupLastSourceMoveAcceptsUniqueAndClonedDestinations() throws {
        let fixture = makeFixture()
        let uniqueDestination = layout(
            primary: [fixture.tabs[0].id],
            secondary: [fixture.tabs[1].id],
            primarySelection: fixture.tabs[0].id,
            secondarySelection: fixture.tabs[1].id,
            orientation: .stacked
        )
        fixture.view.apply(workspace: workspace(tabs: fixture.tabs), layout: uniqueDestination)
        let payload = EditorGroupDragPayload(tabID: fixture.tabs[0].id, sourceGroup: .primary)
        let board = pasteboard(payload)
        #expect((try #require(fixture.view.secondaryPane)).tabStrip.acceptDrop(
            from: board,
            insertionIndex: 1,
            optionPressed: false
        ))

        let clonedDestination = layout(
            primary: [fixture.tabs[0].id],
            secondary: [fixture.tabs[0].id, fixture.tabs[1].id],
            primarySelection: fixture.tabs[0].id,
            secondarySelection: fixture.tabs[1].id,
            orientation: .stacked
        )
        fixture.view.apply(workspace: workspace(tabs: fixture.tabs), layout: clonedDestination)
        var action: EditorGroupWorkspaceView.Action?
        fixture.view.onAction = { action = $0 }
        #expect((try #require(fixture.view.secondaryPane)).tabStrip.acceptDrop(
            from: board,
            insertionIndex: 1,
            optionPressed: false
        ))
        #expect(action == .transfer(fixture.tabs[0].id, .primary, .secondary, 1, .move))
    }

    @Test @MainActor func secondaryCollapseAndReopenReusesHostWithFreshCallbacksAndDragRouting() throws {
        let fixture = makeFixture()
        let splitLayout = layout(
            primary: [fixture.tabs[0].id, fixture.tabs[1].id],
            secondary: [fixture.tabs[2].id],
            primarySelection: fixture.tabs[0].id,
            secondarySelection: fixture.tabs[2].id,
            orientation: .sideBySide
        )
        fixture.view.apply(workspace: workspace(tabs: fixture.tabs), layout: splitLayout)
        let originalPane = try #require(fixture.view.secondaryPane)

        fixture.view.apply(
            workspace: workspace(tabs: fixture.tabs),
            layout: layout(primary: fixture.tabs.map(\.id), primarySelection: fixture.tabs[0].id)
        )
        #expect(fixture.secondaryEditor.superview == nil)
        #expect(originalPane.tabStrip.onActivate == nil)
        #expect(originalPane.tabStrip.onGroupDrop == nil)
        #expect(originalPane.tabStrip.hostedCollectionView.registeredDraggedTypes.isEmpty)

        fixture.view.apply(workspace: workspace(tabs: fixture.tabs), layout: splitLayout)
        let reopened = try #require(fixture.view.secondaryPane)
        #expect(reopened !== originalPane)
        #expect(reopened.editorHostView === fixture.secondaryEditor)
        #expect(reopened.tabStrip.hostedCollectionView.registeredDraggedTypes.contains(
            .init(EditorGroupDragPayload.pasteboardType)
        ))
        var actions: [EditorGroupWorkspaceView.Action] = []
        fixture.view.onAction = { actions.append($0) }
        reopened.tabStrip.onActivate?(fixture.tabs[2].id)
        #expect(reopened.tabStrip.acceptDrop(
            from: pasteboard(.init(tabID: fixture.tabs[1].id, sourceGroup: .primary)),
            insertionIndex: 1,
            optionPressed: true
        ))
        #expect(actions == [
            .select(fixture.tabs[2].id, .secondary),
            .transfer(fixture.tabs[1].id, .primary, .secondary, 1, .copy),
        ])
    }
}

@MainActor
private func makeFixture(
    tabCount: Int = 3,
    modifierFlagsProvider: @escaping () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
) -> (
    view: EditorGroupWorkspaceView,
    primaryEditor: NSView,
    secondaryEditor: NSView,
    tabs: [TabSnapshot]
) {
    let primaryEditor = NSView(frame: .zero)
    let secondaryEditor = NSView(frame: .zero)
    let view = EditorGroupWorkspaceView(
        primaryEditorHost: primaryEditor,
        secondaryEditorHost: secondaryEditor,
        modifierFlagsProvider: modifierFlagsProvider
    )
    return (view, primaryEditor, secondaryEditor, makeGroupTabs(count: tabCount))
}

private func makeGroupTabs(count: Int) -> [TabSnapshot] {
    (0..<count).map { index in
        TabSnapshot(
            id: TabID(),
            title: "document \(index + 1)",
            isActive: index == 0,
            isDirty: false,
            isPinned: false,
            buffer: EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
        )
    }
}

private func workspace(tabs: [TabSnapshot]) -> WorkspaceSnapshot {
    WorkspaceSnapshot(
        sessionID: SessionID(),
        tabs: tabs,
        activeBuffer: tabs.first?.buffer,
        persistence: .saved,
        startup: .ready
    )
}

private func layout(
    primary: [TabID],
    secondary: [TabID] = [],
    primarySelection: TabID?,
    secondarySelection: TabID? = nil,
    focused: EditorGroupID = .primary,
    orientation: EditorGroupSplitOrientation? = nil
) -> EditorGroupLayoutSnapshot {
    EditorGroupLayoutSnapshot(
        primaryTabIDs: primary,
        secondaryTabIDs: secondary,
        primarySelectedTabID: primarySelection,
        secondarySelectedTabID: secondarySelection,
        focusedGroup: focused,
        orientation: orientation
    )
}

@MainActor
private func hostInWindow(_ workspaceView: EditorGroupWorkspaceView) -> NSWindow {
    let window = NativeDragWindowFixture.window
    let root = NSView(frame: window.contentView?.bounds ?? .zero)
    window.contentView = root
    root.addSubview(workspaceView)
    NSLayoutConstraint.activate([
        workspaceView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 37),
        workspaceView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -19),
        workspaceView.topAnchor.constraint(equalTo: root.topAnchor, constant: 29),
        workspaceView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -41),
    ])
    root.layoutSubtreeIfNeeded()
    workspaceView.layoutSubtreeIfNeeded()
    return window
}

@MainActor
private enum NativeDragWindowFixture {
    static let window: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }()
}

private func pasteboard(_ payload: EditorGroupDragPayload) -> NSPasteboard {
    let board = NSPasteboard(name: .init("duckpad.editor-group.native-drag.\(UUID().uuidString)"))
    board.clearContents()
    board.setData(payload.encodedData(), forType: .init(EditorGroupDragPayload.pasteboardType))
    return board
}

@MainActor
private final class DraggingInfoStub: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingSourceOperationMask: NSDragOperation
    let draggingLocation: NSPoint
    let draggingPasteboard: NSPasteboard
    let draggedImageLocation: NSPoint = .zero
    let draggedImage: NSImage? = nil
    let draggingSource: Any? = nil
    let draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    let springLoadingHighlight: NSSpringLoadingHighlight = .none

    init(
        window: NSWindow,
        pasteboard: NSPasteboard,
        location: NSPoint,
        sourceOperationMask: NSDragOperation
    ) {
        draggingDestinationWindow = window
        draggingPasteboard = pasteboard
        draggingLocation = location
        draggingSourceOperationMask = sourceOperationMask
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func resetSpringLoading() {}
}
