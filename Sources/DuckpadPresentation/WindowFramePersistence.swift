import AppKit

/// Stores window geometry independently of the executable's bundle identity.
@MainActor
public final class WindowFramePersistence {
    private let defaults: UserDefaults
    private let frameKey: String
    private let fallbackKey: String

    public init(defaults: UserDefaults, frameKey: String, fallbackKey: String) {
        self.defaults = defaults
        self.frameKey = frameKey
        self.fallbackKey = fallbackKey
    }

    @discardableResult
    public func restore(_ window: NSWindow) -> Bool {
        guard let frame = readFrame(forKey: frameKey) ?? readFrame(forKey: fallbackKey) else {
            return false
        }
        window.setFrame(Self.visibleFrame(frame, minimumSize: window.minSize), display: false)
        return true
    }

    public func save(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen), !window.isMiniaturized else { return }
        let frame = window.frame
        guard frame.width > 0, frame.height > 0,
              [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) else { return }
        let values: [String: Double] = [
            "x": frame.minX, "y": frame.minY,
            "width": frame.width, "height": frame.height,
        ]
        defaults.set(values, forKey: frameKey)
        defaults.set(values, forKey: fallbackKey)
    }

    private func readFrame(forKey key: String) -> NSRect? {
        guard let values = defaults.dictionary(forKey: key),
              let x = values["x"] as? Double, let y = values["y"] as? Double,
              let width = values["width"] as? Double, let height = values["height"] as? Double,
              [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private static func visibleFrame(_ frame: NSRect, minimumSize: NSSize) -> NSRect {
        let screens = NSScreen.screens
        let intersecting = screens.filter { $0.visibleFrame.intersects(frame) }
        let screen = intersecting.max { lhs, rhs in
            let left = lhs.visibleFrame.intersection(frame)
            let right = rhs.visibleFrame.intersection(frame)
            return left.width * left.height < right.width * right.height
        } ?? NSScreen.main ?? screens.first
        guard let visible = screen?.visibleFrame else { return frame }
        let width = min(max(frame.width, minimumSize.width), visible.width)
        let height = min(max(frame.height, minimumSize.height), visible.height)
        return NSRect(
            x: min(max(frame.minX, visible.minX), visible.maxX - width),
            y: min(max(frame.minY, visible.minY), visible.maxY - height),
            width: width, height: height
        )
    }
}
