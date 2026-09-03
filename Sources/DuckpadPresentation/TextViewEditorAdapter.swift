import AppKit
import DuckpadApplication
import DuckpadDomain

@MainActor
private final class BufferTextView: NSTextView {
    var activeUndoManager: UndoManager?
    override var undoManager: UndoManager? { activeUndoManager }
}

@MainActor
public final class TextViewEditorAdapter: NSObject, EditorPort, EditorViewOptionsPort, EditorCommandPort, @preconcurrency NSTextStorageDelegate {
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
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .labelColor
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor.selectedTextBackgroundColor,
            .foregroundColor: NSColor.selectedTextColor,
        ]
        textView.textContainerInset = NSSize(width: 12, height: 10)
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

    public func canPerform(_ command: EditorCommand) -> Bool {
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
        case .duplicateLine, .indent, .unindent:
            return textView.isEditable && !textView.hasMarkedText()
        case .moveLineUp:
            return textView.isEditable && !textView.hasMarkedText() && selectedLineRange().location > 0
        case .moveLineDown:
            return textView.isEditable && !textView.hasMarkedText()
                && NSMaxRange(selectedLineRange()) < (textView.string as NSString).length
        case .deleteLine, .trimTrailingWhitespace:
            return textView.isEditable && !textView.hasMarkedText() && !textView.string.isEmpty
        case .joinLines:
            guard textView.isEditable && !textView.hasMarkedText() else { return false }
            let lines = selectedLineRange()
            return NSMaxRange(lines) < (textView.string as NSString).length
                || lineChunks(in: lines).count > 1
        case .uppercase, .lowercase:
            return textView.isEditable && !textView.hasMarkedText() && selection.length > 0
        }
    }

    public func perform(_ command: EditorCommand) {
        guard canPerform(command) else { return }
        switch command {
        case .undo: textView.undoManager?.undo()
        case .redo: textView.undoManager?.redo()
        case .cut: textView.cut(nil)
        case .copy: textView.copy(nil)
        case .paste: textView.paste(nil)
        case .delete: textView.deleteForward(nil)
        case .selectAll: textView.selectAll(nil)
        case .duplicateLine: duplicateSelectedLines()
        case .moveLineUp: moveSelectedLines(up: true)
        case .moveLineDown: moveSelectedLines(up: false)
        case .deleteLine: replaceText(in: selectedLineRange(), with: "", selection: NSRange(location: selectedLineRange().location, length: 0))
        case .joinLines: joinSelectedLines()
        case .uppercase: replaceSelection { $0.uppercased() }
        case .lowercase: replaceSelection { $0.lowercased() }
        case .indent: changeIndent(removing: false)
        case .unindent: changeIndent(removing: true)
        case .trimTrailingWhitespace: trimTrailingWhitespace()
        }
    }

    private struct LineChunk {
        let body: String
        let ending: String
    }

    private func selectedLineRange() -> NSRange {
        let source = textView.string as NSString
        let selection = textView.selectedRange()
        let start = min(selection.location, source.length)
        var end = min(NSMaxRange(selection), source.length)
        if end > start {
            let endLine = source.lineRange(for: NSRange(location: end, length: 0))
            if end == endLine.location { end -= 1 }
        }
        return source.lineRange(for: NSRange(location: start, length: max(0, end - start)))
    }

    private func lineChunks(in range: NSRange, includingTerminalEmptyLine: Bool = false) -> [LineChunk] {
        let value = (textView.string as NSString).substring(with: range)
        guard !value.isEmpty else { return [LineChunk(body: "", ending: "")] }
        let utf16 = value as NSString
        var chunks: [LineChunk] = []
        var index = 0
        while index < utf16.length {
            let bodyStart = index
            while index < utf16.length {
                let codeUnit = utf16.character(at: index)
                if codeUnit == 10 || codeUnit == 13 { break }
                index += 1
            }
            let body = utf16.substring(with: NSRange(location: bodyStart, length: index - bodyStart))
            let endingStart = index
            if index < utf16.length {
                if utf16.character(at: index) == 13 {
                    index += 1
                    if index < utf16.length, utf16.character(at: index) == 10 { index += 1 }
                } else {
                    index += 1
                }
            }
            chunks.append(LineChunk(
                body: body,
                ending: utf16.substring(with: NSRange(location: endingStart, length: index - endingStart))
            ))
        }
        if includingTerminalEmptyLine,
           NSMaxRange(range) == (textView.string as NSString).length,
           chunks.last?.ending.isEmpty == false {
            chunks.append(LineChunk(body: "", ending: ""))
        }
        return chunks
    }

    private func rendered(_ chunks: [LineChunk]) -> String {
        chunks.map { $0.body + $0.ending }.joined()
    }

    private func duplicateSelectedLines() {
        let range = selectedLineRange()
        let chunks = lineChunks(in: range)
        let original = rendered(chunks)
        let separator: String
        if chunks.last?.ending.isEmpty == true {
            let newline = textView.string.contains("\r\n") ? "\r\n" : "\n"
            separator = newline
        } else {
            separator = ""
        }
        replaceText(
            in: range,
            with: original + separator + original,
            selection: NSRange(
                location: range.location + original.utf16.count + separator.utf16.count,
                length: original.utf16.count
            )
        )
    }

    private func moveSelectedLines(up: Bool) {
        let source = textView.string as NSString
        let current = selectedLineRange()
        let adjacent: NSRange
        if up {
            adjacent = source.lineRange(for: NSRange(location: current.location - 1, length: 0))
        } else {
            adjacent = source.lineRange(for: NSRange(location: NSMaxRange(current), length: 0))
        }
        let currentChunks = lineChunks(in: current)
        let adjacentChunks = lineChunks(in: adjacent)
        let combined = up ? NSUnionRange(adjacent, current) : NSUnionRange(current, adjacent)
        let first = up ? currentChunks : adjacentChunks
        let second = up ? adjacentChunks : currentChunks
        var reordered = first + second
        let original = lineChunks(in: combined, includingTerminalEmptyLine: true)
        for index in reordered.indices where index < original.count {
            reordered[index] = LineChunk(body: reordered[index].body, ending: original[index].ending)
        }
        let movedChunkRange: Range<Int>
        if up {
            movedChunkRange = 0..<currentChunks.count
        } else {
            movedChunkRange = adjacentChunks.count..<(adjacentChunks.count + currentChunks.count)
        }
        let prefix = rendered(Array(reordered[..<movedChunkRange.lowerBound]))
        let moved = rendered(Array(reordered[movedChunkRange]))
        replaceText(
            in: combined,
            with: rendered(reordered),
            selection: NSRange(
                location: combined.location + prefix.utf16.count,
                length: moved.utf16.count
            )
        )
    }

    private func joinSelectedLines() {
        let source = textView.string as NSString
        var range = selectedLineRange()
        if lineChunks(in: range).count == 1, NSMaxRange(range) < source.length {
            range = NSUnionRange(range, source.lineRange(for: NSRange(location: NSMaxRange(range), length: 0)))
        }
        let chunks = lineChunks(in: range)
        guard chunks.count > 1 else { return }
        let ending = chunks.last?.ending ?? ""
        let joined = chunks.map(\.body).joined(separator: " ") + ending
        replaceText(in: range, with: joined, selection: NSRange(location: range.location, length: joined.utf16.count - ending.utf16.count))
    }

    private func replaceSelection(_ transform: (String) -> String) {
        let range = textView.selectedRange()
        let value = (textView.string as NSString).substring(with: range)
        let replacement = transform(value)
        replaceText(in: range, with: replacement, selection: NSRange(location: range.location, length: replacement.utf16.count))
    }

    private func changeIndent(removing: Bool) {
        let range = selectedLineRange()
        var chunks = lineChunks(in: range)
        for index in chunks.indices {
            var body = chunks[index].body
            if removing {
                if body.hasPrefix("\t") {
                    body.removeFirst()
                } else {
                    let spaces = body.prefix(4).prefix(while: { $0 == " " }).count
                    body.removeFirst(spaces)
                }
            } else {
                body = "\t" + body
            }
            chunks[index] = LineChunk(body: body, ending: chunks[index].ending)
        }
        let replacement = rendered(chunks)
        replaceText(in: range, with: replacement, selection: NSRange(location: range.location, length: replacement.utf16.count))
    }

    private func trimTrailingWhitespace() {
        let source = textView.string
        let expression = try? NSRegularExpression(pattern: "[ \\t]+(?=\\r?$)", options: [.anchorsMatchLines])
        let range = NSRange(location: 0, length: source.utf16.count)
        let replacement = expression?.stringByReplacingMatches(in: source, range: range, withTemplate: "") ?? source
        guard replacement != source else { return }
        let selection = textView.selectedRange()
        let safeSelection = NSRange(
            location: min(selection.location, replacement.utf16.count),
            length: min(selection.length, max(0, replacement.utf16.count - min(selection.location, replacement.utf16.count)))
        )
        replaceText(in: range, with: replacement, selection: safeSelection)
    }

    private func replaceText(in range: NSRange, with replacement: String, selection: NSRange) {
        let undoManager = textView.undoManager
        undoManager?.beginUndoGrouping()
        textView.insertText(replacement, replacementRange: range)
        let currentLength = (textView.string as NSString).length
        let safeLocation = min(selection.location, currentLength)
        textView.setSelectedRange(NSRange(
            location: safeLocation,
            length: min(selection.length, currentLength - safeLocation)
        ))
        undoManager?.endUndoGrouping()
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
