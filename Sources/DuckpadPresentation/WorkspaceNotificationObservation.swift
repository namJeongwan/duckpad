import Foundation

final class WorkspaceNotificationObservation: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(center: NotificationCenter, token: NSObjectProtocol) {
        self.center = center
        self.token = token
    }

    func invalidate() {
        center.removeObserver(token)
    }

    deinit {
        invalidate()
    }
}
