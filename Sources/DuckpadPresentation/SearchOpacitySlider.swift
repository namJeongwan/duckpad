import AppKit

@MainActor
final class SearchOpacitySlider: NSSlider {
    var onTrackingChange: (() -> Void)?
    private(set) var isAdjustingOpacity = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = SearchOpacitySliderCell()
        minValue = 0.5
        maxValue = 1
        doubleValue = 0.75
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isAdjustingOpacity = true
        onTrackingChange?()
        defer {
            isAdjustingOpacity = false
            onTrackingChange?()
        }
        super.mouseDown(with: event)
    }
}

@MainActor
private final class SearchOpacitySliderCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let dark = controlView?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let track = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
        NSColor(calibratedWhite: dark ? 0.4 : 0.7, alpha: 1).setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        guard isEnabled else { return }
        let fraction = CGFloat((doubleValue - minValue) / max(0.001, maxValue - minValue))
        let fill = NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height)
        NSColor.controlAccentColor.withAlphaComponent(1).setFill()
        NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
    }

    override func drawKnob(_ knobRect: NSRect) {
        let diameter: CGFloat = 12
        let rect = NSRect(x: knobRect.midX - diameter / 2, y: knobRect.midY - diameter / 2,
                          width: diameter, height: diameter)
        let path = NSBezierPath(ovalIn: rect)
        NSColor(calibratedWhite: isEnabled ? 1 : 0.82, alpha: 1).setFill()
        path.fill()
        NSColor(calibratedWhite: 0.42, alpha: 1).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
