import AppKit
import MetalKit
import GhosttyKit
import DuckpadLocalization

@MainActor
final class GhosttyInspectorController: NSWindowController, NSWindowDelegate {
    private var inspectorView: GhosttyInspectorView?
    private var surface: ghostty_surface_t?

    init?(surface: ghostty_surface_t) {
        GhosttyInspectorLocalization.configure()
        guard let inspector = ghostty_surface_inspector(surface), let view = GhosttyInspectorView(inspector: inspector) else { return nil }
        self.surface = surface
        inspectorView = view
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.text("Terminal Inspector")
        window.isReleasedWhenClosed = false
        window.contentView = view
        super.init(window: window)
        window.delegate = self
        window.center()
    }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { shutdown() }
    func refreshLocalization() {
        guard let surface, let window, window.isVisible else { return }
        // Recreate the inspector (not the terminal) so the renderer and its font
        // atlas switch languages together, including Latin → CJK changes.
        inspectorView?.shutdown()
        inspectorView = nil
        ghostty_inspector_free(surface)
        GhosttyInspectorLocalization.configure()
        guard let inspector = ghostty_surface_inspector(surface), let view = GhosttyInspectorView(inspector: inspector) else {
            shutdown(); return
        }
        inspectorView = view
        window.contentView = view
        window.title = L10n.text("Terminal Inspector")
    }
    func shutdown() {
        inspectorView?.shutdown()
        inspectorView = nil
        if let surface { self.surface = nil; ghostty_inspector_free(surface) }
        window?.orderOut(nil)
    }
}

extension GhosttySurfaceView {
    func toggleInspector() {
        if let controller = inspectorController, controller.window?.isVisible == true {
            controller.shutdown(); inspectorController = nil
        } else if let surface {
            inspectorController = GhosttyInspectorController(surface: surface)
            inspectorController?.showWindow(nil)
        }
    }
}
