import DuckpadLocalization
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
    func chooseSaveAccessURL(for url: URL, attachedTo window: NSWindow?) async -> URL?
    func chooseFolderURL(attachedTo window: NSWindow?) async -> URL?
    func chooseWorkspaceFolderURL(attachedTo window: WeakWindowReference) async -> URL?
    func cancelOutstandingPanels()
}

public extension FilePanelPresenting {
    func chooseSaveAccessURL(for url: URL, attachedTo window: NSWindow?) async -> URL? {
        await chooseSaveURL(suggestedName: url.lastPathComponent, attachedTo: window)
    }
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
    func decisionForAll(_ tabs: [TabSnapshot], saveAvailable: Bool, attachedTo window: NSWindow?) async -> CloseDecision?
}

public extension DirtyDocumentDecisionPresenting {
    func decisionForAll(_ tabs: [TabSnapshot], saveAvailable: Bool, attachedTo window: NSWindow?) async -> CloseDecision? { nil }
}

@MainActor
public final class NativeFilePanelAdapter: FilePanelPresenting, FileConflictPresenting, DirtyDocumentDecisionPresenting, OpenDocumentComparePresenting {
    public var hasPresentedSnapshot: Bool { openDocumentComparePresenter.hasPresentedSnapshot }
    public var restoresEditorFocusAfterDismissal: Bool { openDocumentComparePresenter.restoresEditorFocusAfterDismissal }
    public var preferredFileDirectory: (() -> URL?)?

    func configureFileDirectory(_ panel: NSSavePanel) {
        if let directory = preferredFileDirectory?(), directory.isFileURL { panel.directoryURL = directory }
    }

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
        configureFileDirectory(panel)
        return await run(panel, attachedTo: window) == .OK ? panel.url : nil
    }

    public func chooseSaveURL(suggestedName: String, attachedTo window: NSWindow?) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        configureFileDirectory(panel)
        return await run(panel, attachedTo: window) == .OK ? panel.url : nil
    }

    public func chooseSaveAccessURL(for url: URL, attachedTo window: NSWindow?) async -> URL? {
        let panel = NSSavePanel()
        panel.title = L10n.text("Allow Access and Save")
        panel.message = L10n.text("Choose this file again to restore access and save your edits. If it was moved or deleted, choose a new location.")
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = url.lastPathComponent
        return await run(panel, attachedTo: window) == .OK ? panel.url : nil
    }

    public func chooseFolderURL(attachedTo window: NSWindow?) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = L10n.text("Search")
        panel.message = L10n.text("Choose a folder to search recursively. Hidden files, packages, and symbolic links are skipped.")
        return await run(panel, attachedTo: window) == .OK ? panel.url : nil
    }

    public func chooseWorkspaceFolderURL(attachedTo window: WeakWindowReference) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = L10n.text("Add")
        panel.message = L10n.text("Choose a folder to keep in the Duckpad workspace sidebar.")
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
        alert.messageText = L10n.text("The file changed outside Duckpad.")
        alert.informativeText = L10n.text("Compare both versions, overwrite the external version, reload it, or cancel and keep your edits.")
        alert.addButton(withTitle: L10n.text("Cancel"))
        alert.addButton(withTitle: L10n.text("Compare"))
        alert.addButton(withTitle: L10n.text("Reload"))
        alert.addButton(withTitle: L10n.text("Overwrite"))
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
            title: L10n.text("Compare External Changes — %1$@", L10n.argument(comparison.path)),
            leftTitle: L10n.text("Duckpad — revision %1$@", L10n.argument(comparison.localRevision)),
            rightTitle: L10n.text("On Disk"),
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
        alert.messageText = L10n.text("Duckpad could not complete the file operation.")
        alert.informativeText = PresentationErrorText.message(failure)
        switch failure {
        case .unsavedChanges:
            alert.messageText = L10n.text("This document has unsaved changes.")
            alert.informativeText = L10n.text("Reopening with another encoding reads the file from disk and replaces the displayed text. Save your edits, or use Save As to keep a separate copy, before reopening.")
        case .codec:
            alert.messageText = L10n.text("The file could not be read using the selected encoding.")
            alert.informativeText = L10n.text("Choose another encoding. The file and any open document contents have been kept unchanged.")
        case .store(.permissionDenied(let path)):
            alert.messageText = L10n.text("Duckpad cannot access this file.")
            alert.informativeText = L10n.text("%1$@\n\nUse File > Open to grant access again. To keep a recovered tab's contents in another location, use File > Save As.", L10n.argument(path))
        case .store(.notFound(let path)):
            alert.messageText = L10n.text("This file is no longer available.")
            alert.informativeText = L10n.text("%1$@\n\nThe file may have been moved or deleted. Use File > Save As to keep a recovered tab's contents in another location.", L10n.argument(path))
        default:
            break
        }
        alert.addButton(withTitle: L10n.text("Retry"))
        alert.addButton(withTitle: L10n.text("Cancel"))
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
        alert.messageText = L10n.text("Save changes to %1$@?", L10n.argument(tab.title))
        alert.informativeText = L10n.text("Unsaved changes will be lost if you discard them.")
        if saveAvailable { alert.addButton(withTitle: L10n.text("Save")) }
        alert.addButton(withTitle: L10n.text("Cancel"))
        alert.addButton(withTitle: L10n.text("Discard"))
        let response = await run(alert, attachedTo: window)
        if saveAvailable {
            if response == .alertFirstButtonReturn { return .save }
            if response == .alertThirdButtonReturn { return .discard }
        } else if response == .alertSecondButtonReturn {
            return .discard
        }
        return .cancel
    }

    static func allDocumentsAlert(_ tabs: [TabSnapshot], saveAvailable: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("documents.saveBeforeClosing", tabs.count)
        let names = tabs.prefix(5).map { $0.fullPath ?? $0.title }.joined(separator: "\n")
        let remaining = tabs.count > 5 ? L10n.text("\n…and %1$@ more.", L10n.argument(tabs.count - 5)) : ""
        alert.informativeText = saveAvailable
            ? L10n.text("%1$@%2$@\n\nDiscard All loses the unsaved changes in these documents. Documents without a saved location will ask where to save.", names, remaining)
            : L10n.text("%1$@%2$@\n\nDiscard All loses the unsaved changes in these documents.", names, remaining)
        if saveAvailable {
            alert.addButton(withTitle: L10n.text("Save All"))
        }
        alert.addButton(withTitle: L10n.text("Cancel"))
        alert.addButton(withTitle: L10n.text("Discard All"))
        // Return never discards a batch, including when saving is unavailable.
        alert.buttons[saveAvailable ? 1 : 0].keyEquivalent = "\u{1b}"
        return alert
    }

    public func decisionForAll(_ tabs: [TabSnapshot], saveAvailable: Bool, attachedTo window: NSWindow?) async -> CloseDecision? {
        let response = await run(Self.allDocumentsAlert(tabs, saveAvailable: saveAvailable), attachedTo: window)
        if saveAvailable, response == .alertFirstButtonReturn { return .save }
        let discard: NSApplication.ModalResponse = saveAvailable ? .alertThirdButtonReturn : .alertSecondButtonReturn
        return response == discard ? .discard : .cancel
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
