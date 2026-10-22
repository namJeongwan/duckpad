import AppKit
import DuckpadApplication
import DuckpadLocalization

@MainActor final class TailStatusBar: NSView {
    let message = NSTextField(labelWithString: "")
    let follow = StatusBarButton(image: NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: nil)!, target: nil, action: nil)
    let retry = StatusBarButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)!, target: nil, action: nil)
    let clear = StatusBarButton(image: NSImage(systemSymbolName: "clear", accessibilityDescription: nil)!, target: nil, action: nil)
    let stop = StatusBarButton(image: NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)!, target: nil, action: nil)
    private let chrome = WorkspaceBarView(edge: .bottom)
    private var barHeight: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: NSImage(systemSymbolName: "waveform.path", accessibilityDescription: nil)!)
        icon.contentTintColor = .controlAccentColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        icon.imageScaling = .scaleProportionallyDown
        message.font = .systemFont(ofSize: 11)
        message.lineBreakMode = .byTruncatingMiddle
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (button, id) in [(follow, "follow"), (retry, "retry"), (clear, "clear"), (stop, "stop")] {
            button.configureAsToolbarIcon()
            button.setAccessibilityIdentifier("duckpad.tail." + id)
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        let row = NSStackView(views: [icon, message, follow, retry, clear, stop])
        row.spacing = 6; row.alignment = .centerY; row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chrome); addSubview(row)
        barHeight = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            barHeight, chrome.leadingAnchor.constraint(equalTo: leadingAnchor), chrome.trailingAnchor.constraint(equalTo: trailingAnchor),
            chrome.topAnchor.constraint(equalTo: topAnchor), chrome.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
        ])
        setAccessibilityIdentifier("duckpad.tail.status")
        show(nil); refreshLocalization()
    }
    required init?(coder: NSCoder) { nil }
    func refreshLocalization(catalog: LocalizationCatalog = L10n.catalog) {
        for (button, key) in [(follow, "Follow End"), (retry, "Retry"), (clear, "Clear Tail Output"), (stop, "Stop Tail Mode")] {
            button.toolTip = catalog.text(key); button.setAccessibilityLabel(catalog.text(key))
        }
    }
    func show(_ text: String?, warning: Bool = false, canRetry: Bool = false) {
        retry.isHidden = !canRetry
        message.stringValue = text ?? ""; message.toolTip = text
        message.textColor = warning ? .systemOrange : .secondaryLabelColor
        isHidden = text == nil; barHeight.constant = text == nil ? 0 : 28
    }
}
