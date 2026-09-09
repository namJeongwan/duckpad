import AppKit

@MainActor
final class MenuPresentationSpy: NSMenu {
    nonisolated(unsafe) private(set) var presentationCount = 0
    nonisolated(unsafe) private(set) var presentedItem: NSMenuItem?
    nonisolated(unsafe) private(set) var presentedLocation: NSPoint?
    nonisolated(unsafe) private(set) weak var presentedView: NSView?
    nonisolated(unsafe) var onPresent: (@MainActor () -> Void)?

    override func popUp(
        positioning item: NSMenuItem?,
        at location: NSPoint,
        in view: NSView?
    ) -> Bool {
        presentationCount += 1
        presentedItem = item
        presentedLocation = location
        presentedView = view
        MainActor.assumeIsolated { onPresent?() }
        return false
    }
}
