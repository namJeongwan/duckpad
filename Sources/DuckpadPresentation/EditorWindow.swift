import AppKit

/// Keep the frame cursor in sync even when a view/menu update replaces the
/// cursor without crossing AppKit's existing resize tracking region again.
@MainActor
final class EditorWindow: NSWindow {
    private var appliedFrameCursor = false

    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        if event.type == .mouseMoved || event.type == .cursorUpdate {
            refreshFrameCursor()
        }
    }

    override func update() {
        super.update()
        refreshFrameCursor()
    }

    private func refreshFrameCursor() {
        guard #available(macOS 15.0, *) else { return }
        // Do not replace drag/copy feedback or reset cursor rects mid-gesture.
        guard NSEvent.pressedMouseButtons == 0 else {
            appliedFrameCursor = false
            return
        }
        let point = NSEvent.mouseLocation
        guard NSApp.isActive, isKeyWindow, isVisible, styleMask.contains(.resizable),
              !styleMask.contains(.fullScreen), attachedSheet == nil, NSApp.modalWindow == nil, !inLiveResize,
              let position = Self.resizePosition(at: point, frame: frame),
              Self.isTopmost(windowNumber: windowNumber, at: point, frame: frame) else {
            if appliedFrameCursor {
                appliedFrameCursor = false
                // Recompute the underlying editor/control cursor on leaving the
                // frame; never replace an I-beam or link cursor with an arrow.
                resetCursorRects()
            }
            return
        }
        let horizontal = [.left, .right, .topLeft, .topRight, .bottomLeft, .bottomRight].contains(position)
        let vertical = [.top, .bottom, .topLeft, .topRight, .bottomLeft, .bottomRight].contains(position)
        let contentMinimum = frameRect(forContentRect: NSRect(origin: .zero, size: contentMinSize)).size
        let contentMaximum = frameRect(forContentRect: NSRect(origin: .zero, size: contentMaxSize)).size
        let minimum = NSSize(width: max(minSize.width, contentMinimum.width),
                             height: max(minSize.height, contentMinimum.height))
        let maximum = NSSize(width: min(maxSize.width, contentMaximum.width),
                             height: min(maxSize.height, contentMaximum.height))
        var directions: NSCursor.FrameResizeDirection.Set = []
        if (horizontal && frame.width > minimum.width) || (vertical && frame.height > minimum.height) {
            directions.insert(.inward)
        }
        if (horizontal && frame.width < maximum.width) || (vertical && frame.height < maximum.height) {
            directions.insert(.outward)
        }
        guard !directions.isEmpty else {
            if appliedFrameCursor { resetCursorRects(); appliedFrameCursor = false }
            return
        }
        NSCursor.frameResize(position: position, directions: directions).set()
        appliedFrameCursor = true
    }

    @available(macOS 15.0, *)
    static func resizePosition(at point: NSPoint, frame: NSRect) -> NSCursor.FrameResizePosition? {
        // Restrict recovery to the narrow native frame band, not content or
        // title-bar controls. Keep the native hit-testing/drag behavior intact.
        let band: CGFloat = 3
        guard frame.insetBy(dx: -band, dy: -band).contains(point) else { return nil }
        let left = abs(point.x - frame.minX) <= band
        let right = abs(point.x - frame.maxX) <= band
        let bottom = abs(point.y - frame.minY) <= band
        let top = abs(point.y - frame.maxY) <= band
        guard left || right || bottom || top else { return nil }
        let corner: CGFloat = 12
        if (left || top), point.x <= frame.minX + corner, point.y >= frame.maxY - corner { return .topLeft }
        if (right || top), point.x >= frame.maxX - corner, point.y >= frame.maxY - corner { return .topRight }
        if (left || bottom), point.x <= frame.minX + corner, point.y <= frame.minY + corner { return .bottomLeft }
        if (right || bottom), point.x >= frame.maxX - corner, point.y <= frame.minY + corner { return .bottomRight }
        if left { return .left }; if right { return .right }
        return top ? .top : .bottom
    }

    private static func isTopmost(windowNumber: Int, at point: NSPoint, frame: NSRect) -> Bool {
        // A point just outside the border may belong to the desktop. Check the
        // nearest interior point as well, without affecting overlapping windows.
        let hit = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        if hit == windowNumber { return true }
        guard !frame.contains(point), hit <= 0 else { return false }
        let interior = NSPoint(x: min(max(point.x, frame.minX + 1), frame.maxX - 1),
                               y: min(max(point.y, frame.minY + 1), frame.maxY - 1))
        return NSWindow.windowNumber(at: interior, belowWindowWithWindowNumber: 0) == windowNumber
    }
}
