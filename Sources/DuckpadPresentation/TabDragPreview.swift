import AppKit

/// A drag represents the document, without copying hover buttons or the width
/// added to justify a multiline tab row.
@MainActor
enum TabDragPreview {
    static func prepare(_ items: [NSDraggingItem], at pointer: NSPoint) {
        for item in items {
            guard let image = item.imageComponents?.first?.contents as? NSImage else { continue }
            item.setDraggingFrame(frame(imageSize: image.size, at: pointer), contents: image)
        }
    }

    static func frame(imageSize: NSSize, at pointer: NSPoint) -> NSRect {
        NSRect(x: pointer.x - min(24, imageSize.width / 2), y: pointer.y - imageSize.height / 2,
               width: imageSize.width, height: imageSize.height)
    }

    static func image(title: String, icon: NSImage?, isDirty: Bool, appearance: NSAppearance) -> NSImage {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let width = min(360, max(80, (title as NSString).size(withAttributes: [.font: font]).width + 44))
        let image = NSImage(size: NSSize(width: ceil(width), height: 29))
        appearance.performAsCurrentDrawingAppearance {
            image.lockFocus()
            defer { image.unlockFocus() }
            let bounds = NSRect(origin: .zero, size: image.size).insetBy(dx: 0.5, dy: 0.5)
            let shape = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
            NSColor.windowBackgroundColor.setFill()
            shape.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            shape.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.65).setStroke()
            shape.lineWidth = 1
            shape.stroke()
            icon?.draw(in: NSRect(x: 9, y: 6, width: 17, height: 17), from: .zero,
                       operation: .sourceOver, fraction: 1)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingMiddle
            (title as NSString).draw(in: NSRect(x: 31, y: 7, width: width - 43, height: 16),
                                    withAttributes: [.font: font, .foregroundColor: NSColor.labelColor,
                                                     .paragraphStyle: paragraph])
            if isDirty {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: width - 9, y: 12, width: 4, height: 4)).fill()
            }
        }
        return image
    }
}
