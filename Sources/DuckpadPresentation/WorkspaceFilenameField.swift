import AppKit

@MainActor
final class WorkspaceFilenameField: NSTextField {
    private var hoverTrackingArea: NSTrackingArea?
    private var expansionPanel: NSPanel?

    override var stringValue: String {
        didSet { dismissExpansion() }
    }

    override func expansionFrame(withFrame contentFrame: NSRect) -> NSRect {
        super.expansionFrame(withFrame: contentFrame.intersection(visibleRect))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
        dismissExpansion()
    }

    override func mouseEntered(with event: NSEvent) { showExpansion() }
    override func mouseMoved(with event: NSEvent) { showExpansion() }
    override func mouseExited(with event: NSEvent) { dismissExpansion() }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        dismissExpansion()
        NotificationCenter.default.removeObserver(self)
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        for name in [NSWindow.didResignKeyNotification, NSWindow.didResizeNotification,
                     NSWindow.didMoveNotification, NSWindow.willCloseNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(cancelExpansion(_:)), name: name, object: window)
        }
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(cancelExpansion(_:)),
                name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        dismissExpansion()
    }

    private func showExpansion() {
        guard let window, !isHiddenOrHasHiddenAncestor,
              !expansionFrame(withFrame: bounds).isEmpty else {
            dismissExpansion()
            return
        }
        guard expansionPanel == nil else { return }
        let label = NSTextField(labelWithString: stringValue)
        label.font = font
        label.textColor = textColor
        label.lineBreakMode = .byClipping
        let visible = bounds.intersection(visibleRect)
        let textRect = NSRect(x: visible.minX, y: bounds.minY, width: visible.width, height: bounds.height)
        let textFrame = window.convertToScreen(convert(textRect, to: nil))
        let size = NSSize(width: ceil(label.intrinsicContentSize.width) + 8, height: bounds.height + 4)
        var frame = NSRect(x: textFrame.minX - 4, y: textFrame.minY - 2, width: size.width, height: size.height)
        if let screen = window.screen {
            frame.origin.x = max(screen.visibleFrame.minX, min(frame.minX, screen.visibleFrame.maxX - frame.width))
        }
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.setAccessibilityIdentifier("duckpad.workspace.filename-expansion")
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = effectiveAppearance
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        let surface = NSView(frame: NSRect(origin: .zero, size: size))
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 3
        surface.layer?.borderWidth = 1
        effectiveAppearance.performAsCurrentDrawingAppearance {
            surface.layer?.backgroundColor = WorkspaceColors.panel.cgColor
            surface.layer?.borderColor = WorkspaceColors.border.cgColor
        }
        label.frame = NSRect(x: 4, y: 2, width: size.width - 8, height: bounds.height)
        surface.addSubview(label)
        panel.contentView = surface
        expansionPanel = panel
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
    }

    @objc private func cancelExpansion(_ notification: Notification) { dismissExpansion() }

    private func dismissExpansion() {
        guard let panel = expansionPanel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        expansionPanel = nil
    }
}
