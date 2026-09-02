import AppKit
import DuckpadApplication

@MainActor
public protocol FilePanelPresenting: AnyObject {
    func chooseOpenURL(attachedTo window: NSWindow?) async -> URL?
    func chooseSaveURL(suggestedName: String, attachedTo window: NSWindow?) async -> URL?
}

@MainActor
public protocol FileConflictPresenting: AnyObject {
    func resolveExternalConflict(attachedTo window: NSWindow?) async -> FileConflictResolution
    func presentFileFailure(
        _ failure: FileOperationFailure,
        attachedTo window: NSWindow?,
        retry: @escaping @MainActor () -> Void
    )
}

@MainActor
public protocol DirtyDocumentDecisionPresenting: AnyObject {
    func decision(for tab: TabSnapshot, saveAvailable: Bool, attachedTo window: NSWindow?) async -> CloseDecision
}

@MainActor
public final class NativeFilePanelAdapter: FilePanelPresenting, FileConflictPresenting, DirtyDocumentDecisionPresenting {
    public init() {}

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

    public func resolveExternalConflict(attachedTo window: NSWindow?) async -> FileConflictResolution {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The file changed outside Duckpad."
        alert.informativeText = "Overwrite the external version, reload it, or cancel and keep your edits."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reload")
        alert.addButton(withTitle: "Overwrite")
        switch await run(alert, attachedTo: window) {
        case .alertSecondButtonReturn: return .reload
        case .alertThirdButtonReturn: return .overwrite
        default: return .cancel
        }
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
        guard let window else { return panel.runModal() }
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    private func run(_ alert: NSAlert, attachedTo window: NSWindow?) async -> NSApplication.ModalResponse {
        guard let window else { return alert.runModal() }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }
}
