import AppKit
import DuckpadApplication
import DuckpadDomain

@MainActor
public final class NativeOpenDocumentComparePresenter: OpenDocumentComparePresenting {
    typealias DiffBuilder = @Sendable (String, String) throws -> AlignedLineDiff

    private struct PendingDiff {
        let token: UUID
        let task: Task<AlignedLineDiff, any Error>
    }

    private let diffBuilder: DiffBuilder
    private var activeAlert: NSAlert?
    private var activePanel: OpenDocumentComparePanel?
    private var pendingDiff: PendingDiff?
    private var failureAlerts: [ObjectIdentifier: NSAlert] = [:]
    private var generation: UInt64 = 0

    var comparisonWindowForTesting: NSWindow? { activePanel?.window }
    var hasPendingDiffForTesting: Bool { pendingDiff != nil }
    var failureSheetCountForTesting: Int { failureAlerts.count }

    public var hasPresentedSnapshot: Bool { activePanel != nil }
    public var restoresEditorFocusAfterDismissal: Bool { false }

    public init() {
        diffBuilder = { left, right in try AlignedLineDiff.build(left: left, right: right) }
    }

    init(diffBuilder: @escaping DiffBuilder) {
        self.diffBuilder = diffBuilder
    }

    public static func choices(
        source: TabSnapshot,
        candidates: [TabSnapshot]
    ) -> [OpenDocumentCompareChoice] {
        let eligible = candidates.filter { $0.id != source.id }
        let titleCounts = Dictionary(grouping: eligible + [source], by: \.title).mapValues(\.count)
        return eligible.map { tab in
            let label: String
            if titleCounts[tab.title, default: 0] > 1 {
                label = "\(tab.title) — \(tab.fullPath ?? "Untitled \(tab.id.rawValue.uuidString.prefix(8))")"
            } else {
                label = tab.title
            }
            return OpenDocumentCompareChoice(tabID: tab.id, label: label)
        }
    }

    public func chooseTarget(
        source: TabSnapshot,
        candidates: [TabSnapshot],
        attachedTo window: NSWindow?
    ) async -> TabID? {
        let choices = Self.choices(source: source, candidates: candidates)
        guard !choices.isEmpty, !Task.isCancelled else { return nil }
        let alert = NSAlert()
        alert.messageText = "Compare \(source.title)"
        alert.informativeText = "Choose another open document."
        alert.addButton(withTitle: "Compare")
        alert.addButton(withTitle: "Cancel")
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 28), pullsDown: false)
        choices.forEach { picker.addItem(withTitle: $0.label) }
        picker.setAccessibilityLabel("Open document to compare")
        picker.setAccessibilityHelp("Choose a different open document for a read-only comparison.")
        alert.accessoryView = picker
        if let previous = activeAlert { dismissActiveAlert(previous) }
        activeAlert = alert
        let response = await run(alert, attachedTo: window)
        if activeAlert === alert { activeAlert = nil }
        guard response == .alertFirstButtonReturn,
              choices.indices.contains(picker.indexOfSelectedItem) else { return nil }
        return choices[picker.indexOfSelectedItem].tabID
    }

    public func present(
        _ content: OpenDocumentCompareContent,
        attachedTo window: NSWindow?,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws {
        cancelOutstandingComparisons()
        let requestGeneration = generation
        let panel = try await makePanel(for: content)
        guard requestGeneration == generation, !Task.isCancelled, isCurrent() else {
            panel.dismiss()
            throw OpenDocumentComparison.Error.cancelled
        }
        activePanel = panel
        await withTaskCancellationHandler {
            await panel.present(attachedTo: window)
        } onCancel: {
            Task { @MainActor [weak self, weak panel] in
                guard let panel else { return }
                self?.dismissActivePanel(panel)
            }
        }
        if activePanel === panel { activePanel = nil }
        guard requestGeneration == generation, !Task.isCancelled else {
            throw OpenDocumentComparison.Error.cancelled
        }
    }

    func makePanel(for content: OpenDocumentCompareContent) async throws -> OpenDocumentComparePanel {
        pendingDiff?.task.cancel()
        let token = UUID()
        let builder = diffBuilder
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let diff = try builder(content.leftText, content.rightText)
            try Task.checkCancellation()
            return diff
        }
        pendingDiff = PendingDiff(token: token, task: task)
        defer {
            if pendingDiff?.token == token { pendingDiff = nil }
        }
        do {
            let diff = try await task.value
            guard pendingDiff?.token == token, !task.isCancelled, !Task.isCancelled else {
                throw OpenDocumentComparison.Error.cancelled
            }
            return OpenDocumentComparePanel(content: content, diff: diff)
        } catch is CancellationError {
            throw OpenDocumentComparison.Error.cancelled
        } catch let error as OpenDocumentComparison.Error {
            throw error
        }
    }

    public func presentFailure(_ error: OpenDocumentComparison.Error, attachedTo window: NSWindow?) {
        guard error != .cancelled else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Duckpad could not compare these documents."
        alert.informativeText = String(describing: error)
        alert.addButton(withTitle: "OK")
        let identifier = ObjectIdentifier(alert)
        failureAlerts[identifier] = alert
        if let window {
            alert.beginSheetModal(for: window) { [weak self] _ in
                self?.failureAlerts.removeValue(forKey: identifier)
            }
        } else {
            _ = alert.runModal()
            failureAlerts.removeValue(forKey: identifier)
        }
    }

    public func cancelOutstandingComparisons() {
        generation &+= 1
        pendingDiff?.task.cancel()
        pendingDiff = nil
        if let panel = activePanel { dismissActivePanel(panel) }
        if let alert = activeAlert { dismissActiveAlert(alert) }
        for alert in Array(failureAlerts.values) { dismissFailureAlert(alert) }
    }

    private func dismissActivePanel(_ panel: OpenDocumentComparePanel) {
        guard activePanel === panel else { return }
        activePanel = nil
        panel.dismiss()
    }

    private func dismissActiveAlert(_ alert: NSAlert) {
        guard activeAlert === alert else { return }
        activeAlert = nil
        dismiss(alert)
    }

    private func dismissFailureAlert(_ alert: NSAlert) {
        let identifier = ObjectIdentifier(alert)
        guard failureAlerts.removeValue(forKey: identifier) != nil else { return }
        dismiss(alert)
    }

    private func run(_ alert: NSAlert, attachedTo window: NSWindow?) async -> NSApplication.ModalResponse {
        guard !Task.isCancelled else { return .cancel }
        guard let window else { return alert.runModal() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancel)
                    return
                }
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            Task { @MainActor [weak self, weak alert] in
                guard let alert else { return }
                self?.dismissActiveAlert(alert)
            }
        }
    }

    private func dismiss(_ alert: NSAlert) {
        if let parent = alert.window.sheetParent {
            parent.endSheet(alert.window, returnCode: .cancel)
        } else {
            if NSApplication.shared.modalWindow === alert.window { NSApplication.shared.abortModal() }
            alert.window.orderOut(nil)
        }
    }
}
