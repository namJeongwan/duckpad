import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadScintillaBridge

/// Production editor adapter. Scintilla owns live text; Application owns only
/// buffer identity/revision/dirty metadata.
@MainActor
public final class ScintillaEditorAdapter: SearchEditorPort, LanguageEditorPort, ExtensionEditorPort, EditorViewOptionsPort {
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
    public let view: NSView
    public private(set) var activeScintillaView: DPScintillaEditorView?
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
    private var languageConfigurations: [BufferID: EditorLanguageConfiguration] = [:]
    private var themePalette: EditorThemePalette = .light
    private var isRecovering = false
    private var inputEnabled = true

    public static func prepareResources() {
        guard let directory = Bundle.module.url(
            forResource: "ScintillaCursors",
            withExtension: nil
        ) else {
            assertionFailure("Scintilla cursor resources are missing")
            return
        }
        DPScintillaConfigureResourceDirectory(directory)
    }

    public init() {
        Self.prepareResources()
        view = NSView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setAccessibilityIdentifier("duckpad.editor.host")
    }

    public func display(_ buffer: EditorBufferDescriptor) {
        if activeBuffer == buffer { return }
        if let activeBuffer {
            storeViewState(bufferID: activeBuffer.bufferID)
            storeSnapshot(bufferID: activeBuffer.bufferID, revision: activeBuffer.revision)
        }
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
        viewStates[buffer.bufferID] = viewStates[buffer.bufferID] ?? EditorViewState()
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
        activeScintillaView?.removeFromSuperview()
        activeScintillaView = editorView
        editorView.frame = view.bounds
        editorView.autoresizingMask = [.width, .height]
        editorView.isInputEnabled = inputEnabled
        view.addSubview(editorView)
    }

    public func install(_ snapshot: EditorTextSnapshot) {
        snapshots[snapshot.bufferID] = snapshot
        let bytes = Data(snapshot.text.utf8)
        recoveryBuffers[snapshot.bufferID] = RecoveryBuffer(
            baseRevision: snapshot.revision,
            revision: snapshot.revision,
            baseUTF8: bytes,
            deltas: [],
            byteCount: bytes.count
        )
        viewStates[snapshot.bufferID] = viewStates[snapshot.bufferID] ?? EditorViewState()
        acceptedEdits[snapshot.bufferID] = []
        guard let editorView = bufferViews[snapshot.bufferID] else { return }
        load(snapshot, into: editorView)
        if activeBuffer?.bufferID == snapshot.bufferID {
            activeBuffer = EditorBufferDescriptor(bufferID: snapshot.bufferID, revision: snapshot.revision)
        }
    }

    public func snapshot(for bufferID: BufferID) -> EditorTextSnapshot? {
        if let activeBuffer, activeBuffer.bufferID == bufferID {
            storeSnapshot(bufferID: bufferID, revision: activeBuffer.revision)
        }
        return snapshots[bufferID]
    }

    public func recoverySnapshot(for bufferID: BufferID) -> EditorRecoverySnapshot? {
        try? recoveryCapture(for: bufferID)?.materializedSnapshot()
    }

    public func recoveryCapture(for bufferID: BufferID) -> EditorRecoveryCapture? {
        if activeBuffer?.bufferID == bufferID { storeViewState(bufferID: bufferID) }
        guard let recovery = recoveryBuffers[bufferID] else { return nil }
        return EditorRecoveryCapture(
            bufferID: bufferID,
            baseRevision: recovery.baseRevision,
            revision: recovery.revision,
            baseUTF8: recovery.baseUTF8,
            deltas: recovery.deltas,
            viewState: viewStates[bufferID] ?? EditorViewState()
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
        viewStates[snapshot.bufferID] = sanitized(snapshot.viewState, for: snapshot.utf8)
        install(EditorTextSnapshot(bufferID: snapshot.bufferID, revision: snapshot.revision, text: text))
        if let editorView = bufferViews[snapshot.bufferID] {
            restoreViewState(for: snapshot.bufferID, in: editorView)
        }
    }

    public func retire(bufferID: BufferID) {
        snapshots.removeValue(forKey: bufferID)
        recoveryBuffers.removeValue(forKey: bufferID)
        viewStates.removeValue(forKey: bufferID)
        acceptedEdits.removeValue(forKey: bufferID)
        languageConfigurations.removeValue(forKey: bufferID)
        let retiredView = bufferViews.removeValue(forKey: bufferID)
        retiredView?.onEdit = nil
        retiredView?.removeFromSuperview()
        guard activeBuffer?.bufferID == bufferID else { return }
        activeBuffer = nil
        activeScintillaView = nil
    }

    public func setInputEnabled(_ isEnabled: Bool) {
        inputEnabled = isEnabled
        bufferViews.values.forEach { $0.isInputEnabled = isEnabled }
        view.alphaValue = isEnabled ? 1 : 0.65
    }

    public func focus() { activeScintillaView?.focusEditor() }

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

    public func detectionPrefix(maximumBytes: Int) -> Data {
        activeScintillaView?.contentPrefixUTF8(withMaximumLength: UInt(max(0, maximumBytes))) ?? Data()
    }

    public func supportsLexer(named name: String) -> Bool {
        DPScintillaEditorView.supportsLexerNamed(name)
    }

    @discardableResult
    public func applyLanguage(_ configuration: EditorLanguageConfiguration) -> Bool {
        guard let bufferID = activeBuffer?.bufferID, let editorView = activeScintillaView else { return false }
        guard editorView.applyLexerNamed(
            configuration.lexerName,
            keywords: configuration.keywords,
            tabWidth: UInt(configuration.indentation.width),
            useTabs: configuration.indentation.useTabs,
            folding: configuration.folding,
            braceMatching: configuration.braceMatching,
            maximumStyleBytes: UInt(configuration.maximumStyleBytes)
        ) else { return false }
        languageConfigurations[bufferID] = configuration
        editorView.apply(nativePalette(themePalette))
        return true
    }

    public func applyTheme(_ palette: EditorThemePalette) {
        themePalette = palette
        let native = nativePalette(palette)
        bufferViews.values.forEach { $0.apply(native) }
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
        guard let activeBuffer, let editorView = activeScintillaView,
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
            scheduleRecovery()
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
            scheduleRecovery()
            return outcome
        }
        self.activeBuffer = EditorBufferDescriptor(bufferID: activeBuffer.bufferID, revision: revision)
        acceptedEdits[activeBuffer.bufferID, default: []].append(edit)
        appendRecovery(edit, resultingRevision: revision)
        return outcome
    }

    public func replaceActiveBatch(
        _ replacements: [SearchReplacementEdit],
        expectedRevision: UInt64,
        accept: ([EditorIncrementalEdit]) -> EditorEditOutcome
    ) -> EditorEditOutcome {
        guard let activeBuffer, let editorView = activeScintillaView,
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
            scheduleRecovery()
            return outcome
        }
        self.activeBuffer = EditorBufferDescriptor(bufferID: activeBuffer.bufferID, revision: resultingRevision)
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
            scheduleRecovery()
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
            acceptedEdits[activeBuffer.bufferID, default: []].append(edit)
            appendRecovery(edit, resultingRevision: newRevision)
        case .accepted, .rejected:
            scheduleRecovery()
        }
    }

    private func appendRecovery(_ edit: EditorIncrementalEdit, resultingRevision: UInt64) {
        guard var recovery = recoveryBuffers[edit.bufferID],
              recovery.revision == edit.expectedRevision,
              edit.range.location >= 0, edit.range.length >= 0,
              edit.range.location <= recovery.byteCount,
              edit.range.length <= recovery.byteCount - edit.range.location else {
            scheduleRecovery()
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

    private func recoverActiveBuffer() {
        guard let activeBuffer, let checkpoint = snapshots[activeBuffer.bufferID],
              let snapshot = recoveredSnapshot(
                from: checkpoint,
                edits: acceptedEdits[activeBuffer.bufferID, default: []]
              ) else { return }
        guard let editorView = bufferViews[activeBuffer.bufferID] else { return }
        load(snapshot, into: editorView)
        snapshots[activeBuffer.bufferID] = snapshot
        let bytes = Data(snapshot.text.utf8)
        recoveryBuffers[activeBuffer.bufferID] = RecoveryBuffer(
            baseRevision: snapshot.revision,
            revision: snapshot.revision,
            baseUTF8: bytes,
            deltas: [],
            byteCount: bytes.count
        )
        acceptedEdits[activeBuffer.bufferID] = []
        self.activeBuffer = EditorBufferDescriptor(
            bufferID: activeBuffer.bufferID,
            revision: snapshot.revision
        )
        editorView.isInputEnabled = inputEnabled
    }

    private func scheduleRecovery() {
        activeScintillaView?.isInputEnabled = false
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.recoverActiveBuffer()
        }
    }

    private func makeView(for bufferID: BufferID) -> DPScintillaEditorView {
        let editorView = DPScintillaEditorView(frame: view.bounds)
        editorView.onEdit = { [weak self] edit in self?.receive(edit, bufferID: bufferID) }
        editorView.onError = { [weak self] error in self?.lastMutationError = error }
        return editorView
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
        viewStates[bufferID] = EditorViewState(
            anchorUTF8: Int(clamping: editorView.anchorUTF8Position),
            caretUTF8: Int(clamping: editorView.caretUTF8Position),
            firstVisibleLine: Int(clamping: editorView.firstVisibleLine),
            horizontalScrollOffset: Int(clamping: editorView.horizontalScrollOffset),
            wordWrapEnabled: editorView.isWordWrapEnabled,
            wrapMarkerVisible: editorView.isWrapMarkerVisible
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
    }

    private func sanitized(_ state: EditorViewState, for utf8: Data) -> EditorViewState {
        func boundary(_ value: Int) -> Int {
            var offset = min(max(value, 0), utf8.count)
            while offset > 0, offset < utf8.count, (utf8[offset] & 0xC0) == 0x80 {
                offset -= 1
            }
            return offset
        }
        return EditorViewState(
            anchorUTF8: boundary(state.anchorUTF8),
            caretUTF8: boundary(state.caretUTF8),
            firstVisibleLine: max(0, state.firstVisibleLine),
            horizontalScrollOffset: max(0, state.horizontalScrollOffset),
            wordWrapEnabled: state.wordWrapEnabled,
            wrapMarkerVisible: state.wrapMarkerVisible
        )
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
