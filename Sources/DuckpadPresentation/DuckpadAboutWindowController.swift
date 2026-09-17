import DuckpadLocalization
import AppKit

@MainActor
public final class DuckpadAboutWindowController: NSWindowController {
    let updateTitle = NSTextField(wrappingLabelWithString: "")
    let updateDetail = NSTextField(wrappingLabelWithString: "")
    let updateButton: NSButton
    private let updateIcon = NSImageView()
    private let progress = NSProgressIndicator()
    private let appInfo: DuckpadAppInfo
    private let version = NSTextField(labelWithString: "")
    private var updateState: DuckpadAppInfoController.UpdateState = .idle
    private let tagline = NSTextField(wrappingLabelWithString: "")
    private let copy = NSButton()
    private let star = NSButton()
    private let releases = NSButton()
    private let report = NSButton()

    private var catalog = L10n.catalog

    private func localized(_ key: String, _ arguments: CVarArg...) -> String {
        catalog.text(key, arguments: arguments)
    }

    public init(target: DuckpadAppInfoController) {
        appInfo = target.appInfo
        updateButton = NSButton(title: L10n.text("Check for Updates"), target: target, action: #selector(target.performUpdate(_:)))
        let window = DuckpadAboutWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 306),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = L10n.text("About Duckpad")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let content = NSVisualEffectView()
        content.material = .windowBackground
        content.blendingMode = .behindWindow
        content.state = .active
        window.contentView = content
        let icon = NSImageView(image: NSApplication.shared.applicationIconImage ?? NSImage(size: NSSize(width: 64, height: 64)))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let title = NSTextField(labelWithString: "Duckpad")
        title.font = .systemFont(ofSize: 23, weight: .semibold)
        tagline.stringValue = localized("Text editor for macOS.")
        tagline.font = .systemFont(ofSize: 13)
        tagline.textColor = .secondaryLabelColor
        version.stringValue = target.appInfo.versionDescription
        version.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        version.textColor = .secondaryLabelColor
        version.setAccessibilityIdentifier("duckpad.about.version")
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copy.target = target
        copy.action = #selector(target.performCopyAppInfo(_:))
        copy.imagePosition = .imageOnly
        copy.isBordered = false
        copy.controlSize = .small
        copy.toolTip = localized("Copy version and macOS information")
        copy.setAccessibilityIdentifier("duckpad.about.copy-info")
        let versionRow = NSStackView(views: [version, copy])
        versionRow.alignment = .centerY
        versionRow.spacing = 7

        let card = NSBox()
        card.boxType = .custom
        card.cornerRadius = 8
        card.borderColor = .separatorColor
        card.fillColor = .controlBackgroundColor
        card.contentViewMargins = NSSize(width: 14, height: 14)
        updateTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        updateTitle.setAccessibilityIdentifier("duckpad.about.update-status")
        updateDetail.font = .systemFont(ofSize: 11)
        updateDetail.textColor = .secondaryLabelColor
        updateDetail.maximumNumberOfLines = 3
        let messages = NSStackView(views: [updateTitle, updateDetail])
        messages.orientation = .vertical
        messages.alignment = .leading
        messages.spacing = 4
        updateTitle.maximumNumberOfLines = 2
        updateIcon.imageScaling = .scaleProportionallyUpOrDown
        updateIcon.widthAnchor.constraint(equalToConstant: 22).isActive = true
        updateIcon.heightAnchor.constraint(equalToConstant: 22).isActive = true
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        updateButton.bezelStyle = .rounded
        updateButton.controlSize = .small
        updateButton.font = .systemFont(ofSize: 11, weight: .medium)
        updateButton.setAccessibilityIdentifier("duckpad.about.update-action")
        updateButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let actions = NSStackView(views: [NSView(), progress, updateButton])
        actions.alignment = .centerY
        actions.spacing = 6
        let cardRow = NSStackView(views: [updateIcon, messages])
        cardRow.alignment = .centerY
        cardRow.spacing = 10
        let cardContent = NSStackView(views: [cardRow, actions])
        cardContent.orientation = .vertical
        cardContent.alignment = .leading
        cardContent.spacing = 10
        card.contentView = cardContent
        cardRow.widthAnchor.constraint(equalTo: cardContent.widthAnchor).isActive = true
        actions.widthAnchor.constraint(equalTo: cardContent.widthAnchor).isActive = true

        star.target = target
        star.action = #selector(target.performStarOnGitHub(_:))
        star.image = NSImage(systemSymbolName: "star", accessibilityDescription: nil)
        star.imagePosition = .imageLeading
        star.bezelStyle = .rounded
        star.toolTip = localized("Support Duckpad with a star on GitHub")
        star.setAccessibilityIdentifier("duckpad.about.star")
        releases.target = target
        releases.action = #selector(target.performOpenReleaseNotes(_:))
        releases.bezelStyle = .rounded
        report.target = target
        report.action = #selector(target.performReportIssue(_:))
        for button in [star, releases, report] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
        }
        let links = NSStackView(views: [star, releases, report])
        links.spacing = 8
        let separator = NSBox()
        separator.boxType = .separator
        let details = NSStackView(views: [title, tagline, versionRow])
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 5
        let header = NSStackView(views: [icon, details, NSView()])
        header.alignment = .centerY
        header.spacing = 16
        let stack = NSStackView(views: [header, separator, card, links])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            card.widthAnchor.constraint(equalTo: stack.widthAnchor),
            card.heightAnchor.constraint(equalToConstant: 116),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        window.initialFirstResponder = updateButton
        updateState = target.state
        refreshLocalization()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public func refreshLocalization(catalog: LocalizationCatalog = L10n.catalog) {
        self.catalog = catalog
        window?.title = localized("About Duckpad")
        tagline.stringValue = localized("Text editor for macOS.")
        version.stringValue = appInfo.version.map {
            localized("Version %1$@", L10n.argument($0)) + (appInfo.build.map { " (\($0))" } ?? "")
        } ?? localized("Development build")
        copy.setAccessibilityLabel(localized("Copy app info"))
        copy.toolTip = localized("Copy version and macOS information")
        star.title = "GitHub"
        star.toolTip = localized("Support Duckpad with a star on GitHub")
        releases.title = localized("Release Notes")
        report.title = localized("Report an Issue ↗")
        render(updateState)
    }

    func render(_ state: DuckpadAppInfoController.UpdateState) {
        updateState = state
        updateButton.isEnabled = state != .checking
        updateButton.title = localized("Check for Updates")
        updateIcon.contentTintColor = .secondaryLabelColor
        var symbol = "arrow.triangle.2.circlepath"
        progress.stopAnimation(nil)
        progress.isHidden = state != .checking
        switch state {
        case .idle:
            updateTitle.stringValue = localized("Check for Updates")
            updateDetail.stringValue = localized("Check for a newer version of Duckpad.")
        case .checking:
            updateTitle.stringValue = localized("Checking for updates…")
            updateDetail.stringValue = localized("Looking for the latest Duckpad release.")
            progress.startAnimation(nil)
        case .current:
            updateTitle.stringValue = localized("You're up to date")
            updateDetail.stringValue = localized("No newer release is available.")
            updateIcon.contentTintColor = .systemGreen
            symbol = "checkmark.circle.fill"
        case .available(let release):
            updateTitle.stringValue = localized("Duckpad %1$@ is available", L10n.argument(release.version))
            updateDetail.stringValue = localized("View the changes and install the update.")
            updateButton.title = localized("Download Update")
            updateIcon.contentTintColor = .controlAccentColor
            symbol = "arrow.down.circle.fill"
        case .development(let release):
            updateTitle.stringValue = localized("Latest release: %1$@", L10n.argument(release.version))
            updateDetail.stringValue = localized("You're running a development build.")
            updateButton.title = localized("View Release")
        case .noRelease:
            updateTitle.stringValue = localized("No releases yet")
            updateDetail.stringValue = localized("Published releases will appear here.")
        case .failed:
            updateTitle.stringValue = localized("Couldn't check for updates")
            updateDetail.stringValue = localized("Try again, or open Release Notes below.")
            updateButton.title = localized("Try Again")
            updateIcon.contentTintColor = .systemOrange
            symbol = "exclamationmark.circle"
        }
        updateIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }
}
