import AppKit
import DuckpadApplication

@MainActor
public final class EditorGroupDropOverlay: NSView {
    public enum Zone: CaseIterable, Hashable, Sendable {
        case left
        case right
        case up
        case down

        public var precedesTarget: Bool { self == .left || self == .up }

        public var orientation: EditorGroupSplitOrientation {
            switch self {
            case .left, .right: .sideBySide
            case .up, .down: .stacked
            }
        }
    }

    public private(set) var highlightedZone: Zone?
    public var isPresenting: Bool { !isHidden }

    private var zoneViews: [Zone: EditorGroupDropZoneView] = [:]

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizesSubviews = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(false)
        for zone in Zone.allCases {
            let view = EditorGroupDropZoneView(zone: zone)
            zoneViews[zone] = view
            addSubview(view)
        }
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override func layout() {
        super.layout()
        for (zone, view) in zoneViews { view.frame = previewFrame(for: zone) }
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public func zone(at point: NSPoint) -> Zone? {
        guard bounds.contains(point), bounds.width > 0, bounds.height > 0 else { return nil }
        let distances: [(Zone, CGFloat)] = [
            (.left, (point.x - bounds.minX) / bounds.width),
            (.right, (bounds.maxX - point.x) / bounds.width),
            (.up, (bounds.maxY - point.y) / bounds.height),
            (.down, (point.y - bounds.minY) / bounds.height),
        ]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 < 0.40 else { return nil }
        return nearest.0
    }

    public func present(highlighting zone: Zone?) {
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0
        isHidden = false
        highlightedZone = zone
        for (candidate, view) in zoneViews {
            view.isHidden = candidate != zone
            view.setHighlighted(candidate == zone)
        }
    }

    public func presentTransfer() {
        isHidden = false
        highlightedZone = nil
        for view in zoneViews.values { view.isHidden = true }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        }
        layer?.borderWidth = 1
    }

    public func dismiss() {
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0
        highlightedZone = nil
        for view in zoneViews.values { view.setHighlighted(false) }
        isHidden = true
    }

    public func previewFrame(for zone: Zone) -> NSRect {
        switch zone {
        case .left: NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width / 2, height: bounds.height)
        case .right: NSRect(x: bounds.midX, y: bounds.minY, width: bounds.width / 2, height: bounds.height)
        case .up: NSRect(x: bounds.minX, y: bounds.midY, width: bounds.width, height: bounds.height / 2)
        case .down: NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height / 2)
        }
    }
}
