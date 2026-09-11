import AppKit

@MainActor
final class SearchWindowController: NSWindowController, NSWindowDelegate {
    let searchView: SearchPanelView

    init(searchView: SearchPanelView) {
        self.searchView = searchView
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 330),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.setAccessibilityIdentifier("duckpad.search.window")
        super.init(window: panel)
        panel.delegate = self
        let root = NSView(frame: panel.contentLayoutRect)
        root.addSubview(searchView)
        NSLayoutConstraint.activate([
            searchView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            searchView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            searchView.topAnchor.constraint(equalTo: root.topAnchor),
            searchView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        panel.contentView = root
        searchView.appearanceOptions.onChange = { [weak self] in self?.updateOpacity() }
        searchView.onLayoutChanged = { [weak self] in self?.resizeToFit() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func present(in parent: NSWindow?) {
        guard let window else { return }
        resizeToFit()
        if !window.isVisible {
            if let parent {
                parent.addChildWindow(window, ordered: .above)
                var point = NSPoint(x: parent.frame.midX - window.frame.width / 2, y: parent.frame.maxY - 80)
                if let screen = parent.screen ?? NSScreen.main {
                    let visible = screen.visibleFrame
                    point.x = max(visible.minX, min(point.x, visible.maxX - window.frame.width))
                    point.y = min(visible.maxY, max(point.y, visible.minY + window.frame.height))
                }
                window.setFrameTopLeftPoint(point)
            } else { window.center() }
        }
        window.makeKeyAndOrderFront(nil)
        searchView.focusFind()
    }

    func dismiss() {
        searchView.hide()
        guard let window else { return }
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        searchView.onClose?()
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) { updateOpacity() }
    func windowDidResignKey(_ notification: Notification) { updateOpacity() }

    private func updateOpacity() {
        guard let window else { return }
        window.alphaValue = searchView.appearanceOptions.windowAlpha(isKeyWindow: window.isKeyWindow)
    }

    private func resizeToFit() {
        guard let window else { return }
        window.title = searchView.windowTitle
        let size = searchView.fittingSize
        let contentSize = NSSize(width: max(640, size.width), height: size.height)
        guard contentSize.height > 0 else { return }
        window.setContentSize(contentSize)
        window.contentView?.layoutSubtreeIfNeeded()
    }
}
