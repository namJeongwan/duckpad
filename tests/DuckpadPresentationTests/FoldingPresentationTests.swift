import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadInfrastructure
@testable import DuckpadPresentation
import Foundation
import Testing

@Suite(.serialized)
struct FoldingPresentationTests {
    @Test @MainActor
    func foldingSubmenuHasAccessibleConflictFreeCommands() async throws {
        let fixture = await makeFoldingPortControllerFixture()
        defer { fixture.controller.close() }
        let menu = DuckpadMainMenuFactory.make(target: fixture.controller)

        let collapse = recursiveMenuItem(titled: "Collapse Current Block", in: menu)
        #expect(collapse?.keyEquivalent == "[")
        #expect(collapse?.keyEquivalentModifierMask == [.command, .option])
        #expect(collapse?.accessibilityLabel() == "Collapse current code block")

        let expand = recursiveMenuItem(titled: "Expand Current Block", in: menu)
        #expect(expand?.keyEquivalent == "]")
        #expect(expand?.keyEquivalentModifierMask == [.command, .option])
        #expect(expand?.accessibilityLabel() == "Expand current code block")

        let paletteTitles = CommandPaletteRegistry.commands(in: menu).map(\.title)
        #expect(paletteTitles.contains("Collapse Current Block"))
        #expect(paletteTitles.contains("Expand Current Block"))
        #expect(paletteTitles.contains("Collapse All"))
        #expect(paletteTitles.contains("Expand All"))
        #expect(
            recursiveMenuItem(titled: "Collapse All", in: menu)?.accessibilityLabel()
                == "Collapse all code blocks"
        )
        #expect(
            recursiveMenuItem(titled: "Expand All", in: menu)?.accessibilityLabel()
                == "Expand all code blocks"
        )
    }

    @Test @MainActor
    func foldChangeSchedulesOneRecoverySaveAndTeardownClearsCallback() async {
        let fixture = await makeFoldingPortControllerFixture(debounce: .zero)

        fixture.adapter.onFoldStateChange?()
        await fixture.recoveryUseCase.waitForPendingAutosave()

        #expect(await fixture.recoveryStore.commitCount == 1)
        fixture.controller.close()
        #expect(fixture.adapter.onFoldStateChange == nil)
        #expect(fixture.adapter.invalidateCount == 1)
        #expect(fixture.adapter.callbackWasNilWhenInvalidated)
    }

    @Test @MainActor
    func allFoldMenuValidationStatesMatchPortCapabilities() async {
        let fixture = await makeFoldingPortControllerFixture()
        defer { fixture.controller.close() }

        let cases: [(Selector, FoldingCapability)] = [
            (#selector(DuckpadWindowController.performCollapseCurrentFold(_:)), .collapseCurrent),
            (#selector(DuckpadWindowController.performExpandCurrentFold(_:)), .expandCurrent),
            (#selector(DuckpadWindowController.performCollapseAllFolds(_:)), .collapseAll),
            (#selector(DuckpadWindowController.performExpandAllFolds(_:)), .expandAll),
        ]

        for (selector, capability) in cases {
            fixture.adapter.setOnlyEnabled(capability)
            let item = NSMenuItem(title: capability.title, action: selector, keyEquivalent: "")
            #expect(fixture.controller.validateMenuItem(item), "\(capability) should be enabled")

            fixture.adapter.setOnlyEnabled(nil)
            #expect(!fixture.controller.validateMenuItem(item), "\(capability) should be disabled")
        }

        fixture.adapter.supportsFolding = false
        fixture.adapter.canCollapseCurrentFold = true
        fixture.adapter.canExpandCurrentFold = true
        fixture.adapter.hasCollapsedFolds = true
        for (selector, capability) in cases {
            let item = NSMenuItem(title: capability.title, action: selector, keyEquivalent: "")
            #expect(!fixture.controller.validateMenuItem(item), "Plain Text must disable \(capability)")
        }

        let notReady = await makeFoldingPortControllerFixture(startsWorkspace: false)
        defer { notReady.controller.close() }
        notReady.adapter.supportsFolding = true
        notReady.adapter.canCollapseCurrentFold = true
        notReady.adapter.canExpandCurrentFold = true
        notReady.adapter.hasCollapsedFolds = true
        for (selector, capability) in cases {
            let item = NSMenuItem(title: capability.title, action: selector, keyEquivalent: "")
            #expect(!notReady.controller.validateMenuItem(item), "Restoring workspace must disable \(capability)")
        }
    }

    @Test @MainActor
    func foldCommandsRouteOnlyMatchingActionAndRefocusOnlyAfterChange() async {
        let fixture = await makeFoldingPortControllerFixture()
        defer { fixture.controller.close() }

        let cases: [(Selector, FoldingCapability)] = [
            (#selector(DuckpadWindowController.performCollapseCurrentFold(_:)), .collapseCurrent),
            (#selector(DuckpadWindowController.performExpandCurrentFold(_:)), .expandCurrent),
            (#selector(DuckpadWindowController.performCollapseAllFolds(_:)), .collapseAll),
            (#selector(DuckpadWindowController.performExpandAllFolds(_:)), .expandAll),
        ]

        for (selector, capability) in cases {
            fixture.adapter.resetInvocations()
            fixture.adapter.setOnlyEnabled(capability)
            fixture.adapter.commandResult = true
            NSApplication.shared.sendAction(selector, to: fixture.controller, from: nil)
            #expect(fixture.adapter.invocations == [capability])
            #expect(fixture.adapter.focusCount == 1)

            fixture.adapter.resetInvocations()
            fixture.adapter.commandResult = false
            NSApplication.shared.sendAction(selector, to: fixture.controller, from: nil)
            #expect(fixture.adapter.invocations == [capability])
            #expect(fixture.adapter.focusCount == 0)

            fixture.adapter.resetInvocations()
            fixture.adapter.setOnlyEnabled(nil)
            fixture.adapter.commandResult = true
            NSApplication.shared.sendAction(selector, to: fixture.controller, from: nil)
            #expect(fixture.adapter.invocations.isEmpty)
            #expect(fixture.adapter.focusCount == 0)
        }
    }

    @MainActor
    private func recursiveMenuItem(titled title: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title { return item }
            if let submenu = item.submenu,
               let match = recursiveMenuItem(titled: title, in: submenu) {
                return match
            }
        }
        return nil
    }

    @MainActor
    private func makeFoldingPortControllerFixture(
        debounce: Duration = .seconds(60),
        startsWorkspace: Bool = true
    ) async -> (
        workspace: ScratchWorkspaceUseCase,
        adapter: FoldingEditorFake,
        recoveryUseCase: SessionRecoveryUseCase,
        recoveryStore: RecordingRecoveryStore,
        controller: DuckpadWindowController
    ) {
        _ = NSApplication.shared
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore())
        if startsWorkspace {
            #expect(await workspace.start() == .saved)
        }
        let adapter = FoldingEditorFake()
        let recoveryStore = RecordingRecoveryStore()
        let recoveryUseCase = SessionRecoveryUseCase(
            workspace: workspace,
            editor: adapter,
            store: recoveryStore,
            debounce: debounce
        )
        let controller = DuckpadWindowController(
            workspace: workspace,
            editorAdapter: adapter,
            editorView: NSView(frame: .zero),
            recoveryUseCase: recoveryUseCase,
            automaticallyStarts: false
        )
        return (workspace, adapter, recoveryUseCase, recoveryStore, controller)
    }

    private enum FoldingCapability: Equatable, CustomStringConvertible {
        case collapseCurrent
        case expandCurrent
        case collapseAll
        case expandAll

        var title: String {
            switch self {
            case .collapseCurrent: "Collapse Current Block"
            case .expandCurrent: "Expand Current Block"
            case .collapseAll: "Collapse All"
            case .expandAll: "Expand All"
            }
        }

        var description: String { title }
    }

    @MainActor
    private final class FoldingEditorFake: FoldingEditorPort {
        var onEdit: ((EditorIncrementalEdit) -> EditorEditOutcome)?
        var onFoldStateChange: (() -> Void)?
        var supportsFolding = true
        var canCollapseCurrentFold = true
        var canExpandCurrentFold = true
        var hasCollapsedFolds = true
        var commandResult = true
        private(set) var invocations: [FoldingCapability] = []
        private(set) var focusCount = 0
        private(set) var invalidateCount = 0
        private(set) var callbackWasNilWhenInvalidated = false
        private var activeBuffer: EditorBufferDescriptor?
        private var snapshots: [BufferID: EditorRecoverySnapshot] = [:]

        func display(_ buffer: EditorBufferDescriptor) {
            activeBuffer = buffer
            snapshots[buffer.bufferID] = snapshots[buffer.bufferID] ?? EditorRecoverySnapshot(
                bufferID: buffer.bufferID,
                revision: buffer.revision,
                utf8: Data()
            )
        }

        func install(_ snapshot: EditorTextSnapshot) {
            snapshots[snapshot.bufferID] = EditorRecoverySnapshot(
                bufferID: snapshot.bufferID,
                revision: snapshot.revision,
                utf8: Data(snapshot.text.utf8)
            )
        }

        func snapshot(for bufferID: BufferID) -> EditorTextSnapshot? {
            guard let snapshot = snapshots[bufferID] else { return nil }
            return EditorTextSnapshot(
                bufferID: bufferID,
                revision: snapshot.revision,
                text: String(decoding: snapshot.utf8, as: UTF8.self)
            )
        }

        func retire(bufferID: BufferID) { snapshots.removeValue(forKey: bufferID) }
        func setInputEnabled(_ isEnabled: Bool) {}
        func focus() { focusCount += 1 }
        func recoverySnapshot(for bufferID: BufferID) -> EditorRecoverySnapshot? { snapshots[bufferID] }
        func installRecovery(_ snapshot: EditorRecoverySnapshot) { snapshots[snapshot.bufferID] = snapshot }

        func collapseCurrentFold() -> Bool { invoke(.collapseCurrent) }
        func expandCurrentFold() -> Bool { invoke(.expandCurrent) }
        func collapseAllFolds() -> Bool { invoke(.collapseAll) }
        func expandAllFolds() -> Bool { invoke(.expandAll) }

        func invalidate() {
            invalidateCount += 1
            callbackWasNilWhenInvalidated = onFoldStateChange == nil
            onFoldStateChange = nil
            onEdit = nil
            activeBuffer = nil
            snapshots.removeAll()
        }

        func setOnlyEnabled(_ capability: FoldingCapability?) {
            supportsFolding = capability != nil
            canCollapseCurrentFold = capability == .collapseCurrent
            canExpandCurrentFold = capability == .expandCurrent
            hasCollapsedFolds = capability == .expandAll
        }

        func resetInvocations() {
            invocations = []
            focusCount = 0
        }

        private func invoke(_ capability: FoldingCapability) -> Bool {
            invocations.append(capability)
            return commandResult
        }
    }

    private actor RecordingRecoveryStore: RecoveryStore {
        private var stored: StoredRecoveryArchive?
        private(set) var commitCount = 0

        func loadLatest() async throws(SessionStoreError) -> StoredRecoveryArchive? { stored }

        func commit(
            _ archive: RecoveryArchive,
            generation: PersistenceGeneration
        ) async throws(SessionStoreError) -> SessionCommitResult {
            stored = StoredRecoveryArchive(archive: archive, generation: generation)
            commitCount += 1
            return .committed
        }

        func reset() async throws(SessionStoreError) { stored = nil }
    }
}
