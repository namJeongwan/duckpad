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
    private let layout = NSStackView()

    private var catalog = L10n.catalog

    private func localized(_ key: String, _ arguments: CVarArg...) -> String {
        catalog.text(key, arguments: arguments)
    }

    public init(target: DuckpadAppInfoController) {
        appInfo = target.appInfo
        updateButton = NSButton(title: L10n.text("Check for Updates"), target: target, action: #selector(target.performUpdate(_:)))
        let window = DuckpadAboutWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 220),
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

        updateTitle.font = .systemFont(ofSize: 13, weight: .medium)
        updateTitle.setAccessibilityIdentifier("duckpad.about.update-status")
        updateTitle.maximumNumberOfLines = 0
        updateDetail.font = .systemFont(ofSize: 11)
        updateDetail.textColor = .secondaryLabelColor
        updateDetail.maximumNumberOfLines = 0
        let messages = NSStackView(views: [updateTitle, updateDetail])
        messages.orientation = .vertical
        messages.alignment = .leading
        messages.spacing = 3
        updateTitle.widthAnchor.constraint(equalTo: messages.widthAnchor).isActive = true
        updateDetail.widthAnchor.constraint(equalTo: messages.widthAnchor).isActive = true
        updateIcon.imageScaling = .scaleProportionallyUpOrDown
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        let indicator = NSView()
        for view in [updateIcon, progress] {
            view.translatesAutoresizingMaskIntoConstraints = false
            indicator.addSubview(view)
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: indicator.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: indicator.centerYAnchor),
                view.widthAnchor.constraint(equalToConstant: 16),
                view.heightAnchor.constraint(equalToConstant: 16),
            ])
        }
        updateButton.bezelStyle = .rounded
        updateButton.controlSize = .small
        updateButton.font = .systemFont(ofSize: 11, weight: .medium)
        updateButton.setAccessibilityIdentifier("duckpad.about.update-action")
        updateButton.setContentHuggingPriority(.required, for: .horizontal)
        updateButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let updateRow = NSView()
        for view in [indicator, messages, updateButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            updateRow.addSubview(view)
        }
        NSLayoutConstraint.activate([
            indicator.leadingAnchor.constraint(equalTo: updateRow.leadingAnchor),
            indicator.centerYAnchor.constraint(equalTo: updateRow.centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 16),
            indicator.heightAnchor.constraint(equalToConstant: 16),
            messages.leadingAnchor.constraint(equalTo: indicator.trailingAnchor, constant: 8),
            messages.trailingAnchor.constraint(equalTo: updateButton.leadingAnchor, constant: -16),
            messages.centerYAnchor.constraint(equalTo: updateRow.centerYAnchor),
            messages.topAnchor.constraint(greaterThanOrEqualTo: updateRow.topAnchor),
            messages.bottomAnchor.constraint(lessThanOrEqualTo: updateRow.bottomAnchor),
            updateButton.trailingAnchor.constraint(equalTo: updateRow.trailingAnchor),
            updateButton.centerYAnchor.constraint(equalTo: updateRow.centerYAnchor),
            updateRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])

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
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
        }
        let links = NSStackView(views: [star, releases, report])
        links.spacing = 16
        let footerSeparator = NSBox()
        footerSeparator.boxType = .separator
        let separator = NSBox()
        separator.boxType = .separator
        let details = NSStackView(views: [title, tagline, versionRow])
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 5
        let header = NSStackView(views: [icon, details, NSView()])
        header.alignment = .centerY
        header.spacing = 16
        let stack = layout
        for view in [header, separator, updateRow, footerSeparator, links] { stack.addArrangedSubview(view) }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(16, after: header)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            updateRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footerSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor),
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
        updateDetail.stringValue = ""
        updateIcon.isHidden = state == .checking
        progress.stopAnimation(nil)
        progress.isHidden = state != .checking
        switch state {
        case .idle:
            updateTitle.stringValue = localized("Software Updates")
        case .checking:
            updateTitle.stringValue = localized("Checking for updates…")
            progress.startAnimation(nil)
        case .current:
            updateTitle.stringValue = localized("You're up to date")
            updateIcon.contentTintColor = .systemGreen
            symbol = "checkmark.circle.fill"
        case .available(let release):
            updateTitle.stringValue = localized("New version: %1$@", L10n.argument(release.version))
            updateButton.title = localized("Download Update")
            updateIcon.contentTintColor = .controlAccentColor
            symbol = "arrow.down.circle.fill"
        case .development(let release):
            updateTitle.stringValue = localized("Latest release: %1$@", L10n.argument(release.version))
            updateDetail.stringValue = localized("You're running a development build.")
            updateButton.title = localized("View Release")
        case .noRelease:
            updateTitle.stringValue = localized("No releases yet")
        case .failed:
            updateTitle.stringValue = localized("Couldn't check for updates")
            updateDetail.stringValue = localized("Try again, or open Release Notes below.")
            updateButton.title = localized("Try Again")
            updateIcon.contentTintColor = .systemOrange
            symbol = "exclamationmark.circle"
        }
        updateIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        updateDetail.isHidden = updateDetail.stringValue.isEmpty
        // Fit translated status text instead of reserving an empty update card.
        window?.contentView?.layoutSubtreeIfNeeded()
        if let window {
            let height = ceil(layout.fittingSize.height) + 36
            let top = window.frame.maxY
            window.setContentSize(NSSize(width: 480, height: height))
            window.setFrameOrigin(NSPoint(x: window.frame.minX, y: top - window.frame.height))
        }
    }
}
