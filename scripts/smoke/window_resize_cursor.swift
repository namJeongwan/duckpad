// Run with an unlocked macOS desktop and Accessibility permission:
// swiftc -parse-as-library Sources/DuckpadPresentation/EditorWindow.swift \
//   scripts/smoke/window_resize_cursor.swift -o /tmp/duckpad-frame-cursor-smoke
// /tmp/duckpad-frame-cursor-smoke
// --baseline uses NSWindow to demonstrate stale-cursor recovery failing.
import AppKit
import CoreGraphics

@MainActor
private final class CursorTestView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(visibleRect, cursor: .iBeam)
    }
}

@main
struct WindowResizeCursorSmoke {
    @MainActor static func main() {
        Task { await run() }
        NSApplication.shared.run()
    }

    @MainActor static func run() async {
        guard #available(macOS 15.0, *), CGPreflightPostEventAccess() else {
            print("SKIP: macOS 15+ and Accessibility permission required")
            exit(77)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let originalApp = NSWorkspace.shared.frontmostApplication
        let originalPoint = CGEvent(source: nil)!.location
        let type: NSWindow.Type = CommandLine.arguments.contains("--baseline") ? NSWindow.self : EditorWindow.self
        let window = type.init(contentRect: NSRect(x: 300, y: 300, width: 600, height: 400),
                               styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Duckpad isolated frame cursor test"
        window.contentView = CursorTestView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .milliseconds(250))
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            print("\(condition ? "PASS" : "FAIL"): \(name)")
            if !condition { failures += 1 }
        }
        func same(_ lhs: NSCursor, _ rhs: NSCursor) -> Bool {
            lhs.hotSpot == rhs.hotSpot && lhs.image.tiffRepresentation == rhs.image.tiffRepresentation
        }
        let screenHeight = NSScreen.screens[0].frame.height
        func move(_ point: NSPoint) async {
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                    mouseCursorPosition: CGPoint(x: point.x, y: screenHeight - point.y), mouseButton: .left)!
                .post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(100))
        }
        let frame = window.frame
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let cases: [(String, NSPoint, NSCursor.FrameResizePosition)] = [
            ("left", .init(x: frame.minX + 2, y: frame.midY), .left),
            ("right", .init(x: frame.maxX - 2, y: frame.midY), .right),
            ("top", .init(x: frame.midX, y: frame.maxY - 2), .top),
            ("bottom", .init(x: frame.midX, y: frame.minY + 2), .bottom),
            ("topLeft", .init(x: frame.minX + 2, y: frame.maxY - 2), .topLeft),
            ("topRight", .init(x: frame.maxX - 2, y: frame.maxY - 2), .topRight),
            ("bottomLeft", .init(x: frame.minX + 2, y: frame.minY + 2), .bottomLeft),
            ("bottomRight", .init(x: frame.maxX - 2, y: frame.minY + 2), .bottomRight),
        ]
        for (name, point, position) in cases {
            await move(center)
            await move(point)
            let expected = NSCursor.frameResize(position: position, directions: [.inward, .outward])
            NSCursor.arrow.set() // Simulate a stale cursor without leaving the frame.
            window.update()
            try? await Task.sleep(for: .milliseconds(50))
            // Frame cursors are installed at the WindowServer level; .current
            // can still report the application cursor beneath that override.
            check(same(NSCursor.currentSystem ?? .current, expected), "recover visible \(name) cursor")
            await move(center)
            check(same(NSCursor.currentSystem ?? .current, .iBeam), "restore editor after \(name)")
        }
        NSCursor.pointingHand.set()
        window.update()
        try? await Task.sleep(for: .milliseconds(50))
        check(same(NSCursor.currentSystem ?? .current, .pointingHand), "leave interior control cursor unchanged")

        // A pressed button must not have its drag feedback replaced by update().
        let edge = cases[0].1
        await move(center)
        let eventPoint = CGPoint(x: center.x, y: screenHeight - center.y)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: eventPoint, mouseButton: .left)!
            .post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(50))
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                mouseCursorPosition: CGPoint(x: edge.x, y: screenHeight - edge.y), mouseButton: .left)!
            .post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(50))
        NSCursor.closedHand.set()
        window.update()
        try? await Task.sleep(for: .milliseconds(50))
        check(NSEvent.pressedMouseButtons != 0 && same(NSCursor.currentSystem ?? .current, .closedHand), "preserve active drag cursor")
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                mouseCursorPosition: CGPoint(x: edge.x, y: screenHeight - edge.y), mouseButton: .left)!
            .post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(50))
        await move(center)
        window.styleMask.remove(.resizable)
        await move(edge)
        NSCursor.arrow.set()
        window.update()
        try? await Task.sleep(for: .milliseconds(50))
        check(same(NSCursor.currentSystem ?? .current, .arrow), "non-resizable window unchanged")
        window.close()
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: originalPoint, mouseButton: .left)!
            .post(tap: .cghidEventTap)
        originalApp?.activate()
        print("\(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
