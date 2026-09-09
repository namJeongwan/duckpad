import AppKit

@MainActor
final class EditorGroupDropZoneView: NSView {
    private let divider = CALayer()
    private var highlighted = false
    private let zone: EditorGroupDropOverlay.Zone

    init(zone: EditorGroupDropOverlay.Zone) {
        self.zone = zone
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.addSublayer(divider)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        switch zone {
        case .left:
            setAccessibilityIdentifier("duckpad.editor-group.drop.left")
            setAccessibilityLabel("Split editor to the left")
        case .up:
            setAccessibilityIdentifier("duckpad.editor-group.drop.up")
            setAccessibilityLabel("Split editor up")
        case .right:
            setAccessibilityIdentifier("duckpad.editor-group.drop.right")
            setAccessibilityLabel("Split editor to the right")
        case .down:
            setAccessibilityIdentifier("duckpad.editor-group.drop.down")
            setAccessibilityLabel("Split editor down")
        }
        setAccessibilityHelp("Drop a document tab here to create another editor group")
        setHighlighted(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let thickness = 2 / scale
        switch zone {
        case .left:
            divider.frame = NSRect(x: bounds.width - thickness, y: 0, width: thickness, height: bounds.height)
        case .up:
            divider.frame = NSRect(x: 0, y: 0, width: bounds.width, height: thickness)
        case .right:
            divider.frame = NSRect(x: 0, y: 0, width: thickness, height: bounds.height)
        case .down:
            divider.frame = NSRect(x: 0, y: bounds.height - thickness, width: bounds.width, height: thickness)
        }
    }

    func setHighlighted(_ highlighted: Bool) {
        self.highlighted = highlighted
        let accent = NSColor.controlAccentColor
        layer?.backgroundColor = accent.withAlphaComponent(highlighted ? 0.22 : 0.10).cgColor
        layer?.borderColor = accent.withAlphaComponent(highlighted ? 0.82 : 0.34).cgColor
        divider.backgroundColor = accent.withAlphaComponent(highlighted ? 0.95 : 0.56).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        setHighlighted(highlighted)
    }
}
