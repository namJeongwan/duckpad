import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadLocalization

/// Owns the preview lifecycle and debounced editor captures for one window.
@MainActor final class MarkdownPreviewCoordinator {
    private let workspace: ScratchWorkspaceUseCase
    private let editor: any EditorPort
    private let resourceReader: any PreviewResourceReading
    private let imageAccess: any MarkdownImageAccess
    private var task: Task<Void, Never>?
    private var buffer: EditorBufferDescriptor?
    private var documentPath: String?
    private var sourceTabID: TabID?
    private(set) var panel: MarkdownPreviewPanel?

    init(workspace: ScratchWorkspaceUseCase, editor: any EditorPort,
         resourceReader: any PreviewResourceReading, imageAccess: any MarkdownImageAccess) {
        self.workspace = workspace
        self.editor = editor
        self.resourceReader = resourceReader
        self.imageAccess = imageAccess
    }

    deinit { task?.cancel() }

    func open(in split: NSSplitView, onClose: @escaping () -> Void) {
        close()
        let panel = MarkdownPreviewPanel(frame: .zero, resourceReader: resourceReader, imageAccess: imageAccess)
        panel.onClose = onClose
        self.panel = panel
        sourceTabID = workspace.activeFileContext()?.tabID
        split.addArrangedSubview(panel)
        split.setHoldingPriority(.init(300), forSubviewAt: split.arrangedSubviews.count - 1)
        split.window?.contentView?.layoutSubtreeIfNeeded()
        split.setPosition(split.bounds.width * 0.55, ofDividerAt: split.arrangedSubviews.count - 2)
    }

    func close() {
        task?.cancel()
        task = nil
        buffer = nil
        documentPath = nil
        sourceTabID = nil
        if let panel {
            panel.invalidate()
            (panel.superview as? NSSplitView)?.removeArrangedSubview(panel)
            panel.removeFromSuperview()
        }
        panel = nil
    }

    /// Returns false when tab navigation requires the window to close preview
    /// and refresh its menu/focus. Caret-only changes never capture document text.
    func schedule() -> Bool {
        guard let panel, let context = workspace.activeFileContext() else { return true }
        if sourceTabID != context.tabID {
            guard workspace.snapshot().tabs.first(where: { $0.id == context.tabID })?.isMarkdownDocument == true else { return false }
            sourceTabID = context.tabID
        }
        let nextBuffer = context.buffer
        let nextPath = context.binding?.canonicalPath
        guard buffer != nextBuffer || documentPath != nextPath else { return true }
        documentPath = nextPath
        if buffer?.bufferID != nextBuffer.bufferID { panel.showMessage(L10n.text("Rendering preview…")) }
        buffer = nextBuffer
        task?.cancel()
        if context.binding?.isReadOnly == true {
            panel.showMessage(L10n.text("Markdown preview is unavailable for binary files."))
            return true
        }
        task = Task { [weak self, weak panel] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, let panel, self.panel === panel,
                  self.workspace.activeFileContext()?.buffer == nextBuffer else { return }
            guard let capture = self.editor.recoveryCapture(for: nextBuffer.bufferID),
                  capture.revision == nextBuffer.revision else { return }
            let documentURL = self.workspace.activeFileContext()?.binding.map { URL(fileURLWithPath: $0.canonicalPath) }
            panel.update(capture: capture, documentURL: documentURL)
        }
        return true
    }
}
