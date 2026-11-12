import AppKit

@MainActor final class DiagramCanvas: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill(); dirtyRect.fill()
        image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.high])
    }
}
