import AppKit

@MainActor
public final class ApplicationTerminationCoordinator {
    private weak var windowController: DuckpadWindowController?
    private var inFlightReview: Task<Void, Never>?
    private var windowCloseReply: (@MainActor (Bool) -> Void)?
    private var applicationReplies: [@MainActor (Bool) -> Void] = []

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
        guard windowController.hasDirtyDocuments else {
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
        guard windowController.hasDirtyDocuments else { return .terminateNow }
        applicationReplies.append(reply)
        beginReview(using: windowController)
        return .terminateLater
    }

    private func beginReview(using windowController: DuckpadWindowController) {
        precondition(inFlightReview == nil)
        inFlightReview = Task { @MainActor [weak self, weak windowController] in
            let approved = await windowController?.reviewDirtyDocumentsForTermination() ?? false
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
    }
}
