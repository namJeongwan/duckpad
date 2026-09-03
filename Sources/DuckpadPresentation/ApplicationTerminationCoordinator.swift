import AppKit

@MainActor
public final class ApplicationTerminationCoordinator {
    private weak var windowController: DuckpadWindowController?
    private var inFlightReview: Task<Void, Never>?
    private var windowCloseReply: (@MainActor (Bool) -> Void)?
    private var applicationReplies: [@MainActor (Bool) -> Void] = []
    private var applicationRetryHandler: (@MainActor () -> Void)?
    private var retryApplicationAfterReview = false

    public init() {}

    public convenience init(windowController: DuckpadWindowController) {
        self.init()
        attach(windowController: windowController)
    }

    public func attach(windowController: DuckpadWindowController) {
        precondition(
            self.windowController == nil || self.windowController === windowController,
            "a termination coordinator cannot be shared by different windows"
        )
        self.windowController = windowController
    }

    /// The app delegate installs a handler that starts a new native termination
    /// request. A file Retry therefore receives a new terminateLater/reply pair
    /// instead of being downgraded to an ordinary tab close.
    public func installApplicationRetryHandler(
        _ handler: @escaping @MainActor () -> Void
    ) {
        applicationRetryHandler = handler
    }

    public func retryApplicationTermination() {
        guard inFlightReview == nil else {
            retryApplicationAfterReview = true
            return
        }
        applicationRetryHandler?()
    }

    /// Registers the red-window-close caller with the same review used by Cmd-Q.
    /// Repeated red-close events are coalesced into one close reply.
    public func requestWindowClose(
        reply: @escaping @MainActor (Bool) -> Void
    ) {
        if inFlightReview != nil {
            if windowCloseReply == nil { windowCloseReply = reply }
            return
        }
        guard let windowController else {
            reply(false)
            return
        }
        guard windowController.requiresTerminationReview else {
            reply(true)
            return
        }
        windowCloseReply = reply
        beginReview(using: windowController)
    }

    /// Returns `.terminateLater` while the shared dirty-document review awaits
    /// panels/saves. The App delegate must forward `reply` to NSApplication.
    public func applicationShouldTerminate(
        reply: @escaping @MainActor (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        guard let windowController else { return .terminateNow }
        if inFlightReview != nil {
            applicationReplies.append(reply)
            return .terminateLater
        }
        guard windowController.requiresTerminationReview else { return .terminateNow }
        applicationReplies.append(reply)
        beginReview(using: windowController)
        return .terminateLater
    }

    private func beginReview(using windowController: DuckpadWindowController) {
        precondition(inFlightReview == nil)
        guard windowController.beginTerminationReviewAdmission() else {
            finishReview(approved: false)
            return
        }
        inFlightReview = Task { @MainActor [weak self, weak windowController] in
            let approved = await windowController?.continuePreparedTerminationReview() ?? false
            self?.finishReview(approved: approved)
        }
    }

    private func finishReview(approved: Bool) {
        let windowReply = windowCloseReply
        let appReplies = applicationReplies
        windowCloseReply = nil
        applicationReplies = []
        inFlightReview = nil
        windowReply?(approved)
        for reply in appReplies { reply(approved) }
        guard retryApplicationAfterReview else { return }
        retryApplicationAfterReview = false
        applicationRetryHandler?()
    }
}
