import DuckpadLocalization
import AppKit
import DuckpadApplication

/// The familiar Notepad status order, kept outside the editor's scrolling area.
@MainActor
final class DocumentStatusBarView: NSView {
    let lengthLabel = NSTextField(labelWithString: L10n.text("Length: 0   Lines: 1"))
    let positionButton = StatusBarButton(title: L10n.text("Ln: 1   Col: 1   Sel: 0 | 0"), target: nil, action: nil)
    let lineEndingButton = StatusBarButton(title: "Unix (LF)", target: nil, action: nil)
    let modeButton = StatusBarButton(title: "INS", target: nil, action: nil)
    private var fields: [NSView] = []
    private var statistics: EditorStatusSnapshot?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setAccessibilityIdentifier("duckpad.status.bar")
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.text("Document status"))
        lengthLabel.lineBreakMode = .byTruncatingTail
        lengthLabel.setAccessibilityIdentifier("duckpad.status.length")
        positionButton.setAccessibilityIdentifier("duckpad.status.position")
        lineEndingButton.setAccessibilityIdentifier("duckpad.status.line-ending")
        modeButton.setAccessibilityIdentifier("duckpad.status.insert-mode")
    }

    required init?(coder: NSCoder) { nil }

    func install(language: NSButton, encoding: NSButton) {
        fields = [language, lengthLabel, positionButton, lineEndingButton, encoding, modeButton]
        for field in fields {
            field.translatesAutoresizingMaskIntoConstraints = true
            if let control = field as? NSControl {
                control.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            }
            if let button = field as? NSButton {
                button.isBordered = false
                button.image = nil
                button.imagePosition = .noImage
                button.alignment = .left
                button.lineBreakMode = .byTruncatingTail
            }
            addSubview(field)
        }
        positionButton.toolTip = L10n.text("Go to line and column")
        modeButton.toolTip = L10n.text("Toggle insert / overwrite mode")
        needsLayout = true
    }

    func apply(_ status: EditorStatusSnapshot) {
        guard statistics != status else { return }
        statistics = status
        lengthLabel.stringValue = L10n.text("Length: %1$@   Lines: %2$@", L10n.argument(status.length), L10n.argument(status.lines))
        positionButton.title = L10n.text("Ln: %1$@   Col: %2$@   Sel: %3$@ | %4$@", L10n.argument(status.line), L10n.argument(status.column), L10n.argument(status.selectedCharacters), L10n.argument(status.selectedLines))
        modeButton.title = status.isOvertype ? "OVR" : "INS"
        lengthLabel.toolTip = lengthLabel.stringValue
        lengthLabel.setAccessibilityValue(lengthLabel.stringValue)
        positionButton.setAccessibilityValue(positionButton.title)
        modeButton.setAccessibilityValue(modeButton.title)
    }

    override func layout() {
        super.layout()
        let fractions: [CGFloat] = [0.31, 0.19, 0.23, 0.13, 0.10, 0.04]
        var x: CGFloat = 0
        for (field, fraction) in zip(fields, fractions) {
            let width = bounds.width * fraction
            field.frame = NSRect(x: x + 5, y: (bounds.height - 18) / 2, width: max(0, width - 10), height: 18)
            x += width
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        NSRect(x: 0, y: bounds.maxY - pixel, width: bounds.width, height: pixel).fill()
        for field in fields.dropFirst() {
            NSRect(x: field.frame.minX - 5, y: 4, width: pixel, height: max(0, bounds.height - 8)).fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
