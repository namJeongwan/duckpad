import AppKit

@MainActor final class DiagramPreview: NSView {
    private let scroll = NSScrollView()
    private let canvas = DiagramCanvas()
    private let zoom = NSTextField(labelWithString: "")
    private let fit = NSButton()
    private let minus = NSButton()
    private let plus = NSButton()
    let toolbar = NSStackView()
    private let strings: DiagramStrings
    private let compact: Bool
    private var fitWidth = true
    init(strings: DiagramStrings, compact: Bool = false) {
        self.strings = strings; self.compact = compact
        super.init(frame: .zero)
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.allowsMagnification = true; scroll.minMagnification = 0.05; scroll.maxMagnification = 4
        scroll.drawsBackground = true; scroll.backgroundColor = .textBackgroundColor
        scroll.documentView = canvas
        zoom.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        for (button, symbol, action) in [(minus, "minus.magnifyingglass", #selector(zoomOut)),
                                          (plus, "plus.magnifyingglass", #selector(zoomIn))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.target = self; button.action = action; button.bezelStyle = .inline
        }
        fit.target = self; fit.action = #selector(fitImage); fit.bezelStyle = .inline
        for control in [minus, fit, plus] { control.controlSize = .small }
        for view in [minus, fit, plus, zoom] { toolbar.addArrangedSubview(view) }
        toolbar.spacing = compact ? 3 : 8
        if compact {
            fit.image = NSImage(systemSymbolName: "arrow.left.and.right", accessibilityDescription: nil)
            fit.imagePosition = .imageOnly
        } else { addSubview(toolbar) }
        addSubview(scroll)
        toolbar.translatesAutoresizingMaskIntoConstraints = false; scroll.translatesAutoresizingMaskIntoConstraints = false
        if !compact {
            NSLayoutConstraint.activate([
                toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), toolbar.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                toolbar.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8)
            ])
        }
        NSLayoutConstraint.activate([
            compact ? scroll.topAnchor.constraint(equalTo: topAnchor) : scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        refreshLocalization()
        setAccessibilityLabel(strings.text("Diagram preview"))
        canvas.setAccessibilityIdentifier("duckpad.diagram.diagram")
    }
    required init?(coder: NSCoder) { nil }
    func refreshLocalization() {
        fit.title = compact ? "" : strings.text("Fit width")
        fit.toolTip = strings.text("Fit width"); fit.setAccessibilityLabel(strings.text("Fit width"))
        minus.toolTip = strings.text("Zoom out"); plus.toolTip = strings.text("Zoom in")
        minus.setAccessibilityLabel(strings.text("Zoom out")); plus.setAccessibilityLabel(strings.text("Zoom in"))
    }
    func display(_ image: NSImage?) {
        canvas.image = image
        canvas.setFrameSize(image?.size ?? NSSize(width: 1, height: 1))
        fitWidth = true; needsLayout = true
    }
    override func layout() {
        super.layout()
        if fitWidth, canvas.image != nil, scroll.contentView.bounds.width > 1 { applyFit() }
    }
    private func applyFit() {
        let width = canvas.image?.size.width ?? 1
        let scale = min(1, max(0.05, (scroll.contentSize.width - 2) / width))
        scroll.setMagnification(scale, centeredAt: .zero)
        scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView)
        zoom.stringValue = String(format: "%.0f%%", scale * 100)
    }
    @objc private func fitImage() { fitWidth = true; applyFit() }
    @objc private func zoomOut() { changeZoom(0.8) }
    @objc private func zoomIn() { changeZoom(1.25) }
    private func changeZoom(_ amount: CGFloat) {
        fitWidth = false
        let value = min(4, max(0.05, scroll.magnification * amount))
        scroll.setMagnification(value, centeredAt: scroll.contentView.bounds.origin)
        zoom.stringValue = String(format: "%.0f%%", value * 100)
    }
}
