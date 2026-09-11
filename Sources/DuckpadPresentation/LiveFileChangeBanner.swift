import DuckpadLocalization
import AppKit

@MainActor
final class LiveFileChangeBanner: NSView {
    private let message = NSTextField(labelWithString: "")
    let reload = NSButton(title: L10n.text("Reload from Disk…"), target: nil, action: nil)
    let dismiss = NSButton(title: L10n.text("Keep Editing"), target: nil, action: nil)
    private var barHeight: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        message.lineBreakMode = .byTruncatingMiddle
        message.textColor = .labelColor
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [message, reload, dismiss])
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        barHeight = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            barHeight, row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10), row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityIdentifier("duckpad.file-change.banner")
        isHidden = true
    }
    required init?(coder: NSCoder) { nil }

    func refreshLocalization(catalog: LocalizationCatalog = L10n.catalog) {
        reload.title = catalog.text("Reload from Disk…")
        dismiss.title = catalog.text("Keep Editing")
    }

    func show(_ text: String?) {
        message.stringValue = text ?? ""
        message.toolTip = text
        isHidden = text == nil
        barHeight.constant = text == nil ? 0 : 34
    }
}
