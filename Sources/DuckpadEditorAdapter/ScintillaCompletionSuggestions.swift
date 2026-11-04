import AppKit
import DuckpadDomain
import DuckpadApplication
import DuckpadCompletionUI
import DuckpadLocalization

extension ScintillaEditorAdapter: RichDocumentCompletionEditorPort {
    public func completionCaptureIsCurrent(_ capture: DocumentIntelligenceCapture) -> Bool {
        completionInputContext == .init(buffer: capture.buffer, caretUTF8: capture.caretUTF8,
            contextID: capture.contextID, languageID: capture.languageID) && canReplaceBuffer(capture.buffer)
    }

    public func presentCompletionSuggestions(_ suggestions: [DocumentCompletionSuggestion], capture: DocumentIntelligenceCapture) -> Bool {
        guard completionCaptureIsCurrent(capture) else { return false }
        if suggestions.isEmpty {
            // Clear unmatched candidates without cancelling the provider request that follows.
            completionPanel.onDismiss = nil
            completionPanel.close()
            completionPanelCapture = nil; completionPresentationID = UUID()
            return false
        }
        guard let view = activeScintillaView,
              let window = view.window, let client = window.firstResponder as? any NSTextInputClient else { return false }
        let editorFont = NSFont(name: view.editorFontName, size: max(1, view.editorFontSize + Double(view.zoomLevel)))
            ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        let font = NSFont(name: view.editorFontName, size: min(13, max(11, editorFont.pointSize)))
            ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        var caret = client.firstRect(forCharacterRange: client.selectedRange(), actualRange: nil)
        if let prefix = DocumentCompletionPrefix(capture) { caret.origin.x -= (prefix.text as NSString).size(withAttributes: [.font: editorFont]).width }
        let colors = completionThemeColors
        func color(_ rgb: Int) -> NSColor {
            NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
        let theme = CodeSuggestionTheme(background: color(colors.panel), border: color(colors.border),
            foreground: color(colors.foreground), secondary: color(colors.muted),
            selection: color(colors.selection), accent: color(colors.keyword))
        let items = suggestions.map { suggestion -> CodeSuggestionItem in
            let detail = suggestion.detail
            let symbol: String, color: NSColor
            switch suggestion.kind {
            case 2, 3, 4: symbol = "function"; color = theme.secondary
            case 5, 6, 10, 21: symbol = "number"; color = theme.secondary
            case 7, 8, 13, 22, 25: symbol = "curlybraces"; color = theme.secondary
            case 9: symbol = "shippingbox"; color = theme.secondary
            case 14: symbol = "textformat"; color = theme.secondary
            default: symbol = "textformat.abc"; color = theme.secondary
            }
            return .init(label: suggestion.label, detail: detail, documentation: suggestion.documentation,
                symbol: symbol, color: color, matchedRanges: suggestion.matches)
        }
        completionPanel.show(items: items, at: caret, parent: window, font: font,
            footer: L10n.text("↑↓ select · Tab insert · Esc close"), theme: theme)
        completionPanelCapture = capture
        let presentationID = UUID()
        completionPresentationID = presentationID
        completionPanel.canHandleKeys = { [weak self] in
            guard let view = self?.activeScintillaView else { return false }
            return view.hasEditorFocus && !view.hasMarkedText()
        }
        completionPanel.onDismiss = { [weak self] in
            self?.completionPanelCapture = nil; self?.completionPresentationID = UUID(); self?.onCompletionInput?(.cancel)
        }
        var requestedDocumentation = Set<Int>()
        completionPanel.onSelect = { [weak self] index in
            guard let self, suggestions.indices.contains(index), suggestions[index].resolutionID != nil,
                  requestedDocumentation.insert(index).inserted else { return }
            Task { @MainActor [weak self] in
                guard let self, let resolved = await self.onCompletionResolve?(suggestions[index], capture),
                      self.completionPresentationID == presentationID,
                      self.completionCaptureIsCurrent(capture), self.completionPanel.isVisible else { return }
                self.completionPanel.updateInfo(at: index, detail: resolved.detail, documentation: resolved.documentation)
            }
        }
        completionPanel.onAccept = { [weak self] index, replaceSuffix in
            guard let self, suggestions.indices.contains(index), self.completionCaptureIsCurrent(capture) else { return false }
            let original = suggestions[index]
            Task { @MainActor [weak self] in
                guard let self else { return }
                var item: DocumentCompletionSuggestion
                if let resolver = self.onCompletionResolve {
                    guard let resolved = await resolver(original, capture) else { return }; item = resolved
                } else { item = original }
                item.adjustIndentation = item.adjustIndentation || original.adjustIndentation
                guard self.completionCaptureIsCurrent(capture) else { return }
                await self.applyCompletion(item, capture: capture, replaceSuffix: replaceSuffix)
            }
            return true
        }
        completionPanel.onSelect?(completionPanel.selectedIndex)
        return completionPanel.isVisible
    }
    func completionSelectionDidChange() {
        guard let capture = completionPanelCapture else { return }
        guard let context = completionInputContext,
              context.buffer.bufferID == capture.buffer.bufferID, context.contextID == capture.contextID,
              context.languageID == capture.languageID else { completionPanel.close(); return }
        if context.buffer.revision == capture.buffer.revision && context.caretUTF8 != capture.caretUTF8 { completionPanel.close() }
    }

    private func applyCompletion(_ item: DocumentCompletionSuggestion, capture: DocumentIntelligenceCapture, replaceSuffix: Bool) async {
        let primary = replaceSuffix ? item.replaceRange : item.insertRange
        guard let text = item.insertionText(in: capture, replacing: primary) else { return }
        var edits = item.additionalEdits
        edits.append(.init(range: primary, replacementUTF8: Data(text.utf8)))
        edits.sort { $0.range.location > $1.range.location }
        var lower = capture.utf8.count + 1
        for edit in edits {
            guard edit.range.location >= 0, edit.range.length >= 0,
                  edit.range.location < lower, edit.range.location + edit.range.length <= lower,
                  edit.range.location + edit.range.length <= capture.utf8.count else { return }
            lower = edit.range.location
        }
        let shift = item.additionalEdits.filter { $0.range.location < primary.location }
            .reduce(0) { $0 + $1.replacementUTF8.count - $1.range.length }
        let caret = primary.location + text.utf8.count + shift
        if let handler = onCompletionBatch { _ = await handler(edits, capture, caret) }
        else {
            let result = replaceActiveBatch(edits, expectedRevision: capture.buffer.revision) { updates in
                var outcome: EditorEditOutcome = .rejected(currentRevision: capture.buffer.revision)
                for update in updates {
                    outcome = self.onEdit?(update) ?? .rejected(currentRevision: update.expectedRevision)
                    guard case .accepted = outcome else { return outcome }
                }
                return outcome
            }
            if case .accepted = result { selectAndReveal(.init(location: caret, length: 0)) }
        }
    }

}
