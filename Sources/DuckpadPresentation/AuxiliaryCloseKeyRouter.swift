import AppKit

/// Consume auxiliary-window close shortcuts before document menu bindings.
@MainActor
public final class AuxiliaryCloseKeyRouter {
    private var monitor: Any?
    private var consumedCloseKey: UInt16?

    public init() {}

    public func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) == true }
            return handled ? nil : event
        }
    }

    public func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        consumedCloseKey = nil
    }

    func handle(_ event: NSEvent) -> Bool {
        if event.type == .keyUp {
            if event.keyCode == consumedCloseKey { consumedCloseKey = nil }
            return false
        }
        if event.type == .keyDown {
            if event.isARepeat, event.keyCode == consumedCloseKey { return true }
            if !event.isARepeat { consumedCloseKey = nil }
        }
        let characters = event.charactersIgnoringModifiers?.lowercased()
        let koreanControlW = event.keyCode == 13 && (characters == "ㅈ" || characters == "\u{17}")
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard event.type == .keyDown, characters == "w" || koreanControlW,
              modifiers == [.control] || modifiers == [.command] else { return false }
        // Holding the key must not dismiss successive layers underneath it.
        if event.isARepeat { return modifiers == [.control] }
        let handled = closeAuxiliary(attachedTo: event.window ?? NSApp.keyWindow, closesDockedPanel: modifiers == [.control])
        if handled { consumedCloseKey = event.keyCode }
        return handled
    }

    private func closeAuxiliary(attachedTo window: NSWindow?, closesDockedPanel: Bool) -> Bool {
        if Self.dismissModal(attachedTo: window) { return true }
        guard let window else { return false }
        if let controller = window.windowController as? DuckpadWindowController {
            return closesDockedPanel && controller.closeAuxiliaryPanel()
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
