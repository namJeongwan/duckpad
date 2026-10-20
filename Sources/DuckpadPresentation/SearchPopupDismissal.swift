import AppKit

/// Observes outside clicks without consuming the click that positions the caret.
@MainActor
final class SearchPopupDismissal {
    private weak var popup: NSWindow?
    private var mouseMonitor: Any?
    private var inactiveObserver: NSObjectProtocol?
    private var menuObservers: [NSObjectProtocol] = []
    private var trackingMenus: Set<ObjectIdentifier> = []
    private var onDismiss: (() -> Void)?

    func start(window: NSWindow, onDismiss: @escaping () -> Void) {
        stop()
        popup = window; self.onDismiss = onDismiss
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
            menuObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let menu = note.object as? NSMenu else { return }
                let identity = ObjectIdentifier(menu)
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSMenu.didBeginTrackingNotification { self.trackingMenus.insert(identity) }
                    else { self.trackingMenus.remove(identity) }
                }
            })
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
        inactiveObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.popup?.attachedSheet == nil else { return }
                self.onDismiss?()
            }
        }
    }

    func handle(_ event: NSEvent) {
        guard [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type),
              trackingMenus.isEmpty, let popup, popup.isVisible, popup.attachedSheet == nil,
              let clicked = event.window, clicked !== popup else { return }
        var owner = clicked.parent ?? clicked.sheetParent
        while let current = owner {
            if current === popup { return }
            owner = current.parent ?? current.sheetParent
        }
        onDismiss?()
    }

    func stop() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
        if let inactiveObserver { NotificationCenter.default.removeObserver(inactiveObserver); self.inactiveObserver = nil }
        menuObservers.forEach { NotificationCenter.default.removeObserver($0) }
        menuObservers = []; trackingMenus = []
        popup = nil; onDismiss = nil
    }
}
