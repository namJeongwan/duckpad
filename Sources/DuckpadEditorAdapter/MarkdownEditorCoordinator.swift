import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadLocalization
import DuckpadScintillaBridge

/// CodeMirror owns the Markdown editing surface. The existing native document
/// remains Duckpad's synchronous file/recovery/command bridge and undo journal.
@MainActor
final class MarkdownEditorCoordinator {
    @MainActor private final class Session {
        let bufferID: BufferID
        weak var native: DPScintillaEditorView?
        let editor: CodeMirrorEditorView
        let originalChildren: [(NSView, Bool)]
        var applying = false
        var generation = 0
        var requestedEditable: Bool
        var drainingInput = false
        init(bufferID: BufferID, native: DPScintillaEditorView, editor: CodeMirrorEditorView) {
            self.bufferID = bufferID; self.native = native; self.editor = editor
            originalChildren = native.subviews.map { ($0, $0.isHidden) }
            requestedEditable = native.isInputEnabled
        }
    }
    private var sessions: [ObjectIdentifier: Session] = [:]
    var onCommand: ((String, DPScintillaEditorView) -> Void)?
    var onOpenLink: ((URL) -> Void)?
    var onStatusChange: (() -> Void)?
    var validatesRevision: ((BufferID, UInt64) -> Bool)?
    var resourceReader: (any PreviewResourceReading)?
    var imageAccess: (any MarkdownImageAccess)?
    private var theme = "light"
    private var palette: EditorThemePalette = .light
    private var documentURLs: [BufferID: URL] = [:]

    var hasComposition: Bool { sessions.values.contains { $0.editor.isComposing } }

    func editor(for native: DPScintillaEditorView?) -> CodeMirrorEditorView? {
        native.flatMap { sessions[ObjectIdentifier($0)]?.editor }
    }

    func attach(_ native: DPScintillaEditorView, bufferID: BufferID) {
        guard sessions[ObjectIdentifier(native)] == nil else { return }
        let editor = CodeMirrorEditorView(reader: resourceReader, imageAccess: imageAccess)
        let session = Session(bufferID: bufferID, native: native, editor: editor)
        sessions[ObjectIdentifier(native)] = session
        session.originalChildren.forEach { $0.0.isHidden = true }
        editor.frame = native.bounds; editor.autoresizingMask = [.width, .height]
        native.addSubview(editor)
        editor.onMessage = { [weak self, weak session] message in
            guard let self, let session else { return false }
            return self.receive(message, session: session)
        }
        editor.onNeedsReload = { [weak self, weak session] in if let session { self?.reload(session) } }
        editor.onModeChange = { [weak self] in self?.onStatusChange?() }
        reload(session)
    }

    func detach(_ native: DPScintillaEditorView) {
        guard let session = sessions.removeValue(forKey: ObjectIdentifier(native)) else { return }
        session.editor.invalidate(); session.editor.removeFromSuperview()
        session.originalChildren.forEach { $0.0.isHidden = $0.1 }
    }

    func retire(_ bufferID: BufferID) {
        for (identifier, session) in Array(sessions) where session.bufferID == bufferID {
            if let native = session.native { detach(native) }
            else {
                session.editor.invalidate(); session.editor.removeFromSuperview()
                sessions.removeValue(forKey: identifier)
            }
        }
        documentURLs[bufferID] = nil
    }
    func invalidate() {
        for session in Array(sessions.values) {
            if let native = session.native { detach(native) } else { session.editor.invalidate() }
        }
        sessions.removeAll(); onCommand = nil; onOpenLink = nil; onStatusChange = nil; validatesRevision = nil
    }

    func setTheme(_ palette: EditorThemePalette) {
        self.palette = palette
        switch palette {
        case .light: theme = "light"
        case .dark: theme = "dark"
        case .highContrastLight: theme = "highContrastLight"
        case .highContrastDark: theme = "highContrastDark"
        }
        refreshAppearance()
    }

    func setDocumentURL(_ url: URL?, for bufferID: BufferID) {
        guard documentURLs[bufferID] != url else { return }
        documentURLs[bufferID] = url
        for session in sessions.values where session.bufferID == bufferID {
            session.editor.configure(["documentURL": url?.absoluteString as Any? ?? NSNull()])
        }
    }

    func refreshImageAccess() { for session in sessions.values { session.editor.reloadImageAccess() } }
    func refreshAppearance() { for session in sessions.values { configure(session) } }
    func refreshLocalization(catalog: LocalizationCatalog) { for session in sessions.values { session.editor.refreshLocalization(catalog: catalog) } }
    func reload(_ bufferID: BufferID) { for session in sessions.values where session.bufferID == bufferID { reload(session) } }

    private func configure(_ session: Session) {
        guard let native = session.native, !session.applying else { return }
        session.editor.applyTheme(palette)
        if session.requestedEditable != native.isInputEnabled {
            session.drainingInput = session.requestedEditable && !native.isInputEnabled
            session.requestedEditable = native.isInputEnabled
        }
        session.editor.configure(["theme": theme, "fontName": native.editorFontName, "fontSize": native.editorFontSize, "zoom": native.zoomLevel,
                                  "lineEnding": native.insertionLineEnding,
                                  "editable": native.isInputEnabled, "wrap": native.isWordWrapEnabled,
                                  "live": session.editor.isLive])
    }

    private func reload(_ session: Session) {
        guard let native = session.native, let text = String(data: native.contentUTF8, encoding: .utf8) else { return }
        session.editor.applyTheme(palette)
        session.generation += 1
        session.editor.load(["text": text, "generation": session.generation,
                             "anchor": Int(native.anchorUTF8Position), "caret": Int(native.caretUTF8Position),
                             "ranges": native.selectionUTF8Positions, "mainIndex": native.mainSelectionIndex,
                             "lineEnding": native.insertionLineEnding, "theme": theme,
                             "fontName": native.editorFontName, "fontSize": native.editorFontSize, "zoom": native.zoomLevel,
                             "editable": native.isInputEnabled, "wrap": native.isWordWrapEnabled,
                             "documentURL": documentURLs[session.bufferID]?.absoluteString as Any? ?? NSNull()])
    }

    func accepted(_ edit: EditorIncrementalEdit) {
        for session in sessions.values where session.bufferID == edit.bufferID {
            guard !session.applying else { continue }
            if !session.editor.ready { reload(session); continue }
            session.editor.call("applyHostEdit", arguments: ["generation": session.generation,
                "location": edit.range.location, "length": edit.range.length, "replacement": edit.replacement])
        }
    }

    func nativeStatusChanged(_ native: DPScintillaEditorView) {
        guard let session = sessions[ObjectIdentifier(native)], !session.applying, !session.editor.isComposing else { return }
        configure(session)
        session.editor.call("nativeSelection", arguments: ["anchor": Int(native.anchorUTF8Position),
            "caret": Int(native.caretUTF8Position), "scroll": false,
            "ranges": native.selectionUTF8Positions, "mainIndex": native.mainSelectionIndex])
    }

    func synchronizePendingInput() async -> Bool {
        for session in Array(sessions.values) {
            if !(await session.editor.flush()) { return false }
        }
        return true
    }

    private func selection(_ values: [String: Any], native: DPScintillaEditorView) -> Bool {
        if let ranges = values["ranges"] as? [[String: NSNumber]], let main = values["mainIndex"] as? Int, main >= 0 {
            return native.setSelectionUTF8Positions(ranges, mainIndex: UInt(main))
        }
        guard let anchor = values["anchor"] as? Int, let caret = values["caret"] as? Int,
              anchor >= 0, caret >= 0, max(anchor, caret) <= native.documentByteLength else { return false }
        native.restoreCaretUTF8Position(UInt(caret), anchorPosition: UInt(anchor), firstVisibleLine: native.firstVisibleLine,
                                       horizontalScrollOffset: native.horizontalScrollOffset, wordWrapEnabled: native.isWordWrapEnabled)
        return true
    }

    private func receive(_ message: [String: Any], session: Session) -> Bool {
        guard let native = session.native, let type = message["type"] as? String else { return false }
        switch type {
        case "openLink":
            guard !session.editor.isComposing else { return true }
            guard let href = message["href"] as? String else { return false }
            if let url = MarkdownLinkDestination.resolve(href, relativeTo: documentURLs[session.bufferID]) {
                native.onFocus?()
                onOpenLink?(url)
            }
            return true
        case "barrier", "composition": return true
        case "admission":
            if message["editable"] as? Bool == false, !session.requestedEditable { session.drainingInput = false }
            return true
        case "focus": native.onFocus?(); return true
        case "copy":
            guard let text = message["text"] as? String else { return false }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); return true
        case "selection":
            guard let values = message["selection"] as? [String: Any] else { return false }
            session.applying = true; defer { session.applying = false }
            return selection(values, native: native)
        case "command":
            guard let command = message["command"] as? String else { return false }
            onCommand?(command, native); return true
        case "edit":
            guard native.isInputEnabled || session.drainingInput, let edits = message["edits"] as? [[String: Any]],
                  !edits.isEmpty, edits.count <= 10_000 else { return false }
            var validated: [(NSRange, String)] = []
            var previousStart = Int(native.documentByteLength) + 1
            for edit in edits {
                guard let location = edit["location"] as? Int, let length = edit["length"] as? Int,
                      let replacement = edit["replacement"] as? String, let deleted = edit["deleted"] as? String,
                      location >= 0, length >= 0, location <= native.documentByteLength,
                      length <= Int(native.documentByteLength) - location, location + length <= previousStart,
                      let bytes = try? native.utf8Bytes(in: NSRange(location: location, length: length)),
                      bytes == Data(deleted.utf8) else { return false }
                validated.append((NSRange(location: location, length: length), replacement)); previousStart = location
            }
            session.applying = true; defer { session.applying = false }
            // Already posted web transactions must drain after native UI
            // admission closes; the ordered read-only acknowledgement ends it.
            let wasEnabled = native.isInputEnabled
            if !wasEnabled { native.isInputEnabled = true }
            defer { if !wasEnabled { native.isInputEnabled = false } }
            native.beginGroupedUndo(); defer { native.endGroupedUndo() }
            for (range, replacement) in validated {
                if !native.isInputEnabled { native.isInputEnabled = true }
                native.setPrimarySelectionUTF8Range(range)
                // Scintilla's InsertText("") is a no-op, including when a
                // range is selected. Web deletions require an explicit Clear.
                if replacement.isEmpty { native.deleteSelectionOrNextCharacter() }
                else { native.insertCommittedText(replacement) }
                guard validatesRevision?(session.bufferID, native.revision) == true else { return false }
            }
            if let values = message["selection"] as? [String: Any], !selection(values, native: native) { return false }
            onStatusChange?(); return true
        default: return false
        }
    }
}
