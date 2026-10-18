import AppKit
import DuckpadLocalization

/// A one-time, nonmodal disclosure. It never takes focus from the editor.
@MainActor
final class UsageStatisticsNoticeView: NSView {
    private let message = NSTextField(wrappingLabelWithString: "")
    private let settings = NSButton(title: "", target: nil, action: nil)
    private let dismiss = NSButton(title: "", target: nil, action: nil)
    private var collapsed: NSLayoutConstraint!
    private var expanded: [NSLayoutConstraint] = []
    var onSettings: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        message.font = .systemFont(ofSize: 12)
        let buttons = NSStackView(views: [settings, dismiss])
        buttons.spacing = 8
        for view in [message, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        settings.target = self
        settings.action = #selector(openSettings)
        dismiss.target = self
        dismiss.action = #selector(hideNotice)
        collapsed = heightAnchor.constraint(equalToConstant: 0)
        expanded = [
            message.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            buttons.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 6),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ]
        NSLayoutConstraint.activate([
            message.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            message.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            buttons.leadingAnchor.constraint(equalTo: message.leadingAnchor),
            buttons.trailingAnchor.constraint(lessThanOrEqualTo: message.trailingAnchor),
            collapsed,
        ])
        isHidden = true
        setAccessibilityIdentifier("duckpad.usage.notice")
        refreshLocalization()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show() {
        collapsed.isActive = false
        NSLayoutConstraint.activate(expanded)
        isHidden = false
    }

    @objc func hideNotice() {
        isHidden = true
        NSLayoutConstraint.deactivate(expanded)
        collapsed.isActive = true
    }

    @objc private func openSettings() { onSettings?() }

    func refreshLocalization(catalog: LocalizationCatalog = L10n.catalog) {
        message.stringValue = catalog.text("Usage statistics are on to help improve Duckpad. Document contents, names, and paths are excluded. You can turn sharing off in Privacy Settings.")
        settings.title = catalog.text("Privacy Settings")
        dismiss.title = catalog.text("Dismiss")
    }
}
