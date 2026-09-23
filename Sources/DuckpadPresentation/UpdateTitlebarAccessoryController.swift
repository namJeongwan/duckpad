import AppKit
import DuckpadLocalization

/// A window-local reminder; update state and installation remain application-owned.
@MainActor
final class UpdateTitlebarAccessoryController: NSTitlebarAccessoryViewController {
    let button = UpdateBadgeButton(title: "", target: nil, action: nil)
    var onClick: (() -> Void)?
    private var version = ""

    init(version: String, onClick: @escaping () -> Void) {
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .right
        self.onClick = onClick
        button.cell = UpdateBadgeButtonCell(textCell: "")
        button.target = self
        button.action = #selector(activateUpdate)
        button.isBordered = false
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.contentTintColor = .white
        button.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.alignment = .center
        button.setAccessibilityIdentifier("duckpad.update.available")
        view = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 32))
        view.addSubview(button)
        update(version: version)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(version: String) {
        self.version = version
        refreshLocalization()
    }

    func refreshLocalization(catalog: LocalizationCatalog = L10n.catalog) {
        button.title = catalog.text("New version: %1$@", arguments: [L10n.argument(version)])
        button.toolTip = catalog.text("View update and install…")
        button.setAccessibilityLabel(button.title)
        button.setAccessibilityHelp(button.toolTip)
        let width = min(240, button.intrinsicContentSize.width + 20)
        view.setFrameSize(NSSize(width: width + 8, height: 32))
        button.frame = NSRect(x: 0, y: 6, width: width, height: 20)
        (button.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
    }

    @objc private func activateUpdate() { onClick?() }
}
