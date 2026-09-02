import AppKit
import Foundation
import Testing

@Test func appIconSourceSetHasExactPixelsAlphaAndValidICNS() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let root = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let resources = root.appendingPathComponent("Sources/DuckpadApp/Resources", isDirectory: true)
    let expected: [String: Int] = [
        "icon_16x16.png": 16,
        "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32,
        "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128,
        "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512,
        "icon_512x512@2x.png": 1024,
    ]

    for (name, pixels) in expected {
        let data = try Data(contentsOf: resources.appendingPathComponent("AppIcon.iconset/\(name)"))
        let representation = try #require(NSBitmapImageRep(data: data))
        #expect(representation.pixelsWide == pixels)
        #expect(representation.pixelsHigh == pixels)
        #expect(representation.hasAlpha)
    }

    let iconURL = resources.appendingPathComponent("Duckpad.icns")
    let iconData = try Data(contentsOf: iconURL)
    #expect(iconData.starts(with: Data("icns".utf8)))
    let icon = try #require(NSImage(contentsOf: iconURL))
    let pixelSizes = Set(icon.representations.map { $0.pixelsWide })
    #expect(pixelSizes.contains(16))
    #expect(pixelSizes.contains(1024))
}
