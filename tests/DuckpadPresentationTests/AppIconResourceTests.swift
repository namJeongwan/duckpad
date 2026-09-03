import AppKit
import Foundation
import Testing

private struct IconAlphaBounds: Equatable {
    let minX: Int
    let minY: Int
    let maxX: Int
    let maxY: Int

    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }
}

private enum IconTestError: Error { case missingCGImage, contextCreationFailed }

private func canonicalRGBA(_ representation: NSBitmapImageRep) throws -> Data {
    guard let image = representation.cgImage else { throw IconTestError.missingCGImage }
    let width = representation.pixelsWide
    let height = representation.pixelsHigh
    var rgba = Data(count: width * height * 4)
    let created = rgba.withUnsafeMutableBytes { bytes -> Bool in
        guard let context = CGContext(
            data: bytes.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard created else { throw IconTestError.contextCreationFailed }
    return rgba
}

private func alphaBounds(in rgba: Data, width: Int, height: Int) -> IconAlphaBounds? {
    var minX = width
    var minY = height
    var maxX = -1
    var maxY = -1
    rgba.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
        for y in 0..<height {
            for x in 0..<width where bytes[(y * width + x) * 4 + 3] > 0 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
    }
    guard maxX >= 0 else { return nil }
    return IconAlphaBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
}

private func normalizedRMSE(_ lhs: Data, _ rhs: Data) -> Double {
    guard lhs.count == rhs.count, !lhs.isEmpty else { return .infinity }
    var squaredError = 0.0
    lhs.withUnsafeBytes { (left: UnsafeRawBufferPointer) in
        rhs.withUnsafeBytes { (right: UnsafeRawBufferPointer) in
            for index in 0..<left.count {
                let difference = Double(left[index]) - Double(right[index])
                squaredError += difference * difference
            }
        }
    }
    return sqrt(squaredError / Double(lhs.count)) / 255.0
}

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

    var sourcePixels: [String: Data] = [:]

    for (name, pixels) in expected {
        let data = try Data(contentsOf: resources.appendingPathComponent("AppIcon.iconset/\(name)"))
        let representation = try #require(NSBitmapImageRep(data: data))
        #expect(representation.pixelsWide == pixels)
        #expect(representation.pixelsHigh == pixels)
        #expect(representation.hasAlpha)
        for point in [
            NSPoint(x: 0, y: 0),
            NSPoint(x: pixels - 1, y: 0),
            NSPoint(x: 0, y: pixels - 1),
            NSPoint(x: pixels - 1, y: pixels - 1),
        ] {
            #expect(try #require(representation.colorAt(x: Int(point.x), y: Int(point.y))).alphaComponent <= 1.0 / 255.0)
        }
        #expect(
            try #require(
                representation.colorAt(x: pixels / 2, y: pixels / 2)
            ).alphaComponent > 0.99
        )
        let rgba = try canonicalRGBA(representation)
        sourcePixels[name] = rgba
        if pixels == 1_024 {
            let bounds = try #require(alphaBounds(in: rgba, width: pixels, height: pixels))
            #expect(bounds.width == 863)
            #expect(bounds.height == 865)
            #expect(abs((bounds.minX + bounds.maxX) - (pixels - 1)) <= 1)
            #expect(abs((bounds.minY + bounds.maxY) - (pixels - 1)) <= 1)
        }
    }

    let iconURL = resources.appendingPathComponent("Duckpad.icns")
    let iconData = try Data(contentsOf: iconURL)
    #expect(iconData.starts(with: Data("icns".utf8)))
    let icon = try #require(NSImage(contentsOf: iconURL))
    let pixelSizes = Set(icon.representations.map { $0.pixelsWide })
    #expect(pixelSizes.contains(16))
    #expect(pixelSizes.contains(1024))

    let extractedRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("duckpad-icon-roundtrip-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: extractedRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: extractedRoot) }
    let extractedSet = extractedRoot.appendingPathComponent("AppIcon.iconset", isDirectory: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "iconset", iconURL.path, "-o", extractedSet.path]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)

    for (name, pixels) in expected {
        let extractedData = try Data(contentsOf: extractedSet.appendingPathComponent(name))
        let extracted = try #require(NSBitmapImageRep(data: extractedData))
        #expect(extracted.pixelsWide == pixels)
        #expect(extracted.pixelsHigh == pixels)
        let extractedPixels = try canonicalRGBA(extracted)
        let originalPixels = try #require(sourcePixels[name])
        if name == "icon_16x16.png" || name == "icon_32x32.png" {
            // iconutil stores these 1x slots as legacy ic04/ic05 ARGB chunks,
            // which quantize edge pixels. Bound that platform transform while
            // requiring identical occupied bounds; modern PNG chunks are exact.
            #expect(normalizedRMSE(extractedPixels, originalPixels) < 0.035)
            #expect(
                alphaBounds(in: extractedPixels, width: pixels, height: pixels)
                    == alphaBounds(in: originalPixels, width: pixels, height: pixels)
            )
        } else {
            #expect(extractedPixels == originalPixels)
        }
    }
}
