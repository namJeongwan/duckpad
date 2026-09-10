import AppKit

@MainActor
final class EditorGroupDropZoneView: NSView {
    private var highlighted = false
    private let zone: EditorGroupDropOverlay.Zone

    init(zone: EditorGroupDropOverlay.Zone) {
        self.zone = zone
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 0
        layer?.borderWidth = 1
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

    func setHighlighted(_ highlighted: Bool) {
        self.highlighted = highlighted
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = NSColor.controlAccentColor
            layer?.backgroundColor = accent.withAlphaComponent(highlighted ? 0.10 : 0.05).cgColor
            layer?.borderColor = accent.withAlphaComponent(highlighted ? 0.38 : 0.22).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        setHighlighted(highlighted)
    }
}
