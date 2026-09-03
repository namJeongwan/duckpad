import AppKit
import DuckpadApplication
import DuckpadDomain

public struct DuckpadSettingsSmokeState: Equatable, Sendable {
    public let appearanceMode: AppAppearanceMode
    public let defaultWordWrapEnabled: Bool
    public let defaultWrapMarkerVisible: Bool
    public let wrapMarkerControlEnabled: Bool
    public let status: String

    public init(
        appearanceMode: AppAppearanceMode,
        defaultWordWrapEnabled: Bool,
        defaultWrapMarkerVisible: Bool,
        wrapMarkerControlEnabled: Bool,
        status: String
    ) {
        self.appearanceMode = appearanceMode
        self.defaultWordWrapEnabled = defaultWordWrapEnabled
        self.defaultWrapMarkerVisible = defaultWrapMarkerVisible
        self.wrapMarkerControlEnabled = wrapMarkerControlEnabled
        self.status = status
    }
}

@MainActor
public final class DuckpadSettingsWindowController: NSWindowController, NSWindowDelegate {
    private let appearance = NSPopUpButton(frame: .zero, pullsDown: false)
    private let wordWrap = NSButton(checkboxWithTitle: "Wrap long lines in new tabs", target: nil, action: nil)
    private let wrapMarkers = NSButton(checkboxWithTitle: "Show wrap symbols in new tabs", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private var settings = AppSettings.defaults
    private var update: ((AppSettings) async -> AppSettingsUpdateOutcome)?
    private var updateTask: Task<Void, Never>?
    public var acceptsUpdates: (() -> Bool)?
    public var onUpdateTaskStarted: ((Task<Void, Never>) -> Void)?

    public init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Duckpad Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        configureContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public func present(
        settings: AppSettings,
        update: @escaping (AppSettings) async -> AppSettingsUpdateOutcome
    ) {
        self.update = update
        render(settings)
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    public func smokeState() -> DuckpadSettingsSmokeState {
        DuckpadSettingsSmokeState(
            appearanceMode: selectedAppearanceMode,
            defaultWordWrapEnabled: wordWrap.state == .on,
            defaultWrapMarkerVisible: wrapMarkers.state == .on,
            wrapMarkerControlEnabled: wrapMarkers.isEnabled,
            status: status.stringValue
        )
    }

    public func applyForSmoke(_ settings: AppSettings) async {
        await apply(settings)
    }

    public func submitForSmoke(_ settings: AppSettings) {
        startUpdate(settings)
    }

    public func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil)
    }

    deinit {
        updateTask?.cancel()
    }

    private func configureContent() {
        guard let content = window?.contentView else { return }
        let heading = NSTextField(labelWithString: "Appearance and editor defaults")
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        heading.setAccessibilityLabel("Appearance and editor defaults")

        let appearanceLabel = NSTextField(labelWithString: "Appearance")
        appearance.removeAllItems()
        for mode in AppAppearanceMode.allCases {
            appearance.addItem(withTitle: title(for: mode))
            appearance.lastItem?.representedObject = mode.rawValue
        }
        appearance.target = self
        appearance.action = #selector(settingChanged(_:))
        appearance.setAccessibilityIdentifier("duckpad.settings.appearance")
        appearance.setAccessibilityLabel("Application appearance")

        let appearanceRow = NSStackView(views: [appearanceLabel, appearance])
        appearanceRow.orientation = .horizontal
        appearanceRow.alignment = .centerY
        appearanceRow.distribution = .fill
        appearanceLabel.setContentHuggingPriority(.required, for: .horizontal)

        wordWrap.target = self
        wordWrap.action = #selector(settingChanged(_:))
        wordWrap.setAccessibilityIdentifier("duckpad.settings.default-word-wrap")
        wordWrap.setAccessibilityLabel("Wrap long lines in new tabs")
        wrapMarkers.target = self
        wrapMarkers.action = #selector(settingChanged(_:))
        wrapMarkers.setAccessibilityIdentifier("duckpad.settings.default-wrap-markers")
        wrapMarkers.setAccessibilityLabel("Show wrap symbols in new tabs")

        let explanation = NSTextField(wrappingLabelWithString:
            "These editor options apply to new tabs. Existing and restored tabs keep their own view settings. High Contrast always follows macOS accessibility settings."
        )
        explanation.textColor = .secondaryLabelColor
        status.textColor = .secondaryLabelColor
        status.setAccessibilityIdentifier("duckpad.settings.status")
        status.setAccessibilityLabel("Settings status")

        let stack = NSStackView(views: [heading, appearanceRow, wordWrap, wrapMarkers, explanation, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            appearanceRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
        ])
    }

    @objc private func settingChanged(_ sender: Any?) {
        let proposed = AppSettings(
            appearanceMode: selectedAppearanceMode,
            defaultWordWrapEnabled: wordWrap.state == .on,
            defaultWrapMarkerVisible: wrapMarkers.state == .on
        )
        startUpdate(proposed)
    }

    private func startUpdate(_ proposed: AppSettings) {
        guard acceptsUpdates?() ?? true else {
            NSSound.beep()
            return
        }
        setControlsEnabled(false)
        updateTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.apply(proposed)
            self.setControlsEnabled(true)
        }
        updateTask = task
        onUpdateTaskStarted?(task)
    }

    private func apply(_ proposed: AppSettings) async {
        guard let update else { return }
        switch await update(proposed) {
        case .saved(let saved):
            render(saved)
            status.stringValue = "Saved"
        case .savedWithWarning(let saved, let failure):
            render(saved)
            status.stringValue = "Saved, but durability could not be confirmed: \(failure)"
        case .failed(let failure):
            render(settings)
            status.stringValue = "Could not save settings: \(failure)"
            NSSound.beep()
        }
    }

    private func render(_ settings: AppSettings) {
        self.settings = settings
        if let index = AppAppearanceMode.allCases.firstIndex(of: settings.appearanceMode) {
            appearance.selectItem(at: index)
        }
        wordWrap.state = settings.defaultWordWrapEnabled ? .on : .off
        wrapMarkers.state = settings.defaultWrapMarkerVisible ? .on : .off
        wrapMarkers.isEnabled = settings.defaultWordWrapEnabled
        status.stringValue = ""
    }

    private func setControlsEnabled(_ enabled: Bool) {
        appearance.isEnabled = enabled
        wordWrap.isEnabled = enabled
        wrapMarkers.isEnabled = enabled && wordWrap.state == .on
    }

    private var selectedAppearanceMode: AppAppearanceMode {
        guard let raw = appearance.selectedItem?.representedObject as? String,
              let mode = AppAppearanceMode(rawValue: raw) else { return .system }
        return mode
    }

    private func title(for mode: AppAppearanceMode) -> String {
        switch mode {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}
