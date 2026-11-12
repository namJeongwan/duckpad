import AppKit

@MainActor final class DiagramSettings: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    let path = NSTextField()
    var onChange: (() -> Void)?
    var onSetup: (() -> Void)?
    private let strings: DiagramStrings
    private let label = NSTextField(labelWithString: "")
    private let setup = NSButton()
    init(strings: DiagramStrings) {
        self.strings = strings
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 180),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self; path.delegate = self
        label.lineBreakMode = .byWordWrapping; label.maximumNumberOfLines = 2
        label.widthAnchor.constraint(equalToConstant: 488).isActive = true
        path.target = self; path.action = #selector(changed)
        path.setAccessibilityIdentifier("duckpad.diagram.runtime-path")
        setup.target = self; setup.action = #selector(installRuntime); setup.bezelStyle = .rounded
        let column = NSStackView(views: [label, path, setup])
        column.orientation = .vertical; column.alignment = .leading; column.spacing = 12
        window.contentView = column
        path.widthAnchor.constraint(equalToConstant: 488).isActive = true
        column.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        refreshLocalization()
    }
    required init?(coder: NSCoder) { nil }
    func refreshLocalization() {
        window?.title = strings.text("Runtime settings…")
        label.stringValue = strings.text("D2 executable (blank uses automatic discovery)")
        path.placeholderString = strings.text("Automatic")
        path.setAccessibilityLabel(label.stringValue)
        setup.title = strings.text("Set up runtime")
    }
    func setBusy(_ busy: Bool) { path.isEnabled = !busy; setup.isEnabled = !busy }
    func controlTextDidEndEditing(_ notification: Notification) { onChange?() }
    func windowWillClose(_ notification: Notification) { window?.endEditing(for: nil); onChange?() }
    @objc private func changed() { onChange?() }
    @objc private func installRuntime() { onSetup?() }
}
