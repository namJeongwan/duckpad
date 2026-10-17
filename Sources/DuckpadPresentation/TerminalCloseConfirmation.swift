import AppKit
import DuckpadLocalization

/// A terminal-only preference, shared by windows and persisted between launches.
@MainActor
final class TerminalCloseConfirmation {
    private let defaults: UserDefaults
    private let key = "terminal.suppressCloseConfirmation"
    var present: (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var isEnabled: Bool {
        get { !defaults.bool(forKey: key) }
        set { defaults.set(!newValue, forKey: key) }
    }

    func confirm(multiple: Bool, catalog: LocalizationCatalog) -> Bool {
        guard isEnabled else { return true }
        let alert = NSAlert()
        alert.messageText = catalog.text(multiple ? "Close terminal sessions?" : "Close this terminal session?")
        alert.informativeText = catalog.text(multiple
            ? "Running commands in these sessions will be stopped."
            : "Running commands in this session will be stopped.")
        alert.addButton(withTitle: catalog.text("Close"))
        alert.addButton(withTitle: catalog.text("Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = catalog.text("Don’t ask again for terminal sessions")
        guard present(alert) == .alertFirstButtonReturn else { return false }
        if alert.suppressionButton?.state == .on { isEnabled = false }
        return true
    }
}
