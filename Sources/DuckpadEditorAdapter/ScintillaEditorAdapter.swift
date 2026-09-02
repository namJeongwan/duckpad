import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadScintillaBridge

/// Production editor adapter. Scintilla owns live text; Application owns only
/// buffer identity/revision/dirty metadata.
@MainActor
public final class ScintillaEditorAdapter: EditorPort {
    public static let engineVersion = "5.6.6"
    /// Stable host passed to Presentation. Each live buffer owns a Scintilla
    /// child view so switching/retiring another buffer cannot erase its undo stack.
    public let view: NSView
    public private(set) var activeScintillaView: DPScintillaEditorView?
    public private(set) var lastMutationError: (any Error)?
    public var onEdit: ((EditorIncrementalEdit) -> EditorEditOutcome)?

    private var activeBuffer: EditorBufferDescriptor?
    private var snapshots: [BufferID: EditorTextSnapshot] = [:]
    private var acceptedEdits: [BufferID: [EditorIncrementalEdit]] = [:]
    private var bufferViews: [BufferID: DPScintillaEditorView] = [:]
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
        activeScintillaView?.removeFromSuperview()
        activeScintillaView = editorView
        editorView.frame = view.bounds
        editorView.autoresizingMask = [.width, .height]
        editorView.isInputEnabled = inputEnabled
        view.addSubview(editorView)
    }

    public func install(_ snapshot: EditorTextSnapshot) {
        snapshots[snapshot.bufferID] = snapshot
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

    public func retire(bufferID: BufferID) {
        snapshots.removeValue(forKey: bufferID)
        acceptedEdits.removeValue(forKey: bufferID)
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
        case .accepted, .rejected:
            scheduleRecovery()
        }
    }

    private func storeSnapshot(bufferID: BufferID, revision: UInt64) {
        guard let editorView = bufferViews[bufferID],
              let text = String(data: editorView.contentUTF8, encoding: .utf8) else { return }
        snapshots[bufferID] = EditorTextSnapshot(bufferID: bufferID, revision: revision, text: text)
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
