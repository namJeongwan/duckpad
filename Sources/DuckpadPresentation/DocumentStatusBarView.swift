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
    private var binarySummary: String?
    private var loadingProgress: FileLoadingProgress?

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

    func refreshLocalization(catalog: LocalizationCatalog = L10n.catalog) {
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
