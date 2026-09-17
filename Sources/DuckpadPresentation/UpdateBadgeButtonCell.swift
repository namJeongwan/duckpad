import AppKit

@MainActor
final class UpdateBadgeButtonCell: NSButtonCell {
    override func drawImage(_ image: NSImage, withFrame frame: NSRect, in controlView: NSView) {
        super.drawImage(image, withFrame: frame.offsetBy(dx: -2, dy: 0), in: controlView)
    }
}
