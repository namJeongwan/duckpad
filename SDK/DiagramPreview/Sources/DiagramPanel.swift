import AppKit

@MainActor final class DiagramPanel: NSView {
    let preview: DiagramPreview
    var onRender: (() -> Void)?
    var onOpen: (() -> Void)?
    var onSettings: (() -> Void)?
    var onExport: ((String) -> Void)?
    var onExpand: (() -> Void)?
    var onClose: (() -> Void)?
    private let strings: DiagramStrings
    private let status = NSTextField(labelWithString: "")
    private var controls: [(NSButton, String, String)] = []
    private let exportPNG = NSButton()
    private let exportSVG = NSButton()
    private let expand = NSButton()
    init(strings: DiagramStrings, hasRuntimeSettings: Bool) {
        self.strings = strings; preview = DiagramPreview(strings: strings, compact: true)
        super.init(frame: .zero)
        func button(_ key: String, _ action: Selector, existing: NSButton? = nil, title: String? = nil, symbol: String? = nil) -> NSButton {
            let button = existing ?? NSButton(); button.target = self; button.action = action
            button.bezelStyle = .rounded; button.controlSize = .small
            if let symbol {
                button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                button.imagePosition = .imageOnly
            }
            controls.append((button, key, title ?? key)); return button
        }
        let title = NSTextField(labelWithString: strings.name)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let close = button("Close", #selector(closePanel))
        close.toolTip = "Ctrl+W"
        let settings = button("Runtime settings…", #selector(openSettings), title: "Settings")
        settings.setAccessibilityIdentifier("duckpad.diagram.settings")
        settings.isHidden = !hasRuntimeSettings
        let header = NSStackView(views: [title, NSView(), settings, close])
        let render = button("Preview document", #selector(render), title: "Preview")
        render.setAccessibilityIdentifier("duckpad.diagram.render")
        let open = button("Open file…", #selector(openFile), symbol: "folder")
        status.font = .systemFont(ofSize: 11)
        status.lineBreakMode = .byTruncatingTail
        status.setAccessibilityIdentifier("duckpad.diagram.status")
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [render, open, button("PNG", #selector(savePNG), existing: exportPNG),
                                         button("SVG", #selector(saveSVG), existing: exportSVG),
                                         button("Open preview", #selector(expandPreview), existing: expand, symbol: "arrow.up.left.and.arrow.down.right"), NSView()])
        let details = NSStackView(views: [status, NSView(), preview.toolbar])
        let rows: [NSView] = [header, actions, details]
        for row in [header, actions, details] { row.spacing = 4 }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 3
        addSubview(stack); addSubview(preview)
        stack.translatesAutoresizingMaskIntoConstraints = false; preview.translatesAutoresizingMaskIntoConstraints = false
        for row in rows { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            preview.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 4),
            preview.leadingAnchor.constraint(equalTo: leadingAnchor), preview.trailingAnchor.constraint(equalTo: trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: bottomAnchor), preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])
        refreshLocalization(); setBusy(false, hasImage: false)
    }
    required init?(coder: NSCoder) { nil }
    func refreshLocalization() {
        for (control, key, title) in controls {
            control.title = control.image == nil ? strings.text(title) : ""
            control.setAccessibilityLabel(strings.text(key))
            if key != "Close" { control.toolTip = strings.text(key) }
        }
        preview.refreshLocalization()
    }
    func setStatus(_ text: String, error: Bool = false) {
        status.stringValue = text; status.toolTip = text
        status.textColor = error ? .systemRed : .secondaryLabelColor
    }
    func setBusy(_ busy: Bool, hasImage: Bool) {
        for (button, _, _) in controls { button.isEnabled = !busy }
        exportPNG.isEnabled = !busy && hasImage; exportSVG.isEnabled = !busy && hasImage; expand.isEnabled = !busy && hasImage
        // Closing stays available during downloads/rendering.
        controls.first { $0.1 == "Close" }?.0.isEnabled = true
    }
    @objc private func render() { onRender?() }
    @objc private func openFile() { onOpen?() }
    @objc private func openSettings() { onSettings?() }
    @objc private func savePNG() { onExport?("png") }
    @objc private func saveSVG() { onExport?("svg") }
    @objc private func expandPreview() { onExpand?() }
    @objc private func closePanel() { onClose?() }
}
