import AppKit
import DuckpadApplication
import DuckpadDomain

@MainActor
private final class BufferTextView: NSTextView {
    var activeUndoManager: UndoManager?
    override var undoManager: UndoManager? { activeUndoManager }
}

@MainActor
public final class TextViewEditorAdapter: NSObject, EditorPort, @preconcurrency NSTextStorageDelegate {
    public let scrollView: NSScrollView
    public let textView: NSTextView
    public var onEdit: ((EditorIncrementalEdit) -> EditorEditOutcome)?

    private var activeBuffer: EditorBufferDescriptor?
    private var snapshots: [BufferID: EditorTextSnapshot] = [:]
    private var undoManagers: [BufferID: UndoManager] = [:]
    private var isRendering = false

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
    }

    public func snapshot(for bufferID: BufferID) -> EditorTextSnapshot? {
        snapshots[bufferID]
    }

    public func retire(bufferID: BufferID) {
        snapshots.removeValue(forKey: bufferID)
        undoManagers.removeValue(forKey: bufferID)
        guard activeBuffer?.bufferID == bufferID else { return }
        activeBuffer = nil
        (textView as? BufferTextView)?.activeUndoManager = nil
        setTextWithoutEditing("")
    }

    public func setInputEnabled(_ isEnabled: Bool) {
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        scrollView.alphaValue = isEnabled ? 1 : 0.65
    }

    public func focus() {
        textView.window?.makeFirstResponder(textView)
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
        let edit = EditorIncrementalEdit(
            bufferID: activeBuffer.bufferID,
            expectedRevision: activeBuffer.revision,
            range: TextEditRange(location: editedRange.location, length: oldLength),
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
        case .rejected:
            restore(bufferID: activeBuffer.bufferID)
        }
    }

    private func restore(bufferID: BufferID) {
        guard let snapshot = snapshots[bufferID] else { return }
        activeBuffer = EditorBufferDescriptor(bufferID: bufferID, revision: snapshot.revision)
        setTextWithoutEditing(snapshot.text)
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
}
