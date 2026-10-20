import AppKit
import DuckpadApplication
import DuckpadDomain
import Testing
@testable import DuckpadPresentation

@MainActor
private final class PopupClickTarget: NSView {
    var clicks = 0
    override var acceptsFirstResponder: Bool { true }
    // SCIContentView accepts the first click when its window is inactive.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { clicks += 1; window?.makeFirstResponder(self) }
}

@Suite(.serialized) @MainActor
struct SearchPopupDismissalTests {
    private func click(_ window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .init(x: 25, y: 25), modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
    @Test func editorClickClosesBothPopupsAndReachesTheEditorOnFirstClick() throws {
        _ = NSApplication.shared
        let parent = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        let target = PopupClickTarget(); parent.contentView = target
        let files = FileNameSearchController(), multi = MultiFileSearchController()
        parent.makeKeyAndOrderFront(nil)
        defer { files.dismiss(); multi.dismiss(); parent.close() }
        files.present(in: parent, initial: [.init(name: "test.txt", path: "/test.txt", target: .tab(TabID()))])
        #expect(files.window?.isVisible == true)
        NSApp.sendEvent(try click(parent))
        #expect(files.window?.isVisible == false)
        #expect(target.clicks == 1)
        #expect(parent.firstResponder === target)
        multi.present(replace: false, in: parent)
        #expect(multi.window?.isVisible == true)
        NSApp.sendEvent(try click(parent))
        #expect(multi.window?.isVisible == false)
        #expect(target.clicks == 2)
        #expect(parent.firstResponder === target)
    }
    @Test func clicksInsideThePopupOrItsSheetDoNotDismissIt() throws {
        _ = NSApplication.shared
        let panel = MultiFileSearchController()
        panel.present(replace: true, in: nil)
        defer { panel.dismiss() }
        let window = try #require(panel.window)
        let dismissal = SearchPopupDismissal()
        var dismissed = 0
        dismissal.start(window: window) { dismissed += 1 }
        defer { dismissal.stop() }
        dismissal.handle(try click(window))
        #expect(dismissed == 0)
        let sheet = NSPanel(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        window.beginSheet(sheet)
        dismissal.handle(try click(sheet))
        #expect(dismissed == 0)
        window.endSheet(sheet); sheet.orderOut(nil)
    }
    @Test func closingAndReopeningDoesNotLeaveAnOldOutsideClickMonitor() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.makeKeyAndOrderFront(nil)
        let other = NSWindow(contentRect: .init(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { window.close(); other.close() }
        let observer = SearchPopupDismissal(); var count = 0
        observer.start(window: window) { count += 100 }
        observer.stop()
        observer.start(window: window) { count += 1 }
        observer.handle(try click(other))
        #expect(count == 1)
        observer.stop()
        observer.handle(try click(other))
        #expect(count == 1)
    }
    @Test func menuTrackingDoesNotTreatNativeMenuWindowsAsOutsideClicks() throws {
        _ = NSApplication.shared
        let panel = MultiFileSearchController(); panel.present(replace: false, in: nil)
        let window = try #require(panel.window)
        let menuWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [], backing: .buffered, defer: false)
        menuWindow.isReleasedWhenClosed = false
        let observer = SearchPopupDismissal(); var count = 0
        observer.start(window: window) { count += 1 }
        defer { observer.stop(); panel.dismiss(); menuWindow.close() }
        let menu = NSMenu()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        observer.handle(try click(menuWindow))
        #expect(count == 0)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        observer.handle(try click(menuWindow))
        #expect(count == 1)
    }
}
