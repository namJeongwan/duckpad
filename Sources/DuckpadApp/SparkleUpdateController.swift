import AppKit
import Sparkle

/// Owns Sparkle for the application lifetime. Scheduled checks only show our badge;
/// the standard driver handles user-requested release notes and installation.
@MainActor
final class SparkleUpdateController: NSObject, SPUUpdaterDelegate,
    @preconcurrency SPUStandardUserDriverDelegate {
    var onAvailableVersion: ((String?) -> Void)?
    enum Status { case checking, current, available(String), failed, finished }
    var onStatusChange: ((Status) -> Void)?
    private var controller: SPUStandardUpdaterController!
    private(set) var isStarted = false

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false,
            updaterDelegate: self, userDriverDelegate: self)
    }

    func start() throws {
        guard !isStarted else { return }
        try controller.updater.start()
        isStarted = true
        if controller.updater.automaticallyChecksForUpdates {
            onStatusChange?(.checking)
            controller.updater.checkForUpdatesInBackground()
        }
    }

    func checkForUpdates() {
        guard isStarted, controller.updater.canCheckForUpdates else { return }
        if !controller.updater.sessionInProgress { onStatusChange?(.checking) }
        controller.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        onStatusChange?(.available(item.displayVersionString))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        onAvailableVersion?(nil)
        onStatusChange?(.current)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        // Cancelling a check can finish with no error and no result callback.
        // Always release the checking UI, but preserve a result already received.
        defer { onStatusChange?(.finished) }
        guard let error = error as NSError? else { return }
        let expected = [SUError.noUpdateError, .installationCanceledError, .installationAuthorizeLaterError]
        guard error.domain != SUSparkleErrorDomain || !expected.contains(where: { Int($0.rawValue) == error.code }) else { return }
        onStatusChange?(.failed)
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool { false }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        onAvailableVersion?(update.displayVersionString)
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                 forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        // Respect an explicit skip; dismissal and cancelled installation leave
        // the available version actionable from the badge.
        if choice == .skip { onAvailableVersion?(nil) }
    }

    func standardUserDriverWillFinishUpdateSession() {
        // Sparkle also finishes sessions on dismissal, cancellation, or error.
        // None of those means the known update is no longer available.
    }
}
