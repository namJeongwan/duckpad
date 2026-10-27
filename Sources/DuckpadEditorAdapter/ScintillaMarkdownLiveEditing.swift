import DuckpadApplication
import Foundation

extension ScintillaEditorAdapter: MarkdownLiveEditorPort, EditorInputSynchronizationPort {
    public var onOpenMarkdownLink: ((URL) -> Void)? {
        get { markdownEditors.onOpenLink }
        set { markdownEditors.onOpenLink = newValue }
    }
    var activeCodeMirrorEditor: CodeMirrorEditorView? { markdownEditors.editor(for: activeScintillaView) }

    public var canUseMarkdownLiveEditing: Bool {
        guard let editor = activeCodeMirrorEditor else { return false }
        return activeScintillaView?.isInputEnabled == true && !editor.isComposing
    }

    public var isMarkdownLiveEditingEnabled: Bool {
        activeCodeMirrorEditor?.isLive ?? false
    }

    public func setMarkdownLiveEditingEnabled(_ enabled: Bool) {
        guard canUseMarkdownLiveEditing else { return }
        activeCodeMirrorEditor?.setLive(enabled)
    }

    public func setMarkdownDocumentURL(_ url: URL?) {
        guard let activeBuffer else { return }
        markdownEditors.setDocumentURL(url, for: activeBuffer.bufferID)
    }

    public func refreshMarkdownImageAccess() { markdownEditors.refreshImageAccess() }

    public func synchronizePendingInput() async -> Bool { await markdownEditors.synchronizePendingInput() }
}
