import AppKit
import DuckpadDomain

@MainActor
public final class DuckpadAppInfoController: NSObject, NSMenuItemValidation {
    public enum UpdateState: Equatable {
        case idle, checking, noRelease, failed
        case current(AppRelease), available(AppRelease), development(AppRelease)

        var release: AppRelease? {
            switch self {
            case .current(let release), .available(let release), .development(let release): release
            default: nil
            }
        }
    }

    public let appInfo: DuckpadAppInfo
    public private(set) var state: UpdateState = .idle {
        didSet {
            aboutWindow?.render(state)
        }
    }
    private let loadRelease: @Sendable () async throws -> AppRelease?
    private let openURL: (URL) -> Bool
    private var aboutWindow: DuckpadAboutWindowController?
    private var checkTask: Task<Void, Never>?

    public init(
        appInfo: DuckpadAppInfo = .current,
        loadRelease: @escaping @Sendable () async throws -> AppRelease?,
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.appInfo = appInfo
        self.loadRelease = loadRelease
        self.openURL = openURL
    }

    deinit { checkTask?.cancel() }

    public func checkInBackground() {
        guard checkTask == nil else { return }
        checkTask = Task { [weak self] in
            await self?.checkForUpdates()
            self?.checkTask = nil
        }
    }

    public func checkForUpdates() async {
        guard state != .checking else { return }
        state = .checking
        do {
            let release = try await loadRelease()
            try Task.checkCancellation()
            guard let release else { state = .noRelease; return }
            guard let installed = appInfo.version else { state = .development(release); return }
            state = release.version > installed ? .available(release) : .current(release)
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed
        }
    }

    @objc public func performShowAbout(_ sender: Any? = nil) {
        let about = aboutWindow ?? DuckpadAboutWindowController(target: self)
        aboutWindow = about
        about.render(state)
        about.showWindow(sender)
        about.window?.center()
        about.window?.makeKeyAndOrderFront(sender)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc public func performCheckForUpdates(_ sender: Any? = nil) {
        performShowAbout(sender)
        checkInBackground()
    }

    @objc public func performUpdate(_ sender: Any? = nil) {
        switch state {
        case .available(let release), .development(let release): _ = openURL(release.url)
        default: performCheckForUpdates(sender)
        }
    }

    @objc public func performStarOnGitHub(_ sender: Any? = nil) { _ = openURL(DuckpadProject.repositoryURL) }
    @objc public func performOpenReleaseNotes(_ sender: Any? = nil) { _ = openURL(state.release?.url ?? DuckpadProject.releasesURL) }
    @objc public func performReportIssue(_ sender: Any? = nil) { _ = openURL(DuckpadProject.issuesURL) }
    @objc public func performCopyAppInfo(_ sender: Any? = nil) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(appInfo.diagnosticDescription, forType: .string)
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(performCheckForUpdates(_:)) || state != .checking
    }
}
