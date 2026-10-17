import AppKit
import DuckpadLocalization

/// Terminal-specific content with the document tab's colors, hover and active underline.
@MainActor
final class TerminalSessionTabView: NSView {
    let id: UUID
    let activateButton = NSButton()
    let closeButton = StatusBarButton()
    private let indicator = CALayer()
    private let separator = CALayer()
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var selected = false
    private var showClose = true
    private var showInactiveClose = false
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var contextMenu: (() -> NSMenu?)?

    init(id: UUID) {
        self.id = id
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(indicator)
        layer?.addSublayer(separator)
        activateButton.isBordered = false
        activateButton.alignment = .left
        activateButton.font = .systemFont(ofSize: 12)
        activateButton.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        activateButton.imagePosition = .imageLeading
        activateButton.imageScaling = .scaleProportionallyDown
        activateButton.target = self
        activateButton.action = #selector(activate)
        activateButton.setAccessibilityIdentifier("duckpad.terminal.tab.\(id)")
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.setAccessibilityIdentifier("duckpad.terminal.tab.close.\(id)")
        addSubview(activateButton)
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { nil }

    func configure(title: String, directory: String, selected: Bool, showClose: Bool,
                   showInactiveClose: Bool, catalog: LocalizationCatalog) {
        self.selected = selected
        self.showClose = showClose
        self.showInactiveClose = showInactiveClose
        activateButton.title = title
        activateButton.setAccessibilityLabel(catalog.text("%1$@ tab", arguments: [title]))
        activateButton.setAccessibilityValue(catalog.text(selected ? "selected" : "not selected"))
        activateButton.setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: catalog.text("Close %1$@", arguments: [title])) { [weak self] in
                self?.onClose?()
                return true
            },
        ])
        toolTip = directory
        activateButton.toolTip = directory
        closeButton.toolTip = catalog.text("Close Terminal Session")
        closeButton.setAccessibilityLabel(catalog.text("Close %1$@", arguments: [title]))
        updateAppearance()
    }

    var preferredWidth: CGFloat {
        ceil((activateButton.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width) + 58
    }

    override func layout() {
        super.layout()
        activateButton.frame = NSRect(x: 8, y: 2, width: max(0, bounds.width - 33), height: max(0, bounds.height - 4))
        closeButton.frame = NSRect(x: max(0, bounds.width - 23), y: (bounds.height - 20) / 2, width: 20, height: 20)
        indicator.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 2)
        separator.frame = NSRect(x: bounds.width - 0.5, y: 0, width: 0.5, height: bounds.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        tracking = area
        hovered = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        updateAppearance()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; updateAppearance() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateAppearance() }
    override func mouseDown(with event: NSEvent) { onSelect?() }
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose?() } else { super.otherMouseDown(with: event) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu?()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateAppearance() }
    @objc private func activate() { onSelect?() }
    @objc private func close() { onClose?() }

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (hovered ? NSColor.controlAccentColor.withAlphaComponent(0.11)
                : selected ? WorkspaceColors.editor : WorkspaceColors.panel).cgColor
            indicator.backgroundColor = NSColor.controlAccentColor.cgColor
            separator.backgroundColor = WorkspaceColors.border.cgColor
        }
        indicator.isHidden = !selected
        activateButton.contentTintColor = selected || hovered ? .labelColor : .secondaryLabelColor
        closeButton.contentTintColor = hovered ? .controlAccentColor : .secondaryLabelColor
        closeButton.isHidden = !showClose || !(selected || hovered || showInactiveClose)
        if closeButton.isHidden { closeButton.resetPointerState() }
    }
}
