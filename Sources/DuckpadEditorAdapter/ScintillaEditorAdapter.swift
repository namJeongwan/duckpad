import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadScintillaBridge

/// Production editor adapter. Scintilla owns live text; Application owns only
/// buffer identity/revision/dirty metadata.
@MainActor
public final class ScintillaEditorAdapter: SearchEditorPort, LanguageEditorPort, ExtensionEditorPort, EditorDefaultViewOptionsPort, EditorDisplayOptionsPort, EditorNavigationPort, EditorCommandPort, BookmarkEditorPort, SplitEditorPort, DocumentIntelligenceEditorPort {
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
    public var activeScintillaView: DPScintillaEditorView? {
        if splitOrientation != nil, let secondaryActiveView, secondaryActiveView.hasEditorFocus {
            return secondaryActiveView
        }
        return primaryActiveView
    }
    public var secondaryScintillaView: DPScintillaEditorView? { secondaryActiveView }
    public private(set) var lastMutationError: (any Error)?
    public private(set) var lastRecoveryJournalWorkByteCount = 0
    public private(set) var recoveryJournalAppendCount = 0
    public var onEdit: ((EditorIncrementalEdit) -> EditorEditOutcome)?

    private var activeBuffer: EditorBufferDescriptor?
    private var snapshots: [BufferID: EditorTextSnapshot] = [:]
    private var recoveryBuffers: [BufferID: RecoveryBuffer] = [:]
    private var viewStates: [BufferID: EditorViewState] = [:]
    private var acceptedEdits: [BufferID: [EditorIncrementalEdit]] = [:]
    private var bufferViews: [BufferID: DPScintillaEditorView] = [:]
    private var secondaryBufferViews: [BufferID: DPScintillaEditorView] = [:]
    private var documentIntelligenceContextIDs: [ObjectIdentifier: DocumentIntelligenceContextID] = [:]
    private var navigationContextIDs: [ObjectIdentifier: EditorNavigationContextID] = [:]
    private let splitView = NSSplitView(frame: .zero)
    private let primaryHost = NSView(frame: .zero)
    private let secondaryHost = NSView(frame: .zero)
    private var primaryActiveView: DPScintillaEditorView?
    private var secondaryActiveView: DPScintillaEditorView?
    public private(set) var splitOrientation: EditorSplitOrientation?
    private var languageConfigurations: [BufferID: EditorLanguageConfiguration] = [:]
    private var pendingRecoveryBuffers: Set<BufferID> = []
    private var revisionExhaustedBuffers: Set<BufferID> = []
    private var themePalette: EditorThemePalette = .light
    private var defaultViewState: EditorViewState
    private var isRecovering = false
    private var inputEnabled = true

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
        primaryHost.setAccessibilityLabel("Primary editor pane")
        secondaryHost.setAccessibilityLabel("Secondary editor pane")
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setAccessibilityIdentifier("duckpad.editor.host")
    }

    public func display(_ buffer: EditorBufferDescriptor) {
        if let outgoingBufferID = activeBuffer?.bufferID {
            guard recoverPendingBufferIfNeeded(outgoingBufferID) else { return }
        }
        guard recoverPendingBufferIfNeeded(buffer.bufferID) else { return }
        if activeBuffer == buffer { return }
        if let activeBuffer {
            storeViewState(bufferID: activeBuffer.bufferID)
            storeSnapshot(bufferID: activeBuffer.bufferID, revision: activeBuffer.revision)
        }
        hideSplit(focusPrimary: false)
        let stored = snapshots[buffer.bufferID]
            ?? EditorTextSnapshot(bufferID: buffer.bufferID, revision: buffer.revision, text: "")
        let snapshot = EditorTextSnapshot(
            bufferID: buffer.bufferID,
            revision: buffer.revision,
            text: stored.text
        )
        snapshots[buffer.bufferID] = snapshot
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
        activeBuffer = buffer
        let editorView: DPScintillaEditorView
        if let existing = bufferViews[buffer.bufferID] {
            editorView = existing
            if existing.revision != buffer.revision { load(snapshot, into: existing) }
        } else {
            editorView = makeView(for: buffer.bufferID)
            bufferViews[buffer.bufferID] = editorView
            load(snapshot, into: editorView)
        }
        restoreViewState(for: buffer.bufferID, in: editorView)
        applyStoredLanguage(to: editorView, bufferID: buffer.bufferID)
        primaryActiveView?.removeFromSuperview()
        primaryActiveView = editorView
        editorView.frame = primaryHost.bounds
        editorView.autoresizingMask = [.width, .height]
        editorView.isInputEnabled = isInputEnabled(for: buffer.bufferID)
        primaryHost.addSubview(editorView)
        restoreSplitViewState(for: buffer.bufferID, primary: editorView)
    }

    public func install(_ snapshot: EditorTextSnapshot) {
        pendingRecoveryBuffers.remove(snapshot.bufferID)
        updateRevisionExhaustion(bufferID: snapshot.bufferID, revision: snapshot.revision)
        if activeBuffer?.bufferID == snapshot.bufferID { storeViewState(bufferID: snapshot.bufferID) }
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
        secondaryBufferViews[snapshot.bufferID]?.synchronizeRevision(snapshot.revision)
        if activeBuffer?.bufferID == snapshot.bufferID {
            activeBuffer = EditorBufferDescriptor(bufferID: snapshot.bufferID, revision: snapshot.revision)
            restoreViewState(for: snapshot.bufferID, in: editorView)
        }
    }

    public func snapshot(for bufferID: BufferID) -> EditorTextSnapshot? {
        guard recoverPendingBufferIfNeeded(bufferID) else { return snapshots[bufferID] }
        if let activeBuffer, activeBuffer.bufferID == bufferID {
            storeSnapshot(bufferID: bufferID, revision: activeBuffer.revision)
        }
        return snapshots[bufferID]
    }

    public func recoverySnapshot(for bufferID: BufferID) -> EditorRecoverySnapshot? {
        try? recoveryCapture(for: bufferID)?.materializedSnapshot()
    }

    public func recoveryCapture(for bufferID: BufferID) -> EditorRecoveryCapture? {
        guard recoverPendingBufferIfNeeded(bufferID) else { return nil }
        if activeBuffer?.bufferID == bufferID { storeViewState(bufferID: bufferID) }
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
        guard let text = String(data: snapshot.utf8, encoding: .utf8) else { return }
        let recoveredViewState = sanitized(snapshot.viewState, for: snapshot.utf8)
        install(EditorTextSnapshot(bufferID: snapshot.bufferID, revision: snapshot.revision, text: text))
        viewStates[snapshot.bufferID] = recoveredViewState
        if let editorView = bufferViews[snapshot.bufferID] {
            restoreViewState(for: snapshot.bufferID, in: editorView)
            if activeBuffer?.bufferID == snapshot.bufferID {
                hideSplit(focusPrimary: false)
                restoreSplitViewState(for: snapshot.bufferID, primary: editorView)
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
        let retiredView = bufferViews.removeValue(forKey: bufferID)
        if let retiredView {
            documentIntelligenceContextIDs.removeValue(forKey: ObjectIdentifier(retiredView))
            navigationContextIDs.removeValue(forKey: ObjectIdentifier(retiredView))
        }
        retiredView?.onEdit = nil
        retiredView?.removeFromSuperview()
        retiredView?.invalidate()
        let retiredSecondary = secondaryBufferViews.removeValue(forKey: bufferID)
        if let retiredSecondary {
            documentIntelligenceContextIDs.removeValue(forKey: ObjectIdentifier(retiredSecondary))
            navigationContextIDs.removeValue(forKey: ObjectIdentifier(retiredSecondary))
        }
        retiredSecondary?.onEdit = nil
        retiredSecondary?.removeFromSuperview()
        retiredSecondary?.invalidate()
        guard activeBuffer?.bufferID == bufferID else { return }
        activeBuffer = nil
        primaryActiveView = nil
        secondaryActiveView = nil
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
        view.alphaValue = isEnabled ? 1 : 0.65
    }

    public func focus() { activeScintillaView?.focusEditor() }

    public func split(orientation: EditorSplitOrientation) {
        guard let activeBuffer, let primary = primaryActiveView else { return }
        configureSplit(orientation: orientation, bufferID: activeBuffer.bufferID, primary: primary)
        storeViewState(bufferID: activeBuffer.bufferID)
        secondaryActiveView?.focusEditor()
    }

    public func closeSplit() {
        guard splitOrientation != nil, let bufferID = activeBuffer?.bufferID else { return }
        storeViewState(bufferID: bufferID)
        var state = viewStates[bufferID] ?? EditorViewState()
        state.splitOrientation = nil
        state.secondaryViewState = nil
        viewStates[bufferID] = state
        hideSplit(focusPrimary: true)
    }

    public func focusOtherPane() {
        guard splitOrientation != nil, let primaryActiveView, let secondaryActiveView else { return }
        (secondaryActiveView.hasEditorFocus ? primaryActiveView : secondaryActiveView).focusEditor()
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
        if let bufferID = activeBuffer?.bufferID { storeViewState(bufferID: bufferID) }
        return true
    }

    @discardableResult
    public func goTo(utf8Offset: Int, in contextID: EditorNavigationContextID) -> Bool {
        guard utf8Offset >= 0, let editorView = navigationView(for: contextID),
              editorView.go(toUTF8Offset: UInt(utf8Offset)) else { return false }
        editorView.focusEditor()
        if let bufferID = activeBuffer?.bufferID { storeViewState(bufferID: bufferID) }
        return true
    }

    private func navigationView(for contextID: EditorNavigationContextID) -> DPScintillaEditorView? {
        for editorView in [primaryActiveView, secondaryActiveView].compactMap({ $0 })
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
              let primary = primaryActiveView,
              supportsLexer(named: configuration.lexerName) else { return false }
        let editorViews = [primary] + [secondaryActiveView].compactMap { $0 }
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
            editorView.apply(nativePalette(themePalette))
        }
        languageConfigurations[bufferID] = configuration
        return true
    }

    public func applyTheme(_ palette: EditorThemePalette) {
        themePalette = palette
        let native = nativePalette(palette)
        bufferViews.values.forEach { $0.apply(native) }
        secondaryBufferViews.values.forEach { $0.apply(native) }
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
        guard let activeBuffer, let editorView = primaryActiveView,
              activeBuffer.revision == expectedRevision, expectedRevision < .max,
              range.location >= 0, range.length >= 0 else {
            return .rejected(currentRevision: activeBuffer?.revision ?? expectedRevision)
        }
        do {
            try editorView.replaceUTF8Range(
                NSRange(location: range.location, length: range.length),
                withReplacement: replacementUTF8,
                expectedRevision: expectedRevision,
                resultingRevision: expectedRevision + 1
            )
        } catch {
            lastMutationError = error
            return .rejected(currentRevision: activeBuffer.revision)
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
        let outcome = onEdit?(edit) ?? .rejected(currentRevision: expectedRevision)
        guard case .accepted(let revision) = outcome, revision == expectedRevision + 1 else {
            scheduleRecovery(bufferID: activeBuffer.bufferID)
            return outcome
        }
        self.activeBuffer = EditorBufferDescriptor(bufferID: activeBuffer.bufferID, revision: revision)
        updateRevisionExhaustion(bufferID: activeBuffer.bufferID, revision: revision)
        secondaryActiveView?.synchronizeRevision(revision)
        acceptedEdits[activeBuffer.bufferID, default: []].append(edit)
        appendRecovery(edit, resultingRevision: revision)
        return outcome
    }

    public func replaceActiveBatch(
        _ replacements: [SearchReplacementEdit],
        expectedRevision: UInt64,
        accept: ([EditorIncrementalEdit]) -> EditorEditOutcome
    ) -> EditorEditOutcome {
        guard let activeBuffer, let editorView = primaryActiveView,
              activeBuffer.revision == expectedRevision,
              UInt64(replacements.count) <= UInt64.max - expectedRevision else {
            return .rejected(currentRevision: activeBuffer?.revision ?? expectedRevision)
        }
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
        do {
            try editorView.replaceUTF8Ranges(
                replacements.map { NSValue(range: NSRange(location: $0.range.location, length: $0.range.length)) },
                withReplacements: replacements.map(\.replacementUTF8),
                expectedRevision: expectedRevision
            )
        } catch {
            lastMutationError = error
            return .rejected(currentRevision: activeBuffer.revision)
        }
        let outcome = accept(edits)
        guard case .accepted(let resultingRevision) = outcome,
              resultingRevision == expectedRevision + UInt64(edits.count) else {
            scheduleRecovery(bufferID: activeBuffer.bufferID)
            return outcome
        }
        self.activeBuffer = EditorBufferDescriptor(bufferID: activeBuffer.bufferID, revision: resultingRevision)
        updateRevisionExhaustion(bufferID: activeBuffer.bufferID, revision: resultingRevision)
        secondaryActiveView?.synchronizeRevision(resultingRevision)
        for edit in edits {
            acceptedEdits[activeBuffer.bufferID, default: []].append(edit)
            appendRecovery(edit, resultingRevision: edit.expectedRevision + 1)
        }
        return outcome
    }

    private func receive(_ bridgeEdit: DPScintillaEdit, bufferID: BufferID) {
        guard !isRecovering, let activeBuffer, activeBuffer.bufferID == bufferID,
              bridgeEdit.baseRevision == activeBuffer.revision,
              let replacement = String(data: bridgeEdit.replacementUTF8, encoding: .utf8) else {
            scheduleRecovery(bufferID: bufferID)
            return
        }
        let edit = EditorIncrementalEdit(
            bufferID: activeBuffer.bufferID,
            expectedRevision: bridgeEdit.baseRevision,
            range: TextEditRange(
                location: bridgeEdit.range.location,
                length: bridgeEdit.range.length
            ),
            replacement: replacement
        )
        switch onEdit?(edit) ?? .rejected(currentRevision: activeBuffer.revision) {
        case .accepted(let newRevision) where newRevision == bridgeEdit.resultingRevision:
            self.activeBuffer = EditorBufferDescriptor(
                bufferID: activeBuffer.bufferID,
                revision: newRevision
            )
            updateRevisionExhaustion(bufferID: activeBuffer.bufferID, revision: newRevision)
            secondaryActiveView?.synchronizeRevision(newRevision)
            acceptedEdits[activeBuffer.bufferID, default: []].append(edit)
            appendRecovery(edit, resultingRevision: newRevision)
        case .accepted, .rejected:
            scheduleRecovery(bufferID: bufferID)
        }
    }

    private func appendRecovery(_ edit: EditorIncrementalEdit, resultingRevision: UInt64) {
        guard var recovery = recoveryBuffers[edit.bufferID],
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
        guard let editorView = bufferViews[bufferID],
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
        guard let checkpoint = snapshots[bufferID],
              let snapshot = recoveredSnapshot(
                from: checkpoint,
                edits: acceptedEdits[bufferID, default: []]
              ), let editorView = bufferViews[bufferID] else { return false }
        load(snapshot, into: editorView)
        secondaryBufferViews[bufferID]?.synchronizeRevision(snapshot.revision)
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
        let enabled = isInputEnabled(for: bufferID)
        editorView.isInputEnabled = enabled
        secondaryBufferViews[bufferID]?.isInputEnabled = enabled
        return true
    }

    private func scheduleRecovery(bufferID: BufferID) {
        pendingRecoveryBuffers.insert(bufferID)
        bufferViews[bufferID]?.isInputEnabled = false
        secondaryBufferViews[bufferID]?.isInputEnabled = false
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.recoverPendingBufferIfNeeded(bufferID)
        }
    }

    @discardableResult
    private func recoverPendingBufferIfNeeded(_ bufferID: BufferID) -> Bool {
        guard pendingRecoveryBuffers.contains(bufferID) else { return true }
        guard recoverBuffer(bufferID) else { return false }
        pendingRecoveryBuffers.remove(bufferID)
        return true
    }

    private func makeView(for bufferID: BufferID) -> DPScintillaEditorView {
        let editorView = DPScintillaEditorView(frame: view.bounds)
        documentIntelligenceContextIDs[ObjectIdentifier(editorView)] = DocumentIntelligenceContextID()
        navigationContextIDs[ObjectIdentifier(editorView)] = EditorNavigationContextID()
        editorView.onEdit = { [weak self] edit in self?.receive(edit, bufferID: bufferID) }
        editorView.onError = { [weak self] error in
            self?.receiveBridgeError(error, bufferID: bufferID)
        }
        return editorView
    }

    private func attachSecondaryView(for bufferID: BufferID, primary: DPScintillaEditorView) {
        secondaryActiveView?.removeFromSuperview()
        let secondary: DPScintillaEditorView
        if let existing = secondaryBufferViews[bufferID] {
            secondary = existing
        } else {
            secondary = DPScintillaEditorView(frame: secondaryHost.bounds)
            documentIntelligenceContextIDs[ObjectIdentifier(secondary)] = DocumentIntelligenceContextID()
            navigationContextIDs[ObjectIdentifier(secondary)] = EditorNavigationContextID()
            secondary.shareDocument(with: primary)
            secondary.onError = { [weak self] error in
                self?.receiveBridgeError(error, bufferID: bufferID)
            }
            secondaryBufferViews[bufferID] = secondary
            applyStoredLanguage(to: secondary, bufferID: bufferID)
        }
        secondary.synchronizeRevision(primary.revision)
        secondary.frame = secondaryHost.bounds
        secondary.autoresizingMask = [.width, .height]
        secondary.isInputEnabled = isInputEnabled(for: bufferID)
        secondaryHost.addSubview(secondary)
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
        if secondaryHost.superview == nil { splitView.addArrangedSubview(secondaryHost) }
        attachSecondaryView(for: bufferID, primary: primary)
        splitView.adjustSubviews()
    }

    private func hideSplit(focusPrimary: Bool) {
        let releasedSecondary = secondaryActiveView
        if let releasedSecondary {
            documentIntelligenceContextIDs.removeValue(forKey: ObjectIdentifier(releasedSecondary))
            navigationContextIDs.removeValue(forKey: ObjectIdentifier(releasedSecondary))
        }
        releasedSecondary?.onEdit = nil
        releasedSecondary?.onError = nil
        releasedSecondary?.removeFromSuperview()
        if let bufferID = activeBuffer?.bufferID,
           let releasedSecondary,
           secondaryBufferViews[bufferID] === releasedSecondary {
            secondaryBufferViews.removeValue(forKey: bufferID)
        }
        releasedSecondary?.invalidate()
        secondaryActiveView = nil
        if secondaryHost.superview != nil {
            splitView.removeArrangedSubview(secondaryHost)
            secondaryHost.removeFromSuperview()
        }
        splitOrientation = nil
        if focusPrimary { primaryActiveView?.focusEditor() }
    }

    private func restoreSplitViewState(for bufferID: BufferID, primary: DPScintillaEditorView) {
        guard let state = viewStates[bufferID],
              let orientation = state.splitOrientation,
              let secondaryState = state.secondaryViewState else { return }
        configureSplit(orientation: orientation, bufferID: bufferID, primary: primary)
        guard let secondary = secondaryActiveView else { return }
        secondary.restoreCaretUTF8Position(
            UInt(clamping: secondaryState.caretUTF8),
            anchorPosition: UInt(clamping: secondaryState.anchorUTF8),
            firstVisibleLine: UInt(clamping: secondaryState.firstVisibleLine),
            horizontalScrollOffset: UInt(clamping: secondaryState.horizontalScrollOffset),
            wordWrapEnabled: secondaryState.wordWrapEnabled
        )
        secondary.isWrapMarkerVisible = secondaryState.wrapMarkerVisible
        secondary.isWhitespaceVisible = secondaryState.whitespaceVisible
        secondary.areLineEndingsVisible = secondaryState.lineEndingsVisible
        secondary.zoomLevel = secondaryState.zoomLevel
    }

    private func applyStoredLanguage(to editorView: DPScintillaEditorView, bufferID: BufferID) {
        let configuration = languageConfigurations[bufferID] ?? EditorLanguageConfiguration(
            languageID: .plainText, lexerName: "null", indentation: .init(),
            folding: false, braceMatching: false
        )
        _ = editorView.applyLexerNamed(
            configuration.lexerName, keywords: configuration.keywords,
            tabWidth: UInt(configuration.indentation.width),
            useTabs: configuration.indentation.useTabs,
            folding: configuration.folding,
            braceMatching: configuration.braceMatching,
            maximumStyleBytes: UInt(configuration.maximumStyleBytes)
        )
        editorView.apply(nativePalette(themePalette))
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
        guard let editorView = bufferViews[bufferID] else { return }
        let secondaryState = secondaryBufferViews[bufferID].map {
            SecondaryEditorViewState(
                anchorUTF8: Int(clamping: $0.anchorUTF8Position),
                caretUTF8: Int(clamping: $0.caretUTF8Position),
                firstVisibleLine: Int(clamping: $0.firstVisibleLine),
                horizontalScrollOffset: Int(clamping: $0.horizontalScrollOffset),
                wordWrapEnabled: $0.isWordWrapEnabled,
                wrapMarkerVisible: $0.isWrapMarkerVisible,
                whitespaceVisible: $0.isWhitespaceVisible,
                lineEndingsVisible: $0.areLineEndingsVisible,
                zoomLevel: Int($0.zoomLevel)
            )
        }
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
            splitOrientation: splitOrientation,
            secondaryViewState: splitOrientation == nil ? nil : secondaryState
        )
    }

    private func restoreViewState(for bufferID: BufferID, in editorView: DPScintillaEditorView) {
        let state = viewStates[bufferID] ?? EditorViewState()
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
                zoomLevel: $0.zoomLevel
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
        isRecovering = true
        defer { isRecovering = false }
        try? editorView.loadUTF8(Data(snapshot.text.utf8), revision: snapshot.revision)
    }
}
