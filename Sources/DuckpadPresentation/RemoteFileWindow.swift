import AppKit

/// Browser commands precede application menu equivalents only in this window.
/// Other windows retain editor Replace/Close Tab and their configured bindings.
@MainActor final class RemoteFileWindow: NSPanel {
    var onShortcut: ((String) -> Bool)?
    private var shortcutMonitor: Any?

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        guard shortcutMonitor == nil else { return }
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.isVisible, (event.window ?? NSApp.keyWindow) === self else { return false }
                return self.handleShortcut(event)
            }
            return consumed ? nil : event
        }
    }
    private func handleShortcut(_ event: NSEvent) -> Bool {
        guard let shortcut = ShortcutRecorder.declaration(for: event) else { return false }
        return onShortcut?(shortcut) == true
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func orderOut(_ sender: Any?) {
        stopMonitoring()
        super.orderOut(sender)
    }
    override func close() {
        stopMonitoring()
        super.close()
    }
    private func stopMonitoring() {
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor); self.shortcutMonitor = nil }
    }
}
