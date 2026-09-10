import DuckpadLocalization
import AppKit

@MainActor
public final class DuckpadAboutWindowController: NSWindowController {
    let updateTitle = NSTextField(labelWithString: "")
    let updateDetail = NSTextField(wrappingLabelWithString: "")
    let updateButton: NSButton
    private let updateIcon = NSImageView()
    private let progress = NSProgressIndicator()

    public init(target: DuckpadAppInfoController) {
        updateButton = NSButton(title: L10n.text("Check for Updates"), target: target, action: #selector(target.performUpdate(_:)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 430),
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
        let icon = NSImageView(image: NSApplication.shared.applicationIconImage ?? NSImage(size: NSSize(width: 72, height: 72)))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let title = NSTextField(labelWithString: "Duckpad")
        title.font = .systemFont(ofSize: 27, weight: .bold)
        let tagline = NSTextField(wrappingLabelWithString: L10n.text("A focused text editor for macOS."))
        tagline.font = .systemFont(ofSize: 13)
        tagline.textColor = .secondaryLabelColor
        let version = NSTextField(labelWithString: target.appInfo.versionDescription)
        version.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        version.textColor = .secondaryLabelColor
        version.setAccessibilityIdentifier("duckpad.about.version")
        let copy = NSButton(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: L10n.text("Copy app info"))!, target: target, action: #selector(target.performCopyAppInfo(_:)))
        copy.isBordered = false
        copy.controlSize = .small
        copy.toolTip = L10n.text("Copy version and macOS information")
        copy.setAccessibilityIdentifier("duckpad.about.copy-info")
        let versionRow = NSStackView(views: [version, copy])
        versionRow.alignment = .centerY
        versionRow.spacing = 7

        let card = NSBox()
        card.boxType = .custom
        card.cornerRadius = 12
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
        messages.widthAnchor.constraint(equalToConstant: 275).isActive = true
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
        let actions = NSStackView(views: [progress, updateButton])
        actions.orientation = .vertical
        actions.spacing = 6
        let cardRow = NSStackView(views: [updateIcon, messages, actions])
        cardRow.alignment = .centerY
        cardRow.spacing = 10
        card.contentView = cardRow

        let star = NSButton(title: L10n.text("Star on GitHub"), target: target, action: #selector(target.performStarOnGitHub(_:)))
        star.image = NSImage(systemSymbolName: "star", accessibilityDescription: nil)
        star.imagePosition = .imageLeading
        star.bezelStyle = .rounded
        star.toolTip = L10n.text("Support Duckpad with a star on GitHub")
        star.setAccessibilityIdentifier("duckpad.about.star")
        let releases = NSButton(title: L10n.text("Release Notes"), target: target, action: #selector(target.performOpenReleaseNotes(_:)))
        releases.bezelStyle = .rounded
        let links = NSStackView(views: [star, releases])
        links.spacing = 10
        let separator = NSBox()
        separator.boxType = .separator
        let footer = NSTextField(labelWithString: L10n.text("Built for macOS."))
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor
        let report = NSButton(title: L10n.text("Report an Issue ↗"), target: target, action: #selector(target.performReportIssue(_:)))
        report.isBordered = false
        report.font = .systemFont(ofSize: 11)
        report.contentTintColor = .secondaryLabelColor
        let footerRow = NSStackView(views: [footer, NSView(), report])
        footerRow.alignment = .centerY

        let stack = NSStackView(views: [icon, title, tagline, versionRow, card, links, separator, footerRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 9
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(18, after: versionRow)
        stack.setCustomSpacing(16, after: card)
        stack.setCustomSpacing(16, after: links)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
            card.widthAnchor.constraint(equalTo: stack.widthAnchor),
            card.heightAnchor.constraint(equalToConstant: 88),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footerRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        render(target.state)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func render(_ state: DuckpadAppInfoController.UpdateState) {
        updateButton.isEnabled = state != .checking
        updateButton.title = L10n.text("Check for Updates")
        updateIcon.contentTintColor = .secondaryLabelColor
        var symbol = "arrow.triangle.2.circlepath"
        progress.stopAnimation(nil)
        progress.isHidden = state != .checking
        switch state {
        case .idle:
            updateTitle.stringValue = L10n.text("Keep Duckpad up to date")
            updateDetail.stringValue = L10n.text("Get the latest improvements from GitHub Releases.")
        case .checking:
            updateTitle.stringValue = L10n.text("Checking for updates…")
            updateDetail.stringValue = L10n.text("Looking for the latest Duckpad release.")
            progress.startAnimation(nil)
        case .current:
            updateTitle.stringValue = L10n.text("You're up to date")
            updateDetail.stringValue = L10n.text("No newer release is available.")
            updateIcon.contentTintColor = .systemGreen
            symbol = "checkmark.circle.fill"
        case .available(let release):
            updateTitle.stringValue = L10n.text("Duckpad %1$@ is available", L10n.argument(release.version))
            updateDetail.stringValue = L10n.text("Download the update from GitHub Releases.")
            updateButton.title = L10n.text("Download Update")
            updateIcon.contentTintColor = .controlAccentColor
            symbol = "arrow.down.circle.fill"
        case .development(let release):
            updateTitle.stringValue = L10n.text("Latest release: %1$@", L10n.argument(release.version))
            updateDetail.stringValue = L10n.text("You're running a development build.")
            updateButton.title = L10n.text("View Release")
        case .noRelease:
            updateTitle.stringValue = L10n.text("No releases yet")
            updateDetail.stringValue = L10n.text("Published releases will appear here.")
        case .failed:
            updateTitle.stringValue = L10n.text("Couldn't check for updates")
            updateDetail.stringValue = L10n.text("Try again, or open Release Notes below.")
            updateButton.title = L10n.text("Try Again")
            updateIcon.contentTintColor = .systemOrange
            symbol = "exclamationmark.circle"
        }
        updateIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }
}
