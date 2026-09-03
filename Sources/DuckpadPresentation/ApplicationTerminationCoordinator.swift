import AppKit

@MainActor
public final class ApplicationTerminationCoordinator {
    private final class WeakController {
        weak var value: DuckpadWindowController?
        init(_ value: DuckpadWindowController) { self.value = value }
    }

    private struct WindowReply {
        let controllerID: ObjectIdentifier
        let reply: @MainActor (Bool) -> Void
    }

    @MainActor
    private final class CleanupRecord {
        let operation: @MainActor () async -> Bool
        var task: Task<Bool, Never>

        init(operation: @escaping @MainActor () async -> Bool) {
            self.operation = operation
            task = Task { await operation() }
        }

        func restart() {
            task = Task { await operation() }
        }
    }

    @MainActor
    private final class ApplicationTaskRecord {
        let task: Task<Void, Never>

        init(task: Task<Void, Never>) {
            self.task = task
        }
    }

    private var controllers: [ObjectIdentifier: WeakController] = [:]
    private var attachmentOrder: [ObjectIdentifier] = []
    private var inFlightReview: Task<Void, Never>?
    private var reviewQueue: [DuckpadWindowController] = []
    private var admittedControllers: [DuckpadWindowController] = []
    private var admittedIDs: Set<ObjectIdentifier> = []
    private var windowCloseReplies: [WindowReply] = []
    private var applicationReplies: [@MainActor (Bool) -> Void] = []
    private var applicationRetryHandler: (@MainActor () -> Void)?
    private var retryApplicationAfterReview = false
    private var applicationReviewInFlight = false
    private var applicationTerminationApproved = false
    private var cleanupRecords: [UUID: CleanupRecord] = [:]
    private var applicationTaskRecords: [UUID: ApplicationTaskRecord] = [:]

    public init() {}

    public convenience init(windowController: DuckpadWindowController) {
        self.init()
        attach(windowController: windowController)
    }

    public func attach(windowController: DuckpadWindowController) {
        compactControllers()
        let id = ObjectIdentifier(windowController)
        if controllers[id] == nil { attachmentOrder.append(id) }
        controllers[id] = WeakController(windowController)
        if applicationTerminationApproved {
            _ = windowController.beginTerminationReviewAdmission()
            return
        }
        guard applicationReviewInFlight else { return }
        guard admit(windowController) else {
            finishReview(approved: false)
            return
        }
        startReviewIfNeeded()
    }

    public func detach(windowController: DuckpadWindowController) {
        let id = ObjectIdentifier(windowController)
        controllers.removeValue(forKey: id)
        attachmentOrder.removeAll { $0 == id }
    }

    public var attachedWindowCount: Int {
        compactControllers()
        return controllers.count
    }

    public var permitsApplicationCommands: Bool {
        !applicationReviewInFlight && !applicationTerminationApproved
    }

    public func trackApplicationTask(_ task: Task<Void, Never>) {
        guard !applicationTerminationApproved else { return }
        let id = UUID()
        let record = ApplicationTaskRecord(task: task)
        applicationTaskRecords[id] = record
        Task { @MainActor [weak self, weak record] in
            await task.value
            guard let self, let record,
                  self.applicationTaskRecords[id] === record else { return }
            self.applicationTaskRecords.removeValue(forKey: id)
        }
    }

    public func trackWindowCloseCleanup(
        _ operation: @escaping @MainActor () async -> Bool
    ) {
        guard !applicationTerminationApproved else { return }
        let id = UUID()
        let record = CleanupRecord(operation: operation)
        cleanupRecords[id] = record
        let task = record.task
        Task { @MainActor [weak self, weak record] in
            guard await task.value, let self, let record,
                  self.cleanupRecords[id] === record else { return }
            self.cleanupRecords.removeValue(forKey: id)
        }
    }

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

    public func requestWindowClose(
        windowController: DuckpadWindowController,
        reply: @escaping @MainActor (Bool) -> Void
    ) {
        guard windowController.requiresTerminationReview else {
            reply(true)
            return
        }
        let id = ObjectIdentifier(windowController)
        guard !windowCloseReplies.contains(where: { $0.controllerID == id }) else { return }
        windowCloseReplies.append(WindowReply(controllerID: id, reply: reply))
        guard admit(windowController) else {
            finishReview(approved: false)
            return
        }
        startReviewIfNeeded()
    }

    public func requestWindowClose(reply: @escaping @MainActor (Bool) -> Void) {
        let live = liveControllers()
        guard live.count == 1, let controller = live.first else {
            reply(false)
            return
        }
        requestWindowClose(windowController: controller, reply: reply)
    }

    public func applicationShouldTerminate(
        reply: @escaping @MainActor (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        applicationReviewInFlight = true
        let requiringReview = liveControllers().filter { $0.requiresTerminationReview }
        if inFlightReview == nil, requiringReview.isEmpty,
           cleanupRecords.isEmpty, applicationTaskRecords.isEmpty {
            applicationReviewInFlight = false
            applicationTerminationApproved = true
            return .terminateNow
        }
        applicationReplies.append(reply)
        for controller in requiringReview where !admittedIDs.contains(ObjectIdentifier(controller)) {
            guard admit(controller) else {
                finishReview(approved: false)
                return .terminateLater
            }
        }
        startReviewIfNeeded()
        return .terminateLater
    }

    private func admit(_ controller: DuckpadWindowController) -> Bool {
        let id = ObjectIdentifier(controller)
        if admittedIDs.contains(id) { return true }
        guard controller.beginTerminationReviewAdmission() else { return false }
        admittedIDs.insert(id)
        admittedControllers.append(controller)
        reviewQueue.append(controller)
        return true
    }

    private func startReviewIfNeeded() {
        guard inFlightReview == nil else { return }
        inFlightReview = Task { @MainActor [weak self] in
            await self?.reviewAdmittedWindows()
        }
    }

    private func reviewAdmittedWindows() async {
        while true {
            while !reviewQueue.isEmpty {
                let controller = reviewQueue.removeFirst()
                guard await controller.continuePreparedTerminationReview() else {
                    finishReview(approved: false)
                    return
                }
            }
            await finishTrackedApplicationTasks()
            guard await finishTrackedCleanups() else {
                finishReview(approved: false)
                return
            }
            // A restored window can attach while a close-cleanup task is
            // suspended. Main-actor serialization makes this empty check the
            // final admission point before the synchronous approval reply.
            guard !reviewQueue.isEmpty else { break }
        }
        finishReview(approved: true)
    }

    private func finishTrackedApplicationTasks() async {
        while let (id, record) = applicationTaskRecords.first {
            await record.task.value
            applicationTaskRecords.removeValue(forKey: id)
        }
    }

    private func finishTrackedCleanups() async -> Bool {
        while let (id, record) = cleanupRecords.first {
            guard await record.task.value else {
                record.restart()
                return false
            }
            cleanupRecords.removeValue(forKey: id)
        }
        return true
    }

    private func finishReview(approved: Bool) {
        if !approved {
            for controller in admittedControllers { controller.cancelPreparedTerminationReview() }
        }
        let windowReplies = windowCloseReplies
        let appReplies = applicationReplies
        if !appReplies.isEmpty {
            applicationReviewInFlight = false
            applicationTerminationApproved = approved
        }
        windowCloseReplies = []
        applicationReplies = []
        reviewQueue = []
        admittedControllers = []
        admittedIDs = []
        inFlightReview = nil
        for item in windowReplies { item.reply(approved) }
        for reply in appReplies { reply(approved) }
        guard retryApplicationAfterReview else { return }
        retryApplicationAfterReview = false
        applicationRetryHandler?()
    }

    private func liveControllers() -> [DuckpadWindowController] {
        compactControllers()
        return attachmentOrder.compactMap { controllers[$0]?.value }
    }

    private func compactControllers() {
        controllers = controllers.filter { $0.value.value != nil }
        attachmentOrder.removeAll { controllers[$0] == nil }
    }
}
