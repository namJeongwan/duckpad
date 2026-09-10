import AppKit
import DuckpadApplication
import DuckpadDomain
@testable import DuckpadPresentation
import Testing

private actor EditorGroupSessionStore: SessionStore {
    private var session: ScratchSession?
    private var generation = PersistenceGeneration(rawValue: 0)
    private var shouldFailNextCommit = false
    private var shouldBlockNextCommit = false
    private var blockedCommitEntered = false
    private var releaseBlockedCommit = false

    init(session: ScratchSession) { self.session = session }

    func loadSession() async throws(SessionStoreError) -> StoredSession? {
        session.map { StoredSession(session: $0, generation: generation) }
    }

    func commitSession(
        _ session: ScratchSession,
        generation: PersistenceGeneration
    ) async throws(SessionStoreError) -> SessionCommitResult {
        if shouldBlockNextCommit,
           session.tabs.count < (self.session?.tabs.count ?? session.tabs.count) {
            shouldBlockNextCommit = false
            blockedCommitEntered = true
            while !releaseBlockedCommit { await Task.yield() }
        }
        if shouldFailNextCommit, !shouldBlockNextCommit {
            shouldFailNextCommit = false
            throw .unavailable("injected editor-group persistence failure")
        }
        guard generation > self.generation else {
            return .superseded(durableGeneration: self.generation)
        }
        self.session = session
        self.generation = generation
        return .committed
    }

    func failNextCommit() { shouldFailNextCommit = true }
    func blockNextCommit(failingAfterRelease: Bool = false) {
        shouldBlockNextCommit = true
        shouldFailNextCommit = failingAfterRelease
        blockedCommitEntered = false
        releaseBlockedCommit = false
    }
    func waitUntilCommitIsBlocked() async {
        while !blockedCommitEntered { await Task.yield() }
    }
    func releaseCommit() { releaseBlockedCommit = true }
}

private actor EditorGroupFileStore: TextFileStore {
    func canonicalURL(for url: URL) async throws(TextFileStoreError) -> URL { url }

    func read(from url: URL) async throws(TextFileStoreError) -> FileReadResult {
        throw .notFound(url.path)
    }

    func writeAtomically(
        _ data: Data,
        to url: URL,
        expectedIdentity: FileIdentity?,
        overwrite: Bool
    ) async throws(TextFileStoreError) -> FileWriteReceipt {
        FileWriteReceipt(identity: identity(for: url, byteCount: data.count))
    }

    private func identity(for url: URL, byteCount: Int) -> FileIdentity {
        FileIdentity(
            canonicalPath: url.path,
            device: 1,
            inode: 1,
            byteCount: UInt64(byteCount),
            modifiedNanoseconds: 1,
            contentToken: "saved"
        )
    }
}

@MainActor
private final class EditorGroupFilePanels: FilePanelPresenting {
    var saveURLs: [URL] = []

    func chooseOpenURL(attachedTo window: NSWindow?) async -> URL? { nil }
    func chooseSaveURL(suggestedName: String, attachedTo window: NSWindow?) async -> URL? {
        saveURLs.isEmpty ? nil : saveURLs.removeFirst()
    }
    func chooseFolderURL(attachedTo window: NSWindow?) async -> URL? { nil }
}

@MainActor
private final class EditorGroupRouterSpy: EditorGroupRoutingPort, SplitEditorPort {
    enum Event: Equatable {
        case orientation(EditorGroupSplitOrientation?)
        case activate(EditorGroupID)
        case display(EditorBufferDescriptor, EditorGroupID?)
        case assign(EditorBufferDescriptor, EditorGroupID?, EditorGroupID, Bool)
        case focus
        case internalSplit(EditorSplitOrientation)
        case closeInternalSplit
    }

    var onEdit: ((EditorIncrementalEdit) -> EditorEditOutcome)?
    var onEditorGroupFocus: ((EditorGroupID) -> Void)?
    private(set) var activeEditorGroup: EditorGroupID = .primary
    private(set) var editorGroupOrientation: EditorGroupSplitOrientation?
    var hasVisibleGroups: Bool { editorGroupOrientation != nil }
    private(set) var suspendedInternalSplitOrientation: EditorSplitOrientation?
    private(set) var splitOrientation: EditorSplitOrientation?
    private(set) var events: [Event] = []
    var publishesGroupFocusSynchronously = false
    private(set) var synchronousGroupFocusCallbackCount = 0
    private var snapshots: [BufferID: EditorTextSnapshot] = [:]
    private(set) var visibleBuffers: [EditorGroupID: EditorBufferDescriptor] = [:]

    func setEditorGroupOrientation(_ orientation: EditorGroupSplitOrientation?) {
        events.append(.orientation(orientation))
        if orientation != nil, let splitOrientation {
            suspendedInternalSplitOrientation = splitOrientation
            self.splitOrientation = nil
        } else if orientation == nil, let suspendedInternalSplitOrientation {
            splitOrientation = suspendedInternalSplitOrientation
            self.suspendedInternalSplitOrientation = nil
        }
        editorGroupOrientation = orientation
    }

    func activateEditorGroup(_ group: EditorGroupID) {
        activeEditorGroup = group
        events.append(.activate(group))
    }

    func display(_ buffer: EditorBufferDescriptor, in group: EditorGroupID) {
        events.append(.display(buffer, group))
        visibleBuffers[group] = buffer
    }

    func assign(
        _ buffer: EditorBufferDescriptor,
        from source: EditorGroupID?,
        to destination: EditorGroupID,
        cloning: Bool
    ) {
        events.append(.assign(buffer, source, destination, cloning))
        if !cloning, let source, visibleBuffers[source]?.bufferID == buffer.bufferID {
            visibleBuffers.removeValue(forKey: source)
        }
        visibleBuffers[destination] = buffer
    }

    func display(_ buffer: EditorBufferDescriptor) {
        events.append(.display(buffer, nil))
        snapshots[buffer.bufferID] = snapshots[buffer.bufferID]
            ?? .init(bufferID: buffer.bufferID, revision: buffer.revision, text: "")
    }

    func install(_ snapshot: EditorTextSnapshot) { snapshots[snapshot.bufferID] = snapshot }
    func snapshot(for bufferID: BufferID) -> EditorTextSnapshot? { snapshots[bufferID] }
    func retire(bufferID: BufferID) { snapshots.removeValue(forKey: bufferID) }
    func setInputEnabled(_ isEnabled: Bool) {}
    func focus() {
        events.append(.focus)
        guard publishesGroupFocusSynchronously,
              synchronousGroupFocusCallbackCount < 8 else { return }
        synchronousGroupFocusCallbackCount += 1
        onEditorGroupFocus?(activeEditorGroup)
    }

    func split(orientation: EditorSplitOrientation) {
        splitOrientation = orientation
        events.append(.internalSplit(orientation))
    }

    func closeSplit() {
        splitOrientation = nil
        events.append(.closeInternalSplit)
    }

    func focusOtherPane() {}

    func resetEvents() {
        events = []
        synchronousGroupFocusCallbackCount = 0
    }
}

@Suite(.serialized)
struct EditorGroupCommandTests {
    @Test @MainActor
    func adjacentSplitsRouteDynamicPanesAndKeepTheSourceEditorPopulated() async throws {
        let fixture = await makeEditorGroupController(tabCount: 5)
        defer { fixture.controller.close() }
        let tabs = fixture.workspace.snapshot().tabs
        let active = try #require(tabs.first(where: { $0.isActive }))
        fixture.controller.editorGroupWorkspace.onAction?(.splitAdjacent(active.id, .primary, .primary, .right, .move))
        let first = fixture.controller.editorGroupLayoutSnapshot
        let sourceSelected = try #require(first.primarySelectedTabID)
        let sourceBuffer = try #require(tabs.first(where: { $0.id == sourceSelected })?.buffer)
        #expect(fixture.router.visibleBuffers[.primary] == sourceBuffer)
        let rootSplit = fixture.controller.editorGroupWorkspace.splitView
        rootSplit.setPosition(300, ofDividerAt: 0)
        let originalLeftWidth = rootSplit.arrangedSubviews[0].frame.width
        let remaining = tabs.filter { $0.id != active.id }
        fixture.controller.editorGroupWorkspace.onAction?(.splitAdjacent(remaining[1].id, .primary, .primary, .down, .move))
        fixture.controller.editorGroupWorkspace.onAction?(.splitAdjacent(remaining[2].id, .primary, .secondary, .down, .move))
        await eventually { fixture.router.activeEditorGroup == .quaternary }
        let layout = fixture.controller.editorGroupLayoutSnapshot
        #expect(layout.visibleGroups.count == 4)
        #expect(abs(rootSplit.arrangedSubviews[0].frame.width - originalLeftWidth) < 1)
        fixture.controller.window?.contentView?.layoutSubtreeIfNeeded()
        let panes = try layout.visibleGroups.map { try #require(fixture.controller.editorGroupWorkspace.pane(for: $0)) }
        #expect(panes.allSatisfy { $0.frame.width > 100 && $0.frame.height > 60 })
        for group in layout.visibleGroups {
            let selected = try #require(layout.selectedTabID(in: group))
            let buffer = try #require(tabs.first(where: { $0.id == selected })?.buffer)
            #expect(fixture.router.visibleBuffers[group] == buffer)
        }
        let drop = fixture.controller.editorGroupWorkspace
        let bottom = NSPoint(x: drop.dropOverlay.bounds.midX, y: drop.dropOverlay.bounds.minY + 2)
        let payload = EditorGroupDragPayload(tabID: remaining[0].id, sourceGroup: .primary)
        #expect(drop.updateEdgeDrop(payload: payload, location: bottom, optionPressed: false) == .move)
        #expect(drop.performEdgeDrop(payload: payload, location: bottom, optionPressed: false))
        let expanded = fixture.controller.editorGroupLayoutSnapshot
        #expect(expanded.visibleGroups.count == 5)
        let fifth = try #require(expanded.visibleGroups.first { !EditorGroupID.predefined.contains($0) })
        #expect(fixture.controller.editorGroupWorkspace.pane(for: fifth) != nil)
        #expect(fixture.router.visibleBuffers[fifth] == remaining[0].buffer)
        fixture.controller.editorGroupWorkspace.onAction?(.context(remaining[0].id, fifth, .closeEditorGroup))
        fixture.controller.editorGroupWorkspace.onAction?(.context(active.id, .secondary, .closeEditorGroup))
        let closed = fixture.controller.editorGroupLayoutSnapshot
        #expect(closed.visibleGroups.count == 3)
        #expect(!closed.visibleGroups.contains(.secondary))
        #expect(closed.visibleGroups.contains(.quaternary))
        let primaryID = try #require(closed.primarySelectedTabID)
        fixture.controller.editorGroupWorkspace.onAction?(.context(primaryID, .primary, .focusOtherEditorGroup))
        await eventually { fixture.router.activeEditorGroup == .tertiary }
        #expect(fixture.router.activeEditorGroup == .tertiary)
    }

    @Test @MainActor
    func reentrantEditorFocusIgnoresAffirmationButStillRoutesGenuineGroupFocus() async throws {
        let fixture = await makeEditorGroupController(tabCount: 2)
        defer { fixture.controller.close() }
        let tabs = fixture.workspace.snapshot().tabs
        let moved = try #require(tabs.first(where: { $0.isActive }))
        fixture.router.resetEvents()
        fixture.router.publishesGroupFocusSynchronously = true

        fixture.controller.performMoveActiveTabToGroupRight(nil)
        await eventually {
            fixture.controller.editorGroupLayoutSnapshot.orientation == .sideBySide
                && fixture.controller.editorGroupLayoutSnapshot.focusedGroup == .secondary
        }

        #expect(fixture.controller.editorGroupLayoutSnapshot.secondaryTabIDs == [moved.id])
        #expect(fixture.router.events.filter { $0 == .display(moved.buffer, .secondary) }.count == 1)
        #expect(fixture.router.events.filter { $0 == .activate(.secondary) }.count == 1)
        #expect(fixture.router.events.filter { $0 == .focus }.count == 1)
        #expect(fixture.router.synchronousGroupFocusCallbackCount == 1)

        let primarySelection = try #require(
            fixture.controller.editorGroupLayoutSnapshot.primarySelectedTabID
        )
        fixture.router.resetEvents()
        fixture.router.activateEditorGroup(.primary)
        fixture.router.onEditorGroupFocus?(.primary)
        await eventually {
            fixture.workspace.snapshot().tabs.first(where: \.isActive)?.id == primarySelection
                && fixture.controller.editorGroupLayoutSnapshot.focusedGroup == .primary
                && fixture.router.synchronousGroupFocusCallbackCount == 1
        }

        #expect(fixture.router.events.filter { $0 == .focus }.count == 1)
        #expect(fixture.router.synchronousGroupFocusCallbackCount == 1)
    }

    @Test @MainActor
    func reentrantEditorFocusAfterCloneRendersAndFocusesDestinationOnce() async throws {
        let fixture = await makeEditorGroupController(tabCount: 2)
        defer { fixture.controller.close() }
        let cloned = try #require(
            fixture.workspace.snapshot().tabs.first(where: { $0.isActive })
        )
        fixture.router.resetEvents()
        fixture.router.publishesGroupFocusSynchronously = true

        fixture.controller.performCloneActiveTabToGroupDown(nil)
        await eventually {
            fixture.controller.editorGroupLayoutSnapshot.orientation == .stacked
                && fixture.controller.editorGroupLayoutSnapshot.focusedGroup == .secondary
        }

        #expect(fixture.controller.editorGroupLayoutSnapshot.secondaryTabIDs == [cloned.id])
        #expect(fixture.router.events.filter { $0 == .display(cloned.buffer, .secondary) }.count == 1)
        #expect(fixture.router.events.filter { $0 == .activate(.secondary) }.count == 1)
        #expect(fixture.router.events.filter { $0 == .focus }.count == 1)
        #expect(fixture.router.synchronousGroupFocusCallbackCount == 1)
    }

    @Test @MainActor
    func movingActivePrimaryTabToNewSecondaryRendersThePrimaryReplacementAfterAssignment() async throws {
        let fixture = await makeEditorGroupController(tabCount: 3)
        defer { fixture.controller.close() }
        let tabs = fixture.workspace.snapshot().tabs
        let moved = try #require(tabs.first(where: { $0.isActive }))
        fixture.router.resetEvents()

        fixture.controller.performMoveActiveTabToGroupRight(nil)

        let layout = fixture.controller.editorGroupLayoutSnapshot
        let primaryTabID = try #require(layout.primarySelectedTabID)
        let primary = try #require(tabs.first(where: { $0.id == primaryTabID }))
        let events = fixture.router.events
        let assignment = try #require(events.firstIndex(of: .assign(
            moved.buffer,
            .primary,
            .secondary,
            false
        )))
        let sourceDisplay = try #require(events.firstIndex(of: .display(primary.buffer, .primary)))
        let destinationDisplay = try #require(events.firstIndex(of: .display(moved.buffer, .secondary)))

        #expect(assignment < sourceDisplay)
        #expect(sourceDisplay < destinationDisplay)
        #expect(events.filter { $0 == .display(primary.buffer, .primary) }.count == 1)
        #expect(events.filter { $0 == .display(moved.buffer, .secondary) }.count == 1)
        #expect(fixture.router.visibleBuffers[.primary] == primary.buffer)
        #expect(fixture.router.visibleBuffers[.secondary] == moved.buffer)
        #expect(layout.secondarySelectedTabID == moved.id)
        #expect(fixture.router.events.filter { $0 == .focus }.count == 1)
    }

    @Test @MainActor
    func splitCloneAssignsAndActivatesDestinationBeforeWorkspaceDisplay() async throws {
        let fixture = await makeEditorGroupController(tabCount: 2)
        defer { fixture.controller.close() }
        let active = try #require(fixture.workspace.snapshot().tabs.first(where: { $0.isActive }))
        fixture.router.resetEvents()

        fixture.controller.editorGroupWorkspace.onAction?(
            .split(active.id, .primary, .sideBySide, .copy)
        )
        await eventually {
            fixture.router.events.contains(.display(active.buffer, nil))
        }

        let events = fixture.router.events
        let assign = try #require(events.firstIndex(of: .assign(active.buffer, .primary, .secondary, true)))
        let activate = try #require(events.firstIndex(of: .activate(.secondary)))
        let globalDisplay = try #require(events.lastIndex(of: .display(active.buffer, nil)))
        #expect(assign < activate)
        #expect(activate < globalDisplay)
        #expect(fixture.controller.editorGroupLayoutSnapshot.focusedGroup == .secondary)
        #expect(fixture.controller.editorGroupLayoutSnapshot.secondaryTabIDs == [active.id])
    }

    @Test @MainActor
    func oneTabRejectsMoveButAllowsCloneAndSuspendsInternalSplit() async throws {
        let fixture = await makeEditorGroupController(tabCount: 1)
        defer { fixture.controller.close() }
        fixture.router.split(orientation: .stacked)
        let move = menuItem(#selector(DuckpadWindowController.performMoveActiveTabToGroupRight(_:)))
        let clone = menuItem(#selector(DuckpadWindowController.performCloneActiveTabToGroupRight(_:)))
        let internalSplit = menuItem(#selector(DuckpadWindowController.performSplitEditorRight(_:)))

        #expect(!fixture.controller.validateMenuItem(move))
        #expect(fixture.controller.validateMenuItem(clone))
        fixture.controller.performMoveActiveTabToGroupRight(nil)
        #expect(fixture.controller.editorGroupLayoutSnapshot.orientation == nil)

        fixture.controller.performCloneActiveTabToGroupRight(nil)
        await eventually { fixture.controller.editorGroupLayoutSnapshot.orientation == .sideBySide }
        #expect(fixture.router.suspendedInternalSplitOrientation == .stacked)
        #expect(!fixture.controller.validateMenuItem(internalSplit))
    }

    @Test @MainActor
    func groupFocusActivatesThatGroupsSelectionAndCloneAmbiguityIsValidated() async throws {
        let fixture = await makeEditorGroupController(tabCount: 2)
        defer { fixture.controller.close() }
        let tabs = fixture.workspace.snapshot().tabs
        let cloned = try #require(tabs.last)
        fixture.controller.editorGroupWorkspace.onAction?(
            .split(cloned.id, .primary, .stacked, .copy)
        )
        await eventually { fixture.controller.editorGroupLayoutSnapshot.orientation == .stacked }
        #expect(fixture.controller.editorGroupLayoutSnapshot.secondarySelectedTabID == cloned.id)
        fixture.controller.editorGroupWorkspace.onAction?(.select(tabs[0].id, .primary))
        await eventually {
            fixture.workspace.snapshot().tabs.first(where: \.isActive)?.id == tabs[0].id
                && fixture.controller.editorGroupLayoutSnapshot.focusedGroup == .primary
        }
        await fixture.workspace.waitForPendingPersistence()

        fixture.router.onEditorGroupFocus?(.secondary)
        #expect(fixture.controller.editorGroupLayoutSnapshot.focusedGroup == .secondary)
        await eventually {
            fixture.workspace.snapshot().tabs.first(where: \.isActive)?.id == cloned.id
                && fixture.controller.editorGroupLayoutSnapshot.focusedGroup == .secondary
        }
        #expect(fixture.workspace.snapshot().tabs.first(where: \.isActive)?.id == cloned.id)
        #expect(fixture.controller.editorGroupLayoutSnapshot.secondaryTabIDs.contains(cloned.id))
        #expect(fixture.controller.editorGroupLayoutSnapshot.focusedGroup == .secondary)

        fixture.controller.editorGroupWorkspace.onAction?(.select(cloned.id, .primary))
        #expect(fixture.controller.editorGroupLayoutSnapshot.focusedGroup == .primary)

        let cloneDown = menuItem(#selector(DuckpadWindowController.performCloneActiveTabToGroupDown(_:)))
        let moveDown = menuItem(#selector(DuckpadWindowController.performMoveActiveTabToGroupDown(_:)))
        #expect(!fixture.controller.validateMenuItem(cloneDown))
        #expect(fixture.controller.validateMenuItem(moveDown))
    }

    @Test @MainActor
    func programmaticActivationRoutesUniqueTabToItsGroupBeforeNormalDisplay() async throws {
        let fixture = await makeEditorGroupController(tabCount: 3)
        defer { fixture.controller.close() }
        let tabs = fixture.workspace.snapshot().tabs
        fixture.controller.editorGroupWorkspace.onAction?(
            .split(tabs[2].id, .primary, .sideBySide, .move)
        )
        await eventually { fixture.controller.editorGroupLayoutSnapshot.orientation == .sideBySide }
        fixture.controller.editorGroupWorkspace.onAction?(.select(tabs[0].id, .primary))
        await eventually { fixture.workspace.snapshot().tabs.first(where: \.isActive)?.id == tabs[0].id }
        fixture.router.resetEvents()

        _ = await fixture.workspace.activate(tabID: tabs[2].id)

        let activate = try #require(fixture.router.events.firstIndex(of: .activate(.secondary)))
        let display = try #require(fixture.router.events.firstIndex(of: .display(tabs[2].buffer, nil)))
        #expect(activate < display)
        #expect(fixture.controller.editorGroupLayoutSnapshot.focusedGroup == .secondary)
    }

    @Test @MainActor
    func closeGroupCollapsesWorkspaceAndRestoresSuspendedInternalSplit() async throws {
        let fixture = await makeEditorGroupController(tabCount: 2)
        defer { fixture.controller.close() }
        fixture.router.split(orientation: .sideBySide)
        fixture.controller.performCloneActiveTabToGroupDown(nil)
        await eventually { fixture.controller.editorGroupLayoutSnapshot.orientation == .stacked }

        fixture.controller.performCloseEditorGroup(nil)

        #expect(fixture.controller.editorGroupLayoutSnapshot.orientation == nil)
        #expect(fixture.controller.editorGroupLayoutSnapshot.secondaryTabIDs.isEmpty)
        #expect(fixture.router.editorGroupOrientation == nil)
        #expect(fixture.router.splitOrientation == .sideBySide)
    }

    @Test @MainActor
    func dragMoveCanCollapseAClonedSecondaryReferenceBackIntoPrimary() async throws {
        let fixture = await makeEditorGroupController(tabCount: 2)
        defer { fixture.controller.close() }
        let active = try #require(fixture.workspace.snapshot().tabs.first(where: { $0.isActive }))
        fixture.controller.editorGroupWorkspace.onAction?(
            .split(active.id, .primary, .sideBySide, .copy)
        )
        #expect(fixture.controller.editorGroupLayoutSnapshot.orientation == .sideBySide)

        fixture.controller.editorGroupWorkspace.onAction?(.move(active.id, .secondary, .primary))

        #expect(fixture.controller.editorGroupLayoutSnapshot.orientation == nil)
        #expect(fixture.controller.editorGroupLayoutSnapshot.secondaryTabIDs.isEmpty)
        #expect(fixture.controller.editorGroupLayoutSnapshot.primaryTabIDs.contains(active.id))
    }

    @Test @MainActor
    func nativeViewMenuPublishesGroupCommandsWithKeyboardAndAccessibilityAlternatives() async throws {
        let fixture = await makeEditorGroupController(tabCount: 2)
        defer { fixture.controller.close() }
        let menu = DuckpadMainMenuFactory.make(target: fixture.controller)
        let expected: [(String, Selector)] = [
            ("Move Active Tab to Group Right", #selector(DuckpadWindowController.performMoveActiveTabToGroupRight(_:))),
            ("Move Active Tab to Group Down", #selector(DuckpadWindowController.performMoveActiveTabToGroupDown(_:))),
            ("Clone Active Tab to Group Right", #selector(DuckpadWindowController.performCloneActiveTabToGroupRight(_:))),
            ("Clone Active Tab to Group Down", #selector(DuckpadWindowController.performCloneActiveTabToGroupDown(_:))),
            ("Focus Other Editor Group", #selector(DuckpadWindowController.performFocusOtherEditorGroup(_:))),
            ("Close Editor Group", #selector(DuckpadWindowController.performCloseEditorGroup(_:))),
        ]

        for (title, action) in expected {
            let item = try #require(menu.item(withTitle: title, recursively: true))
            #expect(item.action == action)
            #expect(!item.keyEquivalent.isEmpty)
            #expect(!(item.accessibilityLabel() ?? "").isEmpty)
        }
    }

    @Test @MainActor
    func tabContextMenuUsesTheSameGroupCommandValidation() async throws {
        let fixture = await makeEditorGroupController(tabCount: 1)
        defer { fixture.controller.close() }
        let tabID = try #require(fixture.workspace.snapshot().tabs.first?.id)
        fixture.controller.tabStrip.layoutSubtreeIfNeeded()
        fixture.controller.tabStrip.hostedCollectionView.layoutSubtreeIfNeeded()
        let menu = try #require(fixture.controller.tabStrip.contextMenu(for: tabID))

        #expect(menu.item(withTitle: "Move to Group Right")?.isEnabled == false)
        #expect(menu.item(withTitle: "Clone to Group Right")?.isEnabled == true)
        #expect(menu.item(withTitle: "Focus Other Group")?.isEnabled == false)
        #expect(menu.item(withTitle: "Close Editor Group")?.isEnabled == false)
    }

    @Test @MainActor
    func closeTearsDownWorkspaceAndRouterCallbacks() async {
        let fixture = await makeEditorGroupController(tabCount: 1)
        #expect(fixture.router.onEditorGroupFocus != nil)
        #expect(fixture.controller.editorGroupWorkspace.onAction != nil)

        fixture.controller.close()

        #expect(fixture.router.onEditorGroupFocus == nil)
        #expect(fixture.controller.editorGroupWorkspace.onAction == nil)
        #expect(fixture.controller.tabStrip.onActivate == nil)
    }

    @Test @MainActor
    func sameActiveCloneRequestDoesNotOverrideLaterProgrammaticFocus() async throws {
        let fixture = await makeEditorGroupController(tabCount: 3)
        defer { fixture.controller.close() }
        let tabs = fixture.workspace.snapshot().tabs
        let cloned = try #require(tabs.last)
        fixture.controller.editorGroupWorkspace.onAction?(
            .split(cloned.id, .primary, .sideBySide, .copy)
        )
        _ = await fixture.workspace.activate(tabID: tabs[0].id)
        await fixture.workspace.waitForPendingPersistence()
        #expect(fixture.router.activeEditorGroup == .primary)

        _ = await fixture.workspace.activate(tabID: cloned.id)

        #expect(fixture.controller.editorGroupLayoutSnapshot.focusedGroup == .primary)
        #expect(fixture.controller.editorGroupLayoutSnapshot.primarySelectedTabID == cloned.id)
    }

    @Test @MainActor
    func closeGroupSelectsTheMergedGloballyActiveTab() async throws {
        let fixture = await makeEditorGroupController(tabCount: 3)
        defer { fixture.controller.close() }
        let tabs = fixture.workspace.snapshot().tabs
        let secondary = try #require(tabs.last)
        fixture.controller.editorGroupWorkspace.onAction?(
            .split(secondary.id, .primary, .stacked, .move)
        )
        fixture.controller.editorGroupWorkspace.onAction?(.select(tabs[0].id, .primary))
        await eventually { fixture.router.activeEditorGroup == .primary }
        fixture.controller.editorGroupWorkspace.onAction?(.focus(.secondary))
        await eventually { fixture.router.activeEditorGroup == .secondary }

        fixture.controller.performCloseEditorGroup(nil)

        #expect(fixture.controller.editorGroupLayoutSnapshot.primarySelectedTabID == secondary.id)
        #expect(fixture.controller.tabStrip.activeTabID == secondary.id)
        #expect(fixture.router.activeEditorGroup == .primary)
    }

    @Test @MainActor
    func saveAllRestoresOriginalGroupWhenClonedTabIDIsAlreadyActive() async throws {
        let urls = [
            URL(fileURLWithPath: "/tmp/duckpad-group-save-first.txt"),
            URL(fileURLWithPath: "/tmp/duckpad-group-save-second.txt"),
        ]
        let fixture = await makeEditorGroupController(tabCount: 2, saveURLs: urls)
        defer { fixture.controller.close() }
        let tabs = fixture.workspace.snapshot().tabs
        let original = try #require(tabs.last)

        _ = await fixture.workspace.activate(tabID: tabs[0].id)
        markDirty(tabs[0].buffer, workspace: fixture.workspace, router: fixture.router, text: "first")
        _ = await fixture.workspace.activate(tabID: original.id)
        markDirty(original.buffer, workspace: fixture.workspace, router: fixture.router, text: "second")
        await fixture.workspace.waitForPendingPersistence()
        _ = await fixture.workspace.activate(tabID: tabs[0].id)
        fixture.controller.editorGroupWorkspace.onAction?(
            .split(original.id, .primary, .sideBySide, .copy)
        )
        await eventually {
            fixture.workspace.snapshot().tabs.first(where: \.isActive)?.id == original.id
        }
        await fixture.workspace.waitForPendingPersistence()
        #expect(fixture.controller.editorGroupLayoutSnapshot.focusedGroup == .secondary)

        fixture.controller.performSaveAll(nil)
        await eventually { fixture.workspace.snapshot().tabs.allSatisfy { !$0.isDirty } }

        #expect(fixture.workspace.snapshot().tabs.first(where: \.isActive)?.id == original.id)
        #expect(fixture.controller.editorGroupLayoutSnapshot.focusedGroup == .secondary)
        #expect(fixture.router.activeEditorGroup == .secondary)
    }

    @Test @MainActor
    func failedCloseRestoresExactEditorGroupLayout() async throws {
        let fixture = await makeEditorGroupController(tabCount: 3)
        defer { fixture.controller.close() }
        let tabs = fixture.workspace.snapshot().tabs
        let secondary = try #require(tabs.last)
        fixture.controller.editorGroupWorkspace.onAction?(
            .split(secondary.id, .primary, .stacked, .move)
        )
        fixture.controller.editorGroupWorkspace.onAction?(.select(tabs[0].id, .primary))
        await eventually { fixture.router.activeEditorGroup == .primary }
        fixture.controller.editorGroupWorkspace.onAction?(.focus(.secondary))
        await eventually { fixture.router.activeEditorGroup == .secondary }
        await fixture.workspace.waitForPendingPersistence()
        let expected = fixture.controller.editorGroupLayoutSnapshot
        await fixture.store.failNextCommit()

        await fixture.controller.performClose(secondary.id).value

        #expect(fixture.controller.editorGroupLayoutSnapshot == expected)
        #expect(fixture.router.editorGroupOrientation == .stacked)
        #expect(fixture.router.activeEditorGroup == .secondary)
    }

    @Test @MainActor
    func splitModeBufferEditReloadsOnlyItsGroupItemWithFiveHundredTabs() async throws {
        let fixture = await makeEditorGroupController(tabCount: 500)
        defer { fixture.controller.close() }
        let active = try #require(fixture.workspace.snapshot().tabs.last)
        fixture.controller.editorGroupWorkspace.onAction?(
            .split(active.id, .primary, .sideBySide, .move)
        )
        let secondaryStrip = try #require(fixture.controller.editorGroupWorkspace.secondaryPane?.tabStrip)
        let primaryBefore = fixture.controller.tabStrip.updateMetrics
        let secondaryBefore = secondaryStrip.updateMetrics

        markDirty(active.buffer, workspace: fixture.workspace, router: fixture.router, text: "edited")

        #expect(fixture.controller.tabStrip.updateMetrics.fullReloads == primaryBefore.fullReloads)
        #expect(fixture.controller.tabStrip.updateMetrics.itemReloads == primaryBefore.itemReloads)
        #expect(secondaryStrip.updateMetrics.fullReloads == secondaryBefore.fullReloads)
        #expect(secondaryStrip.updateMetrics.itemReloads == secondaryBefore.itemReloads + 1)
    }

    @Test @MainActor
    func splitModeTabUpdateReloadsOnlyItsGroupItem() async throws {
        let fixture = await makeEditorGroupController(tabCount: 4)
        defer { fixture.controller.close() }
        let active = try #require(fixture.workspace.snapshot().tabs.last)
        fixture.controller.editorGroupWorkspace.onAction?(
            .split(active.id, .primary, .sideBySide, .move)
        )
        let secondaryStrip = try #require(fixture.controller.editorGroupWorkspace.secondaryPane?.tabStrip)
        let primaryBefore = fixture.controller.tabStrip.updateMetrics
        let secondaryBefore = secondaryStrip.updateMetrics

        _ = await fixture.workspace.setLanguageOverride(
            .manual(LanguageID(rawValue: "json")),
            for: active.id
        )

        #expect(fixture.controller.tabStrip.updateMetrics.fullReloads == primaryBefore.fullReloads)
        #expect(fixture.controller.tabStrip.updateMetrics.itemReloads == primaryBefore.itemReloads)
        #expect(secondaryStrip.updateMetrics.fullReloads == secondaryBefore.fullReloads)
        #expect(secondaryStrip.updateMetrics.itemReloads == secondaryBefore.itemReloads + 1)
    }

    @Test @MainActor
    func blockedCloseRendersASelectedReplacementInItsProvisionalGroup() async throws {
        let fixture = await makeEditorGroupController(tabCount: 4)
        defer { fixture.controller.close() }
        let tabs = fixture.workspace.snapshot().tabs
        let firstSecondary = try #require(tabs.last)
        let closing = tabs[2]
        fixture.controller.editorGroupWorkspace.onAction?(
            .split(firstSecondary.id, .primary, .stacked, .move)
        )
        fixture.controller.editorGroupWorkspace.onAction?(.move(closing.id, .primary, .secondary))
        await eventually {
            fixture.workspace.snapshot().tabs.first(where: \.isActive)?.id == closing.id
        }
        await fixture.workspace.waitForPendingPersistence()
        await fixture.store.blockNextCommit()

        let close = fixture.controller.performClose(closing.id)
        await fixture.store.waitUntilCommitIsBlocked()

        let active = try #require(fixture.workspace.snapshot().tabs.first(where: { $0.isActive }))
        let secondaryStrip = try #require(fixture.controller.editorGroupWorkspace.secondaryPane?.tabStrip)
        #expect(fixture.controller.editorGroupLayoutSnapshot.orientation == .stacked)
        #expect(secondaryStrip.activeTabID == active.id)
        #expect(secondaryStrip.tabIDs.contains(active.id))
        #expect(fixture.router.activeEditorGroup == .secondary)
        #expect(fixture.router.events.contains(.display(active.buffer, .secondary)))
        #expect(!fixture.controller.tabStrip.hostedCollectionView.isSelectable)
        #expect(!secondaryStrip.hostedCollectionView.isSelectable)
        #expect(!fixture.controller.validateMenuItem(menuItem(
            #selector(DuckpadWindowController.performFocusOtherEditorGroup(_:))
        )))
        #expect(!fixture.controller.validateMenuItem(menuItem(
            #selector(DuckpadWindowController.performCloseEditorGroup(_:))
        )))

        await fixture.store.releaseCommit()
        await close.value
        #expect(!fixture.controller.editorGroupLayoutSnapshot.primaryTabIDs.contains(closing.id))
        #expect(fixture.controller.tabStrip.hostedCollectionView.isSelectable)
        #expect(secondaryStrip.hostedCollectionView.isSelectable)
    }

    @Test @MainActor
    func blockedFailedCloseRendersProvisionallyThenRestoresDurableLayout() async throws {
        let fixture = await makeEditorGroupController(tabCount: 3)
        defer { fixture.controller.close() }
        let tabs = fixture.workspace.snapshot().tabs
        let closing = try #require(tabs.last)
        fixture.controller.editorGroupWorkspace.onAction?(
            .split(closing.id, .primary, .sideBySide, .move)
        )
        await fixture.workspace.waitForPendingPersistence()
        let durable = fixture.controller.editorGroupLayoutSnapshot
        await fixture.store.blockNextCommit(failingAfterRelease: true)

        let close = fixture.controller.performClose(closing.id)
        await fixture.store.waitUntilCommitIsBlocked()

        let replacement = try #require(fixture.workspace.snapshot().tabs.first(where: { $0.isActive }))
        #expect(fixture.controller.editorGroupLayoutSnapshot.orientation == nil)
        #expect(fixture.controller.tabStrip.activeTabID == replacement.id)
        #expect(fixture.router.activeEditorGroup == .primary)

        await fixture.store.releaseCommit()
        await close.value
        #expect(fixture.controller.editorGroupLayoutSnapshot == durable)
        #expect(fixture.router.activeEditorGroup == .secondary)
        #expect(fixture.router.editorGroupOrientation == .sideBySide)
    }

    @Test @MainActor
    func overlappingClosesRemainCoherentAcrossTheBlockedCommitBoundary() async throws {
        let fixture = await makeEditorGroupController(tabCount: 4)
        defer { fixture.controller.close() }
        let tabs = fixture.workspace.snapshot().tabs
        let firstClosing = try #require(tabs.last)
        fixture.controller.editorGroupWorkspace.onAction?(
            .split(firstClosing.id, .primary, .stacked, .move)
        )
        await fixture.workspace.waitForPendingPersistence()
        await fixture.store.blockNextCommit()

        let firstClose = fixture.controller.performClose(firstClosing.id)
        await fixture.store.waitUntilCommitIsBlocked()
        let secondClosing = try #require(fixture.workspace.snapshot().tabs.first?.id)
        let secondClose = fixture.controller.performClose(secondClosing)
        let provisionalActive = try #require(fixture.workspace.snapshot().tabs.first(where: \.isActive)?.id)
        #expect(fixture.controller.tabStrip.activeTabID == provisionalActive)
        #expect(fixture.router.activeEditorGroup == .primary)

        await fixture.store.releaseCommit()
        await firstClose.value
        await secondClose.value

        let finalActive = try #require(fixture.workspace.snapshot().tabs.first(where: \.isActive)?.id)
        #expect(fixture.controller.editorGroupLayoutSnapshot.orientation == nil)
        #expect(fixture.controller.tabStrip.activeTabID == finalActive)
        #expect(fixture.controller.editorGroupLayoutSnapshot.primaryTabIDs == fixture.workspace.snapshot().tabs.map(\.id))
    }

    @Test @MainActor
    func clonedSplitEditUsesBoundedCachedLookupsAndDirectItemUpdates() async throws {
        let fixture = await makeEditorGroupController(tabCount: 500)
        defer { fixture.controller.close() }
        let active = try #require(fixture.workspace.snapshot().tabs.last)
        fixture.controller.editorGroupWorkspace.onAction?(
            .split(active.id, .primary, .sideBySide, .copy)
        )
        let secondaryStrip = try #require(fixture.controller.editorGroupWorkspace.secondaryPane?.tabStrip)
        let lookupBefore = fixture.controller.editorGroupIncrementalLookupCount
        let rebuildBefore = fixture.controller.editorGroupIndexRebuildCount
        let primaryBefore = fixture.controller.tabStrip.updateMetrics
        let secondaryBefore = secondaryStrip.updateMetrics

        markDirty(active.buffer, workspace: fixture.workspace, router: fixture.router, text: "bounded")

        #expect(fixture.controller.editorGroupIncrementalLookupCount == lookupBefore + 2)
        #expect(fixture.controller.editorGroupIndexRebuildCount == rebuildBefore)
        #expect(fixture.controller.tabStrip.updateMetrics.directItemInspections == primaryBefore.directItemInspections + 1)
        #expect(secondaryStrip.updateMetrics.directItemInspections == secondaryBefore.directItemInspections + 1)
        #expect(fixture.controller.tabStrip.activeTabID == active.id)
        #expect(secondaryStrip.activeTabID == active.id)
    }

    @Test @MainActor
    func splitScratchInsertionUpdatesOnlyTheFocusedGroupStripWithFiveHundredTabs() async throws {
        let fixture = await makeEditorGroupController(tabCount: 500)
        defer { fixture.controller.close() }
        // Physical pointer movement can independently reconfigure a hovered
        // tab while this async performance measurement yields to AppKit.
        fixture.controller.window?.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        let cloned = try #require(fixture.workspace.snapshot().tabs.last)
        fixture.controller.editorGroupWorkspace.onAction?(
            .split(cloned.id, .primary, .sideBySide, .copy)
        )
        let secondaryStrip = try #require(
            fixture.controller.editorGroupWorkspace.secondaryPane?.tabStrip
        )
        fixture.controller.window?.contentView?.layoutSubtreeIfNeeded()
        fixture.controller.tabStrip.layoutSubtreeIfNeeded()
        secondaryStrip.layoutSubtreeIfNeeded()
        fixture.controller.tabStrip.hostedCollectionView.layoutSubtreeIfNeeded()
        secondaryStrip.hostedCollectionView.layoutSubtreeIfNeeded()
        let layoutBefore = fixture.controller.editorGroupLayoutSnapshot
        let primaryMetricsBefore = fixture.controller.tabStrip.updateMetrics
        let secondaryMetricsBefore = secondaryStrip.updateMetrics
        let primaryIDsBefore = fixture.controller.tabStrip.tabIDs
        let primarySelectionBefore = fixture.controller.tabStrip.activeTabID

        _ = await fixture.workspace.addScratch()

        let inserted = try #require(fixture.workspace.snapshot().tabs.last)
        let layout = fixture.controller.editorGroupLayoutSnapshot
        #expect(fixture.controller.tabStrip.updateMetrics == primaryMetricsBefore)
        #expect(secondaryStrip.updateMetrics.fullReloads == secondaryMetricsBefore.fullReloads)
        #expect(secondaryStrip.updateMetrics.itemInsertions == secondaryMetricsBefore.itemInsertions + 1)
        #expect(secondaryStrip.updateMetrics.itemReloads == secondaryMetricsBefore.itemReloads + 1)
        #expect(!fixture.controller.tabStrip.tabIDs.contains(inserted.id))
        #expect(secondaryStrip.tabIDs == [cloned.id, inserted.id])
        #expect(fixture.controller.tabStrip.tabIDs == primaryIDsBefore)
        #expect(fixture.controller.tabStrip.activeTabID == primarySelectionBefore)
        #expect(layout.primaryTabIDs == layoutBefore.primaryTabIDs)
        #expect(layout.primarySelectedTabID == layoutBefore.primarySelectedTabID)
        #expect(layout.secondaryTabIDs == [cloned.id, inserted.id])
        #expect(layout.secondarySelectedTabID == inserted.id)
        #expect(layout.focusedGroup == .secondary)
        #expect(secondaryStrip.tabIDs.count == 2)
        #expect(secondaryStrip.activeTabID == inserted.id)
    }

    @Test @MainActor
    func staleNonReceivingStripFallsBackToFullWorkspaceApply() async throws {
        let fixture = await makeEditorGroupController(tabCount: 4)
        defer { fixture.controller.close() }
        let workspaceTabs = fixture.workspace.snapshot().tabs
        let cloned = try #require(workspaceTabs.last)
        fixture.controller.editorGroupWorkspace.onAction?(
            .split(cloned.id, .primary, .sideBySide, .copy)
        )
        let layoutBefore = fixture.controller.editorGroupLayoutSnapshot
        let staleSelection = workspaceTabs[0].id
        let tabsByID = Dictionary(uniqueKeysWithValues: workspaceTabs.map { ($0.id, $0) })
        let stalePrimaryTabs = layoutBefore.primaryTabIDs.compactMap { tabID in
            tabsByID[tabID].map { tab in
                TabSnapshot(
                    id: tab.id,
                    title: tab.title,
                    isActive: tab.id == staleSelection,
                    isDirty: tab.isDirty,
                    isPinned: tab.isPinned,
                    buffer: tab.buffer,
                    fullPath: tab.fullPath
                )
            }
        }
        #expect(stalePrimaryTabs.count == layoutBefore.primaryTabIDs.count)
        fixture.controller.tabStrip.apply(tabs: stalePrimaryTabs)
        #expect(fixture.controller.tabStrip.activeTabID == staleSelection)
        let secondaryStrip = try #require(
            fixture.controller.editorGroupWorkspace.secondaryPane?.tabStrip
        )
        let primaryMetricsBefore = fixture.controller.tabStrip.updateMetrics
        let secondaryMetricsBefore = secondaryStrip.updateMetrics

        _ = await fixture.workspace.addScratch()

        let inserted = try #require(fixture.workspace.snapshot().tabs.last)
        let authoritativeLayout = fixture.controller.editorGroupLayoutSnapshot
        #expect(
            fixture.controller.tabStrip.updateMetrics.fullReloads
                == primaryMetricsBefore.fullReloads + 1
        )
        #expect(
            secondaryStrip.updateMetrics.fullReloads
                == secondaryMetricsBefore.fullReloads + 1
        )
        #expect(fixture.controller.tabStrip.tabIDs == authoritativeLayout.primaryTabIDs)
        #expect(fixture.controller.tabStrip.activeTabID == authoritativeLayout.primarySelectedTabID)
        #expect(authoritativeLayout.primarySelectedTabID == cloned.id)
        #expect(secondaryStrip.tabIDs == [cloned.id, inserted.id])
        #expect(secondaryStrip.activeTabID == inserted.id)
        #expect(fixture.controller.editorGroupWorkspace.validateTabDrop(
            payload: EditorGroupDragPayload(tabID: inserted.id, sourceGroup: .secondary),
            destinationGroup: .primary,
            insertionIndex: authoritativeLayout.primaryTabIDs.count,
            optionPressed: true
        ) == .copy)
    }

    @Test @MainActor
    func incrementalEventsSkipMembershipReconciliationWhileStructuralEventsStillReconcile() async throws {
        let fixture = await makeEditorGroupController(tabCount: 500)
        defer { fixture.controller.close() }
        let active = try #require(fixture.workspace.snapshot().tabs.last)
        fixture.controller.editorGroupWorkspace.onAction?(
            .split(active.id, .primary, .sideBySide, .copy)
        )
        let reconcileBefore = fixture.controller.editorGroupReconcileCount
        let inspectionsBefore = fixture.controller.editorGroupReconcileTabInspectionCount

        markDirty(active.buffer, workspace: fixture.workspace, router: fixture.router, text: "bounded")
        #expect(fixture.controller.editorGroupReconcileCount == reconcileBefore)
        #expect(fixture.controller.editorGroupReconcileTabInspectionCount == inspectionsBefore)

        await fixture.workspace.waitForPendingPersistence()
        #expect(fixture.controller.editorGroupReconcileCount == reconcileBefore)
        #expect(fixture.controller.editorGroupReconcileTabInspectionCount == inspectionsBefore)

        _ = await fixture.workspace.setLanguageOverride(
            .manual(LanguageID(rawValue: "json")),
            for: active.id
        )
        #expect(fixture.controller.editorGroupReconcileCount == reconcileBefore)
        #expect(fixture.controller.editorGroupReconcileTabInspectionCount == inspectionsBefore)

        _ = await fixture.workspace.addScratch()
        #expect(fixture.controller.editorGroupReconcileCount == reconcileBefore + 1)
        #expect(fixture.controller.editorGroupReconcileTabInspectionCount == inspectionsBefore + 501)
        #expect(fixture.controller.editorGroupLayoutSnapshot.secondaryTabIDs.count == 2)
    }

    @Test @MainActor
    func splitActiveChangeUsesCachedGroupSelectionWithoutFullReconciliationOrReload() async throws {
        let fixture = await makeEditorGroupController(tabCount: 500)
        defer { fixture.controller.close() }
        let tabs = fixture.workspace.snapshot().tabs
        let secondary = try #require(tabs.last)
        fixture.controller.editorGroupWorkspace.onAction?(
            .split(secondary.id, .primary, .sideBySide, .move)
        )
        let primary = tabs[250]
        let oldPrimarySelection = try #require(
            fixture.controller.editorGroupLayoutSnapshot.primarySelectedTabID
        )
        let secondaryStrip = try #require(fixture.controller.editorGroupWorkspace.secondaryPane?.tabStrip)
        let reconcileBefore = fixture.controller.editorGroupReconcileCount
        let inspectionsBefore = fixture.controller.editorGroupReconcileTabInspectionCount
        let cachedLookupsBefore = fixture.controller.editorGroupCachedTabLookupCount
        let linearInspectionsBefore = fixture.controller.editorGroupLinearTabInspectionCount
        let primaryMetricsBefore = fixture.controller.tabStrip.updateMetrics
        let secondaryMetricsBefore = secondaryStrip.updateMetrics
        let primaryFocusBefore = fixture.controller.editorGroupWorkspace.primaryPane.focusUpdateCount
        let secondaryFocusBefore = fixture.controller.editorGroupWorkspace.secondaryPane?.focusUpdateCount
        fixture.router.resetEvents()

        _ = await fixture.workspace.activate(tabID: primary.id)

        #expect(fixture.controller.editorGroupReconcileCount == reconcileBefore)
        #expect(fixture.controller.editorGroupReconcileTabInspectionCount == inspectionsBefore)
        #expect(fixture.controller.editorGroupLinearTabInspectionCount == linearInspectionsBefore)
        #expect(fixture.controller.editorGroupCachedTabLookupCount - cachedLookupsBefore <= 8)
        #expect(fixture.controller.tabStrip.updateMetrics.fullReloads == primaryMetricsBefore.fullReloads)
        #expect(secondaryStrip.updateMetrics.fullReloads == secondaryMetricsBefore.fullReloads)
        #expect(fixture.controller.tabStrip.updateMetrics.itemReloads == primaryMetricsBefore.itemReloads + 2)
        #expect(secondaryStrip.updateMetrics.itemReloads == secondaryMetricsBefore.itemReloads)
        #expect(fixture.controller.tabStrip.activeTabID == primary.id)
        #expect(secondaryStrip.activeTabID == secondary.id)
        #expect(fixture.controller.editorGroupLayoutSnapshot.primarySelectedTabID == primary.id)
        #expect(fixture.controller.editorGroupLayoutSnapshot.secondarySelectedTabID == secondary.id)
        #expect(fixture.controller.editorGroupLayoutSnapshot.focusedGroup == .primary)
        #expect(fixture.controller.editorGroupWorkspace.primaryPane.isFocused)
        #expect(fixture.controller.editorGroupWorkspace.primaryPane.accessibilityValue() as? String == "focused")
        #expect(fixture.controller.editorGroupWorkspace.secondaryPane?.isFocused == false)
        #expect(fixture.controller.editorGroupWorkspace.primaryPane.focusUpdateCount == primaryFocusBefore + 1)
        #expect(fixture.controller.editorGroupWorkspace.secondaryPane?.focusUpdateCount == secondaryFocusBefore.map { $0 + 1 })
        #expect(fixture.workspace.snapshot().tabs.first(where: { $0.isActive })?.id == primary.id)
        #expect(oldPrimarySelection != primary.id)
        #expect(fixture.router.events.filter { $0 == .display(primary.buffer, .primary) }.count == 1)
        #expect(fixture.router.events.filter { $0 == .display(primary.buffer, nil) }.count == 1)
        #expect(fixture.router.events.filter { $0 == .display(secondary.buffer, .secondary) }.isEmpty)
    }

    @Test @MainActor
    func groupTabClickUsesCachedLocalSelectionAndAvoidsFullWorkspaceApply() async throws {
        let fixture = await makeEditorGroupController(tabCount: 500)
        defer { fixture.controller.close() }
        let tabs = fixture.workspace.snapshot().tabs
        let secondary = try #require(tabs.last)
        fixture.controller.editorGroupWorkspace.onAction?(
            .split(secondary.id, .primary, .sideBySide, .move)
        )
        let primary = tabs[250]
        let secondaryStrip = try #require(fixture.controller.editorGroupWorkspace.secondaryPane?.tabStrip)
        let reconcileBefore = fixture.controller.editorGroupReconcileCount
        let inspectionsBefore = fixture.controller.editorGroupReconcileTabInspectionCount
        let cachedLookupsBefore = fixture.controller.editorGroupCachedTabLookupCount
        let linearInspectionsBefore = fixture.controller.editorGroupLinearTabInspectionCount
        let primaryMetricsBefore = fixture.controller.tabStrip.updateMetrics
        let secondaryMetricsBefore = secondaryStrip.updateMetrics
        let primaryFocusBefore = fixture.controller.editorGroupWorkspace.primaryPane.focusUpdateCount
        let secondaryFocusBefore = fixture.controller.editorGroupWorkspace.secondaryPane?.focusUpdateCount
        fixture.router.resetEvents()

        fixture.controller.editorGroupWorkspace.onAction?(.select(primary.id, .primary))
        await eventually {
            fixture.workspace.snapshot().tabs.first(where: { $0.isActive })?.id == primary.id
        }

        #expect(fixture.controller.editorGroupReconcileCount == reconcileBefore)
        #expect(fixture.controller.editorGroupReconcileTabInspectionCount == inspectionsBefore)
        #expect(fixture.controller.editorGroupLinearTabInspectionCount == linearInspectionsBefore)
        #expect(fixture.controller.editorGroupCachedTabLookupCount - cachedLookupsBefore <= 8)
        #expect(fixture.controller.tabStrip.updateMetrics.fullReloads == primaryMetricsBefore.fullReloads)
        #expect(secondaryStrip.updateMetrics.fullReloads == secondaryMetricsBefore.fullReloads)
        #expect(fixture.controller.tabStrip.updateMetrics.itemReloads == primaryMetricsBefore.itemReloads + 2)
        #expect(secondaryStrip.updateMetrics.itemReloads == secondaryMetricsBefore.itemReloads)
        #expect(fixture.controller.editorGroupLayoutSnapshot.primarySelectedTabID == primary.id)
        #expect(fixture.controller.editorGroupLayoutSnapshot.focusedGroup == .primary)
        #expect(fixture.router.activeEditorGroup == .primary)
        #expect(fixture.controller.editorGroupWorkspace.primaryPane.isFocused)
        #expect(fixture.controller.editorGroupWorkspace.primaryPane.accessibilityValue() as? String == "focused")
        #expect(fixture.controller.editorGroupWorkspace.secondaryPane?.isFocused == false)
        #expect(fixture.controller.editorGroupWorkspace.primaryPane.focusUpdateCount == primaryFocusBefore + 1)
        #expect(fixture.controller.editorGroupWorkspace.secondaryPane?.focusUpdateCount == secondaryFocusBefore.map { $0 + 1 })
        #expect(fixture.router.events.filter { $0 == .display(primary.buffer, .primary) }.count == 1)
        #expect(fixture.router.events.filter { $0 == .display(primary.buffer, nil) }.count == 1)
        #expect(fixture.router.events.filter { $0 == .display(secondary.buffer, .secondary) }.isEmpty)
    }

    @Test @MainActor
    func focusingTheOtherCloneGroupChangesOnlyFocusWithoutReloadingEitherStrip() async throws {
        let fixture = await makeEditorGroupController(tabCount: 500)
        defer { fixture.controller.close() }
        let cloned = try #require(fixture.workspace.snapshot().tabs.last)
        fixture.controller.editorGroupWorkspace.onAction?(
            .split(cloned.id, .primary, .sideBySide, .copy)
        )
        let secondaryStrip = try #require(fixture.controller.editorGroupWorkspace.secondaryPane?.tabStrip)
        let primaryMetricsBefore = fixture.controller.tabStrip.updateMetrics
        let secondaryMetricsBefore = secondaryStrip.updateMetrics
        let cachedLookupsBefore = fixture.controller.editorGroupCachedTabLookupCount
        let linearInspectionsBefore = fixture.controller.editorGroupLinearTabInspectionCount
        let primaryFocusBefore = fixture.controller.editorGroupWorkspace.primaryPane.focusUpdateCount
        let secondaryFocusBefore = fixture.controller.editorGroupWorkspace.secondaryPane?.focusUpdateCount
        fixture.router.resetEvents()

        fixture.controller.editorGroupWorkspace.onAction?(.focus(.primary))

        #expect(fixture.controller.editorGroupLayoutSnapshot.focusedGroup == .primary)
        #expect(fixture.controller.editorGroupLayoutSnapshot.primarySelectedTabID == cloned.id)
        #expect(fixture.controller.editorGroupWorkspace.primaryPane.isFocused)
        #expect(fixture.controller.editorGroupWorkspace.primaryPane.accessibilityValue() as? String == "focused")
        #expect(fixture.controller.editorGroupWorkspace.secondaryPane?.isFocused == false)
        #expect(fixture.controller.editorGroupWorkspace.primaryPane.focusUpdateCount == primaryFocusBefore + 1)
        #expect(fixture.controller.editorGroupWorkspace.secondaryPane?.focusUpdateCount == secondaryFocusBefore.map { $0 + 1 })
        #expect(fixture.workspace.snapshot().tabs.first(where: { $0.isActive })?.id == cloned.id)
        #expect(fixture.controller.tabStrip.updateMetrics == primaryMetricsBefore)
        #expect(secondaryStrip.updateMetrics == secondaryMetricsBefore)
        #expect(fixture.controller.editorGroupLinearTabInspectionCount == linearInspectionsBefore)
        #expect(fixture.controller.editorGroupCachedTabLookupCount - cachedLookupsBefore <= 4)
        #expect(fixture.router.events.filter { $0 == .display(cloned.buffer, .primary) }.count == 1)
        #expect(fixture.router.events.filter { $0 == .activate(.primary) }.count == 1)
        #expect(fixture.router.events.filter { $0 == .focus }.count == 1)
    }

    @Test @MainActor
    func unsplitTabClickDoesNotApplyTheSameSelectionTwice() async throws {
        let fixture = await makeEditorGroupController(tabCount: 500)
        defer { fixture.controller.close() }
        let target = fixture.workspace.snapshot().tabs[250]
        let metricsBefore = fixture.controller.tabStrip.updateMetrics
        let reconcileBefore = fixture.controller.editorGroupReconcileCount
        let linearBefore = fixture.controller.editorGroupLinearTabInspectionCount

        fixture.controller.editorGroupWorkspace.onAction?(.select(target.id, .primary))
        await eventually {
            fixture.workspace.snapshot().tabs.first(where: { $0.isActive })?.id == target.id
        }

        #expect(fixture.controller.editorGroupReconcileCount == reconcileBefore)
        #expect(fixture.controller.editorGroupLinearTabInspectionCount == linearBefore)
        #expect(fixture.controller.tabStrip.updateMetrics.fullReloads == metricsBefore.fullReloads)
        #expect(fixture.controller.tabStrip.updateMetrics.itemReloads == metricsBefore.itemReloads + 2)
        #expect(fixture.controller.tabStrip.activeTabID == target.id)
    }

}

@MainActor
private func makeEditorGroupController(
    tabCount: Int,
    saveURLs: [URL] = []
) async -> (
    controller: DuckpadWindowController,
    workspace: ScratchWorkspaceUseCase,
    router: EditorGroupRouterSpy,
    store: EditorGroupSessionStore
) {
    var session = ScratchSession()
    for _ in 0..<tabCount { session.addUntitled() }
    let store = EditorGroupSessionStore(session: session)
    let workspace = ScratchWorkspaceUseCase(store: store)
    let router = EditorGroupRouterSpy()
    let panels = EditorGroupFilePanels()
    panels.saveURLs = saveURLs
    let fileUseCase = saveURLs.isEmpty
        ? nil
        : FileDocumentUseCase(workspace: workspace, editor: router, store: EditorGroupFileStore())
    let controller = DuckpadWindowController(
        workspace: workspace,
        editorAdapter: router,
        editorView: NSView(),
        secondaryEditorView: NSView(),
        editorGroupRouter: router,
        fileUseCase: fileUseCase,
        filePanels: saveURLs.isEmpty ? nil : panels,
        automaticallyStarts: false
    )
    controller.start()
    await controller.waitForStartup()
    return (controller, workspace, router, store)
}

@MainActor
private func markDirty(
    _ buffer: EditorBufferDescriptor,
    workspace: ScratchWorkspaceUseCase,
    router: EditorGroupRouterSpy,
    text: String
) {
    let outcome = workspace.acceptEditorEdit(.init(
        bufferID: buffer.bufferID,
        expectedRevision: buffer.revision,
        range: .init(location: 0, length: 0),
        replacement: text
    ))
    guard case .accepted(let revision) = outcome else {
        Issue.record("Expected edit acceptance, got \(outcome)")
        return
    }
    router.install(.init(bufferID: buffer.bufferID, revision: revision, text: text))
}

@MainActor
private func eventually(_ condition: @escaping @MainActor () -> Bool) async {
    for _ in 0..<1_000 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("Timed out waiting for editor-group state")
}

private func menuItem(_ action: Selector) -> NSMenuItem {
    NSMenuItem(title: "", action: action, keyEquivalent: "")
}

@MainActor
private extension NSMenu {
    func item(withTitle title: String, recursively: Bool) -> NSMenuItem? {
        if let item = items.first(where: { $0.title == title }) { return item }
        guard recursively else { return nil }
        return items.lazy.compactMap(\.submenu).compactMap {
            $0.item(withTitle: title, recursively: true)
        }.first
    }
}

@Test @MainActor func preferencesHideAndRestoreChromeWithoutDisablingDocumentCommands() async throws {
    let fixture = await makeEditorGroupController(tabCount: 2)
    defer { fixture.controller.close() }
    fixture.controller.applyPreferences(AppSettings(menuBarVisible: false, statusBarVisible: false, tabDragEnabled: false))
    #expect(fixture.controller.workspaceChromeSmokeState().statusBarHeight == 0)
    #expect(fixture.controller.commandBar.isHidden)
    #expect(fixture.controller.tabStrip.collectionView(fixture.controller.tabStrip.hostedCollectionView, pasteboardWriterForItemAt: IndexPath(item: 0, section: 0)) == nil)
    #expect(fixture.controller.tabStrip.interactionsEnabled)
    fixture.controller.applyPreferences(.defaults)
    #expect(fixture.controller.workspaceChromeSmokeState().statusBarHeight == 24)
    #expect(!fixture.controller.commandBar.isHidden)
    #expect(fixture.controller.tabStrip.collectionView(fixture.controller.tabStrip.hostedCollectionView, pasteboardWriterForItemAt: IndexPath(item: 0, section: 0)) != nil)
}
