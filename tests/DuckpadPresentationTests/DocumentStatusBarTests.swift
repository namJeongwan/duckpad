import AppKit
import DuckpadApplication
@testable import DuckpadPresentation
import Testing

@Suite(.serialized)
struct DocumentStatusBarTests {
    @Test @MainActor func familiarStatusFieldsKeepTheirOrderInBothAppearances() throws {
        _ = NSApplication.shared
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let bar = DocumentStatusBarView(frame: NSRect(x: 0, y: 0, width: 1080, height: 24))
            let window = NSWindow(contentRect: bar.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = bar
            defer { window.contentView = nil; window.close() }
            let language = StatusBarButton(title: "Text", target: nil, action: nil)
            let encoding = StatusBarButton(title: "UTF-8", target: nil, action: nil)
            bar.install(language: language, encoding: encoding)
            bar.apply(.init(length: 27, lines: 1, line: 1, column: 10,
                            selectedCharacters: 0, selectedLines: 0, isOvertype: false))
            bar.layoutSubtreeIfNeeded()
            let fields: [NSView] = [language, bar.lengthLabel, bar.positionButton, bar.lineEndingButton, encoding, bar.modeButton]
            #expect(fields.map(\.frame.minX) == fields.map(\.frame.minX).sorted())
            #expect(fields.allSatisfy { bar.bounds.contains($0.frame) })
            #expect(bar.lengthLabel.stringValue == "Length: 27   Lines: 1")
            #expect(bar.positionButton.title == "Ln: 1   Col: 10   Sel: 0 | 0")
            #expect(bar.lineEndingButton.title == "Unix (LF)")
            #expect(bar.modeButton.title == "INS")
            let event = try #require(NSEvent.mouseEvent(
                with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 0, pressure: 0
            ))
            for button in [language, bar.positionButton, bar.lineEndingButton, encoding, bar.modeButton] {
                button.mouseExited(with: event)
                let resting = button.layer?.backgroundColor
                button.mouseEntered(with: event)
                let hovered = button.layer?.backgroundColor
                #expect(hovered != resting)
                let hoverCGColor = try #require(hovered)
                let hoverColor = try #require(NSColor(cgColor: hoverCGColor)?.usingColorSpace(.deviceRGB))
                // Contrast follows the hosted window, even when the system
                // appearance differs from this test's explicit appearance.
                #expect(appearance == .aqua ? hoverColor.redComponent < 0.5 : hoverColor.redComponent > 0.5)
                button.highlight(true)
                #expect(button.layer?.backgroundColor != hovered)
                button.highlight(false)
                button.isEnabled = false
                #expect(button.layer?.backgroundColor == resting)
                button.isEnabled = true
                button.mouseExited(with: event)
                #expect(button.layer?.backgroundColor == resting)
            }
            bar.lineEndingButton.mouseEntered(with: event)
            if let directory = ProcessInfo.processInfo.environment["DUCKPAD_CHROME_TEST_IMAGES"] {
                let bitmap = try #require(bar.bitmapImageRepForCachingDisplay(in: bar.bounds))
                bar.cacheDisplay(in: bar.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                let destination = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try png.write(to: destination.appendingPathComponent("status-\(appearance == .aqua ? "light" : "dark").png"))
            }
        }
    }
}
