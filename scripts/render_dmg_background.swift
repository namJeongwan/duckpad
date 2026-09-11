import AppKit

// Package the approved artwork at Finder's logical size with Retina support.
guard CommandLine.arguments.count == 3 else {
    fputs("Usage: swift render_dmg_background.swift <resources> <output.tiff>\n", stderr)
    exit(64)
}
let resources = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let artwork = NSImage(contentsOf: resources.appendingPathComponent("background.png")) else {
    fputs("Missing or invalid DMG background.png\n", stderr)
    exit(66)
}
let size = NSSize(width: 680, height: 384)
let image = NSImage(size: size)

for scale in [1, 2] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
        pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    artwork.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    image.addRepresentation(rep)
}
try image.tiffRepresentation!.write(to: output, options: .atomic)
