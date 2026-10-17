import DuckpadLocalization
import AppKit
import DuckpadApplication

/// Panel controls on the left, compact document information on the right.
@MainActor
final class DocumentStatusBarView: NSView {
    let terminalButton = StatusBarButton(title: "", target: nil, action: nil)
    let lengthLabel = NSTextField(labelWithString: L10n.text("Length: 0   Lines: 1"))
    let positionButton = StatusBarButton(title: L10n.text("Ln: 1   Col: 1   Sel: 0 | 0"), target: nil, action: nil)
    let lineEndingButton = StatusBarButton(title: "Unix (LF)", target: nil, action: nil)
    let modeButton = StatusBarButton(title: "INS", target: nil, action: nil)
    private var fields: [NSView] = []
    private var statistics: EditorStatusSnapshot?
    private var binarySummary: String?
    private var loadingProgress: FileLoadingProgress?
    private var terminalVisible = false
    private var catalog = L10n.catalog

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setAccessibilityIdentifier("duckpad.status.bar")
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.text("Document status"))
        terminalButton.isBordered = false
        terminalButton.imagePosition = .imageOnly
        terminalButton.imageScaling = .scaleProportionallyDown
        terminalButton.setAccessibilityIdentifier("duckpad.status.terminal")
        addSubview(terminalButton)
        setTerminalVisible(false)
        lengthLabel.lineBreakMode = .byTruncatingTail
        lengthLabel.setAccessibilityIdentifier("duckpad.status.length")
        positionButton.setAccessibilityIdentifier("duckpad.status.position")
        lineEndingButton.setAccessibilityIdentifier("duckpad.status.line-ending")
        modeButton.setAccessibilityIdentifier("duckpad.status.insert-mode")
    }

    required init?(coder: NSCoder) { nil }

    func refreshLocalization(catalog: LocalizationCatalog = L10n.catalog) {
        self.catalog = catalog
        setTerminalVisible(terminalVisible)
        setAccessibilityLabel(catalog.text("Document status"))
        positionButton.toolTip = catalog.text("Go to line and column")
        modeButton.toolTip = catalog.text("Toggle insert / overwrite mode")
        if let statistics {
            self.statistics = nil
            apply(statistics, binarySummary: binarySummary, catalog: catalog)
        } else {
            renderLength(catalog: catalog)
            positionButton.title = catalog.text("Ln: 1   Col: 1   Sel: 0 | 0")
        }
        needsLayout = true
    }

    func setTerminalVisible(_ visible: Bool) {
        terminalVisible = visible
        let label = catalog.text(visible ? "Hide Terminal" : "Show Terminal")
        terminalButton.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: label)
        terminalButton.setAccessibilityLabel(label)
        terminalButton.toolTip = label + " (⌃`)"
        terminalButton.state = visible ? .on : .off
        terminalButton.contentTintColor = visible ? .controlAccentColor : .secondaryLabelColor
    }

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

    func apply(_ status: EditorStatusSnapshot, binarySummary: String? = nil, catalog: LocalizationCatalog = L10n.catalog) {
        guard statistics != status || self.binarySummary != binarySummary else { return }
        statistics = status
        self.binarySummary = binarySummary
        renderLength(catalog: catalog)
        positionButton.title = catalog.text("Ln: %1$@   Col: %2$@   Sel: %3$@ | %4$@", arguments: [status.line, status.column, status.selectedCharacters, status.selectedLines].map { $0.formatted(.number.locale(catalog.locale)) })
        modeButton.title = binarySummary == nil ? (status.isOvertype ? "OVR" : "INS") : "—"
        positionButton.setAccessibilityValue(positionButton.title)
        modeButton.setAccessibilityValue(modeButton.title)
    }

    func showLoading(_ progress: FileLoadingProgress?) {
        guard progress != loadingProgress else { return }
        loadingProgress = progress
        renderLength()
    }

    private func renderLength(catalog: LocalizationCatalog = L10n.catalog) {
        let loadingSummary = loadingProgress.map {
            catalog.text("Loading: %1$@%%", arguments: [$0.percent.formatted(.number.locale(catalog.locale))])
        }
        lengthLabel.stringValue = loadingSummary ?? binarySummary ?? statistics.map {
            catalog.text("Length: %1$@   Lines: %2$@", arguments: [$0.length, $0.lines].map { $0.formatted(.number.locale(catalog.locale)) })
        } ?? catalog.text("Length: 0   Lines: 1")
        lengthLabel.toolTip = loadingProgress?.path ?? lengthLabel.stringValue
        lengthLabel.setAccessibilityValue(lengthLabel.stringValue)
    }

    override func layout() {
        super.layout()
        terminalButton.frame = NSRect(x: 4, y: (bounds.height - 20) / 2,
                                      width: min(28, max(0, bounds.width - 8)), height: 20)
        // Bounded widths avoid turning the language picker into a huge target
        // on wide windows. Keep the mode readable while compressing narrow bars.
        let preferredWidths: [CGFloat] = [110, 210, 250, 130, 115]
        let available = max(0, bounds.width - 40)
        let modeWidth = min(40, available)
        let scale = min(1, max(0, available - modeWidth) / preferredWidths.reduce(0, +))
        let widths = preferredWidths.map { $0 * scale } + [modeWidth]
        var x = bounds.width - 4 - widths.reduce(0, +)
        for (field, width) in zip(fields, widths) {
            field.frame = NSRect(x: x + 5, y: (bounds.height - 18) / 2, width: max(0, width - 10), height: 18)
            x += width
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        WorkspaceColors.chrome.setFill()
        bounds.fill()
        WorkspaceColors.border.setFill()
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
