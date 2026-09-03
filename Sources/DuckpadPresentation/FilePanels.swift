import AppKit
import DuckpadApplication

@MainActor
public protocol FilePanelPresenting: AnyObject {
    func chooseOpenURL(attachedTo window: NSWindow?) async -> URL?
    func chooseSaveURL(suggestedName: String, attachedTo window: NSWindow?) async -> URL?
    func chooseFolderURL(attachedTo window: NSWindow?) async -> URL?
}

public extension FilePanelPresenting {
    func chooseFolderURL(attachedTo window: NSWindow?) async -> URL? { nil }
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
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Compare External Changes"
        alert.informativeText = comparison.path
        alert.addButton(withTitle: "Done")

        let local = comparisonTextView(
            title: "Duckpad — revision \(comparison.localRevision)",
            text: comparison.localText,
            otherText: comparison.externalText
        )
        let external = comparisonTextView(
            title: "On Disk",
            text: comparison.externalText,
            otherText: comparison.localText
        )
        let panes = NSStackView(views: [local, external])
        panes.orientation = .horizontal
        panes.distribution = .fillEqually
        panes.spacing = 10
        panes.frame = NSRect(x: 0, y: 0, width: 820, height: 440)
        alert.accessoryView = panes
        _ = await run(alert, attachedTo: window)
    }

    private func comparisonTextView(title: String, text: String, otherText: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.textStorage?.setAttributedString(comparisonText(text, otherText: otherText))
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.setAccessibilityLabel("\(title), read-only comparison")
        textView.setAccessibilityHelp("Changed lines are marked with a dot and a highlighted background.")
        let scroll = NSScrollView(frame: .zero)
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        let stack = NSStackView(views: [label, scroll])
        stack.orientation = .vertical
        stack.spacing = 4
        scroll.heightAnchor.constraint(equalToConstant: 410).isActive = true
        return stack
    }

    private func comparisonText(_ text: String, otherText: String) -> NSAttributedString {
        let lines = comparisonLines(text)
        let otherLines = comparisonLines(otherText)
        let result = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        for (index, line) in lines.enumerated() {
            let changed = index >= otherLines.count || line != otherLines[index]
            let marker = changed ? "●" : " "
            let rendered = String(format: "%@ %5d  %@%@", marker, index + 1, line, index + 1 < lines.count ? "\n" : "")
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.textColor,
            ]
            if changed { attributes[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(0.18) }
            result.append(NSAttributedString(string: rendered, attributes: attributes))
        }
        return result
    }

    private func comparisonLines(_ text: String) -> [String] {
        var lines: [String] = []
        var lineStart = text.startIndex
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if text[index].isNewline {
                lines.append(String(text[lineStart..<index]))
                lineStart = next
            }
            index = next
        }
        lines.append(String(text[lineStart...]))
        return lines
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
