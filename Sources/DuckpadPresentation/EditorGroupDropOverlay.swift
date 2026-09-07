import AppKit
import DuckpadApplication

@MainActor
public final class EditorGroupDropOverlay: NSView {
    public enum Zone: Equatable, Sendable {
        case right
        case down

        public var orientation: EditorGroupSplitOrientation {
            switch self {
            case .right: .sideBySide
            case .down: .stacked
            }
        }
    }

    public private(set) var highlightedZone: Zone?
    public var isPresenting: Bool { !isHidden }

    private let rightDropZone = EditorGroupDropZoneView(zone: .right)
    private let downDropZone = EditorGroupDropZoneView(zone: .down)

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizesSubviews = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(false)
        addSubview(rightDropZone)
        addSubview(downDropZone)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override func layout() {
        super.layout()
        let frames = zoneFrames
        rightDropZone.frame = frames.right
        downDropZone.frame = frames.down
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public func zone(at point: NSPoint) -> Zone? {
        let frames = zoneFrames
        if frames.down.contains(point) { return .down }
        if frames.right.contains(point) { return .right }
        return nil
    }

    public func present(highlighting zone: Zone?) {
        isHidden = false
        highlightedZone = zone
        rightDropZone.setHighlighted(zone == .right)
        downDropZone.setHighlighted(zone == .down)
    }

    public func dismiss() {
        highlightedZone = nil
        rightDropZone.setHighlighted(false)
        downDropZone.setHighlighted(false)
        isHidden = true
    }

    private var zoneFrames: (right: NSRect, down: NSRect) {
        guard bounds.width > 0, bounds.height > 0 else { return (.zero, .zero) }
        let edgeWidth = min(bounds.width * 0.5, max(72, bounds.width * 0.30))
        let edgeHeight = min(bounds.height * 0.5, max(72, bounds.height * 0.30))
        let right = NSRect(
            x: bounds.maxX - edgeWidth,
            y: bounds.minY + edgeHeight,
            width: edgeWidth,
            height: max(0, bounds.height - edgeHeight)
        )
        let down = NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: edgeHeight
        )
        return (right, down)
    }
}
