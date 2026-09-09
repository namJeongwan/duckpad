import DuckpadApplication
import DuckpadDomain
@testable import DuckpadPresentation
import Testing

@Test @MainActor func fourDirectionalSplitsBuildAGridAndRejectAFifthPaneWithoutLosingTabs() throws {
    let tabs = (0..<5).map { _ in TabID() }
    let model = EditorGroupLayoutModel()
    model.reconcile(workspace: workspace(tabs))
    #expect(model.splitAdjacent(tabID: tabs[1], source: .primary, target: .primary, zone: .right, operation: .move) == .secondary)
    #expect(model.splitAdjacent(tabID: tabs[2], source: .primary, target: .primary, zone: .down, operation: .move) == .tertiary)
    #expect(model.splitAdjacent(tabID: tabs[3], source: .primary, target: .secondary, zone: .up, operation: .move) == .quaternary)
    #expect(model.snapshot.tree == .split(.sideBySide,
        .split(.stacked, .leaf(.primary), .leaf(.tertiary)),
        .split(.stacked, .leaf(.quaternary), .leaf(.secondary))))
    let before = model.snapshot
    #expect(model.splitAdjacent(tabID: tabs[4], source: .primary, target: .secondary, zone: .left, operation: .move) == nil)
    #expect(model.snapshot == before)
    #expect(Set(before.visibleGroups.flatMap { before.tabIDs(in: $0) }) == Set(tabs))
    model.closeGroup(.quaternary)
    #expect(model.snapshot.visibleGroups.count == 3)
    #expect(Set(model.snapshot.visibleGroups.flatMap { model.snapshot.tabIDs(in: $0) }) == Set(tabs))
    #expect(model.splitAdjacent(tabID: tabs[4], source: .primary, target: .tertiary, zone: .left, operation: .move) == .quaternary)
    #expect(model.snapshot.tree.groups == [.primary, .quaternary, .tertiary, .secondary])
}

@Test @MainActor func closingTheLastTabOfAFourPaneLayoutCollapsesOnlyThatLeaf() {
    let tabs = (0..<4).map { _ in TabID() }
    let model = EditorGroupLayoutModel()
    model.reconcile(workspace: workspace(tabs))
    _ = model.splitAdjacent(tabID: tabs[1], source: .primary, target: .primary, zone: .left, operation: .move)
    _ = model.splitAdjacent(tabID: tabs[2], source: .primary, target: .secondary, zone: .down, operation: .move)
    _ = model.splitAdjacent(tabID: tabs[3], source: .primary, target: .primary, zone: .up, operation: .move)
    model.reconcile(workspace: workspace(Array(tabs.dropLast()), active: tabs[2]))
    #expect(model.snapshot.visibleGroups.count == 3)
    #expect(model.snapshot.selectedTabID(in: .tertiary) == tabs[2])
    #expect(model.snapshot.focusedGroup == .tertiary)
    #expect(!model.snapshot.visibleGroups.contains(.quaternary))
}

@MainActor
private func workspace(
    _ tabIDs: [TabID],
    active activeTabID: TabID? = nil
) -> WorkspaceSnapshot {
    let activeTabID = activeTabID ?? tabIDs.first
    return WorkspaceSnapshot(
        sessionID: SessionID(),
        tabs: tabIDs.map { id in
            TabSnapshot(
                id: id,
                title: id.rawValue.uuidString,
                isActive: id == activeTabID,
                isDirty: false,
                isPinned: false,
                buffer: EditorBufferDescriptor(bufferID: BufferID(), revision: 0)
            )
        },
        activeBuffer: nil,
        persistence: .idle,
        startup: .ready
    )
}

@Test @MainActor func reconciliationPlacesInitialTabsInPrimaryAndSelectsTheActiveTab() {
    let tabs = [TabID(), TabID(), TabID()]
    let model = EditorGroupLayoutModel()

    model.reconcile(workspace: workspace(tabs, active: tabs[1]))

    #expect(model.snapshot.tabIDs(in: .primary) == tabs)
    #expect(model.snapshot.tabIDs(in: .secondary).isEmpty)
    #expect(model.snapshot.selectedTabID(in: .primary) == tabs[1])
    #expect(model.snapshot.focusedGroup == .primary)
    #expect(model.snapshot.orientation == nil)
}

@Test @MainActor func movingTabsToRightOrDownCreatesTheRequestedSplitOrientation() {
    let tabs = [TabID(), TabID(), TabID()]
    let model = EditorGroupLayoutModel()
    model.reconcile(workspace: workspace(tabs))

    #expect(model.split(tabID: tabs[1], source: .primary, orientation: .sideBySide, operation: .move))
    #expect(model.snapshot.tabIDs(in: .primary) == [tabs[0], tabs[2]])
    #expect(model.snapshot.tabIDs(in: .secondary) == [tabs[1]])
    #expect(model.snapshot.orientation == .sideBySide)

    let downModel = EditorGroupLayoutModel()
    downModel.reconcile(workspace: workspace(tabs))
    #expect(downModel.split(tabID: tabs[1], source: .primary, orientation: .stacked, operation: .move))
    #expect(downModel.snapshot.orientation == .stacked)
}

@Test @MainActor func movingTheOnlyTabInItsSourceGroupIsRejectedWithoutChangingLayout() {
    let tab = TabID()
    let model = EditorGroupLayoutModel()
    model.reconcile(workspace: workspace([tab]))

    #expect(!model.split(tabID: tab, source: .primary, orientation: .sideBySide, operation: .move))
    #expect(model.snapshot.tabIDs(in: .primary) == [tab])
    #expect(model.snapshot.orientation == nil)
}

@Test @MainActor func directMoveIsRejectedUntilASplitOrientationExists() {
    let tabs = [TabID(), TabID()]
    let model = EditorGroupLayoutModel()
    model.reconcile(workspace: workspace(tabs))

    #expect(!model.move(tabs[0], from: .primary, to: .secondary))
    #expect(model.snapshot.tabIDs(in: .primary) == tabs)
    #expect(model.snapshot.tabIDs(in: .secondary).isEmpty)
    #expect(model.snapshot.orientation == nil)
}

@Test @MainActor func directMoveRejectsAFinalUniqueSourceReference() {
    let tabs = [TabID(), TabID()]
    let model = EditorGroupLayoutModel()
    model.reconcile(workspace: workspace(tabs))
    #expect(model.split(tabID: tabs[1], source: .primary, orientation: .sideBySide, operation: .move))
    let snapshot = model.snapshot

    #expect(!model.move(tabs[1], from: .secondary, to: .primary))
    #expect(model.snapshot == snapshot)
}

@Test @MainActor func optionCopyClonesATabIntoTheSecondaryGroup() {
    let tabs = [TabID(), TabID()]
    let model = EditorGroupLayoutModel()
    model.reconcile(workspace: workspace(tabs))

    #expect(model.split(tabID: tabs[0], source: .primary, orientation: .sideBySide, operation: .copy))
    #expect(model.snapshot.tabIDs(in: .primary) == tabs)
    #expect(model.snapshot.tabIDs(in: .secondary) == [tabs[0]])
    #expect(model.snapshot.selectedTabID(in: .secondary) == tabs[0])
    #expect(model.snapshot.focusedGroup == .secondary)
}

@Test @MainActor func copyingAnExistingDestinationReferenceIsRejected() {
    let tabs = [TabID(), TabID()]
    let model = EditorGroupLayoutModel()
    model.reconcile(workspace: workspace(tabs))
    #expect(model.split(tabID: tabs[0], source: .primary, orientation: .sideBySide, operation: .copy))
    let snapshot = model.snapshot

    #expect(!model.split(tabID: tabs[0], source: .primary, orientation: .sideBySide, operation: .copy))
    #expect(model.snapshot == snapshot)
}

@Test @MainActor func movingAClonedReferenceRemovesOnlyItsSourceAndCollapsesAnEmptyGroup() {
    let tab = TabID()
    let model = EditorGroupLayoutModel()
    model.reconcile(workspace: workspace([tab]))
    #expect(model.split(tabID: tab, source: .primary, orientation: .sideBySide, operation: .copy))

    #expect(model.split(tabID: tab, source: .primary, orientation: .sideBySide, operation: .move))
    #expect(model.snapshot.tabIDs(in: .primary) == [tab])
    #expect(model.snapshot.tabIDs(in: .secondary).isEmpty)
    #expect(model.snapshot.orientation == nil)
    #expect(model.snapshot.focusedGroup == .primary)
}

@Test @MainActor func selectionsRemainIndependentAndSelectionFocusesThatGroup() {
    let tabs = [TabID(), TabID(), TabID()]
    let model = EditorGroupLayoutModel()
    model.reconcile(workspace: workspace(tabs))
    #expect(model.split(tabID: tabs[2], source: .primary, orientation: .sideBySide, operation: .move))

    #expect(model.select(tabs[0], in: .primary))
    #expect(model.select(tabs[2], in: .secondary))
    #expect(model.snapshot.selectedTabID(in: .primary) == tabs[0])
    #expect(model.snapshot.selectedTabID(in: .secondary) == tabs[2])
    #expect(model.snapshot.focusedGroup == .secondary)
}

@Test @MainActor func reconciliationInsertsNewTabsIntoFocusedGroupAndReconcilesActiveMembership() {
    let tabs = [TabID(), TabID()]
    let model = EditorGroupLayoutModel()
    model.reconcile(workspace: workspace(tabs))
    #expect(model.split(tabID: tabs[1], source: .primary, orientation: .sideBySide, operation: .move))
    #expect(model.select(tabs[1], in: .secondary))
    let newTab = TabID()

    model.reconcile(workspace: workspace(tabs + [newTab], active: newTab))

    #expect(model.snapshot.tabIDs(in: .primary) == [tabs[0]])
    #expect(model.snapshot.tabIDs(in: .secondary) == [tabs[1], newTab])
    #expect(model.snapshot.selectedTabID(in: .secondary) == newTab)
    #expect(model.snapshot.focusedGroup == .secondary)
}

@Test @MainActor func reconciliationFocusesTheUniqueActiveGroupAndKeepsFocusForAClonedActiveTab() {
    let tabs = [TabID(), TabID()]
    let model = EditorGroupLayoutModel()
    model.reconcile(workspace: workspace(tabs))
    #expect(model.split(tabID: tabs[1], source: .primary, orientation: .sideBySide, operation: .move))

    model.reconcile(workspace: workspace(tabs, active: tabs[1]))
    #expect(model.snapshot.focusedGroup == .secondary)

    #expect(model.split(tabID: tabs[1], source: .secondary, orientation: .sideBySide, operation: .copy))
    #expect(model.select(tabs[0], in: .primary))
    model.reconcile(workspace: workspace(tabs, active: tabs[1]))
    #expect(model.snapshot.focusedGroup == .primary)
    #expect(model.snapshot.selectedTabID(in: .primary) == tabs[1])
    #expect(model.snapshot.selectedTabID(in: .secondary) == tabs[1])
}

@Test @MainActor func reconciliationRemovesClosedTabsAndNormalizesTheRemainingGroup() {
    let tabs = [TabID(), TabID()]
    let model = EditorGroupLayoutModel()
    model.reconcile(workspace: workspace(tabs))
    #expect(model.split(tabID: tabs[1], source: .primary, orientation: .sideBySide, operation: .move))

    model.reconcile(workspace: workspace([tabs[1]], active: tabs[1]))

    #expect(model.snapshot.tabIDs(in: .primary) == [tabs[1]])
    #expect(model.snapshot.tabIDs(in: .secondary).isEmpty)
    #expect(model.snapshot.orientation == nil)
}

@Test @MainActor func reconciliationMaintainsWorkspaceOrderInBothGroupsAfterAWorkspaceReorder() {
    let tabs = [TabID(), TabID(), TabID(), TabID()]
    let model = EditorGroupLayoutModel()
    model.reconcile(workspace: workspace(tabs))
    #expect(model.split(tabID: tabs[1], source: .primary, orientation: .sideBySide, operation: .copy))
    #expect(model.split(tabID: tabs[3], source: .primary, orientation: .sideBySide, operation: .move))
    let reordered = [tabs[3], tabs[2], tabs[1], tabs[0]]

    model.reconcile(workspace: workspace(reordered, active: tabs[3]))

    #expect(model.snapshot.tabIDs(in: .primary) == [tabs[2], tabs[1], tabs[0]])
    #expect(model.snapshot.tabIDs(in: .secondary) == [tabs[3], tabs[1]])
}

@Test @MainActor func reconciliationRemovesAClosedClonedTabFromBothGroups() {
    let tabs = [TabID(), TabID()]
    let model = EditorGroupLayoutModel()
    model.reconcile(workspace: workspace(tabs))
    #expect(model.split(tabID: tabs[0], source: .primary, orientation: .sideBySide, operation: .copy))

    model.reconcile(workspace: workspace([tabs[1]], active: tabs[1]))

    #expect(model.snapshot.tabIDs(in: .primary) == [tabs[1]])
    #expect(model.snapshot.tabIDs(in: .secondary).isEmpty)
    #expect(model.snapshot.orientation == nil)
}

@Test @MainActor func closingSecondaryMovesItsUniqueTabsBackToPrimaryInWorkspaceOrder() {
    let tabs = [TabID(), TabID(), TabID()]
    let model = EditorGroupLayoutModel()
    model.reconcile(workspace: workspace(tabs))
    #expect(model.split(tabID: tabs[2], source: .primary, orientation: .sideBySide, operation: .move))

    model.closeSecondaryGroup()

    #expect(model.snapshot.tabIDs(in: .primary) == tabs)
    #expect(model.snapshot.tabIDs(in: .secondary).isEmpty)
    #expect(model.snapshot.orientation == nil)
    #expect(model.snapshot.focusedGroup == .primary)
}
