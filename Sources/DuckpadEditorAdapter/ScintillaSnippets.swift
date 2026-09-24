import AppKit
import DuckpadApplication
import DuckpadDomain

extension ScintillaEditorAdapter: SnippetEditorPort {
    public var canInsertSnippet: Bool {
        guard let activeBuffer, let view = activeScintillaView else { return false }
        return isReadyForFormatting(activeBuffer) && view.isInputEnabled && view.selectionCount == 1 && !hasBinaryContent(for: activeBuffer.bufferID)
    }

    @discardableResult
    public func insertSnippet(_ template: String) -> Bool {
        guard canInsertSnippet, !template.isEmpty, template.utf8.count <= 65_536,
              let buffer = activeBuffer, let view = activeScintillaView,
              let selection = activeSelectionUTF8Range() else { return false }
        cancelSnippet()
        // Bounded current-line context, never a full-document snapshot.
        let start = max(0, selection.location - 4096)
        let prefix = (try? view.utf8Bytes(in: NSRange(location: start, length: selection.location - start))) ?? Data()
        let line = prefix.split(omittingEmptySubsequences: false, whereSeparator: { $0 == 10 || $0 == 13 }).last ?? Data.SubSequence()
        let leading = line.prefix { $0 == 9 || $0 == 32 }
        let indentation = String(decoding: leading, as: UTF8.self)
        let ending = view.insertionLineEnding
        let expansion = SnippetExpansion(template, indentation: indentation, lineEnding: ending)
        guard expansion.isWithinLimits, expansion.fields.count <= 256, expansion.text.utf8.count <= 1_048_576 else { return false }
        view.beginGroupedUndo()
        let outcome = replaceActive(range: selection, with: Data(expansion.text.utf8), expectedRevision: buffer.revision)
        view.endGroupedUndo()
        guard case .accepted = outcome else { return false }
        snippetView = view
        snippetPreviousAdditionalTyping = view.additionalSelectionTyping
        view.additionalSelectionTyping = true
        snippetBuffer = buffer.bufferID
        snippetSession = SnippetSession(expansion: expansion, offset: selection.location)
        selectSnippetFields()
        if snippetSession?.isFinal == true { cancelSnippet(); return true }
        snippetKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleSnippetKey(event) ?? false }
            return handled ? nil : event
        }
        return true
    }

    public func cancelSnippet() {
        if let view = snippetView {
            view.additionalSelectionTyping = snippetPreviousAdditionalTyping
            if view.selectionCount > 1 {
                view.setPrimarySelectionUTF8Range(NSRange(location: Int(view.caretUTF8Position), length: 0))
            }
        }
        snippetView = nil
        if let snippetKeyMonitor { NSEvent.removeMonitor(snippetKeyMonitor) }
        snippetKeyMonitor = nil; snippetSession = nil; snippetBuffer = nil
    }

    func updateSnippet(_ edit: EditorIncrementalEdit) {
        guard snippetBuffer == edit.bufferID else { return }
        if snippetSession?.apply(range: NSRange(location: edit.range.location, length: edit.range.length), replacementBytes: edit.replacement.utf8.count) != true {
            cancelSnippet()
        }
    }

    @discardableResult
    public func moveSnippetField(backwards: Bool = false) -> Bool {
        guard snippetBuffer == activeBuffer?.bufferID, var session = snippetSession,
              let selection = activeSelectionUTF8Range(),
              session.ranges.contains(where: { selection.location >= $0.location && selection.location + selection.length <= NSMaxRange($0) }) else {
            cancelSnippet(); return false
        }
        guard session.move(backwards: backwards) else { return true }
        snippetSession = session; selectSnippetFields()
        if session.isFinal { cancelSnippet() }
        return true
    }

    private func handleSnippetKey(_ event: NSEvent) -> Bool {
        guard let view = activeScintillaView, view.hasEditorFocus, !view.hasMarkedText(),
              snippetBuffer == activeBuffer?.bufferID else { return false }
        if !event.modifierFlags.intersection([.command, .option, .control]).isEmpty { cancelSnippet(); return false }
        if event.keyCode == 53 {
            if let range = activeSelectionUTF8Range() { selectAndReveal(range) }
            cancelSnippet(); return true
        }
        return event.keyCode == 48 ? moveSnippetField(backwards: event.modifierFlags.contains(.shift)) : false
    }

    private func selectSnippetFields() {
        guard let fields = snippetSession?.ranges, let first = fields.first, let view = activeScintillaView else { return }
        view.setPrimarySelectionUTF8Range(first)
        for field in fields.dropFirst() { _ = view.addSelectionUTF8Range(field) }
        focus()
    }
}
