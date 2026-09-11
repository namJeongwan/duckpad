import AppKit
import DuckpadLocalization
import DuckpadApplication
import DuckpadDomain
import DuckpadScintillaBridge

/// Production editor adapter. Scintilla owns live text; Application owns only
/// buffer identity/revision/dirty metadata.
@MainActor
public final class ScintillaEditorAdapter: SearchEditorPort, EditorFindTextPort, LanguageEditorPort, ExtensionEditorPort, EditorDefaultViewOptionsPort, EditorDisplayOptionsPort, EditorNavigationPort, EditorCommandPort, BookmarkEditorPort, SplitEditorPort, DocumentIntelligenceEditorPort, FoldingEditorPort, EditorGroupRoutingPort, EditorStatusReportingPort {
    private struct RecoveryBuffer {
        var baseRevision: UInt64
        var revision: UInt64
        var baseUTF8: Data
        var deltas: [EditorRecoveryDelta]
        var byteCount: Int
    }

    public static let engineVersion = "5.6.6"
    /// Stable host passed to Presentation. Each live buffer owns a Scintilla
    /// child view so switching/retiring another buffer cannot erase its undo stack.
    public var view: NSView { splitView }
    /// Stable second group host. Presentation owns its placement and layout.
    public var secondaryGroupView: NSView { secondaryGroupHost }
    public var activeScintillaView: DPScintillaEditorView? {
        guard !isInvalidated else { return nil }
        if hasVisibleGroups {
            return displayedGroupViews[activeEditorGroup]
        }
        if let primaryActiveView, primaryActiveView.hasEditorFocus {
            lastFocusedViewID = ObjectIdentifier(primaryActiveView)
            return primaryActiveView
        }
        if splitOrientation != nil, let secondaryActiveView, secondaryActiveView.hasEditorFocus {
            lastFocusedViewID = ObjectIdentifier(secondaryActiveView)
            return secondaryActiveView
        }
        if let lastFocusedViewID {
            if let primaryActiveView, ObjectIdentifier(primaryActiveView) == lastFocusedViewID {
                return primaryActiveView
            }
            if splitOrientation != nil,
               let secondaryActiveView,
               ObjectIdentifier(secondaryActiveView) == lastFocusedViewID {
                return secondaryActiveView
            }
        }
        return primaryActiveView
    }
    public var secondaryScintillaView: DPScintillaEditorView? {
        isInvalidated ? nil : secondaryActiveView
    }
    public private(set) var lastMutationError: (any Error)?
    public private(set) var lastRecoveryJournalWorkByteCount = 0
    public private(set) var recoveryJournalAppendCount = 0
    public var onEdit: ((EditorIncrementalEdit) -> EditorEditOutcome)?
    public var onEditorStatusChange: (() -> Void)?
    public var editorStatus: EditorStatusSnapshot? {
        guard let view = activeScintillaView else { return nil }
        return EditorStatusSnapshot(
            length: Int(clamping: view.documentByteLength), lines: Int(clamping: view.lineCount),
            line: Int(clamping: view.caretLine) + 1, column: Int(clamping: view.caretColumn) + 1,
            selectedCharacters: Int(clamping: view.selectedCharacterCount),
            selectedLines: Int(clamping: view.selectedLineCount), isOvertype: view.overtype
        )
    }
    public func toggleOvertype() {
        guard inputEnabled, let view = activeScintillaView else { return }
        view.overtype.toggle()
    }
    public var onFoldStateChange: (() -> Void)?
    public var onEditorGroupFocus: ((EditorGroupID) -> Void)?

    private var activeBuffer: EditorBufferDescriptor?
    private var snapshots: [BufferID: EditorTextSnapshot] = [:]
    private var recoveryBuffers: [BufferID: RecoveryBuffer] = [:]
    private var viewStates: [BufferID: EditorViewState] = [:]
    private var acceptedEdits: [BufferID: [EditorIncrementalEdit]] = [:]
    private var displayPreferences = AppSettings.defaults
    private var bufferViews: [BufferID: DPScintillaEditorView] = [:]
    private var secondaryBufferViews: [BufferID: DPScintillaEditorView] = [:]
    private var groupPeerViews: [BufferID: [DPScintillaEditorView]] = [:]
    private var bufferGroupViews: [BufferID: [EditorGroupID: DPScintillaEditorView]] = [:]
    private var displayedGroupBuffers: [EditorGroupID: EditorBufferDescriptor] = [:]
    private var displayedGroupViews: [EditorGroupID: DPScintillaEditorView] = [:]
    private var bufferOwners: [BufferID: EditorGroupID] = [:]
    private var pendingGroupRecoveryViewStates: [BufferID: [ObjectIdentifier: EditorViewState]] = [:]
    private var documentIntelligenceContextIDs: [ObjectIdentifier: DocumentIntelligenceContextID] = [:]
    private var navigationContextIDs: [ObjectIdentifier: EditorNavigationContextID] = [:]
    private var pendingFoldRecoveryByView: [ObjectIdentifier: FoldRecoveryState] = [:]
    private var pendingSmartIndentationViewIDs: [BufferID: ObjectIdentifier] = [:]
    private var lastFocusedViewID: ObjectIdentifier?
    private let splitView = NSSplitView(frame: .zero)
    private let primaryHost = NSView(frame: .zero)
    private let internalSecondaryHost = NSView(frame: .zero)
    private let secondaryGroupHost = NSView(frame: .zero)
    private var additionalGroupHosts: [EditorGroupID: NSView] = [.tertiary: NSView(), .quaternary: NSView()]

    public var additionalEditorGroupViews: [EditorGroupID: NSView] { additionalGroupHosts }
    public func editorGroupHost(for group: EditorGroupID) -> NSView {
        if group == .primary { return primaryHost }
        if group == .secondary { return secondaryGroupHost }
        if let host = additionalGroupHosts[group] { return host }
        let host = NSView()
        additionalGroupHosts[group] = host
        return host
    }

    private var primaryActiveView: DPScintillaEditorView?
    private var secondaryActiveView: DPScintillaEditorView?
    public private(set) var splitOrientation: EditorSplitOrientation?
    public private(set) var activeEditorGroup: EditorGroupID = .primary
    public private(set) var editorGroupOrientation: EditorGroupSplitOrientation?
    public var hasVisibleGroups: Bool { editorGroupOrientation != nil }
    public var suspendedInternalSplitOrientation: EditorSplitOrientation? {
        guard hasVisibleGroups, let bufferID = activeBuffer?.bufferID else { return nil }
        return viewStates[bufferID]?.splitOrientation
    }
    private var languageConfigurations: [BufferID: EditorLanguageConfiguration] = [:]
    private var pendingRecoveryBuffers: Set<BufferID> = []
    private var revisionExhaustedBuffers: Set<BufferID> = []
    private var themePalette: EditorThemePalette = .light
    private var defaultViewState: EditorViewState
    private var isRecovering = false
    private var inputEnabled = true
    private var lifecycleGeneration: UInt64 = 0
    private var isInvalidated = false
    private var editCallbackDepth = 0
    private var editorGroupLayoutRequestGeneration: UInt64 = 0
    private var deferredEditorGroupCloseRequestGeneration: UInt64?
    private var scheduledEditorGroupCloseRequestGeneration: UInt64?

    public static func prepareResources() {
        guard let directory = DuckpadEditorResources.bundle.url(
            forResource: "ScintillaCursors",
            withExtension: nil
        ) else {
            assertionFailure("Scintilla cursor resources are missing")
            return
        }
        DPScintillaConfigureResourceDirectory(directory)
    }

    public init(defaultViewState: EditorViewState = EditorViewState()) {
        self.defaultViewState = defaultViewState
        Self.prepareResources()
        splitView.dividerStyle = .thin
        splitView.isVertical = true
        splitView.addArrangedSubview(primaryHost)
        primaryHost.setAccessibilityLabel(L10n.text("Primary editor pane"))
        internalSecondaryHost.setAccessibilityLabel(L10n.text("Secondary editor pane"))
        secondaryGroupHost.setAccessibilityLabel(L10n.text("Secondary editor group"))
        secondaryGroupHost.translatesAutoresizingMaskIntoConstraints = false
        secondaryGroupHost.setAccessibilityIdentifier("duckpad.editor.secondary-group-host")
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setAccessibilityIdentifier("duckpad.editor.host")
    }

    public func refreshLocalization(catalog: LocalizationCatalog = L10n.catalog) {
        primaryHost.setAccessibilityLabel(catalog.text("Primary editor pane"))
        internalSecondaryHost.setAccessibilityLabel(catalog.text("Secondary editor pane"))
        secondaryGroupHost.setAccessibilityLabel(catalog.text("Secondary editor group"))
    }

    public func display(_ buffer: EditorBufferDescriptor) {
        guard !isInvalidated else { return }
        if hasVisibleGroups {
            display(buffer, in: activeEditorGroup)
            return
        }
        guard recoverPendingBufferIfNeeded(buffer.bufferID),
              let buffer = authoritativeDescriptor(for: buffer) else { return }
        if let outgoingBufferID = activeBuffer?.bufferID {
            guard recoverPendingBufferIfNeeded(outgoingBufferID) else { return }
        }
        if activeBuffer == buffer { return }
        if let activeBuffer {
            storeViewState(bufferID: activeBuffer.bufferID)
            storeSnapshot(bufferID: activeBuffer.bufferID, revision: activeBuffer.revision)
        }
        hideSplit(focusPrimary: false)
        let editorView = preparePrimaryView(for: buffer)
        activeBuffer = buffer
        restoreViewState(for: buffer.bufferID, in: editorView)
        applyStoredLanguage(to: editorView, bufferID: buffer.bufferID)
        primaryActiveView?.removeFromSuperview()
        primaryActiveView = editorView
        editorView.frame = primaryHost.bounds
        editorView.autoresizingMask = [.width, .height]
        editorView.isInputEnabled = isInputEnabled(for: buffer.bufferID)
        primaryHost.addSubview(editorView)
        displayedGroupBuffers = [.primary: buffer]
        displayedGroupViews = [.primary: editorView]
        bufferOwners[buffer.bufferID] = bufferOwners[buffer.bufferID] ?? .primary
        bufferGroupViews[buffer.bufferID, default: [:]][.primary] = editorView
        restoreSplitViewState(for: buffer.bufferID, primary: editorView)
    }

    public func setEditorGroupOrientation(_ orientation: EditorGroupSplitOrientation?) {
        guard !isInvalidated else { return }
        editorGroupLayoutRequestGeneration &+= 1
        let requestGeneration = editorGroupLayoutRequestGeneration
        deferredEditorGroupCloseRequestGeneration = nil
        scheduledEditorGroupCloseRequestGeneration = nil
        guard let orientation else {
            closeEditorGroups(requestGeneration: requestGeneration)
            return
        }
        if !hasVisibleGroups {
            if let bufferID = activeBuffer?.bufferID {
                guard recoverPendingBufferIfNeeded(bufferID) else { return }
                storeViewState(bufferID: bufferID)
                storeSnapshot(bufferID: bufferID, revision: currentRevision(for: bufferID))
            }
            hideSplit(focusPrimary: false)
            activeEditorGroup = .primary
            if let activeBuffer, let primaryActiveView {
                displayedGroupBuffers[.primary] = activeBuffer
                displayedGroupViews[.primary] = primaryActiveView
                bufferOwners[activeBuffer.bufferID] = bufferOwners[activeBuffer.bufferID] ?? .primary
                bufferGroupViews[activeBuffer.bufferID, default: [:]][.primary] = primaryActiveView
            }
        }
        editorGroupOrientation = orientation
    }

    public func retainEditorGroups(_ groups: Set<EditorGroupID>) {
        for group in Array(displayedGroupViews.keys) where !groups.contains(group) {
            displayedGroupViews.removeValue(forKey: group)?.removeFromSuperview()
            displayedGroupBuffers.removeValue(forKey: group)
            for bufferID in Array(bufferGroupViews.keys) {
                bufferGroupViews[bufferID]?[group] = nil
            }
        }
        for group in Array(additionalGroupHosts.keys) where !groups.contains(group) && !EditorGroupID.predefined.contains(group) {
            additionalGroupHosts.removeValue(forKey: group)?.removeFromSuperview()
        }
    }

    public func activateEditorGroup(_ group: EditorGroupID) {
        guard !isInvalidated,
              group == .primary || hasVisibleGroups,
              let descriptor = displayedGroupBuffers[group],
              displayedGroupViews[group] != nil else { return }
        if let outgoingID = activeBuffer?.bufferID,
           bufferOwners[outgoingID] == activeEditorGroup {
            storeViewState(bufferID: outgoingID)
        }
        activeEditorGroup = group
        activeBuffer = descriptor
        if let editorView = displayedGroupViews[group] {
            lastFocusedViewID = ObjectIdentifier(editorView)
        }
        onEditorStatusChange?()
    }

    public func display(_ buffer: EditorBufferDescriptor, in group: EditorGroupID) {
        guard !isInvalidated else { return }
        if !hasVisibleGroups {
            guard group == .primary else { return }
            display(buffer)
            return
        }
        guard recoverPendingBufferIfNeeded(buffer.bufferID),
              let buffer = authoritativeDescriptor(for: buffer) else { return }
        if let outgoing = displayedGroupBuffers[group], outgoing != buffer {
            guard recoverPendingBufferIfNeeded(outgoing.bufferID) else { return }
            if bufferOwners[outgoing.bufferID] == group {
                storeViewState(bufferID: outgoing.bufferID)
            }
            storeSnapshot(bufferID: outgoing.bufferID, revision: currentRevision(for: outgoing.bufferID))
        }
        let publisher = preparePrimaryView(for: buffer)
        bufferOwners[buffer.bufferID] = bufferOwners[buffer.bufferID] ?? group
        let editorView = groupView(for: buffer.bufferID, group: group, publisher: publisher)
        attach(editorView, to: group)
        displayedGroupBuffers[group] = buffer
        displayedGroupViews[group] = editorView
        editorView.isInputEnabled = isInputEnabled(for: buffer.bufferID)
        applyStoredLanguage(to: editorView, bufferID: buffer.bufferID)
        if activeEditorGroup == group {
            activeBuffer = buffer
        }
    }

    public func assign(
        _ buffer: EditorBufferDescriptor,
        from source: EditorGroupID?,
        to destination: EditorGroupID,
        cloning: Bool
    ) {
        guard !isInvalidated else { return }
        if cloning {
            bufferOwners[buffer.bufferID] = bufferOwners[buffer.bufferID] ?? source ?? destination
            return
        }
        let destinationView = bufferGroupViews[buffer.bufferID]?[destination]
            ?? source.flatMap { bufferGroupViews[buffer.bufferID]?[$0] }
        if let destinationView {
            storeViewState(bufferID: buffer.bufferID, using: destinationView)
        }
        bufferOwners[buffer.bufferID] = destination
        if let source, source != destination,
           bufferGroupViews[buffer.bufferID]?[destination] == nil,
           let sourceView = bufferGroupViews[buffer.bufferID]?[source] {
            bufferGroupViews[buffer.bufferID]?[source] = nil
            bufferGroupViews[buffer.bufferID]?[destination] = sourceView
        }
    }

    public func install(_ snapshot: EditorTextSnapshot) {
        guard !isInvalidated else { return }
        pendingRecoveryBuffers.remove(snapshot.bufferID)
        updateRevisionExhaustion(bufferID: snapshot.bufferID, revision: snapshot.revision)
        if canonicalOwnerView(for: snapshot.bufferID) != nil {
            storeViewState(bufferID: snapshot.bufferID)
        }
        snapshots[snapshot.bufferID] = snapshot
        let bytes = Data(snapshot.text.utf8)
        recoveryBuffers[snapshot.bufferID] = RecoveryBuffer(
            baseRevision: snapshot.revision,
            revision: snapshot.revision,
            baseUTF8: bytes,
            deltas: [],
            byteCount: bytes.count
        )
        viewStates[snapshot.bufferID] = sanitized(
            viewStates[snapshot.bufferID] ?? defaultViewState,
            for: bytes
        )
        acceptedEdits[snapshot.bufferID] = []
        guard let editorView = bufferViews[snapshot.bufferID] else { return }
        load(snapshot, into: editorView)
        synchronizeRevision(snapshot.revision, for: snapshot.bufferID, excluding: editorView)
        updateDisplayedRevision(snapshot.revision, for: snapshot.bufferID)
        if activeBuffer?.bufferID == snapshot.bufferID {
            activeBuffer = EditorBufferDescriptor(bufferID: snapshot.bufferID, revision: snapshot.revision)
        }
        if let ownerView = canonicalOwnerView(for: snapshot.bufferID) {
            restoreViewState(for: snapshot.bufferID, in: ownerView)
        }
    }

    public func snapshot(for bufferID: BufferID) -> EditorTextSnapshot? {
        guard !isInvalidated else { return nil }
        guard recoverPendingBufferIfNeeded(bufferID) else { return snapshots[bufferID] }
        if bufferViews[bufferID] != nil {
            storeSnapshot(bufferID: bufferID, revision: currentRevision(for: bufferID))
        }
        return snapshots[bufferID]
    }

    public func recoverySnapshot(for bufferID: BufferID) -> EditorRecoverySnapshot? {
        try? recoveryCapture(for: bufferID)?.materializedSnapshot()
    }

    public func recoveryCapture(for bufferID: BufferID) -> EditorRecoveryCapture? {
        guard !isInvalidated else { return nil }
        guard recoverPendingBufferIfNeeded(bufferID) else { return nil }
        if canonicalOwnerView(for: bufferID) != nil { storeViewState(bufferID: bufferID) }
        guard let recovery = recoveryBuffers[bufferID] else { return nil }
        return EditorRecoveryCapture(
            bufferID: bufferID,
            baseRevision: recovery.baseRevision,
            revision: recovery.revision,
            baseUTF8: recovery.baseUTF8,
            deltas: recovery.deltas,
            viewState: viewStates[bufferID] ?? defaultViewState
        )
    }

    public func acknowledgeRecoverySnapshot(_ snapshot: EditorRecoverySnapshot) {
        guard !isInvalidated else { return }
        guard var recovery = recoveryBuffers[snapshot.bufferID],
              snapshot.revision >= recovery.baseRevision,
              snapshot.revision <= recovery.revision else { return }
        var consumed = 0
        var revision = recovery.baseRevision
        while revision < snapshot.revision, consumed < recovery.deltas.count {
            guard recovery.deltas[consumed].expectedRevision == revision else { return }
            revision += 1
            consumed += 1
        }
        guard revision == snapshot.revision else { return }
        recovery.baseRevision = snapshot.revision
        recovery.baseUTF8 = snapshot.utf8
        recovery.deltas.removeFirst(consumed)
        recoveryBuffers[snapshot.bufferID] = recovery
    }

    public func installRecovery(_ snapshot: EditorRecoverySnapshot) {
        guard !isInvalidated else { return }
        guard let text = String(data: snapshot.utf8, encoding: .utf8) else { return }
        let recoveredViewState = sanitized(snapshot.viewState, for: snapshot.utf8)
        install(EditorTextSnapshot(bufferID: snapshot.bufferID, revision: snapshot.revision, text: text))
        viewStates[snapshot.bufferID] = recoveredViewState
        let recoveryView = canonicalOwnerView(for: snapshot.bufferID)
            ?? (hasVisibleGroups ? nil : bufferViews[snapshot.bufferID])
        if let editorView = recoveryView {
            restoreViewState(for: snapshot.bufferID, in: editorView)
            if activeBuffer?.bufferID == snapshot.bufferID, !hasVisibleGroups,
               let primary = bufferViews[snapshot.bufferID] {
                hideSplit(focusPrimary: false)
                restoreSplitViewState(for: snapshot.bufferID, primary: primary)
            }
        }
    }

    public func retire(bufferID: BufferID) {
        snapshots.removeValue(forKey: bufferID)
        recoveryBuffers.removeValue(forKey: bufferID)
        viewStates.removeValue(forKey: bufferID)
        acceptedEdits.removeValue(forKey: bufferID)
        languageConfigurations.removeValue(forKey: bufferID)
        pendingRecoveryBuffers.remove(bufferID)
        revisionExhaustedBuffers.remove(bufferID)
        bufferOwners.removeValue(forKey: bufferID)
        bufferGroupViews.removeValue(forKey: bufferID)
        pendingGroupRecoveryViewStates.removeValue(forKey: bufferID)
        for group in Array(displayedGroupBuffers.keys) where displayedGroupBuffers[group]?.bufferID == bufferID {
            displayedGroupBuffers.removeValue(forKey: group)
            displayedGroupViews.removeValue(forKey: group)?.removeFromSuperview()
        }
        let retiredView = bufferViews[bufferID]
        retiredView?.cancelPendingSmartIndentation()
        if let retiredView {
            discardViewIdentity(retiredView)
        }
        bufferViews.removeValue(forKey: bufferID)
        retiredView?.onEdit = nil
        retiredView?.onWillModifyDocument = nil
        retiredView?.onError = nil
        retiredView?.onFocus = nil
        retiredView?.onFoldStateChange = nil
        retiredView?.onFoldRecoveryProgress = nil
        retiredView?.onSmartIndentationStateChange = nil
        retiredView?.removeFromSuperview()
        retiredView?.invalidate()
        let retiredSecondary = secondaryBufferViews[bufferID]
        retiredSecondary?.cancelPendingSmartIndentation()
        if let retiredSecondary {
            discardViewIdentity(retiredSecondary)
        }
        secondaryBufferViews.removeValue(forKey: bufferID)
        retiredSecondary?.onEdit = nil
        retiredSecondary?.onWillModifyDocument = nil
        retiredSecondary?.onError = nil
        retiredSecondary?.onFocus = nil
        retiredSecondary?.onFoldStateChange = nil
        retiredSecondary?.onFoldRecoveryProgress = nil
        retiredSecondary?.onSmartIndentationStateChange = nil
        retiredSecondary?.removeFromSuperview()
        retiredSecondary?.invalidate()
        let retiredGroupPeers = groupPeerViews.removeValue(forKey: bufferID) ?? []
        for peer in retiredGroupPeers {
            peer.cancelPendingSmartIndentation()
            discardViewIdentity(peer)
            peer.onEdit = nil
            peer.onWillModifyDocument = nil
            peer.onError = nil
            peer.onFocus = nil
            peer.onFoldStateChange = nil
            peer.onFoldRecoveryProgress = nil
            peer.onSmartIndentationStateChange = nil
            peer.removeFromSuperview()
            peer.invalidate()
        }
        let retiredViews = [retiredView, retiredSecondary].compactMap { $0 } + retiredGroupPeers
        if retiredViews.contains(where: { primaryActiveView === $0 }) {
            primaryActiveView = nil
        }
        if retiredViews.contains(where: { secondaryActiveView === $0 }) {
            secondaryActiveView = nil
        }
        guard activeBuffer?.bufferID == bufferID else { return }
        activeBuffer = nil
    }

    public func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        lifecycleGeneration &+= 1
        let editorViews = Array(bufferViews.values)
            + Array(secondaryBufferViews.values)
            + groupPeerViews.values.flatMap { $0 }
        for editorView in editorViews {
            editorView.cancelPendingSmartIndentation()
            editorView.onWillModifyDocument = nil
            editorView.onEdit = nil
            editorView.onError = nil
            editorView.onFocus = nil
            editorView.onFoldStateChange = nil
            editorView.onFoldRecoveryProgress = nil
            editorView.onSmartIndentationStateChange = nil
            discardViewIdentity(editorView)
            editorView.removeFromSuperview()
            editorView.invalidate()
        }
        bufferViews.removeAll()
        secondaryBufferViews.removeAll()
        groupPeerViews.removeAll()
        bufferGroupViews.removeAll()
        displayedGroupBuffers.removeAll()
        displayedGroupViews.removeAll()
        bufferOwners.removeAll()
        pendingGroupRecoveryViewStates.removeAll()
        pendingFoldRecoveryByView.removeAll()
        pendingSmartIndentationViewIDs.removeAll()
        documentIntelligenceContextIDs.removeAll()
        navigationContextIDs.removeAll()
        lastFocusedViewID = nil
        primaryActiveView = nil
        secondaryActiveView = nil
        activeBuffer = nil
        splitOrientation = nil
        activeEditorGroup = .primary
        editorGroupOrientation = nil
        if internalSecondaryHost.superview != nil {
            splitView.removeArrangedSubview(internalSecondaryHost)
            internalSecondaryHost.removeFromSuperview()
        }
        snapshots.removeAll()
        recoveryBuffers.removeAll()
        viewStates.removeAll()
        acceptedEdits.removeAll()
        languageConfigurations.removeAll()
        pendingRecoveryBuffers.removeAll()
        revisionExhaustedBuffers.removeAll()
        deferredEditorGroupCloseRequestGeneration = nil
        scheduledEditorGroupCloseRequestGeneration = nil
        onEdit = nil
        onFoldStateChange = nil
        onEditorStatusChange = nil
        onEditorGroupFocus = nil
    }

    public func setInputEnabled(_ isEnabled: Bool) {
        if !isEnabled {
            for bufferID in Array(pendingRecoveryBuffers) {
                recoverPendingBufferIfNeeded(bufferID)
            }
        }
        inputEnabled = isEnabled
        for (bufferID, editorView) in bufferViews {
            editorView.isInputEnabled = isInputEnabled(for: bufferID)
        }
        for (bufferID, editorView) in secondaryBufferViews {
            editorView.isInputEnabled = isInputEnabled(for: bufferID)
        }
        for (bufferID, peers) in groupPeerViews {
            peers.forEach { $0.isInputEnabled = isInputEnabled(for: bufferID) }
        }
        view.alphaValue = isEnabled ? 1 : 0.65
        secondaryGroupView.alphaValue = isEnabled ? 1 : 0.65
        additionalGroupHosts.values.forEach { $0.alphaValue = isEnabled ? 1 : 0.65 }
    }

    public func focus() { activeScintillaView?.focusEditor() }

    public func split(orientation: EditorSplitOrientation) {
        guard !hasVisibleGroups else { return }
        guard let activeBuffer, let primary = primaryActiveView else { return }
        configureSplit(orientation: orientation, bufferID: activeBuffer.bufferID, primary: primary)
        storeViewState(bufferID: activeBuffer.bufferID)
        secondaryActiveView?.focusEditor()
        if let secondaryActiveView, secondaryActiveView.hasEditorFocus {
            lastFocusedViewID = ObjectIdentifier(secondaryActiveView)
        }
    }

    public func closeSplit() {
        guard !hasVisibleGroups else { return }
        guard splitOrientation != nil, let bufferID = activeBuffer?.bufferID else { return }
        storeViewState(bufferID: bufferID)
        var state = viewStates[bufferID] ?? EditorViewState()
        state.splitOrientation = nil
        state.secondaryViewState = nil
        viewStates[bufferID] = state
        hideSplit(focusPrimary: true)
    }

    public func focusOtherPane() {
        guard !hasVisibleGroups else { return }
        guard splitOrientation != nil, let primaryActiveView, let secondaryActiveView else { return }
        let target = secondaryActiveView.hasEditorFocus ? primaryActiveView : secondaryActiveView
        target.focusEditor()
        if target.hasEditorFocus { lastFocusedViewID = ObjectIdentifier(target) }
    }

    public var isWordWrapEnabled: Bool {
        activeScintillaView?.isWordWrapEnabled ?? true
    }

    public var isWrapMarkerVisible: Bool {
        activeScintillaView?.isWrapMarkerVisible ?? false
    }

    public let supportsWrapMarker = true

    public func setWordWrapEnabled(_ isEnabled: Bool) {
        guard let bufferID = activeBuffer?.bufferID, let editorView = activeScintillaView else { return }
        editorView.isWordWrapEnabled = isEnabled
        storeViewState(bufferID: bufferID)
    }

    public func setWrapMarkerVisible(_ isVisible: Bool) {
        guard let bufferID = activeBuffer?.bufferID, let editorView = activeScintillaView else { return }
        editorView.isWrapMarkerVisible = isVisible
        storeViewState(bufferID: bufferID)
    }

    public func setDefaultViewOptions(wordWrapEnabled: Bool, wrapMarkerVisible: Bool) {
        defaultViewState.wordWrapEnabled = wordWrapEnabled
        defaultViewState.wrapMarkerVisible = wrapMarkerVisible
    }

    public func applyPreferences(_ settings: AppSettings) {
        displayPreferences = settings
        setDefaultViewOptions(wordWrapEnabled: settings.defaultWordWrapEnabled,
                              wrapMarkerVisible: settings.defaultWrapMarkerVisible)
        let views = Array(bufferViews.values) + Array(secondaryBufferViews.values)
            + groupPeerViews.values.flatMap { $0 }
        for view in views { applyDisplayPreferences(to: view) }
        for bufferID in bufferViews.keys {
            for view in allViews(for: bufferID) {
                applyIndentationPreferences(to: view, indentation: languageConfigurations[bufferID]?.indentation ?? .init())
            }
        }
    }

    private func applyDisplayPreferences(to view: DPScintillaEditorView) {
        let settings = displayPreferences
        view.configureEditorFont(settings.editorFontName, size: settings.editorFontSize)
        view.configureGuides(withIndentation: settings.indentationGuidesVisible,
                             virtualSpace: settings.virtualSpaceEnabled,
                             edgeVisible: settings.edgeLineVisible, edgeColumn: settings.edgeColumn)
        view.configureDisplay(withLineNumbers: settings.lineNumbersVisible,
                              bookmarkMargin: settings.bookmarkMarginVisible,
                              highlightCurrentLine: settings.highlightCurrentLine,
                              caretWidth: settings.caretWidth,
                              caretBlinkPeriod: settings.caretBlinkPeriod,
                              scrollBeyondLastLine: settings.scrollBeyondLastLine,
                              wrapIndentMode: settings.wrapIndentMode)
    }

    private func applyIndentationPreferences(to view: DPScintillaEditorView, indentation: LanguageIndentation) {
        let settings = displayPreferences
        view.configureIndentation(withWidth: UInt(clamping: settings.overrideLanguageIndentation ? settings.indentationWidth : indentation.width),
                                  useTabs: settings.overrideLanguageIndentation ? settings.indentationUsesTabs : indentation.useTabs)
    }

    public var isWhitespaceVisible: Bool { activeScintillaView?.isWhitespaceVisible ?? false }
    public var areLineEndingsVisible: Bool { activeScintillaView?.areLineEndingsVisible ?? false }
    public var zoomLevel: Int { Int(activeScintillaView?.zoomLevel ?? 0) }

    public func setWhitespaceVisible(_ isVisible: Bool) {
        guard let bufferID = activeBuffer?.bufferID, let editorView = activeScintillaView else { return }
        editorView.isWhitespaceVisible = isVisible
        storeViewState(bufferID: bufferID)
    }

    public func setLineEndingsVisible(_ isVisible: Bool) {
        guard let bufferID = activeBuffer?.bufferID, let editorView = activeScintillaView else { return }
        editorView.areLineEndingsVisible = isVisible
        storeViewState(bufferID: bufferID)
    }

    public func setZoomLevel(_ level: Int) {
        guard let bufferID = activeBuffer?.bufferID, let editorView = activeScintillaView else { return }
        editorView.zoomLevel = min(max(level, -10), 20)
        storeViewState(bufferID: bufferID)
    }

    public var navigationPosition: EditorNavigationPosition? {
        guard let editorView = activeScintillaView,
              let contextID = navigationContextIDs[ObjectIdentifier(editorView)] else { return nil }
        return EditorNavigationPosition(
            contextID: contextID,
            line: Int(clamping: editorView.caretLine) + 1,
            column: Int(clamping: editorView.caretColumn) + 1,
            utf8Offset: Int(clamping: editorView.caretUTF8Position),
            lineCount: Int(clamping: editorView.lineCount),
            utf8Length: Int(clamping: editorView.documentByteLength)
        )
    }

    @discardableResult
    public func goTo(line: Int, column: Int, in contextID: EditorNavigationContextID) -> Bool {
        guard line > 0, column > 0, let editorView = navigationView(for: contextID),
              editorView.go(toOneBasedLine: UInt(line), column: UInt(column)) else { return false }
        editorView.focusEditor()
        if editorView.hasEditorFocus { lastFocusedViewID = ObjectIdentifier(editorView) }
        if let bufferID = activeBuffer?.bufferID { storeViewState(bufferID: bufferID) }
        return true
    }

    @discardableResult
    public func goTo(utf8Offset: Int, in contextID: EditorNavigationContextID) -> Bool {
        guard utf8Offset >= 0, let editorView = navigationView(for: contextID),
              editorView.go(toUTF8Offset: UInt(utf8Offset)) else { return false }
        editorView.focusEditor()
        if editorView.hasEditorFocus { lastFocusedViewID = ObjectIdentifier(editorView) }
        if let bufferID = activeBuffer?.bufferID { storeViewState(bufferID: bufferID) }
        return true
    }

    private func navigationView(for contextID: EditorNavigationContextID) -> DPScintillaEditorView? {
        let candidates = hasVisibleGroups
            ? Array(displayedGroupViews.values)
            : [primaryActiveView, secondaryActiveView].compactMap { $0 }
        for editorView in candidates
        where navigationContextIDs[ObjectIdentifier(editorView)] == contextID {
            return editorView
        }
        return nil
    }

    public var hasBookmarks: Bool {
        !(activeScintillaView?.bookmarkedLines.isEmpty ?? true)
    }

    public func toggleBookmarkAtCaret() {
        guard let bufferID = activeBuffer?.bufferID, let editorView = activeScintillaView else { return }
        editorView.toggleBookmarkAtCaret()
        if editorView.bookmarkedLines.count > EditorViewState.maximumBookmarkCount {
            editorView.toggleBookmarkAtCaret()
        }
        storeViewState(bufferID: bufferID)
    }

    @discardableResult
    public func navigateToBookmark(forward: Bool) -> Bool {
        guard let bufferID = activeBuffer?.bufferID,
              let editorView = activeScintillaView,
              editorView.navigate(toBookmarkForward: forward) else { return false }
        storeViewState(bufferID: bufferID)
        return true
    }

    public func clearBookmarks() {
        guard let bufferID = activeBuffer?.bufferID, let editorView = activeScintillaView else { return }
        editorView.clearBookmarks()
        storeViewState(bufferID: bufferID)
    }

    public var supportsFolding: Bool {
        activeScintillaView?.configuredFoldingEnabled ?? false
    }

    public var canCollapseCurrentFold: Bool {
        supportsFolding && (activeScintillaView?.canCollapseCurrentFold ?? false)
    }

    public var canExpandCurrentFold: Bool {
        supportsFolding && (activeScintillaView?.canExpandCurrentFold ?? false)
    }

    public var hasCollapsedFolds: Bool {
        guard supportsFolding, let editorView = activeScintillaView else { return false }
        return editorView.hasContractedFolds
            || pendingFoldRecoveryByView[ObjectIdentifier(editorView)] != nil
    }

    @discardableResult
    public func collapseCurrentFold() -> Bool {
        guard supportsFolding, let editorView = activeScintillaView else { return false }
        return editorView.collapseCurrentFold()
    }

    @discardableResult
    public func expandCurrentFold() -> Bool {
        guard supportsFolding, let editorView = activeScintillaView else { return false }
        return editorView.expandCurrentFold()
    }

    @discardableResult
    public func collapseAllFolds() -> Bool {
        guard supportsFolding, let editorView = activeScintillaView else { return false }
        let identifier = ObjectIdentifier(editorView)
        let hadPending = pendingFoldRecoveryByView.removeValue(forKey: identifier) != nil
        let changed = editorView.collapseAllFolds()
        if let bufferID = activeBuffer?.bufferID { storeViewState(bufferID: bufferID) }
        if hadPending, !changed { onFoldStateChange?() }
        return changed || hadPending
    }

    @discardableResult
    public func expandAllFolds() -> Bool {
        guard supportsFolding, let editorView = activeScintillaView else { return false }
        let identifier = ObjectIdentifier(editorView)
        let hadPending = pendingFoldRecoveryByView.removeValue(forKey: identifier) != nil
        let changed = editorView.expandAllFolds()
        if let bufferID = activeBuffer?.bufferID { storeViewState(bufferID: bufferID) }
        if hadPending, !changed { onFoldStateChange?() }
        return changed || hadPending
    }

    public func canPerform(_ command: EditorCommand) -> Bool {
        guard let editorView = activeScintillaView else { return false }
        switch command {
        case .undo:
            return editorView.isInputEnabled && editorView.canUndo
        case .redo:
            return editorView.isInputEnabled && editorView.canRedo
        case .cut:
            return editorView.canCut
        case .copy:
            return editorView.canCopy
        case .paste:
            return editorView.canPaste
        case .delete:
            return editorView.canDelete
        case .selectAll:
            return editorView.canSelectAll
        case .duplicateLine, .moveLineUp, .moveLineDown, .deleteLine, .joinLines,
             .uppercase, .lowercase, .indent, .unindent, .trimTrailingWhitespace:
            return editorView.canPerform(nativeEditingCommand(command))
        }
    }

    public func perform(_ command: EditorCommand) {
        guard canPerform(command), let editorView = activeScintillaView else { return }
        switch command {
        case .undo: editorView.undo()
        case .redo: editorView.redo()
        case .cut: editorView.cutSelection()
        case .copy: editorView.copySelection()
        case .paste: editorView.paste()
        case .delete: editorView.deleteSelectionOrNextCharacter()
        case .selectAll: editorView.selectAll()
        case .duplicateLine, .moveLineUp, .moveLineDown, .deleteLine, .joinLines,
             .uppercase, .lowercase, .indent, .unindent, .trimTrailingWhitespace:
            editorView.perform(nativeEditingCommand(command))
        }
    }

    private func nativeEditingCommand(_ command: EditorCommand) -> DPScintillaEditingCommand {
        switch command {
        case .duplicateLine: .duplicateLine
        case .moveLineUp: .moveLineUp
        case .moveLineDown: .moveLineDown
        case .deleteLine: .deleteLine
        case .joinLines: .joinLines
        case .uppercase: .uppercase
        case .lowercase: .lowercase
        case .indent: .indent
        case .unindent: .unindent
        case .trimTrailingWhitespace: .trimTrailingWhitespace
        case .undo, .redo, .cut, .copy, .paste, .delete, .selectAll:
            preconditionFailure("Standard responder command has no native editing-command mapping")
        }
    }

    public var activeLanguageID: LanguageID {
        guard let id = activeBuffer?.bufferID else { return .plainText }
        return languageConfigurations[id]?.languageID ?? .plainText
    }

    public var canToggleBlockComment: Bool {
        guard !isInvalidated,
              let bufferID = activeBuffer?.bufferID,
              let primary = bufferViews[bufferID],
              let selectionOwner = activeScintillaView,
              let delimiters = activeBlockCommentDelimiters() else {
            return false
        }
        return primary.canToggleBlockComments(
            withStartUTF8: delimiters.start,
            endUTF8: delimiters.end,
            selectionOwner: selectionOwner
        )
    }

    public var isLanguageStylingFallback: Bool {
        activeScintillaView?.languageStylingFallback ?? false
    }
    public var activeDocumentByteLength: Int {
        Int(clamping: activeScintillaView?.documentByteLength ?? 0)
    }

    public var activeDocumentIntelligenceBuffer: EditorBufferDescriptor? { activeBuffer }

    public var activeDocumentIntelligenceByteLength: Int { activeDocumentByteLength }

    public func captureDocumentIntelligence(maximumBytes: Int) -> DocumentIntelligenceCapture? {
        guard maximumBytes >= 0,
              let activeBuffer,
              let editorView = activeScintillaView,
              editorView.revision == activeBuffer.revision,
              editorView.documentByteLength <= maximumBytes,
              let contextID = documentIntelligenceContextIDs[ObjectIdentifier(editorView)] else { return nil }
        return DocumentIntelligenceCapture(
            buffer: activeBuffer,
            utf8: editorView.contentUTF8,
            caretUTF8: Int(clamping: editorView.caretUTF8Position),
            languageID: activeLanguageID,
            contextID: contextID
        )
    }

    @discardableResult
    public func presentCompletionItems(
        _ items: [String],
        replacingPrefixByteCount: Int,
        expectedBuffer: EditorBufferDescriptor,
        expectedCaretUTF8: Int,
        expectedContextID: DocumentIntelligenceContextID
    ) -> Bool {
        guard replacingPrefixByteCount >= 0,
              activeBuffer == expectedBuffer,
              let editorView = activeScintillaView,
              documentIntelligenceContextIDs[ObjectIdentifier(editorView)] == expectedContextID,
              editorView.revision == expectedBuffer.revision,
              editorView.caretUTF8Position == expectedCaretUTF8,
              editorView.selectionCount == 1,
              !editorView.hasMarkedText() else { return false }
        return editorView.showCompletionItems(
            items,
            replacingPrefixByteCount: UInt(replacingPrefixByteCount)
        )
    }

    public func cancelCompletion() {
        bufferViews.values.forEach { $0.cancelCompletion() }
        secondaryBufferViews.values.forEach { $0.cancelCompletion() }
        groupPeerViews.values.flatMap { $0 }.forEach { $0.cancelCompletion() }
    }

    public func detectionPrefix(maximumBytes: Int) -> Data {
        activeScintillaView?.contentPrefixUTF8(withMaximumLength: UInt(max(0, maximumBytes))) ?? Data()
    }

    public func supportsLexer(named name: String) -> Bool {
        DPScintillaEditorView.supportsLexerNamed(name)
    }

    @discardableResult
    public func applyLanguage(_ configuration: EditorLanguageConfiguration) -> Bool {
        guard let bufferID = activeBuffer?.bufferID,
              bufferViews[bufferID] != nil,
              supportsLexer(named: configuration.lexerName) else { return false }
        let editorViews = allViews(for: bufferID)
        for editorView in editorViews {
            guard editorView.applyLexerNamed(
                configuration.lexerName,
                keywords: configuration.keywords,
                tabWidth: UInt(configuration.indentation.width),
                useTabs: configuration.indentation.useTabs,
                folding: configuration.folding,
                braceMatching: configuration.braceMatching,
                maximumStyleBytes: UInt(configuration.maximumStyleBytes)
            ) else { return false }
            applyIndentationPreferences(to: editorView, indentation: configuration.indentation)
            editorView.apply(nativePalette(themePalette))
        }
        languageConfigurations[bufferID] = configuration
        if editorViews.allSatisfy(\.configuredFoldingEnabled) {
            editorViews.forEach { retryPendingFoldRecovery(in: $0) }
        } else {
            discardPendingFoldRecovery(bufferID: bufferID)
            storeViewState(bufferID: bufferID)
        }
        return true
    }

    public func applyTheme(_ palette: EditorThemePalette) {
        themePalette = palette
        let native = nativePalette(palette)
        bufferViews.values.forEach { $0.apply(native) }
        secondaryBufferViews.values.forEach { $0.apply(native) }
        groupPeerViews.values.flatMap { $0 }.forEach { $0.apply(native) }
    }

    public func toggleLineComment(prefix: String) -> EditorEditOutcome {
        guard !prefix.isEmpty, let activeBuffer, let editorView = activeScintillaView else {
            return .rejected(currentRevision: activeBuffer?.revision ?? 0)
        }
        let oldRevision = activeBuffer.revision
        guard editorView.toggleLineComments(withPrefixUTF8: Data(prefix.utf8)) else {
            return .rejected(currentRevision: oldRevision)
        }
        guard let revision = self.activeBuffer?.revision, revision > oldRevision else {
            return .rejected(currentRevision: self.activeBuffer?.revision ?? oldRevision)
        }
        return .accepted(newRevision: revision)
    }

    public func toggleBlockComment() -> EditorEditOutcome {
        guard !isInvalidated,
              let activeBuffer,
              activeBuffer.revision < .max,
              let primary = bufferViews[activeBuffer.bufferID],
              let selectionOwner = activeScintillaView,
              let delimiters = activeBlockCommentDelimiters(),
              primary.canToggleBlockComments(
                withStartUTF8: delimiters.start,
                endUTF8: delimiters.end,
                selectionOwner: selectionOwner
              ) else {
            return .rejected(currentRevision: activeBuffer?.revision ?? 0)
        }
        let oldRevision = activeBuffer.revision
        storeViewState(bufferID: activeBuffer.bufferID)
        guard primary.toggleBlockComments(
            withStartUTF8: delimiters.start,
            endUTF8: delimiters.end,
            selectionOwner: selectionOwner
        ) else {
            return .rejected(currentRevision: oldRevision)
        }
        guard let authoritative = self.activeBuffer,
              authoritative.bufferID == activeBuffer.bufferID,
              authoritative.revision == oldRevision + 1 else {
            return .rejected(currentRevision: self.activeBuffer?.revision ?? oldRevision)
        }
        return .accepted(newRevision: authoritative.revision)
    }

    public func selectedTextForFind(maximumUTF16Length: Int) -> String? {
        let limit = min(max(maximumUTF16Length, 0), 16383)
        guard limit > 0, let view = activeScintillaView, view.selectionCount == 1,
              let range = activeSelectionUTF8Range(), range.length > 0,
              range.length <= limit * 4,
              let bytes = try? view.utf8Bytes(in: NSRange(location: range.location, length: range.length)),
              let text = String(data: bytes, encoding: .utf8), text.utf16.count <= limit else { return nil }
        return text
    }

    public func activeSelectionUTF8Range() -> SearchUTF8Range? {
        guard let editorView = activeScintillaView else { return nil }
        let lower = min(editorView.anchorUTF8Position, editorView.caretUTF8Position)
        let upper = max(editorView.anchorUTF8Position, editorView.caretUTF8Position)
        return SearchUTF8Range(location: Int(clamping: lower), length: Int(clamping: upper - lower))
    }

    public func captureExtensionInput(
        tabID: TabID,
        expectedBuffer: EditorBufferDescriptor,
        scope: ExtensionCommandContribution.InputScope,
        maximumBytes: Int
    ) throws(ExtensionFailure) -> ExtensionEditorCapture {
        guard maximumBytes >= 0, activeBuffer == expectedBuffer,
              let editorView = activeScintillaView,
              editorView.revision == expectedBuffer.revision else { throw .staleContext }
        let documentLength = Int(clamping: editorView.documentByteLength)
        let selection = activeSelectionUTF8Range() ?? SearchUTF8Range(location: 0, length: 0)
        guard selection.location >= 0, selection.length >= 0,
              selection.location <= documentLength,
              selection.length <= documentLength - selection.location else { throw .staleContext }
        let bytes: Data
        switch scope {
        case .selection:
            guard selection.length > 0 else { throw .invalidResult("command requires a selection") }
            guard selection.length <= maximumBytes else { throw .limitExceeded("command input") }
            do {
                bytes = try editorView.utf8Bytes(in: NSRange(location: selection.location, length: selection.length))
            } catch let failure as ExtensionFailure {
                throw failure
            } catch {
                throw .invalidResult(String(describing: error))
            }
        case .document:
            guard documentLength <= maximumBytes else { throw .limitExceeded("command input") }
            bytes = editorView.contentUTF8
        }
        guard editorView.revision == expectedBuffer.revision else { throw .staleContext }
        return ExtensionEditorCapture(tabID: tabID, buffer: expectedBuffer, documentByteLength: documentLength, selection: selection, scopedUTF8: bytes)
    }

    public func findActive(_ request: ActiveSearchRequest) throws(SearchFailure) -> SearchUTF8Range? {
        guard let editorView = activeScintillaView else { return nil }
        let restriction = request.restrictTo.map {
            NSRange(location: $0.location, length: $0.length)
        } ?? NSRange(location: NSNotFound, length: 0)
        var failure: NSError?
        let range = editorView.searchUTF8(
            request.patternUTF8,
            backwards: request.direction == .backward,
            matchCase: request.matchCase,
            wholeWord: request.wholeWord,
            regularExpression: request.mode == .regularExpression,
            restrictTo: restriction,
            wrapAround: request.wrapAround,
            error: &failure
        )
        if let failure {
            if request.mode == .regularExpression {
                throw .invalidRegularExpression(failure.localizedDescription)
            }
            throw .invalidUTF8Range
        }
        guard range.location != NSNotFound else { return nil }
        return SearchUTF8Range(location: range.location, length: range.length)
    }

    public func selectAndReveal(_ range: SearchUTF8Range) {
        guard range.location >= 0, range.length >= 0 else { return }
        activeScintillaView?.setPrimarySelectionUTF8Range(
            NSRange(location: range.location, length: range.length)
        )
    }

    public func replaceActive(
        range: SearchUTF8Range,
        with replacementUTF8: Data,
        expectedRevision: UInt64
    ) -> EditorEditOutcome {
        guard !isInvalidated, let activeBuffer, let editorView = bufferViews[activeBuffer.bufferID],
              activeBuffer.revision == expectedRevision, expectedRevision < .max,
              range.location >= 0, range.length >= 0 else {
            return .rejected(currentRevision: activeBuffer?.revision ?? expectedRevision)
        }
        let generation = lifecycleGeneration
        captureGroupRecoveryViewStates(bufferID: activeBuffer.bufferID)
        do {
            try editorView.replaceUTF8Range(
                NSRange(location: range.location, length: range.length),
                withReplacement: replacementUTF8,
                expectedRevision: expectedRevision,
                resultingRevision: expectedRevision + 1
            )
        } catch {
            guard isCurrentLifecycle(generation) else {
                return .rejected(currentRevision: expectedRevision)
            }
            lastMutationError = error
            return .rejected(currentRevision: activeBuffer.revision)
        }
        guard isCurrentLifecycle(generation) else {
            return .rejected(currentRevision: expectedRevision)
        }
        guard let replacement = String(data: replacementUTF8, encoding: .utf8) else {
            scheduleRecovery(bufferID: activeBuffer.bufferID)
            return .rejected(currentRevision: activeBuffer.revision)
        }
        let edit = EditorIncrementalEdit(
            bufferID: activeBuffer.bufferID,
            expectedRevision: expectedRevision,
            range: TextEditRange(location: range.location, length: range.length),
            replacement: replacement
        )
        let outcome = withEditCallbackScope {
            onEdit?(edit) ?? .rejected(currentRevision: expectedRevision)
        }
        defer { finishDeferredEditorGroupCloseIfNeeded() }
        guard isCurrentLifecycle(generation) else { return outcome }
        guard case .accepted(let revision) = outcome, revision == expectedRevision + 1 else {
            scheduleRecovery(bufferID: activeBuffer.bufferID)
            return outcome
        }
        self.activeBuffer = EditorBufferDescriptor(bufferID: activeBuffer.bufferID, revision: revision)
        updateDisplayedRevision(revision, for: activeBuffer.bufferID)
        updateRevisionExhaustion(bufferID: activeBuffer.bufferID, revision: revision)
        synchronizeRevision(revision, for: activeBuffer.bufferID)
        acceptedEdits[activeBuffer.bufferID, default: []].append(edit)
        appendRecovery(edit, resultingRevision: revision)
        discardPendingFoldRecovery(bufferID: activeBuffer.bufferID)
        captureGroupRecoveryViewStates(bufferID: activeBuffer.bufferID)
        return outcome
    }

    public func replaceActiveBatch(
        _ replacements: [SearchReplacementEdit],
        expectedRevision: UInt64,
        accept: ([EditorIncrementalEdit]) -> EditorEditOutcome
    ) -> EditorEditOutcome {
        guard !isInvalidated, let activeBuffer, let editorView = bufferViews[activeBuffer.bufferID],
              activeBuffer.revision == expectedRevision,
              UInt64(replacements.count) <= UInt64.max - expectedRevision else {
            return .rejected(currentRevision: activeBuffer?.revision ?? expectedRevision)
        }
        let generation = lifecycleGeneration
        var revision = expectedRevision
        let edits: [EditorIncrementalEdit] = replacements.map { replacement in
            defer { revision += 1 }
            return EditorIncrementalEdit(
                bufferID: activeBuffer.bufferID,
                expectedRevision: revision,
                range: TextEditRange(location: replacement.range.location, length: replacement.range.length),
                replacement: String(decoding: replacement.replacementUTF8, as: UTF8.self)
            )
        }
        captureGroupRecoveryViewStates(bufferID: activeBuffer.bufferID)
        do {
            try editorView.replaceUTF8Ranges(
                replacements.map { NSValue(range: NSRange(location: $0.range.location, length: $0.range.length)) },
                withReplacements: replacements.map(\.replacementUTF8),
                expectedRevision: expectedRevision
            )
        } catch {
            guard isCurrentLifecycle(generation) else {
                return .rejected(currentRevision: expectedRevision)
            }
            lastMutationError = error
            return .rejected(currentRevision: activeBuffer.revision)
        }
        guard isCurrentLifecycle(generation) else {
            return .rejected(currentRevision: expectedRevision)
        }
        let outcome = withEditCallbackScope { accept(edits) }
        defer { finishDeferredEditorGroupCloseIfNeeded() }
        guard isCurrentLifecycle(generation) else { return outcome }
        guard case .accepted(let resultingRevision) = outcome,
              resultingRevision == expectedRevision + UInt64(edits.count) else {
            scheduleRecovery(bufferID: activeBuffer.bufferID)
            return outcome
        }
        self.activeBuffer = EditorBufferDescriptor(bufferID: activeBuffer.bufferID, revision: resultingRevision)
        updateDisplayedRevision(resultingRevision, for: activeBuffer.bufferID)
        updateRevisionExhaustion(bufferID: activeBuffer.bufferID, revision: resultingRevision)
        synchronizeRevision(resultingRevision, for: activeBuffer.bufferID)
        for edit in edits {
            acceptedEdits[activeBuffer.bufferID, default: []].append(edit)
            appendRecovery(edit, resultingRevision: edit.expectedRevision + 1)
        }
        discardPendingFoldRecovery(bufferID: activeBuffer.bufferID)
        captureGroupRecoveryViewStates(bufferID: activeBuffer.bufferID)
        return outcome
    }

    private func receive(_ bridgeEdit: DPScintillaEdit, bufferID: BufferID) {
        let pendingSmartCloser = isPendingSmartCloser(bridgeEdit, bufferID: bufferID)
        guard !isInvalidated, !isRecovering,
              bridgeEdit.baseRevision == currentRevision(for: bufferID),
              let replacement = String(data: bridgeEdit.replacementUTF8, encoding: .utf8) else {
            captureGroupRecoveryViewStates(bufferID: bufferID, preserveExisting: true)
            pendingRecoveryBuffers.insert(bufferID)
            if pendingSmartCloser { cancelPendingSmartIndentation(for: bufferID) }
            scheduleRecovery(bufferID: bufferID)
            return
        }
        let edit = EditorIncrementalEdit(
            bufferID: bufferID,
            expectedRevision: bridgeEdit.baseRevision,
            range: TextEditRange(
                location: bridgeEdit.range.location,
                length: bridgeEdit.range.length
            ),
            replacement: replacement
        )
        let generation = lifecycleGeneration
        let outcome = withEditCallbackScope {
            onEdit?(edit) ?? .rejected(currentRevision: bridgeEdit.baseRevision)
        }
        defer { finishDeferredEditorGroupCloseIfNeeded() }
        guard isCurrentLifecycle(generation) else { return }
        switch outcome {
        case .accepted(let newRevision) where newRevision == bridgeEdit.resultingRevision:
            if activeBuffer?.bufferID == bufferID {
                self.activeBuffer = EditorBufferDescriptor(bufferID: bufferID, revision: newRevision)
            }
            updateDisplayedRevision(newRevision, for: bufferID)
            updateRevisionExhaustion(bufferID: bufferID, revision: newRevision)
            synchronizeRevision(newRevision, for: bufferID)
            acceptedEdits[bufferID, default: []].append(edit)
            appendRecovery(edit, resultingRevision: newRevision)
            discardPendingFoldRecovery(bufferID: bufferID)
            captureGroupRecoveryViewStates(bufferID: bufferID)
        case .accepted, .rejected:
            captureGroupRecoveryViewStates(bufferID: bufferID, preserveExisting: true)
            pendingRecoveryBuffers.insert(bufferID)
            if pendingSmartCloser { cancelPendingSmartIndentation(for: bufferID) }
            scheduleRecovery(bufferID: bufferID)
        }
    }

    private func appendRecovery(_ edit: EditorIncrementalEdit, resultingRevision: UInt64) {
        guard !isInvalidated, var recovery = recoveryBuffers[edit.bufferID],
              recovery.revision == edit.expectedRevision,
              edit.range.location >= 0, edit.range.length >= 0,
              edit.range.location <= recovery.byteCount,
              edit.range.length <= recovery.byteCount - edit.range.location else {
            scheduleRecovery(bufferID: edit.bufferID)
            return
        }
        let replacement = Data(edit.replacement.utf8)
        recovery.deltas.append(EditorRecoveryDelta(
            expectedRevision: edit.expectedRevision,
            range: edit.range,
            replacementUTF8: replacement
        ))
        recovery.revision = resultingRevision
        recovery.byteCount = recovery.byteCount - edit.range.length + replacement.count
        recoveryBuffers[edit.bufferID] = recovery
        lastRecoveryJournalWorkByteCount = replacement.count + MemoryLayout<EditorRecoveryDelta>.stride
        recoveryJournalAppendCount += 1
    }

    private func storeSnapshot(bufferID: BufferID, revision: UInt64) {
        guard !isInvalidated, let editorView = bufferViews[bufferID],
              let text = String(data: editorView.contentUTF8, encoding: .utf8) else { return }
        snapshots[bufferID] = EditorTextSnapshot(bufferID: bufferID, revision: revision, text: text)
        let bytes = Data(text.utf8)
        recoveryBuffers[bufferID] = RecoveryBuffer(
            baseRevision: revision,
            revision: revision,
            baseUTF8: bytes,
            deltas: [],
            byteCount: bytes.count
        )
        acceptedEdits[bufferID] = []
    }

    @discardableResult
    private func recoverBuffer(_ bufferID: BufferID) -> Bool {
        guard !isInvalidated, let checkpoint = snapshots[bufferID],
              let snapshot = recoveredSnapshot(
                from: checkpoint,
                edits: acceptedEdits[bufferID, default: []]
              ), let editorView = bufferViews[bufferID] else { return false }
        load(snapshot, into: editorView)
        synchronizeRevision(snapshot.revision, for: bufferID, excluding: editorView)
        updateDisplayedRevision(snapshot.revision, for: bufferID)
        snapshots[bufferID] = snapshot
        let bytes = Data(snapshot.text.utf8)
        recoveryBuffers[bufferID] = RecoveryBuffer(
            baseRevision: snapshot.revision,
            revision: snapshot.revision,
            baseUTF8: bytes,
            deltas: [],
            byteCount: bytes.count
        )
        acceptedEdits[bufferID] = []
        updateRevisionExhaustion(bufferID: bufferID, revision: snapshot.revision)
        if activeBuffer?.bufferID == bufferID {
            self.activeBuffer = EditorBufferDescriptor(
                bufferID: bufferID,
                revision: snapshot.revision
            )
        }
        if hasVisibleGroups {
            let recoveryStates = pendingGroupRecoveryViewStates[bufferID] ?? [:]
            for editorView in groupViews(for: bufferID) {
                if let state = recoveryStates[ObjectIdentifier(editorView)] {
                    restoreViewState(state, in: editorView)
                }
                applyStoredLanguage(to: editorView, bufferID: bufferID)
            }
        } else if activeBuffer?.bufferID == bufferID {
            if let ownerView = canonicalOwnerView(for: bufferID) {
                restoreViewState(for: bufferID, in: ownerView)
                applyStoredLanguage(to: ownerView, bufferID: bufferID)
            }
            if !hasVisibleGroups, let secondary = secondaryBufferViews[bufferID],
               let secondaryState = viewStates[bufferID]?.secondaryViewState {
                restoreSecondaryViewState(secondaryState, in: secondary)
                applyStoredLanguage(to: secondary, bufferID: bufferID)
            }
        }
        pendingGroupRecoveryViewStates.removeValue(forKey: bufferID)
        let enabled = isInputEnabled(for: bufferID)
        allViews(for: bufferID).forEach { $0.isInputEnabled = enabled }
        return true
    }

    private func scheduleRecovery(bufferID: BufferID) {
        guard !isInvalidated else { return }
        if hasVisibleGroups, pendingGroupRecoveryViewStates[bufferID] == nil {
            captureGroupRecoveryViewStates(bufferID: bufferID)
        }
        let generation = lifecycleGeneration
        pendingRecoveryBuffers.insert(bufferID)
        bufferViews[bufferID]?.isInputEnabled = false
        secondaryBufferViews[bufferID]?.isInputEnabled = false
        groupPeerViews[bufferID]?.forEach { $0.isInputEnabled = false }
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.isCurrentLifecycle(generation) else { return }
            self.recoverPendingBufferIfNeeded(bufferID)
        }
    }

    @discardableResult
    private func recoverPendingBufferIfNeeded(_ bufferID: BufferID) -> Bool {
        guard !isInvalidated else { return false }
        guard pendingRecoveryBuffers.contains(bufferID) else { return true }
        guard recoverBuffer(bufferID) else { return false }
        pendingRecoveryBuffers.remove(bufferID)
        return true
    }

    private func isCurrentLifecycle(_ generation: UInt64) -> Bool {
        !isInvalidated && lifecycleGeneration == generation
    }

    private func preparePrimaryView(
        for buffer: EditorBufferDescriptor
    ) -> DPScintillaEditorView {
        let snapshot = snapshots[buffer.bufferID]
            ?? EditorTextSnapshot(bufferID: buffer.bufferID, revision: buffer.revision, text: "")
        snapshots[buffer.bufferID] = snapshots[buffer.bufferID] ?? snapshot
        if recoveryBuffers[buffer.bufferID] == nil {
            let bytes = Data(snapshot.text.utf8)
            recoveryBuffers[buffer.bufferID] = RecoveryBuffer(
                baseRevision: snapshot.revision,
                revision: snapshot.revision,
                baseUTF8: bytes,
                deltas: [],
                byteCount: bytes.count
            )
        }
        viewStates[buffer.bufferID] = viewStates[buffer.bufferID] ?? defaultViewState
        if let existing = bufferViews[buffer.bufferID] {
            return existing
        }
        let editorView = makeView(for: buffer.bufferID)
        bufferViews[buffer.bufferID] = editorView
        load(snapshot, into: editorView)
        return editorView
    }

    private func authoritativeDescriptor(
        for buffer: EditorBufferDescriptor
    ) -> EditorBufferDescriptor? {
        let hasStoredBuffer = snapshots[buffer.bufferID] != nil
            || recoveryBuffers[buffer.bufferID] != nil
            || bufferViews[buffer.bufferID] != nil
        guard hasStoredBuffer else { return buffer }
        let revision = currentRevision(for: buffer.bufferID)
        if revision == buffer.revision { return buffer }
        guard bufferViews[buffer.bufferID] == nil else { return nil }
        return EditorBufferDescriptor(bufferID: buffer.bufferID, revision: revision)
    }

    private func groupView(
        for bufferID: BufferID,
        group: EditorGroupID,
        publisher: DPScintillaEditorView
    ) -> DPScintillaEditorView {
        if let existing = bufferGroupViews[bufferID]?[group] {
            existing.synchronizeRevision(currentRevision(for: bufferID))
            return existing
        }
        let publisherIsAssigned = bufferGroupViews[bufferID]?.values.contains {
            $0 === publisher
        } ?? false
        let editorView: DPScintillaEditorView
        if publisherIsAssigned {
            if let existing = groupPeerViews[bufferID]?.first(where: { peer in
                !(bufferGroupViews[bufferID]?.values.contains { $0 === peer } ?? false)
            }) {
                editorView = existing
            } else {
                editorView = makeSharedGroupPeer(for: bufferID, publisher: publisher)
                groupPeerViews[bufferID, default: []].append(editorView)
            }
        } else {
            editorView = publisher
        }
        bufferGroupViews[bufferID, default: [:]][group] = editorView
        restoreViewState(for: bufferID, in: editorView)
        return editorView
    }

    private func makeSharedGroupPeer(
        for bufferID: BufferID,
        publisher: DPScintillaEditorView
    ) -> DPScintillaEditorView {
        let peer = DPScintillaEditorView(frame: secondaryGroupHost.bounds)
        applyDisplayPreferences(to: peer)
        documentIntelligenceContextIDs[ObjectIdentifier(peer)] = DocumentIntelligenceContextID()
        navigationContextIDs[ObjectIdentifier(peer)] = EditorNavigationContextID()
        peer.shareDocument(with: publisher)
        attachViewCallbacks(peer, bufferID: bufferID)
        peer.isInputEnabled = isInputEnabled(for: bufferID)
        applyStoredLanguage(to: peer, bufferID: bufferID)
        return peer
    }

    private func attach(_ editorView: DPScintillaEditorView, to group: EditorGroupID) {
        let host = editorGroupHost(for: group)
        guard displayedGroupViews[group] !== editorView || editorView.superview !== host else {
            return
        }
        for other in Array(displayedGroupViews.keys)
        where other != group && displayedGroupViews[other] === editorView {
            displayedGroupViews.removeValue(forKey: other)
            displayedGroupBuffers.removeValue(forKey: other)
        }
        displayedGroupViews[group]?.removeFromSuperview()
        editorView.removeFromSuperview()
        editorView.frame = host.bounds
        editorView.autoresizingMask = [.width, .height]
        host.addSubview(editorView)
        if group == .primary { primaryActiveView = editorView }
    }

    private func visibleGroup(containing editorView: DPScintillaEditorView) -> EditorGroupID? {
        guard hasVisibleGroups else { return nil }
        return displayedGroupViews.first { $0.value === editorView }?.key
    }

    private func canonicalOwnerView(for bufferID: BufferID) -> DPScintillaEditorView? {
        guard let owner = bufferOwners[bufferID] else { return bufferViews[bufferID] }
        return bufferGroupViews[bufferID]?[owner]
    }

    private func allViews(for bufferID: BufferID) -> [DPScintillaEditorView] {
        var identifiers: Set<ObjectIdentifier> = []
        return ([bufferViews[bufferID], secondaryBufferViews[bufferID]].compactMap { $0 } + (groupPeerViews[bufferID] ?? []))
            .filter { identifiers.insert(ObjectIdentifier($0)).inserted }
    }

    private func groupViews(for bufferID: BufferID) -> [DPScintillaEditorView] {
        var identifiers: Set<ObjectIdentifier> = []
        return Array(bufferGroupViews[bufferID]?.values ?? [:].values)
            .filter { identifiers.insert(ObjectIdentifier($0)).inserted }
    }

    private func captureGroupRecoveryViewStates(
        bufferID: BufferID,
        preserveExisting: Bool = false
    ) {
        guard hasVisibleGroups else { return }
        if preserveExisting, pendingGroupRecoveryViewStates[bufferID] != nil { return }
        var states: [ObjectIdentifier: EditorViewState] = [:]
        for editorView in groupViews(for: bufferID) {
            states[ObjectIdentifier(editorView)] = capturedGroupViewState(in: editorView)
        }
        guard !states.isEmpty else { return }
        pendingGroupRecoveryViewStates[bufferID] = states
        if let ownerView = canonicalOwnerView(for: bufferID),
           let ownerState = states[ObjectIdentifier(ownerView)] {
            preserveCanonicalGroupState(ownerState, bufferID: bufferID)
        }
    }

    private func capturedGroupViewState(in editorView: DPScintillaEditorView) -> EditorViewState {
        EditorViewState(
            anchorUTF8: Int(clamping: editorView.anchorUTF8Position),
            caretUTF8: Int(clamping: editorView.caretUTF8Position),
            firstVisibleLine: Int(clamping: editorView.firstVisibleLine),
            horizontalScrollOffset: Int(clamping: editorView.horizontalScrollOffset),
            wordWrapEnabled: editorView.isWordWrapEnabled,
            wrapMarkerVisible: editorView.isWrapMarkerVisible,
            whitespaceVisible: editorView.isWhitespaceVisible,
            lineEndingsVisible: editorView.areLineEndingsVisible,
            zoomLevel: Int(editorView.zoomLevel),
            bookmarkedLines: editorView.bookmarkedLines.map(\.intValue),
            foldState: capturedFoldState(in: editorView)
        )
    }

    private func preserveCanonicalGroupState(_ state: EditorViewState, bufferID: BufferID) {
        let preserved = viewStates[bufferID] ?? defaultViewState
        viewStates[bufferID] = EditorViewState(
            anchorUTF8: state.anchorUTF8,
            caretUTF8: state.caretUTF8,
            firstVisibleLine: state.firstVisibleLine,
            horizontalScrollOffset: state.horizontalScrollOffset,
            wordWrapEnabled: state.wordWrapEnabled,
            wrapMarkerVisible: state.wrapMarkerVisible,
            whitespaceVisible: state.whitespaceVisible,
            lineEndingsVisible: state.lineEndingsVisible,
            zoomLevel: state.zoomLevel,
            bookmarkedLines: state.bookmarkedLines,
            foldState: state.foldState,
            splitOrientation: preserved.splitOrientation,
            secondaryViewState: preserved.secondaryViewState
        )
    }

    private func currentRevision(for bufferID: BufferID) -> UInt64 {
        recoveryBuffers[bufferID]?.revision
            ?? snapshots[bufferID]?.revision
            ?? bufferViews[bufferID]?.revision
            ?? 0
    }

    private func updateDisplayedRevision(_ revision: UInt64, for bufferID: BufferID) {
        for group in Array(displayedGroupBuffers.keys)
        where displayedGroupBuffers[group]?.bufferID == bufferID {
            displayedGroupBuffers[group] = EditorBufferDescriptor(
                bufferID: bufferID,
                revision: revision
            )
        }
        if activeBuffer?.bufferID == bufferID {
            activeBuffer = EditorBufferDescriptor(bufferID: bufferID, revision: revision)
        }
    }

    private func synchronizeRevision(
        _ revision: UInt64,
        for bufferID: BufferID,
        excluding excludedView: DPScintillaEditorView? = nil
    ) {
        for editorView in allViews(for: bufferID) where editorView !== excludedView {
            editorView.synchronizeRevision(revision)
        }
    }

    private func closeEditorGroups(requestGeneration: UInt64) {
        guard requestGeneration == editorGroupLayoutRequestGeneration,
              hasVisibleGroups else { return }
        if editCallbackDepth > 0 {
            deferredEditorGroupCloseRequestGeneration = requestGeneration
            return
        }
        for bufferID in Array(pendingRecoveryBuffers) {
            guard recoverPendingBufferIfNeeded(bufferID) else { return }
        }
        deferredEditorGroupCloseRequestGeneration = nil
        scheduledEditorGroupCloseRequestGeneration = nil
        for bufferID in bufferOwners.keys where canonicalOwnerView(for: bufferID) != nil {
            storeViewState(bufferID: bufferID)
        }
        let focusedBuffer = activeBuffer.map {
            EditorBufferDescriptor(
                bufferID: $0.bufferID,
                revision: currentRevision(for: $0.bufferID)
            )
        }
        displayedGroupViews.values.forEach { $0.removeFromSuperview() }
        displayedGroupBuffers.removeAll()
        displayedGroupViews.removeAll()
        editorGroupOrientation = nil
        activeEditorGroup = .primary

        for peer in groupPeerViews.values.flatMap({ $0 }) {
            peer.cancelPendingSmartIndentation()
            discardViewIdentity(peer)
            peer.onWillModifyDocument = nil
            peer.onEdit = nil
            peer.onError = nil
            peer.onFocus = nil
            peer.onFoldStateChange = nil
            peer.onFoldRecoveryProgress = nil
            peer.onSmartIndentationStateChange = nil
            peer.removeFromSuperview()
            peer.invalidate()
        }
        groupPeerViews.removeAll()
        bufferGroupViews.removeAll()
        pendingGroupRecoveryViewStates.removeAll()
        for (bufferID, editorView) in bufferViews {
            bufferOwners[bufferID] = .primary
            bufferGroupViews[bufferID] = [.primary: editorView]
        }

        guard let focusedBuffer,
              let primary = bufferViews[focusedBuffer.bufferID] else {
            activeBuffer = nil
            primaryActiveView = nil
            return
        }
        activeBuffer = focusedBuffer
        displayedGroupBuffers[.primary] = focusedBuffer
        displayedGroupViews[.primary] = primary
        restoreViewState(for: focusedBuffer.bufferID, in: primary)
        applyStoredLanguage(to: primary, bufferID: focusedBuffer.bufferID)
        attach(primary, to: .primary)
        restoreSplitViewState(for: focusedBuffer.bufferID, primary: primary)
    }

    private func finishDeferredEditorGroupCloseIfNeeded() {
        guard editCallbackDepth == 0,
              let requestGeneration = deferredEditorGroupCloseRequestGeneration,
              requestGeneration == editorGroupLayoutRequestGeneration,
              scheduledEditorGroupCloseRequestGeneration != requestGeneration else { return }
        scheduledEditorGroupCloseRequestGeneration = requestGeneration
        let capturedLifecycleGeneration = lifecycleGeneration
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.isCurrentLifecycle(capturedLifecycleGeneration),
                  self.editCallbackDepth == 0,
                  self.editorGroupLayoutRequestGeneration == requestGeneration,
                  self.deferredEditorGroupCloseRequestGeneration == requestGeneration,
                  self.scheduledEditorGroupCloseRequestGeneration == requestGeneration else { return }
            self.closeEditorGroups(requestGeneration: requestGeneration)
        }
    }

    private func withEditCallbackScope<Result>(_ callback: () -> Result) -> Result {
        editCallbackDepth += 1
        defer { editCallbackDepth -= 1 }
        return callback()
    }

    private func makeView(for bufferID: BufferID) -> DPScintillaEditorView {
        let editorView = DPScintillaEditorView(frame: view.bounds)
        applyDisplayPreferences(to: editorView)
        documentIntelligenceContextIDs[ObjectIdentifier(editorView)] = DocumentIntelligenceContextID()
        navigationContextIDs[ObjectIdentifier(editorView)] = EditorNavigationContextID()
        editorView.onWillModifyDocument = { [weak self, weak editorView] in
            guard let self, let editorView,
                  self.bufferViews[bufferID] === editorView,
                  !self.pendingRecoveryBuffers.contains(bufferID) else { return }
            self.captureGroupRecoveryViewStates(bufferID: bufferID)
        }
        editorView.onEdit = { [weak self] edit in self?.receive(edit, bufferID: bufferID) }
        attachViewCallbacks(editorView, bufferID: bufferID)
        return editorView
    }

    private func attachViewCallbacks(_ editorView: DPScintillaEditorView, bufferID: BufferID) {
        editorView.onError = { [weak self] error in
            self?.receiveBridgeError(error, bufferID: bufferID)
        }
        editorView.onStatusChange = { [weak self, weak editorView] in
            guard let self, let editorView, self.activeScintillaView === editorView else { return }
            self.onEditorStatusChange?()
        }
        editorView.onFocus = { [weak self, weak editorView] in
            guard let self, let editorView,
                  self.isLive(editorView, for: bufferID) else { return }
            self.lastFocusedViewID = ObjectIdentifier(editorView)
            if let group = self.visibleGroup(containing: editorView) {
                self.activateEditorGroup(group)
                self.onEditorGroupFocus?(group)
            }
            self.onEditorStatusChange?()
        }
        editorView.onFoldStateChange = { [weak self, weak editorView] in
            guard let self, let editorView,
                  self.isLive(editorView, for: bufferID) else { return }
            if self.canonicalOwnerView(for: bufferID) === editorView {
                self.storeViewState(bufferID: bufferID)
            }
            self.onFoldStateChange?()
        }
        editorView.onFoldRecoveryProgress = { [weak self, weak editorView] in
            guard let self, let editorView,
                  self.isLive(editorView, for: bufferID) else { return }
            self.retryPendingFoldRecovery(in: editorView)
        }
        editorView.onSmartIndentationStateChange = { [weak self, weak editorView] isPending in
            guard let self, let editorView,
                  self.isLive(editorView, for: bufferID) else { return }
            let identifier = ObjectIdentifier(editorView)
            if isPending {
                self.captureGroupRecoveryViewStates(bufferID: bufferID)
                self.storeViewState(bufferID: bufferID)
                self.pendingSmartIndentationViewIDs[bufferID] = identifier
            } else if self.pendingSmartIndentationViewIDs[bufferID] == identifier {
                self.pendingSmartIndentationViewIDs.removeValue(forKey: bufferID)
                if !self.pendingRecoveryBuffers.contains(bufferID) {
                    self.pendingGroupRecoveryViewStates.removeValue(forKey: bufferID)
                }
            }
        }
    }

    private func isLive(_ editorView: DPScintillaEditorView, for bufferID: BufferID) -> Bool {
        bufferViews[bufferID] === editorView
            || secondaryBufferViews[bufferID] === editorView
            || (groupPeerViews[bufferID]?.contains { $0 === editorView } ?? false)
    }

    private func pendingSmartIndentationView(for bufferID: BufferID) -> DPScintillaEditorView? {
        guard let identifier = pendingSmartIndentationViewIDs[bufferID] else { return nil }
        if let primary = bufferViews[bufferID], ObjectIdentifier(primary) == identifier {
            return primary
        }
        if let secondary = secondaryBufferViews[bufferID], ObjectIdentifier(secondary) == identifier {
            return secondary
        }
        if let peer = groupPeerViews[bufferID]?.first(where: { ObjectIdentifier($0) == identifier }) {
            return peer
        }
        pendingSmartIndentationViewIDs.removeValue(forKey: bufferID)
        return nil
    }

    private func isPendingSmartCloser(_ edit: DPScintillaEdit, bufferID: BufferID) -> Bool {
        guard pendingSmartIndentationView(for: bufferID) != nil,
              edit.range.length == 0,
              edit.replacementUTF8.count == 1,
              let byte = edit.replacementUTF8.first else {
            return false
        }
        return byte == 0x7D || byte == 0x5D || byte == 0x29
    }

    private func cancelPendingSmartIndentation(for bufferID: BufferID) {
        guard let editorView = pendingSmartIndentationView(for: bufferID) else { return }
        editorView.cancelPendingSmartIndentation()
    }

    private func discardViewIdentity(_ editorView: DPScintillaEditorView) {
        let identifier = ObjectIdentifier(editorView)
        documentIntelligenceContextIDs.removeValue(forKey: identifier)
        navigationContextIDs.removeValue(forKey: identifier)
        pendingFoldRecoveryByView.removeValue(forKey: identifier)
        pendingSmartIndentationViewIDs = pendingSmartIndentationViewIDs.filter { $0.value != identifier }
        pendingGroupRecoveryViewStates = pendingGroupRecoveryViewStates.reduce(into: [:]) {
            var states = $1.value
            states.removeValue(forKey: identifier)
            if !states.isEmpty { $0[$1.key] = states }
        }
        if lastFocusedViewID == identifier { lastFocusedViewID = nil }
    }

    private func setPendingFoldRecovery(
        _ state: FoldRecoveryState,
        for editorView: DPScintillaEditorView
    ) {
        let identifier = ObjectIdentifier(editorView)
        if state.contractedHeaderLines.isEmpty {
            pendingFoldRecoveryByView.removeValue(forKey: identifier)
        } else {
            pendingFoldRecoveryByView[identifier] = state
        }
    }

    private func retryPendingFoldRecovery(in editorView: DPScintillaEditorView) {
        let identifier = ObjectIdentifier(editorView)
        guard editorView.configuredFoldingEnabled,
              let pending = pendingFoldRecoveryByView[identifier] else {
            _ = editorView.restoreContractedFoldHeaderLines([])
            pendingFoldRecoveryByView.removeValue(forKey: identifier)
            return
        }
        let unresolved = editorView.restoreContractedFoldHeaderLines(
            pending.contractedHeaderLines.map { NSNumber(value: $0) }
        )
        setPendingFoldRecovery(
            FoldRecoveryState(contractedHeaderLines: unresolved.map(\.intValue)),
            for: editorView
        )
    }

    private func capturedFoldState(in editorView: DPScintillaEditorView) -> FoldRecoveryState {
        let native = editorView
            .contractedFoldHeaderLines(maximumCount: UInt(FoldRecoveryState.maximumContractedHeaderCount))
            .map(\.intValue)
        let pending = pendingFoldRecoveryByView[ObjectIdentifier(editorView)]?
            .contractedHeaderLines ?? []
        return FoldRecoveryState(contractedHeaderLines: native + pending)
    }

    private func discardPendingFoldRecovery(bufferID: BufferID) {
        for editorView in allViews(for: bufferID) {
            pendingFoldRecoveryByView.removeValue(forKey: ObjectIdentifier(editorView))
            _ = editorView.restoreContractedFoldHeaderLines([])
        }
        storeViewState(bufferID: bufferID)
    }

    private func attachSecondaryView(for bufferID: BufferID, primary: DPScintillaEditorView) {
        secondaryActiveView?.removeFromSuperview()
        let secondary: DPScintillaEditorView
        if let existing = secondaryBufferViews[bufferID] {
            secondary = existing
        } else {
            secondary = DPScintillaEditorView(frame: internalSecondaryHost.bounds)
            applyDisplayPreferences(to: secondary)
            documentIntelligenceContextIDs[ObjectIdentifier(secondary)] = DocumentIntelligenceContextID()
            navigationContextIDs[ObjectIdentifier(secondary)] = EditorNavigationContextID()
            secondary.shareDocument(with: primary)
            attachViewCallbacks(secondary, bufferID: bufferID)
            secondaryBufferViews[bufferID] = secondary
            applyStoredLanguage(to: secondary, bufferID: bufferID)
        }
        secondary.synchronizeRevision(primary.revision)
        secondary.frame = internalSecondaryHost.bounds
        secondary.autoresizingMask = [.width, .height]
        secondary.isInputEnabled = isInputEnabled(for: bufferID)
        internalSecondaryHost.addSubview(secondary)
        secondaryActiveView = secondary
    }

    private func receiveBridgeError(_ error: Error, bufferID: BufferID) {
        lastMutationError = error
        let native = error as NSError
        if native.domain == DPScintillaErrorDomain,
           bufferViews[bufferID]?.revision == UInt64.max {
            revisionExhaustedBuffers.insert(bufferID)
            bufferViews[bufferID]?.isInputEnabled = false
            secondaryBufferViews[bufferID]?.isInputEnabled = false
            groupPeerViews[bufferID]?.forEach { $0.isInputEnabled = false }
        }
    }

    private func updateRevisionExhaustion(bufferID: BufferID, revision: UInt64) {
        if revision == .max {
            revisionExhaustedBuffers.insert(bufferID)
        } else {
            revisionExhaustedBuffers.remove(bufferID)
        }
    }

    private func isInputEnabled(for bufferID: BufferID) -> Bool {
        inputEnabled && !revisionExhaustedBuffers.contains(bufferID)
    }

    private func configureSplit(
        orientation: EditorSplitOrientation,
        bufferID: BufferID,
        primary: DPScintillaEditorView
    ) {
        splitOrientation = orientation
        splitView.isVertical = orientation == .sideBySide
        if internalSecondaryHost.superview == nil { splitView.addArrangedSubview(internalSecondaryHost) }
        attachSecondaryView(for: bufferID, primary: primary)
        splitView.adjustSubviews()
    }

    private func hideSplit(focusPrimary: Bool) {
        let releasedSecondary = secondaryActiveView
        releasedSecondary?.cancelPendingSmartIndentation()
        if let releasedSecondary {
            discardViewIdentity(releasedSecondary)
        }
        releasedSecondary?.onEdit = nil
        releasedSecondary?.onWillModifyDocument = nil
        releasedSecondary?.onError = nil
        releasedSecondary?.onFocus = nil
        releasedSecondary?.onFoldStateChange = nil
        releasedSecondary?.onFoldRecoveryProgress = nil
        releasedSecondary?.onSmartIndentationStateChange = nil
        releasedSecondary?.removeFromSuperview()
        if let bufferID = activeBuffer?.bufferID,
           let releasedSecondary,
           secondaryBufferViews[bufferID] === releasedSecondary {
            secondaryBufferViews.removeValue(forKey: bufferID)
        }
        releasedSecondary?.invalidate()
        secondaryActiveView = nil
        if internalSecondaryHost.superview != nil {
            splitView.removeArrangedSubview(internalSecondaryHost)
            internalSecondaryHost.removeFromSuperview()
        }
        splitOrientation = nil
        if focusPrimary { primaryActiveView?.focusEditor() }
    }

    private func restoreSplitViewState(for bufferID: BufferID, primary: DPScintillaEditorView) {
        guard !hasVisibleGroups,
              let state = viewStates[bufferID],
              let orientation = state.splitOrientation,
              let secondaryState = state.secondaryViewState else { return }
        configureSplit(orientation: orientation, bufferID: bufferID, primary: primary)
        guard let secondary = secondaryActiveView else { return }
        restoreSecondaryViewState(secondaryState, in: secondary)
        if secondary.configuredFoldingEnabled { retryPendingFoldRecovery(in: secondary) }
    }

    private func restoreSecondaryViewState(
        _ state: SecondaryEditorViewState,
        in editorView: DPScintillaEditorView
    ) {
        editorView.restoreCaretUTF8Position(
            UInt(clamping: state.caretUTF8),
            anchorPosition: UInt(clamping: state.anchorUTF8),
            firstVisibleLine: UInt(clamping: state.firstVisibleLine),
            horizontalScrollOffset: UInt(clamping: state.horizontalScrollOffset),
            wordWrapEnabled: state.wordWrapEnabled
        )
        editorView.isWrapMarkerVisible = state.wrapMarkerVisible
        editorView.isWhitespaceVisible = state.whitespaceVisible
        editorView.areLineEndingsVisible = state.lineEndingsVisible
        editorView.zoomLevel = state.zoomLevel
        setPendingFoldRecovery(state.foldState, for: editorView)
    }

    private func applyStoredLanguage(to editorView: DPScintillaEditorView, bufferID: BufferID) {
        let storedConfiguration = languageConfigurations[bufferID]
        let configuration = storedConfiguration ?? EditorLanguageConfiguration(
            languageID: .plainText, lexerName: "null", indentation: .init(),
            folding: false, braceMatching: false
        )
        let applied = editorView.applyLexerNamed(
            configuration.lexerName, keywords: configuration.keywords,
            tabWidth: UInt(configuration.indentation.width),
            useTabs: configuration.indentation.useTabs,
            folding: configuration.folding,
            braceMatching: configuration.braceMatching,
            maximumStyleBytes: UInt(configuration.maximumStyleBytes)
        )
        applyIndentationPreferences(to: editorView, indentation: configuration.indentation)
        editorView.apply(nativePalette(themePalette))
        guard applied, storedConfiguration != nil else { return }
        if editorView.configuredFoldingEnabled {
            retryPendingFoldRecovery(in: editorView)
        } else {
            pendingFoldRecoveryByView.removeValue(forKey: ObjectIdentifier(editorView))
        }
    }

    private func activeBlockCommentDelimiters() -> (start: Data, end: Data)? {
        guard let bufferID = activeBuffer?.bufferID,
              let comments = languageConfigurations[bufferID]?.comments,
              let start = comments.blockStart,
              let end = comments.blockEnd else {
            return nil
        }
        return (Data(start.utf8), Data(end.utf8))
    }

    private func nativePalette(_ palette: EditorThemePalette) -> DPScintillaPalette {
        switch palette {
        case .light: .light
        case .dark: .dark
        case .highContrastLight: .highContrastLight
        case .highContrastDark: .highContrastDark
        }
    }

    private func storeViewState(bufferID: BufferID) {
        guard let editorView = canonicalOwnerView(for: bufferID) else { return }
        storeViewState(bufferID: bufferID, using: editorView)
    }

    private func storeViewState(bufferID: BufferID, using editorView: DPScintillaEditorView) {
        let preserved = viewStates[bufferID] ?? defaultViewState
        let capturesRenderedInternalSplit = !hasVisibleGroups
            && activeBuffer?.bufferID == bufferID
            && splitOrientation != nil
            && secondaryBufferViews[bufferID] === secondaryActiveView
        let secondaryState = capturesRenderedInternalSplit
            ? secondaryActiveView.map(capturedSecondaryViewState)
            : preserved.secondaryViewState
        let storedSplitOrientation = capturesRenderedInternalSplit
            ? splitOrientation
            : preserved.splitOrientation
        viewStates[bufferID] = EditorViewState(
            anchorUTF8: Int(clamping: editorView.anchorUTF8Position),
            caretUTF8: Int(clamping: editorView.caretUTF8Position),
            firstVisibleLine: Int(clamping: editorView.firstVisibleLine),
            horizontalScrollOffset: Int(clamping: editorView.horizontalScrollOffset),
            wordWrapEnabled: editorView.isWordWrapEnabled,
            wrapMarkerVisible: editorView.isWrapMarkerVisible,
            whitespaceVisible: editorView.isWhitespaceVisible,
            lineEndingsVisible: editorView.areLineEndingsVisible,
            zoomLevel: Int(editorView.zoomLevel),
            bookmarkedLines: editorView.bookmarkedLines.map(\.intValue),
            foldState: capturedFoldState(in: editorView),
            splitOrientation: storedSplitOrientation,
            secondaryViewState: secondaryState
        )
    }

    private func capturedSecondaryViewState(
        _ editorView: DPScintillaEditorView
    ) -> SecondaryEditorViewState {
        SecondaryEditorViewState(
            anchorUTF8: Int(clamping: editorView.anchorUTF8Position),
            caretUTF8: Int(clamping: editorView.caretUTF8Position),
            firstVisibleLine: Int(clamping: editorView.firstVisibleLine),
            horizontalScrollOffset: Int(clamping: editorView.horizontalScrollOffset),
            wordWrapEnabled: editorView.isWordWrapEnabled,
            wrapMarkerVisible: editorView.isWrapMarkerVisible,
            whitespaceVisible: editorView.isWhitespaceVisible,
            lineEndingsVisible: editorView.areLineEndingsVisible,
            zoomLevel: Int(editorView.zoomLevel),
            foldState: capturedFoldState(in: editorView)
        )
    }

    private func restoreViewState(for bufferID: BufferID, in editorView: DPScintillaEditorView) {
        let state = viewStates[bufferID] ?? EditorViewState()
        restoreViewState(state, in: editorView)
    }

    private func restoreViewState(_ state: EditorViewState, in editorView: DPScintillaEditorView) {
        editorView.restoreCaretUTF8Position(
            UInt(clamping: state.caretUTF8),
            anchorPosition: UInt(clamping: state.anchorUTF8),
            firstVisibleLine: UInt(clamping: state.firstVisibleLine),
            horizontalScrollOffset: UInt(clamping: state.horizontalScrollOffset),
            wordWrapEnabled: state.wordWrapEnabled
        )
        editorView.isWrapMarkerVisible = state.wrapMarkerVisible
        editorView.isWhitespaceVisible = state.whitespaceVisible
        editorView.areLineEndingsVisible = state.lineEndingsVisible
        editorView.zoomLevel = state.zoomLevel
        editorView.restoreBookmarkedLines(state.bookmarkedLines.map { NSNumber(value: $0) })
        setPendingFoldRecovery(state.foldState, for: editorView)
    }

    private func sanitized(_ state: EditorViewState, for utf8: Data) -> EditorViewState {
        func boundary(_ value: Int) -> Int {
            var offset = min(max(value, 0), utf8.count)
            while offset > 0, offset < utf8.count, (utf8[offset] & 0xC0) == 0x80 {
                offset -= 1
            }
            return offset
        }
        let maximumLine = lineCount(in: utf8)
        let secondary = state.secondaryViewState.map {
            SecondaryEditorViewState(
                anchorUTF8: boundary($0.anchorUTF8),
                caretUTF8: boundary($0.caretUTF8),
                firstVisibleLine: max(0, $0.firstVisibleLine),
                horizontalScrollOffset: max(0, $0.horizontalScrollOffset),
                wordWrapEnabled: $0.wordWrapEnabled,
                wrapMarkerVisible: $0.wrapMarkerVisible,
                whitespaceVisible: $0.whitespaceVisible,
                lineEndingsVisible: $0.lineEndingsVisible,
                zoomLevel: $0.zoomLevel,
                foldState: FoldRecoveryState(
                    contractedHeaderLines: $0.foldState.contractedHeaderLines.filter { $0 < maximumLine }
                )
            )
        }
        return EditorViewState(
            anchorUTF8: boundary(state.anchorUTF8),
            caretUTF8: boundary(state.caretUTF8),
            firstVisibleLine: max(0, state.firstVisibleLine),
            horizontalScrollOffset: max(0, state.horizontalScrollOffset),
            wordWrapEnabled: state.wordWrapEnabled,
            wrapMarkerVisible: state.wrapMarkerVisible,
            whitespaceVisible: state.whitespaceVisible,
            lineEndingsVisible: state.lineEndingsVisible,
            zoomLevel: state.zoomLevel,
            bookmarkedLines: state.bookmarkedLines.filter { $0 < maximumLine },
            foldState: FoldRecoveryState(
                contractedHeaderLines: state.foldState.contractedHeaderLines.filter { $0 < maximumLine }
            ),
            splitOrientation: secondary == nil ? nil : state.splitOrientation,
            secondaryViewState: secondary
        )
    }

    private func lineCount(in utf8: Data) -> Int {
        var count = 1
        var index = 0
        while index < utf8.count {
            if utf8[index] == 0x0D {
                count += 1
                if index + 1 < utf8.count, utf8[index + 1] == 0x0A { index += 1 }
            } else if utf8[index] == 0x0A {
                count += 1
            }
            index += 1
        }
        return count
    }

    /// Replays only accepted bounded deltas if a later edit must be rejected.
    /// This is intentionally off the normal keystroke path.
    private func recoveredSnapshot(
        from checkpoint: EditorTextSnapshot,
        edits: [EditorIncrementalEdit]
    ) -> EditorTextSnapshot? {
        var bytes = Data(checkpoint.text.utf8)
        var revision = checkpoint.revision
        for edit in edits {
            guard edit.expectedRevision == revision,
                  edit.range.location >= 0,
                  edit.range.length >= 0,
                  edit.range.location <= bytes.count,
                  edit.range.length <= bytes.count - edit.range.location,
                  revision < .max else { return nil }
            let start = edit.range.location
            let end = start + edit.range.length
            bytes.replaceSubrange(start..<end, with: edit.replacement.utf8)
            revision += 1
        }
        guard let text = String(data: bytes, encoding: .utf8) else { return nil }
        return EditorTextSnapshot(bufferID: checkpoint.bufferID, revision: revision, text: text)
    }

    private func load(_ snapshot: EditorTextSnapshot, into editorView: DPScintillaEditorView) {
        cancelPendingSmartIndentation(for: snapshot.bufferID)
        isRecovering = true
        defer { isRecovering = false }
        try? editorView.loadUTF8(Data(snapshot.text.utf8), revision: snapshot.revision)
    }
}
