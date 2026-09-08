import AppKit
import DuckpadApplication
import DuckpadDomain

@MainActor
public final class WeakWindowReference: @unchecked Sendable {
    public weak var window: NSWindow?
    public init(_ window: NSWindow?) { self.window = window }
}

@MainActor
public protocol FilePanelPresenting: AnyObject {
    func chooseOpenURL(attachedTo window: NSWindow?) async -> URL?
    func chooseSaveURL(suggestedName: String, attachedTo window: NSWindow?) async -> URL?
    func chooseFolderURL(attachedTo window: NSWindow?) async -> URL?
    func chooseWorkspaceFolderURL(attachedTo window: WeakWindowReference) async -> URL?
    func cancelOutstandingPanels()
}

public extension FilePanelPresenting {
    func chooseFolderURL(attachedTo window: NSWindow?) async -> URL? { nil }
    func chooseWorkspaceFolderURL(attachedTo window: WeakWindowReference) async -> URL? { nil }
    func cancelOutstandingPanels() {}
}

@MainActor
public protocol FileConflictPresenting: AnyObject {
    func resolveExternalConflict(attachedTo window: NSWindow?) async -> FileConflictResolution
    func presentExternalComparison(_ comparison: ExternalFileComparison, attachedTo window: NSWindow?) async
    func presentFileFailure(
        _ failure: FileOperationFailure,
        attachedTo window: NSWindow?,
        retry: @escaping @MainActor () -> Void
    )
}

public extension FileConflictPresenting {
    func presentExternalComparison(_ comparison: ExternalFileComparison, attachedTo window: NSWindow?) async {}
}

@MainActor
public protocol DirtyDocumentDecisionPresenting: AnyObject {
    func decision(for tab: TabSnapshot, saveAvailable: Bool, attachedTo window: NSWindow?) async -> CloseDecision
}

@MainActor
public final class NativeFilePanelAdapter: FilePanelPresenting, FileConflictPresenting, DirtyDocumentDecisionPresenting, OpenDocumentComparePresenting {
    private var activePanels: [ObjectIdentifier: NSSavePanel] = [:]
    private let openDocumentComparePresenter: any OpenDocumentComparePresenting

    public init(openDocumentComparePresenter: (any OpenDocumentComparePresenting)? = nil) {
        self.openDocumentComparePresenter = openDocumentComparePresenter
            ?? NativeOpenDocumentComparePresenter()
    }

    public func chooseOpenURL(attachedTo window: NSWindow?) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return await run(panel, attachedTo: window) == .OK ? panel.url : nil
    }

    public func chooseSaveURL(suggestedName: String, attachedTo window: NSWindow?) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        return await run(panel, attachedTo: window) == .OK ? panel.url : nil
    }

    public func chooseFolderURL(attachedTo window: NSWindow?) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Search"
        panel.message = "Choose a folder to search recursively. Hidden files, packages, and symbolic links are skipped."
        return await run(panel, attachedTo: window) == .OK ? panel.url : nil
    }

    public func chooseWorkspaceFolderURL(attachedTo window: WeakWindowReference) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Add"
        panel.message = "Choose a folder to keep in the Duckpad workspace sidebar."
        return await run(panel, attachedTo: window.window) == .OK ? panel.url : nil
    }

    public func cancelOutstandingPanels() {
        let panels = Array(activePanels.values)
        for panel in panels { panel.cancel(nil) }
        openDocumentComparePresenter.cancelOutstandingComparisons()
    }

    public func resolveExternalConflict(attachedTo window: NSWindow?) async -> FileConflictResolution {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The file changed outside Duckpad."
        alert.informativeText = "Compare both versions, overwrite the external version, reload it, or cancel and keep your edits."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Compare")
        alert.addButton(withTitle: "Reload")
        alert.addButton(withTitle: "Overwrite")
        switch await run(alert, attachedTo: window) {
        case .alertSecondButtonReturn: return .compare
        case .alertThirdButtonReturn: return .reload
        case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1): return .overwrite
        default: return .cancel
        }
    }

    public func presentExternalComparison(
        _ comparison: ExternalFileComparison,
        attachedTo window: NSWindow?
    ) async {
        let content = OpenDocumentCompareContent(
            title: "Compare External Changes — \(comparison.path)",
            leftTitle: "Duckpad — revision \(comparison.localRevision)",
            rightTitle: "On Disk",
            leftText: comparison.localText,
            rightText: comparison.externalText
        )
        do {
            try await openDocumentComparePresenter.present(
                content,
                attachedTo: window,
                isCurrent: { !Task.isCancelled }
            )
        } catch let error as OpenDocumentComparison.Error {
            openDocumentComparePresenter.presentFailure(error, attachedTo: window)
        } catch { }
    }

    public func chooseTarget(
        source: TabSnapshot,
        candidates: [TabSnapshot],
        attachedTo window: NSWindow?
    ) async -> TabID? {
        await openDocumentComparePresenter.chooseTarget(
            source: source,
            candidates: candidates,
            attachedTo: window
        )
    }

    public func present(
        _ content: OpenDocumentCompareContent,
        attachedTo window: NSWindow?,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws {
        try await openDocumentComparePresenter.present(
            content,
            attachedTo: window,
            isCurrent: isCurrent
        )
    }

    public func presentFailure(_ error: OpenDocumentComparison.Error, attachedTo window: NSWindow?) {
        openDocumentComparePresenter.presentFailure(error, attachedTo: window)
    }

    public func cancelOutstandingComparisons() {
        openDocumentComparePresenter.cancelOutstandingComparisons()
    }

    public func presentFileFailure(
        _ failure: FileOperationFailure,
        attachedTo window: NSWindow?,
        retry: @escaping @MainActor () -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Duckpad could not complete the file operation."
        alert.informativeText = String(describing: failure)
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Cancel")
        if let window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { retry() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            retry()
        }
    }

    public func decision(for tab: TabSnapshot, saveAvailable: Bool, attachedTo window: NSWindow?) async -> CloseDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save changes to \(tab.title)?"
        alert.informativeText = "Unsaved changes will be lost if you discard them."
        if saveAvailable { alert.addButton(withTitle: "Save") }
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard")
        let response = await run(alert, attachedTo: window)
        if saveAvailable {
            if response == .alertFirstButtonReturn { return .save }
            if response == .alertThirdButtonReturn { return .discard }
        } else if response == .alertSecondButtonReturn {
            return .discard
        }
        return .cancel
    }

    private func run(_ panel: NSSavePanel, attachedTo window: NSWindow?) async -> NSApplication.ModalResponse {
        guard !Task.isCancelled else { return .cancel }
        guard let window else { return panel.runModal() }
        let identifier = ObjectIdentifier(panel)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancel)
                    return
                }
                activePanels[identifier] = panel
                panel.beginSheetModal(for: window) { [weak self] response in
                    self?.activePanels.removeValue(forKey: identifier)
                    continuation.resume(returning: response)
                }
            }
        } onCancel: {
            Task { @MainActor [weak panel] in panel?.cancel(nil) }
        }
    }

    private func run(_ alert: NSAlert, attachedTo window: NSWindow?) async -> NSApplication.ModalResponse {
        guard let window else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }
}
