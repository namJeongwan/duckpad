import AppKit
import DuckpadApplication
import DuckpadDomain

@MainActor
private final class BufferTextView: NSTextView {
    var activeUndoManager: UndoManager?
    override var undoManager: UndoManager? { activeUndoManager }
}

@MainActor
public final class TextViewEditorAdapter: NSObject, EditorPort, EditorViewOptionsPort, EditorStandardCommandPort, @preconcurrency NSTextStorageDelegate {
    public let scrollView: NSScrollView
    public let textView: NSTextView
    public var onEdit: ((EditorIncrementalEdit) -> EditorEditOutcome)?

    private var activeBuffer: EditorBufferDescriptor?
    private var snapshots: [BufferID: EditorTextSnapshot] = [:]
    private var undoManagers: [BufferID: UndoManager] = [:]
    private var viewStates: [BufferID: EditorViewState] = [:]
    private var isRendering = false
    private var requestedInputEnabled = true

    public override init() {
        textView = BufferTextView(frame: .zero)
        scrollView = NSScrollView(frame: .zero)
        super.init()
        textView.textStorage?.delegate = self
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        applyInputAvailability()
    }

    public func display(_ buffer: EditorBufferDescriptor) {
        if activeBuffer?.bufferID == buffer.bufferID,
           activeBuffer?.revision == buffer.revision {
            return
        }
        let snapshot = snapshots[buffer.bufferID]
            ?? EditorTextSnapshot(bufferID: buffer.bufferID, revision: buffer.revision, text: "")
        snapshots[buffer.bufferID] = EditorTextSnapshot(
            bufferID: buffer.bufferID,
            revision: buffer.revision,
            text: snapshot.text
        )
        let undoManager = undoManagers[buffer.bufferID] ?? UndoManager()
        undoManagers[buffer.bufferID] = undoManager
        (textView as? BufferTextView)?.activeUndoManager = undoManager
        activeBuffer = buffer
        setTextWithoutEditing(snapshot.text)
        applyWordWrap(viewStates[buffer.bufferID]?.wordWrapEnabled ?? true)
        applyInputAvailability()
    }

    public func install(_ snapshot: EditorTextSnapshot) {
        snapshots[snapshot.bufferID] = snapshot
        viewStates[snapshot.bufferID] = viewStates[snapshot.bufferID] ?? EditorViewState()
        undoManagers[snapshot.bufferID] = UndoManager()
        guard activeBuffer?.bufferID == snapshot.bufferID else { return }
        activeBuffer = EditorBufferDescriptor(bufferID: snapshot.bufferID, revision: snapshot.revision)
        (textView as? BufferTextView)?.activeUndoManager = undoManagers[snapshot.bufferID]
        setTextWithoutEditing(snapshot.text)
        applyInputAvailability()
    }

    public func snapshot(for bufferID: BufferID) -> EditorTextSnapshot? {
        snapshots[bufferID]
    }

    public func recoverySnapshot(for bufferID: BufferID) -> EditorRecoverySnapshot? {
        try? recoveryCapture(for: bufferID)?.materializedSnapshot()
    }

    public func recoveryCapture(for bufferID: BufferID) -> EditorRecoveryCapture? {
        guard let snapshot = snapshots[bufferID] else { return nil }
        return EditorRecoveryCapture(
            bufferID: bufferID,
            baseRevision: snapshot.revision,
            revision: snapshot.revision,
            baseUTF8: Data(snapshot.text.utf8),
            viewState: viewStates[bufferID] ?? EditorViewState()
        )
    }

    public func installRecovery(_ snapshot: EditorRecoverySnapshot) {
        guard let text = String(data: snapshot.utf8, encoding: .utf8) else { return }
        viewStates[snapshot.bufferID] = snapshot.viewState
        install(EditorTextSnapshot(bufferID: snapshot.bufferID, revision: snapshot.revision, text: text))
        if activeBuffer?.bufferID == snapshot.bufferID {
            applyWordWrap(snapshot.viewState.wordWrapEnabled)
        }
    }

    public func retire(bufferID: BufferID) {
        snapshots.removeValue(forKey: bufferID)
        undoManagers.removeValue(forKey: bufferID)
        viewStates.removeValue(forKey: bufferID)
        guard activeBuffer?.bufferID == bufferID else { return }
        activeBuffer = nil
        (textView as? BufferTextView)?.activeUndoManager = nil
        setTextWithoutEditing("")
        applyInputAvailability()
    }

    public func setInputEnabled(_ isEnabled: Bool) {
        requestedInputEnabled = isEnabled
        applyInputAvailability()
    }

    public func focus() {
        textView.window?.makeFirstResponder(textView)
    }

    public var isWordWrapEnabled: Bool {
        guard let bufferID = activeBuffer?.bufferID else { return true }
        return viewStates[bufferID]?.wordWrapEnabled ?? true
    }

    public var isWrapMarkerVisible: Bool { false }
    public let supportsWrapMarker = false

    public func setWordWrapEnabled(_ isEnabled: Bool) {
        guard let bufferID = activeBuffer?.bufferID else { return }
        var state = viewStates[bufferID] ?? EditorViewState()
        state.wordWrapEnabled = isEnabled
        viewStates[bufferID] = state
        applyWordWrap(isEnabled)
    }

    public func setWrapMarkerVisible(_ isVisible: Bool) {}

    public func canPerform(_ command: EditorStandardCommand) -> Bool {
        guard activeBuffer != nil else { return false }
        let selection = textView.selectedRange()
        switch command {
        case .undo:
            return textView.isEditable && (textView.undoManager?.canUndo ?? false)
        case .redo:
            return textView.isEditable && (textView.undoManager?.canRedo ?? false)
        case .cut:
            return textView.isEditable && selection.length > 0
        case .copy:
            return selection.length > 0
        case .paste:
            return textView.isEditable && NSPasteboard.general.string(forType: .string) != nil
        case .delete:
            return textView.isEditable && (selection.length > 0 || selection.location < textView.string.utf16.count)
        case .selectAll:
            return !textView.string.isEmpty
        }
    }

    public func perform(_ command: EditorStandardCommand) {
        guard canPerform(command) else { return }
        switch command {
        case .undo: textView.undoManager?.undo()
        case .redo: textView.undoManager?.redo()
        case .cut: textView.cut(nil)
        case .copy: textView.copy(nil)
        case .paste: textView.paste(nil)
        case .delete: textView.deleteForward(nil)
        case .selectAll: textView.selectAll(nil)
        }
    }

    public func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard !isRendering, editedMask.contains(.editedCharacters),
              let activeBuffer else {
            return
        }
        let oldLength = editedRange.length - delta
        guard oldLength >= 0, NSMaxRange(editedRange) <= textStorage.length else {
            restore(bufferID: activeBuffer.bufferID)
            return
        }
        let replacement = (textStorage.string as NSString).substring(with: editedRange)
        guard let previous = snapshots[activeBuffer.bufferID] else {
            restore(bufferID: activeBuffer.bufferID)
            return
        }
        let previousNSString = previous.text as NSString
        let previousRange = NSRange(location: editedRange.location, length: oldLength)
        guard NSMaxRange(previousRange) <= previousNSString.length else {
            restore(bufferID: activeBuffer.bufferID)
            return
        }
        let utf8Location = previousNSString.substring(to: previousRange.location).utf8.count
        let utf8Length = previousNSString.substring(with: previousRange).utf8.count
        let edit = EditorIncrementalEdit(
            bufferID: activeBuffer.bufferID,
            expectedRevision: activeBuffer.revision,
            range: TextEditRange(location: utf8Location, length: utf8Length),
            replacement: replacement
        )
        switch onEdit?(edit) ?? .rejected(currentRevision: activeBuffer.revision) {
        case .accepted(let newRevision):
            self.activeBuffer = EditorBufferDescriptor(
                bufferID: activeBuffer.bufferID,
                revision: newRevision
            )
            snapshots[activeBuffer.bufferID] = EditorTextSnapshot(
                bufferID: activeBuffer.bufferID,
                revision: newRevision,
                text: textStorage.string
            )
            applyInputAvailability()
        case .rejected:
            restore(bufferID: activeBuffer.bufferID)
        }
    }

    private func restore(bufferID: BufferID) {
        guard let snapshot = snapshots[bufferID] else { return }
        activeBuffer = EditorBufferDescriptor(bufferID: bufferID, revision: snapshot.revision)
        setTextWithoutEditing(snapshot.text)
        applyInputAvailability()
    }

    private func setTextWithoutEditing(_ text: String) {
        guard textView.string != text else { return }
        isRendering = true
        let undoManager = textView.undoManager
        undoManager?.disableUndoRegistration()
        defer {
            undoManager?.enableUndoRegistration()
            isRendering = false
        }
        let selectedRanges = textView.selectedRanges
        textView.string = text
        textView.selectedRanges = selectedRanges.map { value in
            let range = value.rangeValue
            let location = min(range.location, (text as NSString).length)
            return NSValue(range: NSRange(location: location, length: 0))
        }
    }

    private func applyWordWrap(_ isEnabled: Bool) {
        textView.isHorizontallyResizable = !isEnabled
        textView.textContainer?.widthTracksTextView = isEnabled
        textView.textContainer?.containerSize = NSSize(
            width: isEnabled ? max(scrollView.contentSize.width, 1) : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.hasHorizontalScroller = !isEnabled
    }

    private func applyInputAvailability() {
        let hasActiveBuffer = activeBuffer != nil
        textView.isEditable = requestedInputEnabled
            && (activeBuffer?.revision ?? .max) < .max
        textView.isSelectable = requestedInputEnabled && hasActiveBuffer
        scrollView.alphaValue = requestedInputEnabled ? 1 : 0.65
    }
}
