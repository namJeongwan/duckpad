import AppKit

/// Consume Control-W before menus or editor key bindings can close a document.
@MainActor
public final class AuxiliaryCloseKeyRouter {
    private var monitor: Any?

    public init() {}

    public func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) == true }
            return handled ? nil : event
        }
    }

    public func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    func handle(_ event: NSEvent) -> Bool {
        let characters = event.charactersIgnoringModifiers?.lowercased()
        let koreanControlW = event.keyCode == 13 && (characters == "ㅈ" || characters == "\u{17}")
        guard event.type == .keyDown, characters == "w" || koreanControlW,
              event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.control] else { return false }
        // Holding the key must not dismiss successive layers underneath it.
        if event.isARepeat { return true }
        let window = event.window ?? NSApp.keyWindow
        if Self.dismissModal(attachedTo: window) { return true }
        guard let window else { return false }
        if let controller = window.windowController as? DuckpadWindowController {
            return controller.closeAuxiliaryPanel()
        }
        // Settings, plugin dialogs, Find, and the system color picker are
        // auxiliary windows. Respect their normal close/delegate handling.
        guard !(window is EditorWindow), window.styleMask.contains(.closable) else { return false }
        window.performClose(nil)
        return true
    }

    static func dismissModal(attachedTo window: NSWindow?) -> Bool {
        var target = NSApp.modalWindow ?? window
        while let sheet = target?.attachedSheet { target = sheet }
        guard let target, target.sheetParent != nil || target === NSApp.modalWindow else { return false }
        if let picker = target as? NSSavePanel {
            picker.cancel(nil)
        } else if let parent = target.sheetParent {
            parent.endSheet(target, returnCode: .cancel)
            target.orderOut(nil)
        } else {
            NSApp.stopModal(withCode: .cancel)
            target.orderOut(nil)
        }
        return true
    }
}
